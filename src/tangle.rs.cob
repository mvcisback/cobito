# Tangling (§11)

This module is \code{cob tangle}. The prose is the specification. The chunks after it
are the implementation. Tangle extracts compilable source from \code{.cob} files. It is
the inverse of weave: it pulls a root chunk, and everything the root references,
out as a plain source file.

## Three sub-commands {#sec:mtmH}

\code{cob tangle <file.cob>…} writes every root chunk to the output directory (the
current directory by default). \code{cob tangle -R 'name'} writes a single chunk to
stdout. \code{cob tangle --check} tangles to memory, diffs the result against the disk,
and exits nonzero on any drift. The \code{--check} form exists for CI and for the
self-hosting flip (§13) — it is what proves a committed artifact still matches its
\code{.cob}.

The roots are the path-shaped chunk names the model already detects. The files
come from the CLI, the same as weave. Writes go through a temp file and a rename,
and cob skips a write when the content is unchanged, so a build system that
watches mtimes does not rebuild for no reason. noweb ships \code{cpif} for exactly this
reason.

## cob tangles natively (§11) {#sec:dd8Y}

cob tangles in its own code. It does not run \code{notangle}. The document model
already holds every chunk definition (in source order) and every chunk use, so
tangle is a walk of that model — no second parse and no external process. This is
what lets cob ship as one binary and lets \code{checks.selfhost} compare two cob passes
rather than cob against noweb.

The walk grew out of the §11 contingency list. Every one of these reasons now
holds, so the native tangler is the plan, not a fallback:

- A single binary for distribution needs no noweb on \code{PATH}.
- Owning the tangler lets cob keep breadcrumbs noweb discards — the column-level
  chunk provenance that tangle-then-backout highlighting wants (§5.5).
- A frozen set of \code{notangle} outputs (\code{fixtures/tangled/…}) is the correctness
  oracle, so cob no longer needs the live tool to stay honest.

## The expansion rule {#sec:9Fk2}

A chunk expands to text. cob walks the chunk's definitions in source order and
joins them; a chunk defined more than once (a continuation) contributes each
definition, the same as \code{notangle}. Inside a definition, a \code{@<<use@>>} splices the
used chunk in place.

The one subtle part is indentation. The text before a \code{@<<use@>>} on its line sets
a column. The first line of the used chunk follows that text; every line after it
gets that many spaces, so a multi-line chunk lines up under the column where it
was used. A completely empty line is the one exception — it stays empty, so an
indented chunk never grows a blank line of trailing spaces (a whitespace-only
line is not empty, so it is indented like any other). The rule nests: a use
inside a used chunk adds its own column to the one it inherits. \code{markup} already turned a leading tab into spaces (8-column
stops) before the model saw it, so the column is a count of characters, not a
mix of tabs and spaces.

A used chunk drops its one trailing newline at the splice, so \code{let x = @<<c@>>;}
keeps the \code{;} on the chunk's last line. The root keeps its own final newline, so
the file ends the way the source does.

A \code{@<<use@>>} of a chunk that has no definition cannot reach tangle: \code{model::build}
raises E010 first. A chunk that uses itself, directly or through others, is a
cycle — E035, reported, never a hang.

## How the code implements this {#sec:TXnD}

The module is the error type, the recursive expander and its two helpers, the
single-root entry point, two batch drivers (write to a directory, and check
against it without writing), and the disk helpers those drivers share.
<<src/tangle.rs>>=
<<the module banner>>

<<imports>>

<<the tangle error>>

<<expand one chunk>>

<<tangle one root>>

<<provenance for highlighting>>

<<the write outcome>>

<<tangle every root to a directory>>

<<the drift outcome>>

<<check every root against the directory>>

<<compare one root to disk>>

<<write one root if it changed>>

<<the tests>>
@
The banner records the inverse-of-weave relationship and the native-expansion
rule: cob walks the model, and it never runs \code{notangle}.
<<the module banner>>=
//! `cob tangle`: extract compilable source from `.cob` files (§11).
//!
//! Tangling is the inverse of weaving — it pulls a root chunk (and everything
//! it references) out as a plain source file. cob does this natively: it walks
//! the document model, joins each chunk's definitions in source order, and
//! splices every `@<<use@>>` in place with the column indentation noweb uses. It
//! never runs `notangle`, so a shipped binary needs no noweb on PATH.
@
Paths for disk output, formatting for errors, and the model types the expander
walks.
<<imports>>=
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::model::{CodeSpan, DocModel, SectionKind};
@
Two failures. A chunk that uses itself is a cycle (E035), reported with the chain
so the author can find it. Or writing the result to disk failed (E028).
<<the tangle error>>=
#[derive(Debug)]
pub enum TangleError {
    /// A chunk uses itself, directly or through others — the chain of names.
    Cycle { chain: Vec<String> },
    /// Writing a tangled root to disk failed.
    Write { path: PathBuf, source: std::io::Error },
}

