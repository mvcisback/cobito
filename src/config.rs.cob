# The project manifest (§5.2, §6.1)

This module is \code{cob.toml}, the project manifest. The prose is the specification.
The chunks after it are the implementation. Every table is optional, so an absent
or empty file is valid — the CLI then falls back to its argument-derived defaults.

## What the manifest declares {#sec:TLsr}

A \code{[[document]]} table names the document: its id, title, authors, and the \code{.cob}
files in order. A \code{[tangle]} table sets the default output directory, and a
\code{[[tangle.root]]} table per root sets that root's line-pragma format. A \code{[weave]}
table holds the highlight language keys (§5.5).

The \code{files} of a \code{[[document]]} are the book. Their order is the reading order, and
it is the only place that order is written down. \code{cob weave} and \code{cob lock} read
it when the command line names no files, so a build, a review loop, and a CI check all
share one book. A file named on the command line wins over the manifest.

```verbatim \lang{toml}
[[document]]
id = "cob"
title = "cob: a literate programming system"
files = ["intro.cob", "parser.cob", "weave.cob"]

[tangle]
outdir = "."

[[tangle.root]]
chunk = "server/app.py"
line-pragma = '# %L "%F"%N'
```

## Root chunks and the line pragma {#sec:E4N0}

A chunk whose name is path-shaped — it contains a \code{/}, or it matches a file
extension — is a root. \code{notangle -L} takes a printf-ish format for its line
pragma, and the correct format is language-specific: its own default is C's
\code{#line}. So a single boolean would be wrong — it would emit \code{#line} into Python
and Rust. cob takes a per-root format string instead, and it defaults to *off*.

There is a verified caveat. The \code{-L} flag disables indentation propagation, so an
inner chunk's lines land at column 0, and it splits the code around a chunk use
onto separate lines with column-preserving padding. So pragma'd output is a
different shape, not just annotated text. This is acceptable for generated code,
and it is why the default is off.

## One prose dialect {#sec:ZZAp}

A docs chunk is authored in one dialect (§6.4): the command Markdown. Paragraphs,
lists, links, headings, and blockquotes become HTML. Inline formatting is explicit
commands, never CommonMark \code{*}-style flanking: \code{\emph{…}} makes \code{<em>},
\code{\strong{…}} makes \code{<strong>}, \code{\code{…}} an inline code span, and \code{\sidenote{…}}
a margin note (§10). A fenced block is a grammar-owned kind — \code{math}, \code{figure},
\code{table}, \code{verbatim}, or \code{html-escape}. The escape hatch is per fence, not per
document: an \code{html-escape} fence is the one door for raw HTML. So the manifest needs
no dialect key.

The dialect is a post-\code{markup} transform (§6.2) on the already-reassembled prose.
Everything downstream — the numbering, the refs, the math render, the sidenote hoist,
\code{site.json} — reads the same rendered HTML.

## How the code implements this {#sec:Er9s}

This module is a set of serde structs, one per manifest table, plus one \code{impl}
block that loads the file and answers the questions the rest of cob asks of it:
which document, and which tangle roots carry a line-pragma format. The file is
laid out the way a reader meets it: the module banner, the imports, the error
type, then each table struct in source order, then the loader and its queries,
then the tests.
<<src/config.rs>>=
<<the module banner>>

<<imports>>

<<the config error>>

<<the manifest root>>

<<the weave table>>

<<a declared document>>

<<an import>>

<<the cite table>>

<<the forest table>>

<<a fence handler>>

<<the tangle table>>

<<a tangle root>>

<<the line-pragma format>>

<<loading and querying the manifest>>

<<the tests>>
@
The banner records how much of the manifest is live today. M4 reads a small slice;
the \code{[weave.annotate]} keys of §5.3 and §10 parse leniently now and gain meaning
with their milestones.
<<the module banner>>=
//! `cob.toml`, the project manifest (§5.2). M4 reads a deliberately
//! small slice: `[[document]]` metadata (which feeds `site.json`'s `meta`) and
//! `[[tangle.root]]` line-pragma formats. The `[weave]` / `[weave.annotate]`
//! keys of §5.3/§10 are parsed leniently (unknown keys ignored) but not yet
//! acted on — they arrive with the milestones that need them.
@
Three std imports and serde. Every deserialized map is a \code{BTreeMap}, not a
\code{HashMap}, so iteration order is deterministic and weaves stay byte-stable — a
project-wide rule, not a local taste.
<<imports>>=
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use serde::Deserialize;
@
Reading the manifest fails two ways: the file parsed wrong, or the read itself
failed for a reason other than absence. Both surface as E029. Absence is *not* an
error here — the loader turns it into \code{Ok(None)}, because a missing manifest is
the normal case.
<<the config error>>=
#[derive(Debug)]
pub enum ConfigError {
    /// `cob.toml` was present but did not parse.
    Parse { path: String, message: String },
    /// Reading `cob.toml` failed for a reason other than absence.
    Read { path: String, source: std::io::Error },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Parse { path, message } => {
                write!(f, "error[E029]: {path}: {message}")
            }
            ConfigError::Read { path, source } => {
                write!(f, "error[E029]: reading {path}: {source}")
            }
        }
    }
}

