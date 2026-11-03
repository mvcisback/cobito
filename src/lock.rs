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

/// One resolved remote import (§13): the `git` URL, the author's request (`req` —
/// a semver requirement, or a raw `rev`), the resolved semver `version` (absent for
/// a `rev` import), and the commit `sha` `cob fetch` pinned to. Keyed by import
/// alias in the lock's `fetch` section, it lets a later weave read the cached index
/// offline and a `cob fetch` decide whether the pin still satisfies the request.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct FetchPin {
    pub git: String,
    pub req: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub sha: String,
}

/// Whether a weave may mint fresh ids (dev-time) or must find every label
/// already in the lock (`--locked`, for CI and the read-only Nix sandbox; §7.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockMode {
    Mint,
    Locked,
}

/// The JSON shape of `cob.lock` (§7.1): a semver schema, the `file → (label →
/// entry)` id map, and the remote-import pins (§13). `fetch` is skipped when empty
/// so a project with no imports keeps a clean file.
#[derive(Serialize, Deserialize, Default)]
struct LockDoc {
    #[serde(default = "default_schema")]
    schema: String,
    #[serde(default)]
    labels: BTreeMap<String, BTreeMap<String, LockEntry>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    fetch: BTreeMap<String, FetchPin>,
}

/// The current `cob.lock` schema (§7.1). Semver: a newer major is rejected (E038).
pub const SCHEMA: &str = "1.0.0";
const SCHEMA_MAJOR: u64 = 1;

fn default_schema() -> String {
    SCHEMA.to_string()
}

/// `file → (label → entry)`, the remote-import pins, and `used` — a derived index
/// of every id in play, so a mint can reject a collision in one lookup. `used` is
/// rebuilt on load, never serialized.
#[derive(Default, Debug)]
pub struct LockFile {
    files: BTreeMap<String, BTreeMap<String, LockEntry>>,
    fetch: BTreeMap<String, FetchPin>,
    used: BTreeSet<String>,
}