impl fmt::Display for TangleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TangleError::Cycle { chain } => write!(
                f,
                "error[E035]: recursive chunk expansion: {}",
                chain.join(" -> ")
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
@
The expander is the core. \code{group_defs} maps each chunk name to its definitions'
spans, in source order, so a continuation keeps every definition. \code{expand} walks
one chunk: text and newlines pass through, and a \code{@<<use@>>} recurses, drops the
used chunk's one trailing newline, and indents every line after the first by the
column of the use. A name already on the chain is a cycle.
<<expand one chunk>>=
/// Map each chunk name to its definitions' spans, in source order. A chunk
/// defined more than once (a continuation) keeps every definition, so the
/// expansion joins them the way `notangle` does.
fn group_defs(doc: &DocModel) -> BTreeMap<&str, Vec<&[CodeSpan]>> {
    let mut defs: BTreeMap<&str, Vec<&[CodeSpan]>> = BTreeMap::new();
    for sec in &doc.sections {
        if let SectionKind::Code { name, spans, .. } = &sec.kind {
            defs.entry(name.as_str()).or_default().push(spans);
        }
    }
    defs
}

/// Expand one chunk into its tangled text. `chain` is the current expansion
/// path, used to catch a cycle (E035). A `@<<use@>>` of an undefined chunk cannot
/// reach here — `model::build` raises E010 first — so an unknown name expands to
/// nothing rather than panicking.
fn expand<'a>(
    defs: &BTreeMap<&'a str, Vec<&'a [CodeSpan]>>,
    name: &'a str,
    chain: &mut Vec<&'a str>,
) -> Result<String, TangleError> {
    if chain.contains(&name) {
        chain.push(name);
        return Err(TangleError::Cycle {
            chain: chain.iter().map(|s| s.to_string()).collect(),
        });
    }
    chain.push(name);
    let mut out = String::new();
    for spans in defs.get(name).into_iter().flatten() {
        for span in *spans {
            match span {
                CodeSpan::Text(t) => out.push_str(t),
                CodeSpan::Nl => out.push('\n'),
                CodeSpan::Use { name: used } => {
                    let col = last_line_width(&out);
                    let sub = expand(defs, used.as_str(), chain)?;
                    // notangle drops the used chunk's single trailing newline at
                    // the splice, so `let x = @<<c@>>;` keeps `;` on its last line.
                    let sub = sub.strip_suffix('\n').unwrap_or(&sub);
                    splice_indented(&mut out, sub, col);
                }
            }
        }
    }
    chain.pop();
    Ok(out)
}

/// The column at the end of `s`: the character count since the last newline. A
/// chunk use inherits this as the indentation for its continuation lines.
fn last_line_width(s: &str) -> usize {
    match s.rfind('\n') {
        Some(i) => s[i + 1..].chars().count(),
        None => s.chars().count(),
    }
}