impl std::error::Error for ConfigError {}
@
\code{Config} is the whole file. Because every field defaults, \code{#[derive(Default)]}
gives a valid empty manifest, and each \code{#[serde(default)]} lets its table be
omitted entirely.
<<the manifest root>>=
/// The whole manifest. Every section is optional so a bare or absent `cob.toml`
/// is valid — the CLI simply falls back to its argument-derived defaults.
#[derive(Deserialize, Default)]
pub struct Config {
    #[serde(rename = "document", default)]
    pub documents: Vec<Document>,
    #[serde(default)]
    pub tangle: Tangle,
    #[serde(default)]
    pub weave: Weave,
    /// The `[import.<alias>]` tables (§13): each binds another forest to a local
    /// namespace alias used in `label@alias` addresses. `BTreeMap` keeps the
    /// order deterministic.
    #[serde(rename = "import", default)]
    pub imports: BTreeMap<String, Import>,
    #[serde(default)]
    pub cite: Cite,
    #[serde(default)]
    pub forest: Forest,
    /// The `[fence.<name>]` tables (§6.6): each registers a CLI handler for a
    /// `custom[<name>]` fence. `BTreeMap` keeps the order deterministic.
    #[serde(rename = "fence", default)]
    pub fences: BTreeMap<String, FenceHandler>,
}
@
A \code{[fence.<name>]} table registers a handler for a \code{custom[<name>]} fence (§6.6).
\code{cmd} is the argv of a program cob runs at weave time, from the project root; cob
sends it the fence body and context as JSON and reads back the HTML. Declaring the
handler in \code{cob.toml} — the project's own trusted config — is the consent to run
it; an undeclared handler is the E042 error.
<<a fence handler>>=
/// One `[fence.<name>]` table (§6.6): the CLI that renders a `custom[<name>]`
/// fence. `cmd` is the argv — the first element is the program, run from the
/// project root — so a handler can be `["tools/fig"]` or `["python3", "x.py"]`.
#[derive(Deserialize, Default, Clone)]
pub struct FenceHandler {
    pub cmd: Vec<String>,
}
@
The \code{[forest]} table declares this forest's own identity (§16). \code{url} is where its
pages are deployed; it is the join key for reverse backlinks — a consumer's
outgoing edge names the target forest by the same url, so the aggregator matches an
edge to the forest it points at. A forest with no \code{url} does not take part in
cross-forest backlinks.
<<the forest table>>=
/// The `[forest]` table (§16): this forest's own identity. `url` is its deployed
/// base — the join key that lets the backlink aggregator match a consumer's
/// outgoing edge to the forest it targets.
#[derive(Deserialize, Default)]
pub struct Forest {
    #[serde(default)]
    pub url: Option<String>,
}
@
The \code{[cite]} table points at the bibliography (§14). \code{bib} is the path to a BibTeX
file; \code{\cite{key}} resolves against its entries. Absent means the document has no
bibliography, so a \code{\cite} is then the E040 unknown-citation error.
<<the cite table>>=
/// The `[cite]` table (§14): where the bibliography comes from. `bib` is the path
/// to a BibTeX file; a `\cite{key}` resolves against its entries. Absent means no
/// bibliography.
#[derive(Deserialize, Default)]
pub struct Cite {
    #[serde(default)]
    pub bib: Option<String>,
}
@
An \code{[import.<alias>]} table binds another forest to the alias, so \code{label@alias}
addresses resolve against it (§13). \code{path} names a local forest to read now; \code{git}
plus \code{rev} name a remote one that \code{cob fetch} pins into the import cache before a
weave reads it offline. \code{url} is where that forest's pages are deployed, so a
cross-document \code{\ref} or \code{\transclude} makes a link that lands on the real site.
<<an import>>=
/// One `[import.<alias>]` table (§13): where the aliased forest comes from. A
/// local `path`, or a `git` URL resolved by a semver `version` requirement (the
/// release model) or a raw `rev` (the escape hatch). `cob fetch` turns a git import
/// into a cached index keyed by commit; a weave only ever reads the cache, so it
/// stays offline. `url` is the deployed base a cross-document `\ref`/`\transclude`
/// links into.
#[derive(Deserialize, Default, Clone)]
pub struct Import {
    #[serde(default)]
    pub path: Option<String>,
    /// The deployed base URL of the imported forest (§13); a cross-document
    /// reference lands on `<url>/<page>.html#<anchor>`. Empty when unset, which
    /// makes a site-root-relative link.
    #[serde(default)]
    pub url: Option<String>,
    /// A `git` URL. `cob fetch` resolves it (by `version` or `rev`) into a cached
    /// index keyed by commit; a weave then reads the cache offline and never
    /// touches git itself.
    #[serde(default)]
    pub git: Option<String>,
    /// A semver requirement (e.g. `^1.2`) resolved against the forest's semver
    /// tags to the highest matching release — the primary version model (§13).
    #[serde(default)]
    pub version: Option<String>,
    /// An exact git ref (tag, branch, or sha) used as-is, with no semver
    /// resolution — the escape hatch for importing an unreleased branch. Exactly
    /// one of `version`/`rev` is given for a `git` import.
    #[serde(default)]
    pub rev: Option<String>,
}
@
\code{[weave]} carries the syntax-highlighting configuration (§5.5). \code{lang} is the
document-wide default (tier 2); \code{chunk-lang} is the per-chunk override map (tier
1) that beats it. The map is out-of-band config, so it survives \code{markup} — an
inline language tag on the chunk definition line would be tokenized as source and
lost.
<<the weave table>>=
/// The `[weave]` table (§5.5). Only the document-wide highlighting default lives
/// here for now; the `[weave.annotate]` keys of §5.3/§10 arrive with their
/// milestones and are parsed leniently (unknown keys ignored) until then.
#[derive(Deserialize, Default)]
pub struct Weave {
    /// The document-wide language for syntax highlighting (tier 2, §5.5): the
    /// value `cob language`/the weaver resolves against, e.g. `"rust"` or
    /// `"nix"`. Absent means fall back to the tangle-root file extension.
    #[serde(default)]
    pub lang: Option<String>,
    /// The `[weave.chunk-lang]` map (tier 1, §5.5): chunk name → language id, the
    /// per-chunk override that wins over `lang` and the extension fallback. It is
    /// out-of-band config, so it survives `markup` where an inline `{lang=…}`
    /// would not. `BTreeMap` keeps the deserialized order deterministic.
    #[serde(rename = "chunk-lang", default)]
    pub chunk_lang: BTreeMap<String, String>,
}
@
A \code{[[document]]} is one document's identity and its file set. A project may
declare several; the single-document CLI uses the first.
<<a declared document>>=
/// One document's identity and file set (§5.2). A project may declare several;
/// M4's single-document CLI uses the first.
#[derive(Deserialize, Default, Clone)]
pub struct Document {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub files: Vec<String>,
}
@
\code{[tangle]} sets the output directory and the per-root overrides.
<<the tangle table>>=
#[derive(Deserialize, Default)]
pub struct Tangle {
    #[serde(default)]
    pub outdir: Option<String>,
    #[serde(rename = "root", default)]
    pub roots: Vec<Root>,
}
@
Each \code{[[tangle.root]]} names a chunk that is a tangle root and, optionally, the
line-pragma format to emit for it.
<<a tangle root>>=
/// A per-root override. Only `line-pragma` matters in M4; `chunk` names the root
/// it applies to.
#[derive(Deserialize, Default, Clone)]
pub struct Root {
    pub chunk: String,
    #[serde(rename = "line-pragma", default)]
    pub line_pragma: LinePragma,
}
@
The correct \code{-L} format is language-specific, so a bare boolean can only turn
pragmas *off* — turning them on needs the format string itself. The untagged enum
therefore accepts either \code{false} or a format string. The bool variant carries no
information beyond "off", and \code{format()} collapses it to \code{None}.
<<the line-pragma format>>=
/// `notangle -L` format for a root, or `false` for none. The correct format is
/// language-specific, so a plain boolean can only *disable* pragmas — enabling
/// them requires the format string itself (§5.2).
#[derive(Deserialize, Clone)]
#[serde(untagged)]
pub enum LinePragma {
    // The bool is parse-only: it lets `line-pragma = false` deserialize, but
    // carries no information beyond "off", which `format()` returns as `None`.
    Off(#[allow(dead_code)] bool),
    Format(String),
}

impl Default for LinePragma {
    fn default() -> Self {
        LinePragma::Off(false)
    }
}

impl LinePragma {
    /// The `-L` format to pass notangle, or `None` when pragmas are off.
    pub fn format(&self) -> Option<&str> {
        match self {
            LinePragma::Format(s) if !s.is_empty() => Some(s),
            _ => None,
        }
    }
}
@
\code{load} reads \code{dir/cob.toml}. Absence returns \code{Ok(None)} so the caller keeps its
defaults; any other read error, or a parse error, becomes E029. The two query
methods answer exactly what the rest of cob needs: the first document, and the
root-name → format map for the roots that configure one.
<<loading and querying the manifest>>=
impl Config {
    /// Load `dir/cob.toml`. Absence is not an error — returns `Ok(None)` so the
    /// caller keeps its argument-derived defaults.
    pub fn load(dir: &Path) -> Result<Option<Config>, ConfigError> {
        let path = dir.join("cob.toml");
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(ConfigError::Read {
                    path: path.display().to_string(),
                    source,
                })
            }
        };
        toml::from_str(&text)
            .map(Some)
            .map_err(|e| ConfigError::Parse {
                path: path.display().to_string(),
                message: e.message().to_string(),
            })
    }

    /// The first declared document, if any — M4's single-document convention.
    pub fn document(&self) -> Option<&Document> {
        self.documents.first()
    }

    /// Root name → `-L` format, for the roots that configure one.
    pub fn tangle_pragmas(&self) -> BTreeMap<String, String> {
        self.tangle
            .roots
            .iter()
            .filter_map(|r| r.line_pragma.format().map(|f| (r.chunk.clone(), f.to_string())))
            .collect()
    }
}
@
The tests pin the contract: absence is not an error, document metadata
round-trips, a line-pragma is off unless a format string is given, and both
\code{[weave]} keys are read.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Config {
        toml::from_str(text).unwrap()
    }

    #[test]
    fn absent_file_is_not_an_error() {
        let dir = std::env::temp_dir().join("cob-config-absent");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(Config::load(&dir).unwrap().is_none());
    }

    #[test]
    fn document_meta_is_read() {
        let c = parse(
            r#"
            [[document]]
            id = "cob"
            title = "cob: a system"
            authors = ["A", "B"]
            files = ["a.cob", "b.cob"]
            "#,
        );
        let d = c.document().unwrap();
        assert_eq!(d.id, "cob");
        assert_eq!(d.title, "cob: a system");
        assert_eq!(d.authors, vec!["A", "B"]);
        assert_eq!(d.files, vec!["a.cob", "b.cob"]);
    }

    #[test]
    fn line_pragma_off_by_default_and_when_false() {
        let c = parse(
            r#"
            [[tangle.root]]
            chunk = "src/lexer.rs"
            line-pragma = false

            [[tangle.root]]
            chunk = "no-key.rs"

            [[tangle.root]]
            chunk = "server/app.py"
            line-pragma = '# %L "%F"%N'
            "#,
        );
        let pragmas = c.tangle_pragmas();
        // Only the root with a format string appears; `false` and the missing
        // key contribute nothing.
        assert_eq!(pragmas.len(), 1);
        assert_eq!(
            pragmas.get("server/app.py").map(String::as_str),
            Some("# %L \"%F\"%N")
        );
    }

    #[test]
    fn weave_lang_and_chunk_lang_map_are_read() {
        let c = parse(
            r#"
            [weave]
            lang = "nix"

            [weave.chunk-lang]
            "the drift check" = "bash"
            "the lock check" = "bash"
            "#,
        );
        assert_eq!(c.weave.lang.as_deref(), Some("nix"));
        assert_eq!(c.weave.chunk_lang.get("the drift check").map(String::as_str), Some("bash"));
        assert_eq!(c.weave.chunk_lang.get("the lock check").map(String::as_str), Some("bash"));
    }

    #[test]
    fn empty_config_yields_no_document_or_pragmas() {
        let c = parse("");
        assert!(c.document().is_none());
        assert!(c.tangle_pragmas().is_empty());
    }
}
@
