//! Step 6 of the prose pipeline: KaTeX at weave time (§6.3).
//!
//! Rendering is server-side so the math needs no client JavaScript. The
//! `katex` crate drives a bundled JS engine, which is slow enough that every
//! result is cached on disk keyed by a content hash — otherwise re-rendering
//! every equation on every weave dominates build time.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::path::{Path, PathBuf};

use crate::prose::Math;

#[derive(Debug)]
pub struct MathError {
    pub source: String,
    pub message: String,
}

impl fmt::Display for MathError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "error[E020]: math failed to render: {}\n  = source: {}",
            self.message, self.source
        )
    }
}

impl std::error::Error for MathError {}

/// FNV-1a. Stable across toolchains, which `DefaultHasher` does not promise —
/// a cache key that silently changes would quietly cost a full re-render. The
/// macro map is folded in (sorted, since it is a `BTreeMap`), so editing a macro
/// invalidates every formula that could use it (§6.4).
fn hash(s: &str, display: bool, macros: &BTreeMap<String, String>) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut byte = |b: u8| {
        h ^= b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    };
    s.bytes().for_each(&mut byte);
    byte(display as u8);
    for (k, v) in macros {
        k.bytes().for_each(&mut byte);
        byte(b'=');
        v.bytes().for_each(&mut byte);
        byte(b';');
    }
    format!("{h:016x}")
}

pub struct Renderer {
    dir: Option<PathBuf>,
    /// The document macro table: name → expansion, from every `macros` fence
    /// (§6.4) plus the content-id macros of every import (§13). It goes through
    /// KaTeX's `macros` option, *not* prepended to the source, so a formula's
    /// copy-paste annotation stays just the formula.
    macros: BTreeMap<String, String>,
    /// `alias.name` → `\<content-id>` for imported macros (§13). The renderer
    /// rewrites `\alias.name` in a formula to the id before KaTeX.
    rewrites: BTreeMap<String, String>,
}

impl Renderer {
    /// A cache that cannot be created is not fatal; weaving just gets slower. The
    /// macro table is every `macros` fence's definitions (name → expansion, §6.4),
    /// passed to KaTeX's `macros` option so the formula source stays clean.
    pub fn new(
        cache_root: &Path,
        macros: &BTreeMap<String, String>,
        rewrites: &BTreeMap<String, String>,
    ) -> Self {
        let dir = cache_root.join("math");
        Renderer {
            dir: std::fs::create_dir_all(&dir).ok().map(|()| dir),
            macros: macros.clone(),
            rewrites: rewrites.clone(),
        }
    }

    /// Rewrite each `\alias.name` to its imported macro's content id (§13), so KaTeX
    /// sees a plain, letters-only control word. The alias is a letter then
    /// alphanumerics (so a versioned alias like `alg2` works); the macro name is a
    /// KaTeX control word (letters). The alias never reaches KaTeX — it is replaced by
    /// the content id — so a digit in the alias is fine. The scan matches a whole
    /// token, so `\alg.RR` and `\alg.RRR` never confuse; a `\alias.name` with no import
    /// is left as written.
    fn apply_rewrites(&self, src: &str) -> String {
        if self.rewrites.is_empty() {
            return src.to_string();
        }
        let mut out = String::new();
        let mut rest = src;
        while let Some(p) = rest.find('\\') {
            out.push_str(&rest[..p]);
            let after = &rest[p + 1..];
            // The alias must start with a letter, then may carry digits (`alg2`).
            let starts_alpha = after.chars().next().is_some_and(|c| c.is_ascii_alphabetic());
            let a = after.chars().take_while(|c| c.is_ascii_alphanumeric()).count();
            if starts_alpha && after[a..].starts_with('.') {
                let tail = &after[a + 1..];
                let b = tail.chars().take_while(|c| c.is_ascii_alphabetic()).count();
                if b > 0 {
                    let key = format!("{}.{}", &after[..a], &tail[..b]);
                    if let Some(id) = self.rewrites.get(&key) {
                        out.push_str(id);
                        rest = &tail[b..];
                        continue;
                    }
                }
            }
            out.push('\\');
            rest = after;
        }
        out.push_str(rest);
        out
    }

    pub fn render_all(&self, math: &[Math]) -> Result<Vec<String>, MathError> {
        math.iter().map(|m| self.render(m)).collect()
    }

    fn render(&self, m: &Math) -> Result<String, MathError> {
        // Rewrite any `\alias.name` import reference to its content id (§13) first; the
        // cache key is the actual KaTeX input.
        let source = self.apply_rewrites(&m.source);
        let path = self
            .dir
            .as_ref()
            .map(|d| d.join(format!("{}.html", hash(&source, m.display, &self.macros))));
        if let Some(p) = &path {
            if let Ok(cached) = std::fs::read_to_string(p) {
                return Ok(cached);
            }
        }

        // The macros go through KaTeX's `macros` option, never prepended to the source
        // (§6.4), so the formula's `<annotation>` — the copy-paste TeX — stays just the
        // formula, with no `\def` preamble leaking into it.
        let macros: HashMap<String, String> = self
            .macros
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let opts = katex::Opts::builder()
            .display_mode(m.display)
            .macros(macros)
            .build()
            .map_err(|e| MathError {
                source: m.source.clone(),
                message: e.to_string(),
            })?;
        // Hard error, never a silent fallback to raw text (§6.3).
        let out = katex::render_with_opts(&source, &opts).map_err(|e| MathError {
            source: m.source.clone(),
            message: e.to_string(),
        })?;

        if let Some(p) = &path {
            write_atomic(p, &out);
        }
        Ok(out)
    }
}

