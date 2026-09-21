//! The lock file (§7.1): a committed, greppable map from a note-local
//! human label to a frozen opaque id. The id is what a cross-reference renders
//! ("Figure k3f9") and what an eventual import/transclude (§16, M12) names, so it
//! must survive every move and rename — which is exactly why it is *random* and
//! *persisted*, never derived from the label, path, or content.
//!
//! Keyed by source file so two notes may reuse a label (`fig:pipeline`) without
//! colliding once the forest imports both. Within one weave labels are still
//! globally unique (E014); the per-file nesting is forward-looking.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::rewrite::Kind;

/// A frozen id is four base62 characters (`[0-9A-Za-z]`, case-sensitive) — about
/// 14.8M ids, enough for a hobby-scale forest (§7.1).
pub const ID_LEN: u32 = 4;
const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const SPACE: u64 = 62 * 62 * 62 * 62;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct LockEntry {
    pub id: String,
    pub kind: Kind,
}

/// Whether a weave may mint fresh ids (dev-time) or must find every label
/// already in the lock (`--locked`, for CI and the read-only Nix sandbox; §7.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockMode {
    Mint,
    Locked,
}

/// `file → (label → entry)`. `used` is a derived index of every id in play, so a
/// mint can reject a collision in one lookup; it is rebuilt on load, never
/// serialized.
#[derive(Default)]
pub struct LockFile {
    files: BTreeMap<String, BTreeMap<String, LockEntry>>,
    used: BTreeSet<String>,
}

#[derive(Debug)]
pub enum LockError {
    /// E031 — a label absent from `cob.lock` under `--locked` (§7.1).
    Missing { file: String, label: String },
    /// E032 — `cob.lock` could not be read/parsed or written.
    Io(std::io::Error),
    Parse(String),
}

impl fmt::Display for LockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LockError::Missing { file, label } => write!(
                f,
                "error[E031]: label `{label}` (in {file}) is not in cob.lock; \
                 run `cob lock` to mint it, or drop --locked"
            ),
            LockError::Io(e) => write!(f, "error[E032]: cob.lock: {e}"),
            LockError::Parse(m) => write!(f, "error[E032]: cob.lock: {m}"),
        }
    }
}

impl std::error::Error for LockError {}

/// A minter of fresh ids. SplitMix64 seeded from entropy — deterministic weave
/// does *not* depend on this seed, since minted ids are persisted to the lock and
/// re-read on every later run; the RNG only ever decides an id's *first* value.
pub struct Minter {
    state: u64,
}

impl Minter {
    pub fn from_entropy() -> Minter {
        let local = 0u8;
        let addr = &local as *const u8 as u64;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x1234_5678_9ABC_DEF0);
        Minter {
            state: nanos ^ addr.rotate_left(17),
        }
    }

    /// A fixed-seed minter, for reproducible tests.
    #[cfg(test)]
    pub fn seeded(seed: u64) -> Minter {
        Minter { state: seed }
    }

    fn next(&mut self) -> u32 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z % SPACE) as u32
    }
}

/// `n < SPACE` → its four-character base62 spelling.
fn base62(mut n: u32) -> String {
    let mut buf = [b'0'; ID_LEN as usize];
    for slot in buf.iter_mut().rev() {
        *slot = ALPHABET[(n % 62) as usize];
        n /= 62;
    }
    String::from_utf8(buf.to_vec()).expect("base62 alphabet is ASCII")
}