/// Append `sub` to `out`, indenting every line after the first by `col` spaces —
/// the noweb rule that a multi-line chunk lines up under the column of its use. A
/// completely empty line is the one exception: it stays empty, so an indented
/// chunk never grows a blank line of trailing spaces. A whitespace-only line is
/// not empty, so it is indented like any other, the same as `notangle`.
fn splice_indented(out: &mut String, sub: &str, col: usize) {
    for (i, line) in sub.split('\n').enumerate() {
        if i > 0 {
            out.push('\n');
            if !line.is_empty() {
                out.push_str(&" ".repeat(col));
            }
        }
        out.push_str(line);
    }
}
@
The one entry point for a single root. It groups the definitions once and expands
from the root name. The root keeps its own trailing newline, so the file ends the
way the source does.
<<tangle one root>>=
/// Tangle a single root chunk to a string by walking the model (§11). No
/// external process runs. A cycle is E035.
pub fn tangle_root(doc: &DocModel, root: &str) -> Result<String, TangleError> {
    let defs = group_defs(doc);
    let mut chain = Vec::new();
    expand(&defs, root, &mut chain)
}
@
Highlighting a chunk in isolation is wrong — a chunk is a fragment, so a brace,
string, or comment that crosses a chunk boundary mis-tokenizes (§5.5, #1). The fix
is to tokenize the whole tangled file and map its tokens back onto each chunk. This
provenance tangle supports that: it concatenates every root's chunks — with **no**
inserted indentation and **no** trailing-newline drop, because both are whitespace
and whitespace never changes a token class for cob's grammars — and records, for
each literal run, which section's source bytes it is and where they landed. The
mapping is then one-to-one, so the weave can read each chunk's tokens straight out
of the tangled file's token stream.
<<provenance for highlighting>>=
/// One provenance segment (§5.5, #1): `len` bytes of section `section`'s source
/// (its holes-removed text, `\n` per newline), starting at `src_off`, appear at
/// `tangled_off` in the root's tangled text.
pub struct Seg {
    pub section: usize,
    pub src_off: usize,
    pub tangled_off: usize,
    pub len: usize,
}

/// One tangled root for highlighting (§5.5, #1): its name, its tangled text, and the
/// provenance segments mapping each section's source bytes into that text.
pub struct Root {
    pub root: String,
    pub text: String,
    pub segs: Vec<Seg>,
}

/// Tangle every root for the highlighter (§5.5, #1): a plain concatenation (no
/// inserted indentation, no trailing-newline drop — both are whitespace, which does
/// not change a token class), with a provenance map from each section's source bytes
/// into the tangled text. Roots come from `doc.chunks` in sorted order, so the
/// result is deterministic.
pub fn highlight_prov(doc: &DocModel) -> Result<Vec<Root>, TangleError> {
    let defs = group_defs_indexed(doc);
    let mut roots = Vec::new();
    for (name, info) in &doc.chunks {
        if !info.root {
            continue;
        }
        let mut out = String::new();
        let mut segs = Vec::new();
        let mut chain = Vec::new();
        expand_prov(&defs, name.as_str(), &mut chain, &mut out, &mut segs)?;
        roots.push(Root {
            root: name.clone(),
            text: out,
            segs,
        });
    }
    Ok(roots)
}

/// Like `group_defs`, but each definition keeps its section index, so a provenance
/// segment can name the section the weave renders.
fn group_defs_indexed(doc: &DocModel) -> BTreeMap<&str, Vec<(usize, &[CodeSpan])>> {
    let mut defs: BTreeMap<&str, Vec<(usize, &[CodeSpan])>> = BTreeMap::new();
    for (i, sec) in doc.sections.iter().enumerate() {
        if let SectionKind::Code { name, spans, .. } = &sec.kind {
            defs.entry(name.as_str()).or_default().push((i, spans));
        }
    }
    defs
}

/// Expand one chunk into `out`, recording a `Seg` per literal run. A plain
/// concatenation: a `@<<use@>>` recurses with no indentation or newline drop. A
/// cycle is E035 (`model::build` caught any undefined use already).
fn expand_prov<'a>(
    defs: &BTreeMap<&'a str, Vec<(usize, &'a [CodeSpan])>>,
    name: &'a str,
    chain: &mut Vec<&'a str>,
    out: &mut String,
    segs: &mut Vec<Seg>,
) -> Result<(), TangleError> {
    if chain.contains(&name) {
        chain.push(name);
        return Err(TangleError::Cycle {
            chain: chain.iter().map(|s| s.to_string()).collect(),
        });
    }
    chain.push(name);
    for (section, spans) in defs.get(name).into_iter().flatten() {
        let mut src_off = 0usize;
        for span in *spans {
            match span {
                CodeSpan::Text(t) => {
                    segs.push(Seg {
                        section: *section,
                        src_off,
                        tangled_off: out.len(),
                        len: t.len(),
                    });
                    out.push_str(t);
                    src_off += t.len();
                }
                CodeSpan::Nl => {
                    out.push('\n');
                    src_off += 1;
                }
                CodeSpan::Use { name: used } => {
                    expand_prov(defs, used.as_str(), chain, out, segs)?;
                }
            }
        }
    }
    chain.pop();
    Ok(())
}
@
The outcome of writing one root: created, updated, or left untouched because the
bytes already matched. Unchanged matters — rewriting identical bytes would bump
mtime and wake every file-watcher for nothing.
<<the write outcome>>=
/// What happened to one root when writing a whole document to disk.
#[derive(Debug, PartialEq, Eq)]
pub enum Wrote {
    Created,
    Updated,
    /// On-disk bytes already matched — left untouched so mtime-watchers stay
    /// quiet (noweb ships `cpif` for exactly this; §11).
    Unchanged,
}
@
Tangle every root and write each to \code{outdir}, skipping the ones already on disk.
The report keeps the given order, so output is deterministic. The definitions are
grouped once and reused across roots.
<<tangle every root to a directory>>=
/// Tangle every root to `outdir`, skipping any whose content is unchanged.
/// Returns `(root, outcome)` in the order given, for a deterministic report.
pub fn tangle_to_dir(
    doc: &DocModel,
    roots: &[&str],
    outdir: &Path,
) -> Result<Vec<(String, Wrote)>, TangleError> {
    let defs = group_defs(doc);
    let mut report = Vec::with_capacity(roots.len());
    for &root in roots {
        let mut chain = Vec::new();
        let content = expand(&defs, root, &mut chain)?;
        let path = outdir.join(root);
        report.push((root.to_string(), write_if_changed(&path, &content)?));
    }
    Ok(report)
}
@
For \code{--check}: how one root disagrees with disk — missing, or present but different.
<<the drift outcome>>=
/// One root's disagreement with what is on disk, for `--check`.
#[derive(Debug, PartialEq, Eq)]
pub enum Drift {
    Missing,
    Differs,
}
@
The same walk as writing, but it compares instead of writing. An empty result means
the tree is in sync — the self-hosting invariant of §13, and what \code{checks.selfhost}
asserts on every module ported here.
<<check every root against the directory>>=
/// Tangle every root and compare against `outdir` without writing anything.
/// Returns `(root, drift)` for each root that does not match — empty means the
/// tree is in sync (the CI / self-hosting invariant of §13).
pub fn check(
    doc: &DocModel,
    roots: &[&str],
    outdir: &Path,
) -> Result<Vec<(String, Drift)>, TangleError> {
    let defs = group_defs(doc);
    let mut drift = Vec::new();
    for &root in roots {
        let mut chain = Vec::new();
        let content = expand(&defs, root, &mut chain)?;
        if let Some(d) = compare_to_disk(&content, &outdir.join(root))? {
            drift.push((root.to_string(), d));
        }
    }
    Ok(drift)
}
@
Split out from \code{check} so the comparison is unit-testable on its own. Identical is
\code{None}; different is \code{Differs}; absent is \code{Missing}; any other read error is E028.
<<compare one root to disk>>=
/// How `contents` differs from `path`, if at all. Split out so the comparison
/// is unit-testable in isolation.
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
@
Write only on a real change, through a temp file and a rename so a watcher never
sees a half-written source file. A root name is path-shaped, so parent directories
are created as needed. The return distinguishes created from updated by whether a
file was already there.
<<write one root if it changed>>=
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
@
The tests pin the native expander against a frozen \code{notangle} oracle, and the
disk logic on its own. Each golden in \code{fixtures/tangled/<stem>/<root>} was made
once by \code{notangle}; the expander must reproduce it byte for byte from the pinned
\code{fixtures/<stem>.markup}. This is hermetic — no noweb on PATH — and it outlives
noweb: the goldens are a record of the behavior, not a live dependency.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model;
    use crate::noweb;

    <<the golden differential>>

    <<the indentation and cycle tests>>

    <<the disk-logic tests>>
}
@
The differential builds the model from a pinned IR and compares each root's
native expansion to its golden.
<<the golden differential>>=
fn doc_from_markup(ir: &str) -> DocModel {
    model::build(&noweb::parse(ir).unwrap()).unwrap()
}