/// Write via a unique temp file and rename, so a concurrent weave never reads a
/// half-written cache entry (which would make output non-deterministic). Best
/// effort: a failed cache write only costs a re-render.
fn write_atomic(path: &Path, contents: &str) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp.{}.{n}", std::process::id()));
    if std::fs::write(&tmp, contents).is_ok() && std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cob-math-test-{name}"));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn defs(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn renders_inline_and_display() {
        let r = Renderer::new(&tmpdir("render"), &BTreeMap::new(), &BTreeMap::new());
        let out = r
            .render_all(&[
                Math {
                    source: r"O(n \log n)".into(),
                    display: false,
                },
                Math {
                    source: "a < b".into(),
                    display: true,
                },
            ])
            .expect("fixture math renders");
        assert!(out[0].contains("katex"));
        assert!(out[1].contains("katex-display"));
        // `<` must survive as an entity, not as a stray tag.
        assert!(!out[1].contains("< b"));
    }

    #[test]
    fn cache_hit_returns_identical_bytes() {
        let dir = tmpdir("cache");
        let m = Math {
            source: r"\frac{1}{2}".into(),
            display: false,
        };
        let first = Renderer::new(&dir, &BTreeMap::new(), &BTreeMap::new())
            .render_all(std::slice::from_ref(&m))
            .unwrap();
        assert!(dir.join("math").read_dir().unwrap().count() > 0);
        // Second Renderer reads from disk rather than the JS engine.
        let second = Renderer::new(&dir, &BTreeMap::new(), &BTreeMap::new())
            .render_all(std::slice::from_ref(&m))
            .unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn display_mode_is_part_of_the_key() {
        assert_ne!(hash("x", true, &BTreeMap::new()), hash("x", false, &BTreeMap::new()));
    }

    #[test]
    fn macros_are_part_of_the_key() {
        // Editing a macro must invalidate the cache, so the macro table is hashed.
        assert_ne!(
            hash("\\RR", false, &BTreeMap::new()),
            hash("\\RR", false, &defs(&[("\\RR", "\\mathbb{R}")]))
        );
    }

    #[test]
    fn macros_expand_and_do_not_leak_into_the_annotation() {
        // A macro in the table expands the formula, so `\RR` renders instead of
        // failing as an unknown control sequence.
        let r = Renderer::new(&tmpdir("macros"), &defs(&[("\\RR", "\\mathbb{R}")]), &BTreeMap::new());
        let out = &r
            .render_all(&[Math {
                source: "\\RR".into(),
                display: false,
            }])
            .expect("a macro from the table expands")[0];
        assert!(out.contains("katex"));
        // The macro goes through KaTeX's `macros` option, NOT prepended to the
        // source — so the copy-paste annotation is just the formula, with no
        // definition leaking in. This is the modularity guard (§6.4).
        assert!(out.contains("<annotation encoding=\"application/x-tex\">\\RR</annotation>"));
        assert!(!out.contains("\\def"));
        assert!(!out.contains("\\mathbb"));
        // Without the macro, `\RR` is undefined and KaTeX errors (E020).
        let bare = Renderer::new(&tmpdir("macros-bare"), &BTreeMap::new(), &BTreeMap::new());
        assert!(bare
            .render_all(&[Math {
                source: "\\RR".into(),
                display: false,
            }])
            .is_err());
    }

    #[test]
    fn a_versioned_alias_with_a_digit_rewrites_to_its_content_id() {
        // An import alias may carry a digit (`alg2`), e.g. two versions of one
        // forest. `\alg2.RR` is rewritten to the letters-only content id before
        // KaTeX, which only ever sees the id (§13).
        let mut rewrites = BTreeMap::new();
        rewrites.insert("alg2.RR".to_string(), "\\aliasid".to_string());
        let r = Renderer::new(
            &tmpdir("digit-alias"),
            &defs(&[("\\aliasid", "\\mathbb{R}")]),
            &rewrites,
        );
        let out = &r
            .render_all(&[Math {
                source: "\\alg2.RR".into(),
                display: false,
            }])
            .expect("a digit-bearing alias is recognized and rewritten")[0];
        assert!(out.contains("katex"));
        // KaTeX never saw `\alg2` — the alias was rewritten to the content id, so
        // the scanner recognized it despite the digit.
        assert!(!out.contains("alg2"));
    }

    #[test]
    fn bad_math_is_e020() {
        let r = Renderer::new(&tmpdir("bad"), &BTreeMap::new(), &BTreeMap::new());
        let err = r
            .render_all(&[Math {
                source: r"\frac{1".into(),
                display: false,
            }])
            .unwrap_err();
        assert!(err.to_string().starts_with("error[E020]"));
    }
}
