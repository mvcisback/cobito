//! `cob tangle`: extract compilable source from `.cob` files (§11).
//!
//! Tangling is the inverse of weaving — it pulls a root chunk (and everything
//! it references) out as a plain source file. cob does this natively: it walks
//! the document model, joins each chunk's definitions in source order, and
//! splices every `<<use>>` in place with the column indentation noweb uses. It
//! never runs `notangle`, so a shipped binary needs no noweb on PATH.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::model::{CodeSpan, DocModel, SectionKind};

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
/// path, used to catch a cycle (E035). A `<<use>>` of an undefined chunk cannot
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
                    // the splice, so `let x = <<c>>;` keeps `;` on its last line.
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

/// Tangle a single root chunk to a string by walking the model (§11). No
/// external process runs. A cycle is E035.
pub fn tangle_root(doc: &DocModel, root: &str) -> Result<String, TangleError> {
    let defs = group_defs(doc);
    let mut chain = Vec::new();
    expand(&defs, root, &mut chain)
}

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
/// concatenation: a `<<use>>` recurses with no indentation or newline drop. A
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

/// A source location (#3): the `.cob` file, the 1-based source line, and the chunk
/// whose body that line is in. The map `tangle_root_located` returns is a `Vec` of
/// these, one per output line of the tangled file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loc {
    pub file: String,
    pub line: u32,
    pub chunk: String,
}

/// Tangle one root to its text and a line map. `text` is byte-identical to
/// `tangle_root`; `map[i]` is the source location of output line `i` (0-based). A
/// location in the file the compiler sees thus maps back to the `.cob` line that
/// wrote it. A cycle is E035, the same as `tangle_root`.
pub fn tangle_root_located(doc: &DocModel, root: &str) -> Result<(String, Vec<Loc>), TangleError> {
    let defs = group_defs_indexed(doc);
    let mut chain = Vec::new();
    expand_located(&defs, doc, root, &mut chain)
}

/// Expand `name` to its text and per-line source map. Mirrors `expand`: a hole
/// recurses into its own text and map, which `splice_located` merges in with the
/// column indentation. `cur` holds the location of the line being built, assigned
/// by the first content on it, so a line is owned by whoever starts it.
fn expand_located<'a>(
    defs: &BTreeMap<&'a str, Vec<(usize, &'a [CodeSpan])>>,
    doc: &'a DocModel,
    name: &'a str,
    chain: &mut Vec<&'a str>,
) -> Result<(String, Vec<Loc>), TangleError> {
    if chain.contains(&name) {
        chain.push(name);
        return Err(TangleError::Cycle {
            chain: chain.iter().map(|s| s.to_string()).collect(),
        });
    }
    chain.push(name);
    let mut out = String::new();
    let mut map: Vec<Loc> = Vec::new();
    let mut cur: Option<Loc> = None;
    for (sec_idx, spans) in defs.get(name).into_iter().flatten() {
        let sec = &doc.sections[*sec_idx];
        // The body opens on the line after the `<<name>>=` def line.
        let mut line = sec.line + 1;
        let here = |line| Loc {
            file: sec.file.clone(),
            line,
            chunk: name.to_string(),
        };
        for span in *spans {
            match span {
                CodeSpan::Text(t) => {
                    cur.get_or_insert_with(|| here(line));
                    out.push_str(t);
                }
                CodeSpan::Nl => {
                    map.push(cur.take().unwrap_or_else(|| here(line)));
                    out.push('\n');
                    line += 1;
                }
                CodeSpan::Use { name: used } => {
                    let col = last_line_width(&out);
                    let (sub, sub_map) = expand_located(defs, doc, used.as_str(), chain)?;
                    let sub = sub.strip_suffix('\n').unwrap_or(&sub);
                    splice_located(&mut out, &mut map, &mut cur, sub, &sub_map, col, &here(line));
                }
            }
        }
    }
    // A final line with content (no trailing newline) still needs its entry.
    if let Some(loc) = cur.take() {
        map.push(loc);
    }
    chain.pop();
    Ok((out, map))
}

/// Splice `sub` into `out` under column `col` (the noweb indentation rule) and its
/// map into `map`. The sub's first line joins the line in progress; each later line
/// is a new output line owned by the used chunk. `fallback` names the parent line,
/// used only if the sub has no location of its own.
fn splice_located(
    out: &mut String,
    map: &mut Vec<Loc>,
    cur: &mut Option<Loc>,
    sub: &str,
    sub_map: &[Loc],
    col: usize,
    fallback: &Loc,
) {
    for (i, line) in sub.split('\n').enumerate() {
        if i == 0 {
            // The sub's first line joins the line in progress. If the parent
            // contributed only indentation so far (`    <<use>>`, the common
            // case), the used chunk owns the line; otherwise the parent keeps it.
            let line_start = out.rfind('\n').map(|k| k + 1).unwrap_or(0);
            if out[line_start..].trim().is_empty() {
                if let Some(first) = sub_map.first() {
                    *cur = Some(first.clone());
                }
            }
            cur.get_or_insert_with(|| sub_map.first().cloned().unwrap_or_else(|| fallback.clone()));
            out.push_str(line);
        } else {
            map.push(cur.take().unwrap_or_else(|| fallback.clone()));
            out.push('\n');
            if !line.is_empty() {
                out.push_str(&" ".repeat(col));
            }
            *cur = Some(sub_map.get(i).cloned().unwrap_or_else(|| fallback.clone()));
            out.push_str(line);
        }
    }
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

/// One root's disagreement with what is on disk, for `--check`.
#[derive(Debug, PartialEq, Eq)]
pub enum Drift {
    Missing,
    Differs,
}

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
    use crate::model;
    use crate::noweb;

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
        // multi = "a\nb\n"; root = "x = <<multi>>;\n"
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

    #[test]
    fn located_tangle_maps_each_line_to_its_source_chunk() {
        use CodeSpan::*;
        // c (lines 11,12) = "foo\nbar\n"; root "src/r.rs" (line 6) = "x = <<c>>;\n".
        let mut c = code_section("c", vec![Text("foo".into()), Nl, Text("bar".into()), Nl]);
        c.line = 10;
        let mut root = code_section(
            "src/r.rs",
            vec![Text("x = ".into()), Use { name: "c".into() }, Text(";".into()), Nl],
        );
        root.line = 5;
        let doc = model_of(vec![c, root]);

        let (text, map) = tangle_root_located(&doc, "src/r.rs").expect("tangles");
        // Byte-identical to the plain tangle.
        assert_eq!(text, tangle_root(&doc, "src/r.rs").unwrap());
        assert_eq!(text, "x = foo\n    bar;\n");
        // Line 0 is the root's body line; line 1 (the indented `bar;`) is the used
        // chunk's second body line.
        assert_eq!(map.len(), 2);
        assert_eq!(map[0], Loc { file: "t.cob".into(), line: 6, chunk: "src/r.rs".into() });
        assert_eq!(map[1], Loc { file: "t.cob".into(), line: 12, chunk: "c".into() });
    }

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
}