fn assert_golden(ir: &str, root: &str, golden: &str) {
    let doc = doc_from_markup(ir);
    let got = tangle_root(&doc, root).expect("tangles");
    assert_eq!(got, golden, "native tangle of `{root}` must match the notangle golden");
}

#[test]
fn native_tangle_matches_notangle_goldens() {
    assert_golden(
        include_str!("../fixtures/hello.markup"),
        "src/main.rs",
        include_str!("../fixtures/tangled/hello/src/main.rs"),
    );
    assert_golden(
        include_str!("../fixtures/book.markup"),
        "src/main.rs",
        include_str!("../fixtures/tangled/book/src/main.rs"),
    );
    assert_golden(
        include_str!("../fixtures/hl.markup"),
        "src/demo.rs",
        include_str!("../fixtures/tangled/hl/src/demo.rs"),
    );
    assert_golden(
        include_str!("../fixtures/hl.markup"),
        "flake.nix",
        include_str!("../fixtures/tangled/hl/flake.nix"),
    );
    assert_golden(
        include_str!("../fixtures/md.markup"),
        "src/answer.rs",
        include_str!("../fixtures/tangled/md/src/answer.rs"),
    );
    assert_golden(
        include_str!("../fixtures/sections.markup"),
        "src/answer.rs",
        include_str!("../fixtures/tangled/sections/src/answer.rs"),
    );
    assert_golden(
        include_str!("../fixtures/tx.markup"),
        "demo.rs",
        include_str!("../fixtures/tangled/tx/demo.rs"),
    );
}
@
Two focused tests. One pins the indentation rule directly on a built model so a
regression names the rule, not a whole fixture. One proves a self-referential
chunk is E035, not a hang.
<<the indentation and cycle tests>>=
fn code_section(name: &str, spans: Vec<CodeSpan>) -> model::Section {
    model::Section {
        id: format!("sec-{name}"),
        file: "t.cob".to_string(),
        line: 1,
        kind: SectionKind::Code {
            name: name.to_string(),
            continues: false,
            spans,
            index_defs: Vec::new(),
        },
    }
}

