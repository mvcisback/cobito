//! Step 6 of the prose pipeline: KaTeX at weave time (SPEC.md §6.3).
//!
//! Rendering is server-side so the archival site needs no JavaScript. The
//! `katex` crate drives a bundled JS engine, which is slow enough that every
//! result is cached on disk keyed by a content hash — otherwise re-rendering
//! every equation on every weave dominates build time.

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
/// a cache key that silently changes would quietly cost a full re-render.
fn hash(s: &str, display: bool) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes().chain(std::iter::once(display as u8)) {
        h ^= b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{h:016x}")
}

pub struct Renderer {
    dir: Option<PathBuf>,
}

impl Renderer {
    /// A cache that cannot be created is not fatal; weaving just gets slower.
    pub fn new(cache_root: &Path) -> Self {
        let dir = cache_root.join("math");
        Renderer {
            dir: std::fs::create_dir_all(&dir).ok().map(|()| dir),
        }
    }

    pub fn render_all(&self, math: &[Math]) -> Result<Vec<String>, MathError> {
        math.iter().map(|m| self.render(m)).collect()
    }

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
        let d = std::env::temp_dir().join(format!("lit-math-test-{name}"));
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