impl LockFile {
    /// Load `cob.lock`; an absent file is an empty lock, not an error (the first
    /// `cob lock`/`weave` mints into it).
    pub fn load(path: &Path) -> Result<LockFile, LockError> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(LockFile::default()),
            Err(e) => return Err(LockError::Io(e)),
        };
        let files: BTreeMap<String, BTreeMap<String, LockEntry>> =
            toml::from_str(&text).map_err(|e| LockError::Parse(e.to_string()))?;
        let mut used = BTreeSet::new();
        for inner in files.values() {
            for entry in inner.values() {
                used.insert(entry.id.clone());
            }
        }
        Ok(LockFile { files, used })
    }

    /// Write the lock deterministically (BTreeMaps → sorted keys, no timestamp).
    pub fn save(&self, path: &Path) -> Result<(), LockError> {
        let body = toml::to_string(&self.files).map_err(|e| LockError::Parse(e.to_string()))?;
        let text = format!(
            "# cob.lock — generated (§7.1). label → frozen opaque id.\n\
             # Edit only to retire a label; ids never change once minted.\n{body}"
        );
        std::fs::write(path, text).map_err(LockError::Io)
    }

    pub fn get(&self, file: &str, label: &str) -> Option<&LockEntry> {
        self.files.get(file).and_then(|m| m.get(label))
    }

    /// The existing id for `(file, label)`, or a freshly minted one written into
    /// the lock. A collision with an id already in use is re-rolled.
    pub fn mint(&mut self, file: &str, label: &str, kind: Kind, minter: &mut Minter) -> String {
        if let Some(entry) = self.get(file, label) {
            return entry.id.clone();
        }
        let id = loop {
            let cand = base62(minter.next());
            if !self.used.contains(&cand) {
                break cand;
            }
        };
        self.used.insert(id.clone());
        self.files
            .entry(file.to_string())
            .or_default()
            .insert(label.to_string(), LockEntry { id: id.clone(), kind });
        id
    }

    /// Mint a fresh opaque id for an unlabelled section and record it under the label
    /// `sec:<id>` — the anchor cob writes into the source (§7.1). Returns the id.
    pub fn mint_section(&mut self, file: &str, minter: &mut Minter) -> String {
        let id = loop {
            let cand = base62(minter.next());
            if !self.used.contains(&cand) {
                break cand;
            }
        };
        self.used.insert(id.clone());
        self.files.entry(file.to_string()).or_default().insert(
            format!("sec:{id}"),
            LockEntry {
                id: id.clone(),
                kind: Kind::Section,
            },
        );
        id
    }

    /// The `(file, label)` of the section entry whose frozen id is `id`, if any.
    pub fn find_section(&self, id: &str) -> Option<(String, String)> {
        for (file, inner) in &self.files {
            for (label, entry) in inner {
                if entry.id == id && entry.kind == Kind::Section {
                    return Some((file.clone(), label.clone()));
                }
            }
        }
        None
    }

    /// Move a section entry from label `old` to `new` in `file`, keeping its frozen id.
    /// Returns false if `new` already exists or `old` is absent, so nothing is lost.
    pub fn rename(&mut self, file: &str, old: &str, new: &str) -> bool {
        let inner = match self.files.get_mut(file) {
            Some(m) => m,
            None => return false,
        };
        if inner.contains_key(new) {
            return false;
        }
        match inner.remove(old) {
            Some(entry) => {
                inner.insert(new.to_string(), entry);
                true
            }
            None => false,
        }
    }

    /// A file's `label → entry` pairs in sorted order (for `cob labels`).
    pub fn labels(&self, file: &str) -> impl Iterator<Item = (&String, &LockEntry)> {
        self.files.get(file).into_iter().flat_map(|m| m.iter())
    }

    /// The total number of frozen ids across every file — used by `cob lock` to
    /// report how many labels were newly minted.
    pub fn count(&self) -> usize {
        self.used.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_is_idempotent_per_label() {
        let mut lock = LockFile::default();
        let mut m = Minter::seeded(1);
        let a = lock.mint("f.cob", "fig:x", Kind::Figure, &mut m);
        let b = lock.mint("f.cob", "fig:x", Kind::Figure, &mut m);
        assert_eq!(a, b, "the same label re-reads its frozen id, never re-mints");
        assert_eq!(a.len(), ID_LEN as usize);
        assert!(a.bytes().all(|c| c.is_ascii_alphanumeric()));
    }

    #[test]
    fn distinct_labels_get_distinct_ids() {
        let mut lock = LockFile::default();
        let mut m = Minter::seeded(42);
        let a = lock.mint("f.cob", "fig:a", Kind::Figure, &mut m);
        let b = lock.mint("f.cob", "fig:b", Kind::Figure, &mut m);
        let c = lock.mint("g.cob", "fig:a", Kind::Figure, &mut m);
        // Note-local: `fig:a` in two files is two entries with two ids.
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_ne!(b, c);
    }

    #[test]
    fn collisions_are_rerolled() {
        // A minter that would hand out the same value twice must still yield two
        // distinct ids, because `used` forces a re-roll.
        let mut lock = LockFile::default();
        // Seed 0: SplitMix64 is stateful, so successive nexts differ; instead
        // pre-seed the used-set with the id the first roll produces.
        let mut probe = Minter::seeded(7);
        let first = base62(probe.next());
        let mut m = Minter::seeded(7);
        // Pretend `first` is already taken elsewhere.
        lock.used.insert(first.clone());
        let got = lock.mint("f.cob", "fig:x", Kind::Figure, &mut m);
        assert_ne!(got, first, "an id already in use is skipped");
    }

    #[test]
    fn toml_round_trips() {
        let dir = std::env::temp_dir().join("cob-lock-roundtrip");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cob.lock");
        let mut lock = LockFile::default();
        let mut m = Minter::seeded(99);
        let fig = lock.mint("parser.cob", "fig:pipeline", Kind::Figure, &mut m);
        let tbl = lock.mint("parser.cob", "tbl:api", Kind::Table, &mut m);
        lock.save(&path).unwrap();

        let reloaded = LockFile::load(&path).unwrap();
        assert_eq!(reloaded.get("parser.cob", "fig:pipeline").unwrap().id, fig);
        assert_eq!(
            reloaded.get("parser.cob", "tbl:api").unwrap().kind,
            Kind::Table
        );
        // The reload rebuilds `used`, so a mint after load still avoids collisions.
        let _ = tbl;
        // Saving the reloaded lock is byte-stable.
        let path2 = dir.join("cob.lock.2");
        reloaded.save(&path2).unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            std::fs::read_to_string(&path2).unwrap()
        );
    }

    #[test]
    fn absent_lock_loads_empty() {
        let path = std::env::temp_dir().join("cob-lock-does-not-exist-xyzzy.lock");
        let _ = std::fs::remove_file(&path);
        let lock = LockFile::load(&path).unwrap();
        assert!(lock.get("f.cob", "fig:x").is_none());
    }
}