fn model_of(sections: Vec<model::Section>) -> DocModel {
    let mut doc = DocModel {
        sections,
        ..Default::default()
    };
    for sec in &doc.sections {
        if let SectionKind::Code { name, .. } = &sec.kind {
            doc.chunks.entry(name.clone()).or_default().defs.push(sec.id.clone());
        }
    }
    doc
}

#[test]
fn a_used_chunk_is_indented_to_its_column_and_drops_its_trailing_newline() {
    use CodeSpan::*;
    // multi = "a\nb\n"; root = "x = @<<multi@>>;\n"
    let doc = model_of(vec![
        code_section("multi", vec![Text("a".into()), Nl, Text("b".into()), Nl]),
        code_section(
            "src/r.rs",
            vec![
                Text("x = ".into()),
                Use { name: "multi".into() },
                Text(";".into()),
                Nl,
            ],
        ),
    ]);
    // The first line follows `x = `; the second gets four spaces; `;` stays on
    // the last line because the used chunk's trailing newline is dropped.
    assert_eq!(tangle_root(&doc, "src/r.rs").unwrap(), "x = a\n    b;\n");
}

#[test]
fn an_empty_line_in_an_indented_chunk_stays_empty() {
    use CodeSpan::*;
    // body = "a\n\nb"; a truly empty middle line, a used chunk at column 4.
    let doc = model_of(vec![
        code_section("body", vec![Text("a".into()), Nl, Nl, Text("b".into()), Nl]),
        code_section(
            "src/r.rs",
            vec![Text("    ".into()), Use { name: "body".into() }, Nl],
        ),
    ]);
    // The blank line gets no indentation — notangle never leaves trailing spaces
    // on an empty line — while the real lines line up at column 4.
    assert_eq!(tangle_root(&doc, "src/r.rs").unwrap(), "    a\n\n    b\n");
}

#[test]
fn a_self_referential_chunk_is_a_cycle_not_a_hang() {
    use CodeSpan::*;
    let doc = model_of(vec![code_section(
        "loop.rs",
        vec![Text("before ".into()), Use { name: "loop.rs".into() }, Nl],
    )]);
    let err = tangle_root(&doc, "loop.rs").unwrap_err();
    match err {
        TangleError::Cycle { chain } => {
            assert_eq!(chain, vec!["loop.rs", "loop.rs"]);
        }
        other => panic!("expected a cycle, got {other:?}"),
    }
}
@
The disk logic is unit-tested on its own: writing creates, then reports unchanged,
then updated; and the comparison tells missing, identical, and differing apart.
<<the disk-logic tests>>=
fn tmpdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("cob-tangle-test-{name}"));
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
    assert_eq!(compare_to_disk("x\n", &path).unwrap(), Some(Drift::Missing));
    std::fs::write(&path, "x\n").unwrap();
    assert_eq!(compare_to_disk("x\n", &path).unwrap(), None);
    assert_eq!(compare_to_disk("y\n", &path).unwrap(), Some(Drift::Differs));
}
@