#[derive(Debug)]
pub enum LockError {
    /// E031 — a label absent from `cob.lock` under `--locked` (§7.1).
    Missing { file: String, label: String },
    /// E032 — `cob.lock` could not be read/parsed or written.
    Io(std::io::Error),
    Parse(String),
    /// E038 — `cob.lock` has a newer major schema than this cob understands.
    Schema { found: String },
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
            LockError::Schema { found } => write!(
                f,
                "error[E038]: cob.lock schema {found} is newer than this cob \
                 supports ({SCHEMA}); upgrade cob"
            ),
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
    /// `cob lock`/`weave` mints into it). The current format is JSON (§7.1); a legacy
    /// TOML label map still loads and upgrades to JSON on the next save.
    pub fn load(path: &Path) -> Result<LockFile, LockError> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(LockFile::default()),
            Err(e) => return Err(LockError::Io(e)),
        };
        let doc = Self::parse_lock(&text)?;
        Self::check_schema(&doc.schema)?;
        let mut used = BTreeSet::new();
        for inner in doc.labels.values() {
            for entry in inner.values() {
                used.insert(entry.id.clone());
            }
        }
        Ok(LockFile {
            files: doc.labels,
            fetch: doc.fetch,
            used,
        })
    }

    /// Parse the lock text: JSON first (the current format), then — as a one-version
    /// bridge — a legacy TOML `file → (label → entry)` map with no fetch pins.
    fn parse_lock(text: &str) -> Result<LockDoc, LockError> {
        if let Ok(doc) = serde_json::from_str::<LockDoc>(text) {
            return Ok(doc);
        }
        let labels: BTreeMap<String, BTreeMap<String, LockEntry>> =
            toml::from_str(text).map_err(|e| LockError::Parse(e.to_string()))?;
        Ok(LockDoc {
            schema: SCHEMA.to_string(),
            labels,
            fetch: BTreeMap::new(),
        })
    }

    /// Reject a lock whose major schema is newer than this cob understands (E038);
    /// a newer minor only adds fields cob ignores, so it is accepted. An unparseable
    /// schema is treated as the current one, so a hand-edited lock is not fatal.
    fn check_schema(schema: &str) -> Result<(), LockError> {
        match semver::Version::parse(schema) {
            Ok(v) if v.major > SCHEMA_MAJOR => Err(LockError::Schema {
                found: schema.to_string(),
            }),
            _ => Ok(()),
        }
    }

    /// Write the lock deterministically as JSON (BTreeMaps → sorted keys, no timestamp).
    pub fn save(&self, path: &Path) -> Result<(), LockError> {
        let doc = LockDoc {
            schema: SCHEMA.to_string(),
            labels: self.files.clone(),
            fetch: self.fetch.clone(),
        };
        let mut text =
            serde_json::to_string_pretty(&doc).map_err(|e| LockError::Parse(e.to_string()))?;
        text.push('\n');
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

    /// The `(file, label, entry)` whose frozen id or label name is `needle`, if any —
    /// unlike `find_section`, not restricted to `Kind::Section` (§7.1, `cob find`).
    pub fn find_label(&self, needle: &str) -> Option<(String, String, LockEntry)> {
        for (file, inner) in &self.files {
            for (label, entry) in inner {
                if entry.id == needle || label == needle {
                    return Some((file.clone(), label.clone(), entry.clone()));
                }
            }
        }
        None
    }

    /// A file's `label → entry` pairs in sorted order (for `cob labels`).
    pub fn labels(&self, file: &str) -> impl Iterator<Item = (&String, &LockEntry)> {
        self.files.get(file).into_iter().flat_map(|m| m.iter())
    }

    /// The pinned commit for a remote import alias, if `cob fetch` recorded one (§13).
    pub fn fetch_pin(&self, alias: &str) -> Option<&FetchPin> {
        self.fetch.get(alias)
    }

    /// Record (or replace) the pin for a remote import alias (§13).
    pub fn set_fetch_pin(&mut self, alias: String, pin: FetchPin) {
        self.fetch.insert(alias, pin);
    }

    /// Every import alias and its pin, in sorted order (for `cob fetch` reporting).
    pub fn fetch_pins(&self) -> impl Iterator<Item = (&String, &FetchPin)> {
        self.fetch.iter()
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
    fn json_round_trips() {
        let dir = std::env::temp_dir().join("cob-lock-roundtrip");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cob.lock");
        let mut lock = LockFile::default();
        let mut m = Minter::seeded(99);
        let fig = lock.mint("parser.cob", "fig:pipeline", Kind::Figure, &mut m);
        let tbl = lock.mint("parser.cob", "tbl:api", Kind::Table, &mut m);
        // A fetch pin rides in the same file (§13).
        lock.set_fetch_pin(
            "algebra".to_string(),
            FetchPin {
                git: "ssh://h/a.cob".to_string(),
                req: "^1.2".to_string(),
                version: Some("1.3.0".to_string()),
                sha: "deadbeef".to_string(),
            },
        );
        lock.save(&path).unwrap();
        // The committed file is JSON with a semver schema.
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(on_disk.trim_start().starts_with('{'));
        assert!(on_disk.contains("\"schema\": \"1.0.0\""));

        let reloaded = LockFile::load(&path).unwrap();
        assert_eq!(reloaded.get("parser.cob", "fig:pipeline").unwrap().id, fig);
        assert_eq!(
            reloaded.get("parser.cob", "tbl:api").unwrap().kind,
            Kind::Table
        );
        assert_eq!(reloaded.fetch_pin("algebra").unwrap().sha, "deadbeef");
        assert_eq!(
            reloaded.fetch_pin("algebra").unwrap().version.as_deref(),
            Some("1.3.0")
        );
        // The reload rebuilds `used`, so a mint after load still avoids collisions.
        let _ = tbl;
        // Saving the reloaded lock is byte-stable.
        let path2 = dir.join("cob.lock.2");
        reloaded.save(&path2).unwrap();
        assert_eq!(on_disk, std::fs::read_to_string(&path2).unwrap());
    }

    #[test]
    fn legacy_toml_lock_upgrades_without_changing_an_id() {
        // An older TOML `cob.lock` must still load, keep its ids, and re-save as
        // JSON (§7.1 in-place upgrade).
        let dir = std::env::temp_dir().join("cob-lock-legacy");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cob.lock");
        std::fs::write(
            &path,
            "[\"parser.cob\"]\n\"fig:pipeline\" = { id = \"k3f9\", kind = \"figure\" }\n",
        )
        .unwrap();
        let lock = LockFile::load(&path).unwrap();
        assert_eq!(lock.get("parser.cob", "fig:pipeline").unwrap().id, "k3f9");
        // Re-save upgrades the format to JSON, id untouched.
        lock.save(&path).unwrap();
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(on_disk.trim_start().starts_with('{'));
        assert!(on_disk.contains("\"k3f9\""));
        assert_eq!(
            LockFile::load(&path).unwrap().get("parser.cob", "fig:pipeline").unwrap().id,
            "k3f9"
        );
    }

    #[test]
    fn a_newer_major_schema_is_rejected() {
        // A lock written by a newer cob (major schema 2) must not load into this
        // one (§7.1 E038); a same-major newer minor is fine.
        let dir = std::env::temp_dir().join("cob-lock-schema");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cob.lock");
        std::fs::write(&path, "{ \"schema\": \"2.0.0\", \"labels\": {} }").unwrap();
        let err = LockFile::load(&path).unwrap_err();
        assert!(err.to_string().starts_with("error[E038]"));
        // A newer minor of the same major loads.
        std::fs::write(&path, "{ \"schema\": \"1.9.0\", \"labels\": {} }").unwrap();
        assert!(LockFile::load(&path).is_ok());
    }

    #[test]
    fn absent_lock_loads_empty() {
        let path = std::env::temp_dir().join("cob-lock-does-not-exist-xyzzy.lock");
        let _ = std::fs::remove_file(&path);
        let lock = LockFile::load(&path).unwrap();
        assert!(lock.get("f.cob", "fig:x").is_none());
    }

    #[test]
    fn find_label_matches_by_id_or_by_name_not_restricted_to_sections() {
        // Unlike find_section, every kind is reachable — a reader with a
        // rendered "Proposition 7F5U" in hand has no way to know it is not a
        // section before asking.
        let mut lock = LockFile::default();
        let mut m = Minter::seeded(5);
        let id = lock.mint("parser.cob", "fig:pipeline", Kind::Figure, &mut m);
        let (file, label, entry) = lock.find_label(&id).expect("found by id");
        assert_eq!(file, "parser.cob");
        assert_eq!(label, "fig:pipeline");
        assert_eq!(entry.kind, Kind::Figure);
        let (file2, _, _) = lock.find_label("fig:pipeline").expect("found by name");
        assert_eq!(file2, "parser.cob");
        assert!(lock.find_label("no-such-thing").is_none());
    }
}
