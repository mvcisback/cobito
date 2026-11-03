# Fetching a remote forest import (§13)

This module is the specification and the implementation of `cob fetch`. The prose
is the specification. The chunks after it are the implementation.

## Why fetch is a separate step {#sec:why-fetch}

A document may import another forest to use its macros and to reference its nodes
across documents (§13). A local import names the other forest by a \code{path} to its
built site. A remote import names it by a \code{git} URL and a \code{rev}. cob must turn that
remote name into something a weave can read.

A weave must stay offline and byte-deterministic (§8). So cob never reaches the
network during a weave. \code{cob fetch} is the one step that does. It runs ahead of a
weave, pins each remote import to a concrete commit, and caches that import's
index. A later weave then reads only the cache, like \code{cargo build} reads a vendored
dependency after \code{cargo fetch}.

## What fetch reads {#sec:what-fetch-reads}

A consumer needs the other forest's **\code{cob-exports.json}** — its exported macro table
and its label index (§13). That file is a build artifact, not a source file, so a
remote forest **publishes** it: the forest commits its \code{cob-exports.json} to the root
of a release ref (a tag or a branch). This is the same shape cob uses to seed
itself — a built artifact committed to a ref (§13 self-host).

So \code{cob fetch} does not build the other forest. It clones the ref, reads the one
\code{cob-exports.json} file at the ref's tree root, and caches it.

## Which version: a semver requirement {#sec:which-version}

A forest publishes releases as semver git tags (\code{v1.2.0}). The author imports by a
**semver requirement**, and \code{cob fetch} resolves it to the highest matching tag —
the release model, like Cargo:

```verbatim \lang{toml}
[import.algebra]
git     = "ssh://git@host/marcell/algebra.cob"
version = "^1.2"
url     = "https://alg.example"
```

For an unreleased branch during development, the author uses \code{rev} instead — an
exact ref (tag, branch, or sha) with no semver resolution. A \code{git} import gives
exactly one of \code{version}/\code{rev}; neither (or both) is E037.

## The pin and the cache {#sec:pin-and-cache}

\code{cob fetch} resolves the request to a concrete commit **SHA** and records the pin
in \code{cob.lock} (the \code{fetch} section, §7.1): the \code{git} URL, the request (\code{req}), the
resolved semver \code{version}, and the \code{sha}. So a build is reproducible: the same pin
gives the same bytes. It writes the fetched index to
\code{.cob-cache/imports/<sha>/cob-exports.json}, keyed by the commit so the cache is
immutable and shared across imports that resolve to the same commit.

## The update story {#sec:update-story}

\code{cob fetch} **honors the lock**: it keeps a pin whose request is unchanged and whose
cache is present, so routine fetches are reproducible and do not drift. It resolves
only an import that is new, whose requirement changed, or whose cache is missing.
\code{cob update [alias]} is the one command that moves a pin forward: it re-resolves to
the highest release matching the requirement, for one named import or all of them.
A released version whose tag moved — the same \code{version} now at a different commit —
is E037, so a published version stays immutable.

A weave resolves a remote import through the pin: it reads the SHA from the lock
and loads the cached file. A \code{git} import with no pin is the E037 error — the
author must run \code{cob fetch} first. A \code{path} import needs no fetch and is read
directly; a \code{path} wins over a \code{git} when both are set, so an author can override
a remote import with a local checkout.

## How the code implements this {#sec:fetch-impl}

The module is the error type, the fetched-import record, the single-import fetch,
the whole-config run, and the weave-time index resolver.
<<src/fetch.rs>>=
<<the module banner>>

<<imports>>

<<the fetch error>>

<<a fetched import>>

<<fetch one import>>

<<run fetch over the config>>

<<resolve an import's index directory>>

<<the tests>>
@
The banner states the one guarantee: the network is touched here and nowhere else,
so a weave stays offline.
<<the module banner>>=
//! `cob fetch` (§13): pin each remote forest import to a commit and cache its
//! `cob-exports.json`, so a later weave resolves cross-document refs and macros
//! offline and a build is reproducible by the pinned commit SHA. This is the one
//! place cob touches the network; a weave never does.
@
The fetch needs a git client (`gix`, pure-Rust for the protocol, pack, and object
store; the `file://` transport is pure-Rust and the `ssh://` transport runs the
system `ssh`), the config's import table, and the lock's pin type.
<<imports>>=
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use semver::{Version, VersionReq};

