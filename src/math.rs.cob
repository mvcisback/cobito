# Math rendering (§6.3)

This module is the specification and the implementation of math rendering. The
prose is the specification. The chunks after it are the implementation. It is
step 6 of the prose pipeline (§6.2).

## The rule {#sec:sHOO}

cob renders KaTeX server-side, at weave time, so the content of the archival site
needs no JavaScript. Every equation, code chunk, cross-reference, and float is
inert markup that a reader reads with script off. A render failure is a hard error
with the source and the location, never a silent fall back to raw text.

The site carries exactly one script: the `nav-spy` navigation aid in `page.html`
(§5.3). It is progressive enhancement — it marks the section the reader is on and
scrolls the nav to it, and nothing else. It injects no content text, so copy-paste
and the annotation quote selectors (§9.2) still hold, and the page reads fully
without it. So the rule is not "no script"; it is "no script the content depends
on". cob still links no CDN and ships every byte in `_site`, so the archive stays
self-contained. The script is inline and identical on every page, so the weave
stays byte-deterministic.

## The engine and the cache {#sec:PzZ2}

The `katex` Rust crate bundles a JS engine to run `katex.js`. This adds real
build weight and Nix-closure cost. The alternatives are worse: a `katex` CLI is
another runtime dependency, and a native Rust math renderer is immature. cob
takes the crate and caches each rendered result under
`hash(math_source + display_mode + macros)` in `.cob-cache`. Without the cache,
re-rendering every equation on every weave would dominate build time.

## Why the assets are not optional {#sec:iVXH}

"Math needs no client-side JavaScript" and "no client-side assets" are different
claims. cob gets the first for free and must work for the second (verified
2026-08-23):

- The crate runs `katex.js` inside the cob binary at weave time. The output is
  inert markup: a hidden `katex-mathml` span that carries MathML, plus a
  `katex-html` visual span. No math script reaches the site — the only script is
  the `nav-spy` aid (§6.3, above), which math does not touch. `checks.determinism`
  asserts the page carries no script beyond it.
- The default output needs `katex.min.css` and the woff2 fonts for correctness,
  not for looks. The stylesheet is what hides the MathML layer. Without it both
  layers render and every equation appears twice.
- So cob copies the assets into `_site/katex`, and never links a CDN. Otherwise
  the archival artifact would depend on the network in secret. cob ships woff2
  only (about 330 KB); woff and ttf would multiply that for no reader.
- Version coupling. KaTeX's HTML, CSS, and font metrics move together. The crate
  embeds KaTeX 0.16.4, while nixpkgs' `katex` is a different release, so the
  assets are pinned in `flake.nix` by `fetchzip` at the crate's version and
  exposed as `COB_KATEX_ASSETS`. Bump the crate and the pin together.

## Considered and rejected {#sec:1uIU}

Pure-MathML output needs no CSS, no fonts, and no JS — a genuine single-file
artifact. cob rejects it for v1, because browser-native math typography is much
weaker than KaTeX's CSS layout, and typographic quality is the point of a
Tufte-styled site. Revisit this if a zero-asset artifact ever outranks
typography. Every output mode keeps the original TeX in an annotation element,
which is what makes math copy-pasteable (relevant to `ANNOTATIONS.md` AN-2).

## How the code implements this {#sec:EqJN}

The module is five pieces: the error type, the cache-key hash, the renderer, the
atomic cache write, and the tests.
<<src/math.rs>>=
<<the module banner>>

<<imports>>

<<the math error>>

<<the cache key>>

<<the renderer>>

<<atomic cache writes>>

<<the tests>>
@
The banner states the pipeline position and the two forces that shape the module:
no client JavaScript, and a slow engine that must be cached.
<<the module banner>>=
//! Step 6 of the prose pipeline: KaTeX at weave time (§6.3).
//!
//! Rendering is server-side so the math needs no client JavaScript. The
//! `katex` crate drives a bundled JS engine, which is slow enough that every
//! result is cached on disk keyed by a content hash — otherwise re-rendering
//! every equation on every weave dominates build time.
@
Just paths, formatting, and the `Math` fragment the prose pass hands us.
<<imports>>=
use std::fmt;
use std::path::{Path, PathBuf};

