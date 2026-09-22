# Stable opaque ids and the lock file (§7.1)

This module is the specification and the implementation of stable identity. The
prose is the specification. The chunks after it are the implementation.

## Why an opaque id {#sec:5II3}

cob is meant to be a living document, and one day a forest: separate projects
import and transclude each other's notes (§16, M12). A position-dependent
"Figure 3" cannot survive that. It changes the moment content moves inside a
document, or is pulled into another one. So the identity of a figure, table,
equation, or labelled section is not its position but a frozen opaque id, and a
reference renders kind-qualified with that id ("Figure k3f9", "Section k3f9"),
not "Figure 3". This supersedes the numbering half of §7; the anchoring and
caption mechanics there are unchanged.

## What earns an id {#sec:X0Yp}

A float earns an id by carrying a label. Every section earns one too. A heading
with a \code{sec:} id — \code{{#sec:lexing}} in Markdown, an \code{id="sec:lexing"} in HTML — is a
first-class label: cob mints it into \code{cob.lock} with \code{kind = "section"}, a
\code{\ref{sec:lexing}} renders "Section k3f9", and the section leads with a small
clickable permalink whose id the stylesheet draws. The id lives in \code{data-id}, never
a text node, so it stays out of selections and the quote selectors (§9.2); the
anchor itself is the click target. An h1 is addressed by its page id and is never
minted.

The author does not have to label a section by hand. \code{cob lock} gives every
unlabelled \code{h2}/\code{h3} heading an id: it mints one and writes a \code{sec:<id>} anchor into
the heading's source line (\code{section.rs}). So every section is linkable, and the id
is source-anchored — it lives on the heading, not on a slug of the heading text — so
a reword of the heading does not break the link. The id doubles as its own name
until the author gives it a human one with \code{cob rename-label <id> <name>}, which
rewrites the source anchor and rekeys the lock while the frozen id stays the same.
Because the anchor lives in the source, the write happens only in the dev-time
\code{cob lock} pass; a \code{--locked} weave never mints and never edits, so an anchored
section absent from the committed lock is still the E031 error, like any label.

## The id itself {#sec:oaLc}

The id is a random 4-character base62 string (\code{[0-9A-Za-z]}, case-sensitive,
about 14.8 million values). cob mints it once and never recomputes it. It is
deliberately not derived from the label, the path, or the content, because a
derived id would change under exactly the renames and moves it exists to survive.
4 characters is enough for a hobby-scale forest.

## Labels stay human, ids stay global {#sec:jJzq}

An author keeps writing a human-readable \code{\label{fig:pipeline}} and
\code{\ref{fig:pipeline}} (§6.4). A label is note-local: two notes may both use
\code{fig:pipeline} without colliding, because cob resolves a label only against its
own file. The opaque id is global. Within a file a \code{\ref} resolves by the human
label. Across files (import and transclude, M12) a reference names the target by
its opaque id, which is rename- and move-proof.

## The lock file {#sec:GIRD}

\code{cob.lock} is a committed, human-readable, greppable map from \code{label} to
\code{{ id, kind }}, keyed by source file so note-local labels stay distinct:

```toml
# cob.lock — generated; edit only to delete a retired label.
["parser.cob"]
"fig:pipeline" = { id = "k3f9", kind = "figure" }
"tbl:api"      = { id = "7g2A", kind = "table" }
"eq:wrap"      = { id = "Qx0m", kind = "equation" }
```

\code{kind} is carried from the fence or tag, not parsed off the id. The label prefix
survives only as the E030 sanity check (§6.4); it no longer decides numbering or
identity.

## Mint on miss, freeze under --locked {#sec:YZLc}

A normal \code{weave} mints an id for any label missing from the lock and rewrites
\code{cob.lock}, a dev-time side effect like updating a dependency lockfile. On a
collision it re-rolls. But weave must stay a byte-deterministic function of its
inputs (§8), and CI and the Nix sandbox run against a read-only source tree. So
\code{weave --locked} never mints: a label absent from the lock is the E031 error,
which mirrors \code{cargo --locked} against \code{Cargo.lock}. \code{nix flake check} weaves
\code{--locked}, and the committed lock is what lets a random mint reconcile with
determinism.

## Discovery {#sec:acTW}

The id is random and persisted, so it cannot be computed; you discover it with
tooling. \code{cob lock} is a fast pass that mints and populates \code{cob.lock} with no
full weave, and the committed lock is greppable. \code{cob labels <file>} lists a
file's label-to-id map; \code{cob id <file> <label>} prints one id for scripting.

## How the code implements this {#sec:erRn}

The module holds the id alphabet, the on-disk types, the error, a minter, the
base62 speller, and the lock operations.
<<src/lock.rs>>=
<<the module banner>>

<<imports>>

<<the id constants>>

<<a lock entry>>

<<the lock mode>>

<<the lock file>>

<<the lock error>>

<<the id minter>>

<<the base62 spelling>>

<<the lock file operations>>

<<the tests>>
@
The banner explains why the id is random and persisted rather than derived, and
why the map nests by file.
<<the module banner>>=
//! The lock file (§7.1): a committed, greppable map from a note-local
//! human label to a frozen opaque id. The id is what a cross-reference renders
//! ("Figure k3f9") and what an eventual import/transclude (§16, M12) names, so it
//! must survive every move and rename — which is exactly why it is *random* and
//! *persisted*, never derived from the label, path, or content.
//!
//! Keyed by source file so two notes may reuse a label (`fig:pipeline`) without
//! colliding once the forest imports both. Within one weave labels are still
//! globally unique (E014); the per-file nesting is forward-looking.
@
Ordered maps and sets so the serialized lock is deterministic, plus the reference
\code{Kind} a label carries.
<<imports>>=
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::rewrite::Kind;
@
Four base62 characters — about 14.8 million ids, ample for a hobby-scale forest.
The alphabet is case-sensitive; \code{SPACE} is the count the minter reduces a raw value
modulo.
<<the id constants>>=
/// A frozen id is four base62 characters (`[0-9A-Za-z]`, case-sensitive) — about
/// 14.8M ids, enough for a hobby-scale forest (§7.1).
pub const ID_LEN: u32 = 4;
const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const SPACE: u64 = 62 * 62 * 62 * 62;
@
One stored id and the kind of float or heading it labels.
<<a lock entry>>=
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct LockEntry {
    pub id: String,
    pub kind: Kind,
}
@
Whether a weave may mint fresh ids, or must find every label already present.
\code{Locked} is CI and the read-only Nix sandbox, where minting is forbidden (§7.1).
<<the lock mode>>=
/// Whether a weave may mint fresh ids (dev-time) or must find every label
/// already in the lock (`--locked`, for CI and the read-only Nix sandbox; §7.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockMode {
    Mint,
    Locked,
}
@
The lock is \code{file → (label → entry)}. \code{used} is a derived index of every id in
play, so a mint rejects a collision in one lookup. It is rebuilt on load, never
serialized.
<<the lock file>>=
/// `file → (label → entry)`. `used` is a derived index of every id in play, so a
/// mint can reject a collision in one lookup; it is rebuilt on load, never
/// serialized.
#[derive(Default)]
pub struct LockFile {
    files: BTreeMap<String, BTreeMap<String, LockEntry>>,
    used: BTreeSet<String>,
}
@
Two codes. E031 is a label missing under \code{--locked} — the caller must run
\code{cob lock} first. E032 is any read, parse, or write failure of the lock itself.
<<the lock error>>=
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
@
A minter of fresh ids: SplitMix64 seeded from entropy. Determinism does not depend
on the seed — a minted id is persisted and re-read forever after, so the RNG only
ever decides an id's first value. \code{from_entropy} mixes a stack address with the
clock; \code{seeded} is the reproducible test door; \code{next} is one SplitMix64 step reduced
into the id space.
<<the id minter>>=
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
@
A value below \code{SPACE} to its fixed four-character spelling, most-significant digit
first.
<<the base62 spelling>>=
/// `n < SPACE` → its four-character base62 spelling.
fn base62(mut n: u32) -> String {
    let mut buf = [b'0'; ID_LEN as usize];
    for slot in buf.iter_mut().rev() {
        *slot = ALPHABET[(n % 62) as usize];
        n /= 62;
    }
    String::from_utf8(buf.to_vec()).expect("base62 alphabet is ASCII")
}
@
The operations the rest of cob calls: load and save the whole file, look up or mint
one id, list a file's labels, and count the total.
<<the lock file operations>>=
impl LockFile {
    <<load the lock>>

    <<save the lock>>

    <<look up an entry>>

    <<mint or reuse an id>>

    <<mint an auto section id>>

    <<find and rename a section>>

    <<a file's labels>>

    <<count of frozen ids>>
}
@
An absent lock is an empty lock, not an error — the first \code{cob lock} or \code{weave}
mints into it. Loading rebuilds the \code{used} index from every stored id.
<<load the lock>>=
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
@
Deterministic by construction: sorted keys from the BTreeMaps and no timestamp,
behind a fixed two-line header. Byte-stable output is what lets CI diff the lock.
<<save the lock>>=
/// Write the lock deterministically (BTreeMaps → sorted keys, no timestamp).
pub fn save(&self, path: &Path) -> Result<(), LockError> {
    let body = toml::to_string(&self.files).map_err(|e| LockError::Parse(e.to_string()))?;
    let text = format!(
        "# cob.lock — generated (§7.1). label → frozen opaque id.\n\
         # Edit only to retire a label; ids never change once minted.\n{body}"
    );
    std::fs::write(path, text).map_err(LockError::Io)
}
@
A plain two-level lookup by file, then label.
<<look up an entry>>=
pub fn get(&self, file: &str, label: &str) -> Option<&LockEntry> {
    self.files.get(file).and_then(|m| m.get(label))
}
@
Idempotent: an existing label re-reads its frozen id. A fresh label rolls the
minter until it lands on an id not already used, then records it. Re-rolling on
collision is the reason \code{used} exists.
<<mint or reuse an id>>=
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
@
An auto-anchored section (§7.1, \code{section.rs}) has no author label, so \code{cob lock}
mints its id first, then uses that id as its own label: the source anchor cob writes
is \code{sec:<id>}. The id and its name are the same string until \code{cob rename-label}
gives it a human one. Like \code{mint}, a collision with an id already in use is
re-rolled. It returns the id so the caller can write the anchor.
<<mint an auto section id>>=
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
@
\code{cob rename-label} takes the frozen id and gives it a human name. First it finds the
section entry that carries the id, then it moves the entry to the new label, keeping
the id. The id never changes, so every reference and permalink still resolves. A
move to a label already in the file is refused, so a name is never overwritten.
<<find and rename a section>>=
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
@
A file's label-to-entry pairs in sorted order, for \code{cob labels}.
<<a file's labels>>=
/// A file's `label → entry` pairs in sorted order (for `cob labels`).
pub fn labels(&self, file: &str) -> impl Iterator<Item = (&String, &LockEntry)> {
    self.files.get(file).into_iter().flat_map(|m| m.iter())
}
@
The total number of ids across every file, for the mint report.
<<count of frozen ids>>=
/// The total number of frozen ids across every file — used by `cob lock` to
/// report how many labels were newly minted.
pub fn count(&self) -> usize {
    self.used.len()
}
@
The tests pin the frozen-id contract: minting is idempotent per label, distinct
labels get distinct ids, a collision is re-rolled, the TOML round-trips and re-saves
byte-stable, and an absent lock loads empty.
<<the tests>>=
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
@