use crate::config::{Config, Import};
use crate::lock::{FetchPin, LockFile};
@
One error code, E037, covers every fetch fault: a git operation that failed, a ref
with no `cob-exports.json`, a cache read/write failure, and a `git` import a weave met
with no pin.
<<the fetch error>>=
/// Every `cob fetch` fault is E037 (§13): a git operation failed, the ref has no
/// `cob-exports.json`, the cache could not be written, or a weave met a `git` import
/// with no pin.
#[derive(Debug)]
pub enum FetchError {
    /// A git operation failed (clone, fetch, or rev resolution).
    Git { alias: String, message: String },
    /// The resolved ref carries no `cob-exports.json` at its tree root.
    NoIndex { alias: String, at: String },
    /// A `git` import declared neither (or both) of `version`/`rev`, or a
    /// requirement that is not valid semver.
    BadRequest { alias: String, message: String },
    /// No semver tag satisfies the requirement.
    NoMatch { alias: String, req: String },
    /// A released version's tag moved — its commit differs from the pin (§13).
    MovedTag { alias: String, version: String },
    /// The fetched index has a schema this cob cannot read (E038; the full message
    /// comes from `site::read_exports`).
    Schema(String),
    /// The import cache could not be read or written.
    Io(String),
    /// A `git` import with no pin; a weave needs `cob fetch` first.
    Unpinned { alias: String },
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::Git { alias, message } => {
                write!(f, "error[E037]: fetching import `{alias}`: {message}")
            }
            FetchError::NoIndex { alias, at } => write!(
                f,
                "error[E037]: import `{alias}`: no cob-exports.json at `{at}` \
                 (a forest must publish its index to the ref root)"
            ),
            FetchError::BadRequest { alias, message } => {
                write!(f, "error[E037]: import `{alias}`: {message}")
            }
            FetchError::NoMatch { alias, req } => write!(
                f,
                "error[E037]: import `{alias}`: no released tag satisfies `{req}`"
            ),
            FetchError::MovedTag { alias, version } => write!(
                f,
                "error[E037]: import `{alias}`: the tag for version {version} moved; \
                 a released version must be immutable (run `cob update {alias}` if intended)"
            ),
            FetchError::Schema(m) => write!(f, "{m}"),
            FetchError::Io(m) => write!(f, "error[E037]: import cache: {m}"),
            FetchError::Unpinned { alias } => write!(
                f,
                "error[E037]: import `{alias}` is not fetched; run `cob fetch`"
            ),
        }
    }
}

impl std::error::Error for FetchError {}

/// What an import asks for: a semver requirement resolved against the forest's
/// tags, or a raw git ref used as-is (§13). Exactly one is given for a `git` import.
enum Want {
    Version(String),
    Rev(String),
}

impl Want {
    /// The request string stored in the pin (`req`), so a later `cob fetch` can
    /// tell whether the author changed what they asked for.
    fn key(&self) -> &str {
        match self {
            Want::Version(s) | Want::Rev(s) => s,
        }
    }
}

/// Read an import's version request: exactly one of `version`/`rev`.
fn want(alias: &str, imp: &Import) -> Result<Want, FetchError> {
    match (&imp.version, &imp.rev) {
        (Some(v), None) => {
            VersionReq::parse(v).map_err(|e| FetchError::BadRequest {
                alias: alias.to_string(),
                message: format!("`version = \"{v}\"` is not valid semver: {e}"),
            })?;
            Ok(Want::Version(v.clone()))
        }
        (None, Some(r)) => Ok(Want::Rev(r.clone())),
        (None, None) => Err(FetchError::BadRequest {
            alias: alias.to_string(),
            message: "a git import needs a `version` or a `rev`".to_string(),
        }),
        (Some(_), Some(_)) => Err(FetchError::BadRequest {
            alias: alias.to_string(),
            message: "a git import takes `version` or `rev`, not both".to_string(),
        }),
    }
}