use crate::prose::Math;
@
A formula KaTeX rejects is E020, and it is a hard error — never a silent fallback
to raw text (§6.3). A broken formula cannot wait for a browser that will never run.
<<the math error>>=
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
@
The key is FNV-1a, chosen because it is stable across toolchains. `DefaultHasher`
is not — a hash that silently changed between compilers would invalidate every
cache entry and force a full re-render. The display flag is folded into the hash
so inline and display forms of the same formula never share a key.
<<the cache key>>=
/// FNV-1a. Stable across toolchains, which `DefaultHasher` does not promise —
/// a cache key that silently changes would quietly cost a full re-render.
fn hash(s: &str, display: bool) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes().chain(std::iter::once(display as u8)) {
        h ^= b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{h:016x}")
}
@
The renderer holds an optional cache directory — optional because a cache that
cannot be created is not fatal; weaving just gets slower. `render_all` maps over a
batch; `render` does the work.
<<the renderer>>=
pub struct Renderer {
    dir: Option<PathBuf>,
}

impl Renderer {
    <<create the renderer>>

    <<render a batch>>

    <<render one formula>>
}
@
Creating the cache directory is best-effort: on failure `dir` stays `None` and the
renderer simply runs uncached.
<<create the renderer>>=
/// A cache that cannot be created is not fatal; weaving just gets slower.
pub fn new(cache_root: &Path) -> Self {
    let dir = cache_root.join("math");
    Renderer {
        dir: std::fs::create_dir_all(&dir).ok().map(|()| dir),
    }
}
@
One formula at a time, short-circuiting on the first error.
<<render a batch>>=
pub fn render_all(&self, math: &[Math]) -> Result<Vec<String>, MathError> {
    math.iter().map(|m| self.render(m)).collect()
}
@
The cache key names a file. A hit returns its bytes verbatim. A miss builds KaTeX
options, renders, and — the deliberate choice — maps any KaTeX failure to E020
rather than falling back to raw text. The fresh result is written back through the
atomic writer.
<<render one formula>>=
fn render(&self, m: &Math) -> Result<String, MathError> {
    let path = self
        .dir
        .as_ref()
        .map(|d| d.join(format!("{}.html", hash(&m.source, m.display))));
    if let Some(p) = &path {
        if let Ok(cached) = std::fs::read_to_string(p) {
            return Ok(cached);
        }
    }

    let opts = katex::Opts::builder()
        .display_mode(m.display)
        .build()
        .map_err(|e| MathError {
            source: m.source.clone(),
            message: e.to_string(),
        })?;
    // Hard error, never a silent fallback to raw text (§6.3).
    let out = katex::render_with_opts(&m.source, &opts).map_err(|e| MathError {
        source: m.source.clone(),
        message: e.to_string(),
    })?;

    if let Some(p) = &path {
        write_atomic(p, &out);
    }
    Ok(out)
}
@
The write goes through a unique temp file and a rename, so a concurrent weave never
reads a half-written entry — a torn read would make output non-deterministic. It is
best-effort: a failed write only costs a re-render.
<<atomic cache writes>>=
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
@
The tests pin the contract: inline and display both render, the less-than sign
survives as an entity rather than a stray tag, a second renderer reads identical
bytes from disk, the display flag is part of the key, and bad math is E020.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cob-math-test-{name}"));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn renders_inline_and_display() {
        let r = Renderer::new(&tmpdir("render"));
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
        let first = Renderer::new(&dir)
            .render_all(std::slice::from_ref(&m))
            .unwrap();
        assert!(dir.join("math").read_dir().unwrap().count() > 0);
        // Second Renderer reads from disk rather than the JS engine.
        let second = Renderer::new(&dir)
            .render_all(std::slice::from_ref(&m))
            .unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn display_mode_is_part_of_the_key() {
        assert_ne!(hash("x", true), hash("x", false));
    }

    #[test]
    fn bad_math_is_e020() {
        let r = Renderer::new(&tmpdir("bad"));
        let err = r
            .render_all(&[Math {
                source: r"\frac{1".into(),
                display: false,
            }])
            .unwrap_err();
        assert!(err.to_string().starts_with("error[E020]"));
    }
}
@
