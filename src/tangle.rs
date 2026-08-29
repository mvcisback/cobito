//! `lit tangle`: extract compilable source from `.nw` files (§11).
//!
//! Tangling is the inverse of weaving — it pulls a root chunk (and everything
//! it references) out as a plain source file. v1 shells out to noweb's
//! `notangle`, which is correct by construction; we never reimplement it (§11).
//!
//! Line pragmas (`notangle -L`) are per-root and off by default: the marker
//! syntax is per-language, so `lit.toml` sets a `line-pragma` format string per
//! root (§5.2). A root with no configured format tangles without
//! pragmas, which is the spec's default.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug)]
pub enum TangleError {
    /// `notangle` could not be spawned — almost always a PATH problem.
    Spawn(std::io::Error),
    /// Nonzero exit; stderr carries noweb's own `file:line: message`.
    Failed { root: String, stderr: String },
    /// Writing a tangled root to disk failed.
    Write { path: PathBuf, source: std::io::Error },
}

impl fmt::Display for TangleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TangleError::Spawn(e) => write!(
                f,
                "error[E027]: could not run `notangle` ({e}); it ships with noweb \
                 — run inside the dev shell or the wrapped package"
            ),
            TangleError::Failed { root, stderr } => write!(
                f,
                "error[E027]: notangle failed for root `{root}`:\n{}",
                stderr.trim_end()
            ),
            TangleError::Write { path, source } => write!(
                f,
                "error[E028]: writing tangled output to {} failed: {source}",
                path.display()
            ),
        }
    }
}

impl std::error::Error for TangleError {}

/// Tangle a single root chunk to a string via `notangle -R <root> <files…>`.
///
/// The binary is found on `PATH` (override with `LIT_NOTANGLE`). `notangle`
/// runs its own `markup | nt` pipeline internally, so no pre-pass is needed.
///
/// `pragma` is the per-root `-L` format from `lit.toml` (§5.2); `None` emits no
/// line pragmas. Like `-R`, the format is glued to the flag (`-L<fmt>`).
pub fn tangle_root<S: AsRef<OsStr>>(
    root: &str,
    files: &[S],
    pragma: Option<&str>,
) -> Result<String, TangleError> {
    let bin = std::env::var("LIT_NOTANGLE").unwrap_or_else(|_| "notangle".to_string());
    let mut cmd = Command::new(bin);
    // notangle wants the root name glued to the flag (`-Rname`); a separate
    // `-R name` argument is silently treated as an input file (verified §4.2).
    cmd.arg(format!("-R{root}"));
    if let Some(fmt) = pragma {
        cmd.arg(format!("-L{fmt}"));
    }
    let output = cmd.args(files).output().map_err(TangleError::Spawn)?;
    if !output.status.success() {
        return Err(TangleError::Failed {
            root: root.to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// What happened to one root when writing a whole document to disk.
#[derive(Debug, PartialEq, Eq)]
pub enum Wrote {
    Created,
    Updated,
    /// On-disk bytes already matched — left untouched so mtime-watchers stay
    /// quiet (noweb ships `cpif` for exactly this; §11).
    Unchanged,
}

/// Tangle every root to `outdir`, skipping any whose content is unchanged.
/// Returns `(root, outcome)` in the order given, for a deterministic report.
/// `pragmas` maps a root name to its `-L` format (§5.2); absent ⇒ no pragmas.
pub fn tangle_to_dir<S: AsRef<OsStr>>(
    roots: &[&str],
    files: &[S],
    outdir: &Path,
    pragmas: &BTreeMap<String, String>,
) -> Result<Vec<(String, Wrote)>, TangleError> {
    let mut report = Vec::with_capacity(roots.len());
    for &root in roots {
        let content = tangle_root(root, files, pragmas.get(root).map(String::as_str))?;
        let path = outdir.join(root);
        report.push((root.to_string(), write_if_changed(&path, &content)?));
    }
    Ok(report)
}

/// One root's disagreement with what is on disk, for `--check`.
#[derive(Debug, PartialEq, Eq)]
pub enum Drift {
    Missing,
    Differs,
}

/// Tangle every root and compare against `outdir` without writing anything.
/// Returns `(root, drift)` for each root that does not match — empty means the
/// tree is in sync (the CI / self-hosting invariant of §13).
pub fn check<S: AsRef<OsStr>>(
    roots: &[&str],
    files: &[S],
    outdir: &Path,
    pragmas: &BTreeMap<String, String>,
) -> Result<Vec<(String, Drift)>, TangleError> {
    let mut drift = Vec::new();
    for &root in roots {
        let content = tangle_root(root, files, pragmas.get(root).map(String::as_str))?;
        if let Some(d) = compare_to_disk(&content, &outdir.join(root))? {
            drift.push((root.to_string(), d));
        }
    }
    Ok(drift)
}

/// How `contents` differs from `path`, if at all. Split out so the comparison
/// is unit-testable without `notangle` on PATH (which the hermetic build lacks).
fn compare_to_disk(contents: &str, path: &Path) -> Result<Option<Drift>, TangleError> {
    match std::fs::read_to_string(path) {
        Ok(on_disk) if on_disk == contents => Ok(None),
        Ok(_) => Ok(Some(Drift::Differs)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Some(Drift::Missing)),
        Err(source) => Err(TangleError::Write {
            path: path.to_path_buf(),
            source,
        }),
    }
}

/// Write `contents` to `path` only if it differs, via a temp file and rename so
/// a watcher never sees a half-written source file (§11). Parent dirs — a root
/// name is path-shaped — are created as needed.
fn write_if_changed(path: &Path, contents: &str) -> Result<Wrote, TangleError> {
    let existing = std::fs::read_to_string(path);
    if matches!(&existing, Ok(cur) if cur == contents) {
        return Ok(Wrote::Unchanged);
    }
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
        std::fs::write(&tmp, contents)?;
        std::fs::rename(&tmp, path)
    };
    write().map_err(|source| TangleError::Write {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(if existing.is_ok() {
        Wrote::Updated
    } else {
        Wrote::Created
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // The `notangle`-driven paths (tangle_root/tangle_to_dir/check) are covered
    // by the flake's `checks.tangle`, since the hermetic cargo build has no
    // noweb on PATH. Here we unit-test the pure disk logic those paths reuse.

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("lit-tangle-test-{name}"));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn write_creates_then_reports_unchanged() {
        let dir = tmpdir("skip");
        // A path-shaped root writes through freshly-created parent dirs.
        let path = dir.join("src/main.rs");
        assert_eq!(write_if_changed(&path, "fn main() {}\n").unwrap(), Wrote::Created);
        assert_eq!(
            write_if_changed(&path, "fn main() {}\n").unwrap(),
            Wrote::Unchanged
        );
        assert_eq!(
            write_if_changed(&path, "fn main() { /* v2 */ }\n").unwrap(),
            Wrote::Updated
        );
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "fn main() { /* v2 */ }\n"
        );
    }

    #[test]
    fn compare_distinguishes_missing_identical_and_differing() {
        let dir = tmpdir("compare");
        let path = dir.join("out.rs");
        assert_eq!(
            compare_to_disk("x\n", &path).unwrap(),
            Some(Drift::Missing)
        );
        std::fs::write(&path, "x\n").unwrap();
        assert_eq!(compare_to_disk("x\n", &path).unwrap(), None);
        assert_eq!(compare_to_disk("y\n", &path).unwrap(), Some(Drift::Differs));
    }
}