/// Whether `cob fetch` honors existing pins (`Fetch`) or re-resolves (`Update`).
/// `Update(Some(alias))` re-resolves just that import; `Update(None)` re-resolves
/// every import.
pub enum Mode {
    Fetch,
    Update(Option<String>),
}
@
One fetched import: its alias, the commit it pinned to, and the cache path its
index now lives at. `cob fetch` returns a list of these for its report.
<<a fetched import>>=
/// One import `cob fetch` resolved: its alias, the pinned commit SHA, and the
/// cache path its `cob-exports.json` now lives at.
pub struct Fetched {
    pub alias: String,
    pub sha: String,
    pub cached: PathBuf,
}
@
Fetching one import clones its ref into a scratch bare repo, resolves the request
to one commit (the highest tag matching a semver requirement, or a raw ref used
as-is), reads `cob-exports.json` from that commit's tree root, checks its schema,
and writes it to the commit-keyed cache. The scratch clone is removed after the
one file is read, so the cache holds only the index, not a whole repository.
<<fetch one import>>=
/// The highest semver tag in `tags` that satisfies `req` — the tag name and its
/// parsed version. A tag may lead with `v`. This is the pure selection step, kept
/// out of the git plumbing so it is unit-testable (§13).
fn best_match(tags: &[String], req: &VersionReq) -> Option<(String, Version)> {
    tags.iter()
        .filter_map(|t| {
            let v = t.strip_prefix('v').unwrap_or(t);
            Version::parse(v)
                .ok()
                .filter(|ver| req.matches(ver))
                .map(|ver| (t.clone(), ver))
        })
        .max_by(|a, b| a.1.cmp(&b.1))
}

/// Clone the import's repo bare, resolve `want` to one commit, read
/// `cob-exports.json` from its tree root, check the schema, and write it to
/// `<cache_root>/imports/<sha>/cob-exports.json`. Returns the pin and that path.
/// The network is touched only here (§13).
fn fetch_one(
    alias: &str,
    git: &str,
    want: &Want,
    cache_root: &Path,
) -> Result<(FetchPin, PathBuf), FetchError> {
    let imports = cache_root.join("imports");
    std::fs::create_dir_all(&imports).map_err(|e| FetchError::Io(e.to_string()))?;
    // A scratch bare clone, removed once the one file is read.
    let tmp = imports.join(format!(".fetch-{alias}"));
    let _ = std::fs::remove_dir_all(&tmp);

    let git_err = |e: String| FetchError::Git {
        alias: alias.to_string(),
        message: e,
    };
    let mut prep = gix::prepare_clone_bare(git, &tmp).map_err(|e| git_err(e.to_string()))?;
    let (repo, _out) = prep
        .fetch_only(gix::progress::Discard, &AtomicBool::new(false))
        .map_err(|e| git_err(e.to_string()))?;

    // Resolve the request to a ref name and the version it names (if any).
    let (refname, version) = match want {
        Want::Rev(rev) => (rev.clone(), None),
        Want::Version(reqstr) => {
            let req = VersionReq::parse(reqstr).map_err(|e| FetchError::BadRequest {
                alias: alias.to_string(),
                message: e.to_string(),
            })?;
            let tags = tag_names(&repo).map_err(git_err)?;
            let (name, ver) = best_match(&tags, &req).ok_or_else(|| FetchError::NoMatch {
                alias: alias.to_string(),
                req: reqstr.clone(),
            })?;
            (name, Some(ver.to_string()))
        }
    };

    let id = repo
        .rev_parse_single(refname.as_str())
        .map_err(|e| git_err(e.to_string()))?;
    let obj = id.object().map_err(|e| git_err(e.to_string()))?;
    let commit = obj.try_into_commit().map_err(|e| git_err(e.to_string()))?;
    let sha = commit.id().to_string();
    let tree = commit.tree().map_err(|e| git_err(e.to_string()))?;
    let entry = tree
        .lookup_entry_by_path("cob-exports.json")
        .map_err(|e| git_err(e.to_string()))?
        .ok_or_else(|| FetchError::NoIndex {
            alias: alias.to_string(),
            at: refname.clone(),
        })?;
    let data = entry
        .object()
        .map_err(|e| git_err(e.to_string()))?
        .data
        .clone();
    // Fail fast on an index this cob cannot read (E038), before it is cached.
    let text = String::from_utf8_lossy(&data);
    crate::site::read_exports(&text).map_err(FetchError::Schema)?;

    let dir = imports.join(&sha);
    std::fs::create_dir_all(&dir).map_err(|e| FetchError::Io(e.to_string()))?;
    let path = dir.join("cob-exports.json");
    std::fs::write(&path, &data).map_err(|e| FetchError::Io(e.to_string()))?;
    let _ = std::fs::remove_dir_all(&tmp);

    Ok((
        FetchPin {
            git: git.to_string(),
            req: want.key().to_string(),
            version,
            sha,
        },
        path,
    ))
}

/// Every tag's short name (`refs/tags/v1.2.0` → `v1.2.0`) in a fetched repo.
fn tag_names(repo: &gix::Repository) -> Result<Vec<String>, String> {
    let platform = repo.references().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in platform.tags().map_err(|e| e.to_string())? {
        let r = r.map_err(|e| e.to_string())?;
        out.push(r.name().shorten().to_string());
    }
    Ok(out)
}
@
Running `cob fetch`/`cob update` walks the config's import table and resolves every
import that has a `git` URL. The mode decides whether an existing pin is honored or
re-resolved (§13): `Fetch` keeps a pin that still matches the author's request and
whose cache is present, so a routine fetch is reproducible and does not drift;
`Update` re-resolves (all imports, or one named alias) to the highest matching
release. A `path`-only import is local and skipped. On a re-resolve, a released
version whose tag moved is an error, so a published version stays immutable.
<<run fetch over the config>>=
/// Resolve every `[import.<alias>]` that has a `git` URL, recording each pin in the
/// lock (§13). `mode` decides whether an up-to-date pin is honored or re-resolved.
/// A `path`-only import is local and skipped. Returns what was (re)fetched.
pub fn run(
    cfg: &Config,
    lock: &mut LockFile,
    cache_root: &Path,
    mode: &Mode,
) -> Result<Vec<Fetched>, FetchError> {
    let mut out = Vec::new();
    for (alias, imp) in &cfg.imports {
        let Some(git) = &imp.git else { continue };
        let want = want(alias, imp)?;

        // Honor an existing pin unless this run re-resolves it. A pin is honored
        // when its request is unchanged, its cache is present, and the mode is not
        // an update targeting it.
        let prior = lock.fetch_pin(alias).cloned();
        let targeted = matches!(mode, Mode::Update(None))
            || matches!(mode, Mode::Update(Some(a)) if a == alias);
        if !targeted {
            if let Some(pin) = &prior {
                let cached = cache_root.join("imports").join(&pin.sha).join("cob-exports.json");
                if pin.req == want.key() && cached.exists() {
                    continue;
                }
            }
        }

        let (pin, cached) = fetch_one(alias, git, &want, cache_root)?;
        // A released version's tag must be immutable: if a prior pin named the same
        // version at a different commit, the tag moved (§13).
        if let (Some(prev), Some(now)) = (&prior, &pin.version) {
            if prev.version.as_deref() == Some(now.as_str()) && prev.sha != pin.sha {
                return Err(FetchError::MovedTag {
                    alias: alias.clone(),
                    version: now.clone(),
                });
            }
        }
        let sha = pin.sha.clone();
        lock.set_fetch_pin(alias.clone(), pin);
        out.push(Fetched {
            alias: alias.clone(),
            sha,
            cached,
        });
    }
    Ok(out)
}
@
A weave resolves an import to the directory holding its `cob-exports.json`. A local
`path` wins. A `git` import resolves through its lock pin to the commit-keyed
cache; with no pin it is `Unpinned`, so the weave tells the author to fetch first.
An import with neither source yields `None` and is simply not loaded.
<<resolve an import's index directory>>=
/// The directory holding an import's `cob-exports.json` (§13). A local `path` wins; a
/// `git` import resolves through its lock pin to `<cache_root>/imports/<sha>`; a
/// `git` import with no pin is `Unpinned`. An import with no source is `None`.
pub fn index_dir(
    alias: &str,
    imp: &Import,
    lock: &LockFile,
    cache_root: &Path,
) -> Result<Option<PathBuf>, FetchError> {
    if let Some(path) = &imp.path {
        return Ok(Some(PathBuf::from(path)));
    }
    if imp.git.is_some() {
        return match lock.fetch_pin(alias) {
            Some(pin) => Ok(Some(cache_root.join("imports").join(&pin.sha))),
            None => Err(FetchError::Unpinned {
                alias: alias.to_string(),
            }),
        };
    }
    Ok(None)
}
@
The tests cover the pure resolver and the error text; the real git fetch is
exercised hermetically by the `fetch` flake check against a local `file://` repo
(§13), which needs no network.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn imp(path: Option<&str>, git: Option<&str>) -> Import {
        Import {
            path: path.map(str::to_string),
            url: None,
            git: git.map(str::to_string),
            version: None,
            rev: None,
        }
    }

    fn pin(sha: &str) -> FetchPin {
        FetchPin {
            git: "ssh://h/a".to_string(),
            req: "^1".to_string(),
            version: Some("1.2.0".to_string()),
            sha: sha.to_string(),
        }
    }

    #[test]
    fn index_dir_prefers_a_local_path() {
        let lock = LockFile::default();
        let got = index_dir("a", &imp(Some("/x/_site"), Some("ssh://h/a")), &lock, Path::new(".c"))
            .unwrap();
        assert_eq!(got, Some(PathBuf::from("/x/_site")));
    }

    #[test]
    fn index_dir_uses_the_pin_for_a_git_import() {
        let mut lock = LockFile::default();
        lock.set_fetch_pin("a".to_string(), pin("abc123"));
        let got = index_dir("a", &imp(None, Some("ssh://h/a")), &lock, Path::new(".cob-cache"))
            .unwrap();
        assert_eq!(got, Some(PathBuf::from(".cob-cache/imports/abc123")));
    }

    #[test]
    fn a_git_import_without_a_pin_is_unpinned() {
        let lock = LockFile::default();
        let err = index_dir("a", &imp(None, Some("ssh://h/a")), &lock, Path::new(".c")).unwrap_err();
        assert!(err.to_string().starts_with("error[E037]"));
        assert!(err.to_string().contains("run `cob fetch`"));
    }

    #[test]
    fn an_import_with_no_source_is_none() {
        let lock = LockFile::default();
        assert_eq!(index_dir("a", &imp(None, None), &lock, Path::new(".c")).unwrap(), None);
    }

    #[test]
    fn best_match_picks_the_highest_satisfying_tag() {
        let tags: Vec<String> = ["v1.0.0", "v1.1.0", "v1.2.0", "v2.0.0", "nightly"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let req = VersionReq::parse("^1.0").unwrap();
        let (name, ver) = best_match(&tags, &req).unwrap();
        assert_eq!(name, "v1.2.0");
        assert_eq!(ver, Version::parse("1.2.0").unwrap());
        // Nothing satisfies a requirement past every tag.
        assert!(best_match(&tags, &VersionReq::parse("^3").unwrap()).is_none());
    }

    #[test]
    fn want_requires_exactly_one_of_version_or_rev() {
        let mut i = imp(None, Some("ssh://h/a"));
        assert!(want("a", &i).is_err()); // neither
        i.version = Some("^1".to_string());
        assert!(matches!(want("a", &i), Ok(Want::Version(_))));
        i.rev = Some("main".to_string());
        assert!(want("a", &i).is_err()); // both
        i.version = None;
        assert!(matches!(want("a", &i), Ok(Want::Rev(_))));
        // An invalid semver requirement is rejected.
        i.rev = None;
        i.version = Some("not-a-semver!!".to_string());
        assert!(want("a", &i).is_err());
    }
}
@
