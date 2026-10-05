# The weaver (§5.4)

This module is the whole-document to HTML-page pipeline (§19.3, §6.2). The prose
is the specification. The chunks after it are the implementation. It takes the
folded document model, renders every section, resolves the numbering and the
cross-references across the whole document, splits the result into pages at each
top-level heading, and writes the site to disk.

The order of work is fixed by one constraint. The numbering and the
cross-references cannot be settled until every section has been seen. So prose
bodies make two passes through the rewriter — a scan pass that collects every
labelled float, then an apply pass that fills in the resolved ids — with the
document-global plan computed in between.

Determinism is a hard requirement (§8). Every map is ordered, there are no
timestamps, and the KaTeX fonts are sorted before they are copied. So two weaves
of the same input make byte-identical output.

## How a code chunk renders {#sec:A00S}

A code chunk renders as a \code{section} that wraps a collapsible \code{details}. The
\code{summary} holds the chunk name; the body holds one \code{span} per line:

```verbatim \lang{html}
<section class="code" id="sec-2" data-nw-file="…" data-nw-line="6" data-chunk="lex a token">
  <div class="margin-slot" data-for="sec-2"></div>
  <details class="chunk" open>
    <summary><span class="chunk-name">&lt;&lt;<dfn>lex a token</dfn>&gt;&gt;=</span></summary>
    <pre class="chunk-body">
      <span class="line" data-line="7">let c = <a href="#sec-8">&lt;<i>next char</i>&gt;</a>;</span>
      <span class="line" data-line="8">tokens.push(c);</span>
    </pre>
  </details>
</section>
```

Three decisions shape this markup, and all three need zero client JavaScript.

First, the chunk is collapsible and open by default. A reader can fold a chunk
away. Nothing is hidden from a reader who never touches it, and the collapsed
state is not persisted, because that needs no JavaScript and no storage. The
header lives in the \code{summary}, which matters for a cross-reference: a link targets
the \code{section}, not the \code{details}, so a link into a *collapsed* chunk still scrolls
to a visible element that names the chunk.

Second, the line numbers are \code{.cob} source lines, not per-chunk 1..n. The number a
reader sees is the number they type into an editor. It matches the \code{data-nw-line}
provenance and any \code{notangle -L} pragma. A continuation chunk restarts at its own
source line, which is the honest answer: the two halves of a chunk are not
contiguous in the source.

The numbers render as CSS generated content — \code{data-line} on the span,
\code{content: attr(data-line)} in the stylesheet — never as text nodes. This is not
cosmetic. A text-node number would be copied with a code selection, and it would
sit inside the exact-quote selector the annotation layer anchors with (§9.2). So a
re-weave after an edit above would orphan every annotation on the code below.
Generated content is invisible to both the clipboard and the selector.

Third, the bytes get syntax highlighting. The chunk-use hole stays opaque, the
language is resolved out of band, and the color is pure CSS. This preserves the
copy-paste and the annotation invariants above. The \code{highlight} module owns that
concern and states the full rule (§5.5).

## How the code implements this {#sec:LG7c}

The module is the error type, the per-chunk and per-section renderers, the
fragment passes, the mint-only lock path, the whole-document render, the asset
copy, and the top-level \code{write_site} that ties them to disk.
<<src/weave.rs>>=
<<the module banner>>

<<imports>>

<<the weave error>>

<<display a weave error>>

<<render one code chunk>>

<<the chunk-use anchor>>

<<the no-highlight line splitter>>

<<wrap a section in its provenance>>

<<the rendered page and the site>>

<<one section's fragment>>

<<render every fragment>>

<<scan every fragment>>

<<mint the lock without rendering>>

<<every mintable label>>

<<render the whole document>>

<<the page link and nav context>>

<<the node page context>>

<<copy the katex assets>>

<<write the site to disk>>

<<the tests>>
@
The banner states the pass-through decision: three of the six §6.2 steps are a
deliberate no-op at this milestone, and the placeholder split is already in place
so a later milestone can insert a real HTML parse without reordering anything.
<<the module banner>>=
//! M1 weave: document model → a single HTML page (§19.3).
//!
//! Steps 3–5 of §6.2 (parse, rewrite, serialize) are deliberately a
//! pass-through here: M1 has no numbering, `data-ref`, or sidenote hoisting to
//! do, so there is nothing an HTML parser would contribute yet. The step-2/6
//! placeholder split is already in place so M2 can insert a real parse between
//! them without reordering anything.
@
The weaver pulls a name from nearly every other module, because it is the stage
that ties them together: config for the manifest, highlight for the colors, lock
for the frozen ids, the prose and markdown pipeline, the math renderer, the model,
the resolver, the rewriter, and the site JSON shape.
<<imports>>=
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::highlight::{self, Lang, LangConfig};
use crate::import;
use crate::lock::{LockError, LockFile, LockMode, Minter};
use crate::markdown;
use crate::math::{MathError, Renderer};
use crate::model::{CodeSpan, DocModel, Lint, SectionKind};
use crate::prose::{self, Math};
use crate::resolve::{self, LabelIds, NavNode, PageMeta, ResolveError};
use crate::rewrite::{self, Kind, Plan, RewriteError, Scan};
use crate::site::{self, SiteJson};
use crate::transclude;
@
The error type collects a failure from every stage the weaver drives. The markdown
variant carries the source coordinate so a diagnostic points at the offending line;
the rest wrap another module's error or a message.
<<the weave error>>=
#[derive(Debug)]
pub enum WeaveError {
    Markdown {
        file: String,
        line: u32,
        err: markdown::MarkdownError,
    },
    Math(MathError),
    Rewrite(RewriteError),
    Resolve(ResolveError),
    Lock(LockError),
    Import(crate::import::ImportError),
    Assets(String),
    Io(std::io::Error),
    Template(String),
}
@
Display assigns each variant its §12 error code. The markdown variant appends the
source coordinate; the wrapped variants defer to the inner error, which already
carries its own code.
<<display a weave error>>=
impl fmt::Display for WeaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WeaveError::Markdown { file, line, err } => {
                write!(f, "{err}\n  --> {file}:{line}")
            }
            WeaveError::Math(e) => write!(f, "{e}"),
            WeaveError::Rewrite(e) => write!(f, "{e}"),
            WeaveError::Resolve(e) => write!(f, "{e}"),
            WeaveError::Lock(e) => write!(f, "{e}"),
            WeaveError::Import(e) => write!(f, "{e}"),
            WeaveError::Assets(m) => write!(f, "error[E023]: {m}"),
            WeaveError::Io(e) => write!(f, "error[E024]: writing site: {e}"),
            WeaveError::Template(m) => write!(f, "error[E025]: template: {m}"),
        }
    }
}

impl std::error::Error for WeaveError {}
@
Rendering one code chunk is the delicate part. The chunk body is target text with
chunk-use holes; the holes are cob's syntax, not the target's. So the highlighter
must never see them. The renderer first walks the spans into a clean source buffer:
literal runs are appended, newlines are appended, and each hole is removed but its
byte offset and rendered anchor are recorded. The buffer is handed to the
highlighter, which colors only the target's own text; the holes are spliced back
afterwards at their exact offsets, outside any color span.

Two structural commitments hold. The chunk is a foldable block so a reader can
collapse it. Each body line is its own element carrying its source coordinate, and
the number is drawn by CSS from that attribute, never written into the text — so a
copy-paste is clean and the annotation layer's quote selectors are undisturbed.

The doc-comment shows the definition and continuation markers. In a code chunk a
bare hole is a chunk use, so each bracket pair carries the noweb at-escape; the
example survives tangle as literal text and never expands.
<<render one code chunk>>=
/// Render one code chunk, following noweb's own convention: `@<<name@>>=` for a
/// definition, `@<<name@>>+=` for a continuation (§5.1), and uses linked to the
/// defining section.
///
/// Two structural commitments (§5.3): the chunk is a `<details open>` so a
/// reader can fold it away, and each body line is its own element carrying its
/// `.cob` coordinate. The number is drawn by CSS from `data-line`, never written
/// into the text — generated content does not land in a copy-paste and does not
/// perturb the text-quote selectors the annotation layer anchors on (§9.2).
fn render_code(
    name: &str,
    continues: bool,
    spans: &[CodeSpan],
    first_line: u32,
    doc: &DocModel,
    lang: Option<Lang>,
) -> String {
    let marker = if continues { "+=" } else { "=" };

    // A clean source buffer for the highlighter: the raw literal runs joined by
    // newlines, with chunk-use holes removed but their byte offset and anchor
    // HTML recorded so they splice back into the exact same spot afterwards
    // (§5.5). The tokenizer never sees `@<<...@>>`, only the target's own text.
    let mut source = String::new();
    let mut holes: Vec<(usize, String)> = Vec::new();
    for span in spans {
        match span {
            CodeSpan::Nl => source.push('\n'),
            CodeSpan::Text(t) => source.push_str(t),
            CodeSpan::Use { name } => holes.push((source.len(), hole_anchor(name, doc))),
        }
    }
    // The chunk-terminating newline opens a line that has no source line.
    if source.ends_with('\n') {
        source.pop();
    }

    let hole_refs: Vec<(usize, &str)> = holes.iter().map(|(o, s)| (*o, s.as_str())).collect();
    let lines = match lang {
        // Highlighting is best-effort: a grammar error falls back to the same
        // escaped plain text the no-language path emits (§5.5 — plain text is
        // the floor, never an error).
        Some(l) => highlight::highlight(&source, &hole_refs, l)
            .unwrap_or_else(|_| plain_lines(&source, &holes)),
        None => plain_lines(&source, &holes),
    };

    let mut out = format!(
        "<details class=\"chunk\" open><summary><span class=\"chunk-name\">\
         &lt;&lt;<dfn>{}</dfn>&gt;&gt;{marker}</span></summary><pre class=\"chunk-body\">",
        prose::escape(name)
    );
    for (i, line) in lines.iter().enumerate() {
        out.push_str(&format!(
            "<span class=\"line\" data-line=\"{}\">{line}</span>",
            first_line + i as u32
        ));
    }
    out.push_str("</pre></details>");
    out
}
@
A chunk-use hole renders as an italic label linked to the section that defines the
named chunk, when one exists. An undefined use renders as the label alone.
<<the chunk-use anchor>>=
/// The `<a>` anchor a chunk-use hole renders as: the italic `@<<name@>>` label,
/// linked to the section that defines `name` when there is one (§5.4).
fn hole_anchor(name: &str, doc: &DocModel) -> String {
    let target = doc
        .chunks
        .get(name)
        .and_then(|c| c.defs.first())
        .map(String::as_str);
    let label = format!("&lt;<i>{}</i>&gt;", prose::escape(name));
    match target {
        Some(id) => format!("<a href=\"#{id}\">{label}</a>"),
        None => label,
    }
}
@
The no-highlight path escapes the clean buffer and splices the holes back, one
inner-HTML string per line. It mirrors the highlighter's splice without any
tokenization, so both paths produce the same plain-text payload byte for byte —
which is what lets a grammar error fall back to this path invisibly.
<<the no-highlight line splitter>>=
/// The no-highlight path: escape the clean buffer and splice the holes back,
/// yielding one inner-HTML string per line. Mirrors `highlight::highlight`'s
/// splice but without tokenization, so both paths agree on the plain-text
/// payload byte-for-byte.
fn plain_lines(source: &str, holes: &[(usize, String)]) -> Vec<String> {
    let mut lines: Vec<String> = vec![String::new()];
    let mut pos = 0;
    let mut hi = 0;
    while pos < source.len() {
        while hi < holes.len() && holes[hi].0 == pos {
            lines.last_mut().unwrap().push_str(&holes[hi].1);
            hi += 1;
        }
        let next_hole = holes.get(hi).map_or(source.len(), |h| h.0);
        let next_nl = source[pos..].find('\n').map_or(source.len(), |o| pos + o);
        let stop = next_hole.min(next_nl);
        if stop > pos {
            lines
                .last_mut()
                .unwrap()
                .push_str(&prose::escape(&source[pos..stop]));
            pos = stop;
        }
        if pos == next_nl && pos < source.len() {
            lines.push(String::new());
            pos += 1;
        }
    }
    while hi < holes.len() && holes[hi].0 == source.len() {
        lines.last_mut().unwrap().push_str(&holes[hi].1);
        hi += 1;
    }
    lines
}
@
Every section is wrapped in a provenance envelope: the source file and line it came
from, an optional chunk name, and an empty margin slot. These attributes are the
entire contract the annotation layer depends on. They cost nothing now and are
present from the first milestone even though that layer arrives later.
<<wrap a section in its provenance>>=
/// The §9.1 provenance attributes plus the §9.3 margin slot. Present from M1
/// even though the annotation layer arrives in M5 — they cost nothing now and
/// are the entire contract that layer depends on.
fn wrap_section(
    id: &str,
    class: &str,
    file: &str,
    line: u32,
    chunk: Option<&str>,
    body: &str,
) -> String {
    let chunk_attr = chunk
        .map(|c| format!(" data-chunk=\"{}\"", prose::escape(c)))
        .unwrap_or_default();
    format!(
        "<section class=\"{class}\" id=\"{id}\" data-nw-file=\"{}\" data-nw-line=\"{line}\"{chunk_attr}>\
         <div class=\"margin-slot\" data-for=\"{id}\"></div>{body}</section>",
        prose::escape(file)
    )
}
@
A rendered page pairs its metadata with its HTML. The site is every page, one
standalone sitemap page, the math count, the collected lints, and the archival JSON
— the JSON is always assembled but only written under the archive flag, and its
metadata is a placeholder that \code{write_site} fills in. The test-only helper
concatenates every page's HTML for whole-document assertions where the page split is
not what is under test.
<<the rendered page and the site>>=
pub struct RenderedPage {
    pub meta: PageMeta,
    pub html: String,
}

pub struct Site {
    pub pages: Vec<RenderedPage>,
    /// One per-node page (§10), as `(relative path, html)` — the path is
    /// `n/<id>.html`, one directory down from the document pages.
    pub node_pages: Vec<(String, String)>,
    /// A standalone page listing the whole navigation tree (`sitemap.html`),
    /// always emitted so a reader has one flat overview of every section.
    pub sitemap: String,
    pub math_count: usize,
    pub lints: Vec<Lint>,
    /// The §8 document model, always assembled but only written under
    /// `--archive`. `meta` is a placeholder here; `write_site` fills it in.
    pub json: SiteJson,
    /// This document's macro table (name → expansion) from its `macros` fences
    /// (§6.4). Written to `cob-exports.json` under `--archive` so another forest can
    /// `\import` it (§13).
    pub macros: BTreeMap<String, String>,
}

impl Site {
    /// Every page's HTML concatenated — a convenience for whole-document
    /// assertions where the page split is not what is under test.
    #[cfg(test)]
    pub fn all_html(&self) -> String {
        self.pages
            .iter()
            .map(|p| p.html.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}
@
A fragment is one section's rendered body before math substitution and section
wrapping. Only docs bodies are HTML the rewriter touches; code bodies pass through
untouched, so the two are kept apart by the enum.
<<one section's fragment>>=
/// One section's rendered body, before math substitution and section wrapping.
/// Only docs bodies are HTML the rewriter touches; code bodies pass through.
enum Frag {
    Docs(String),
    Code(String),
}
@
The first pass renders every section into a fragment. A docs body is reassembled
and lowered through the Markdown dialect, which also extracts its math. A code body
is rendered straight, after resolving its highlighting language out of band: the
config default, else the chunk's own or its root's file extension. A chunk with real
code but no known language is rendered as plain text and earns one warning, never an
error. This pass is shared with the mint-only lock path so both see labels the same
way.
<<render every fragment>>=
/// Steps 1–2 (§6.2) per section: reassemble each docs body and lower it through the
/// Markdown dialect (which also extracts math), and render each code body straight.
/// Shared by `render` and the mint-only `cob lock` path so both see labels the same
/// way.
fn render_frags(
    doc: &DocModel,
    lang_cfg: &LangConfig,
    math: &mut Vec<Math>,
    defs: &mut BTreeMap<String, String>,
    lints: &mut Vec<Lint>,
) -> Result<Vec<Frag>, WeaveError> {
    let mut frags: Vec<Frag> = Vec::with_capacity(doc.sections.len());
    for section in &doc.sections {
        match &section.kind {
            SectionKind::Docs { spans } => {
                let reassembled = prose::reassemble(spans);
                let body = markdown::render(&reassembled, math, defs).map_err(|err| {
                    WeaveError::Markdown {
                        file: section.file.clone(),
                        line: section.line,
                        err,
                    }
                })?;
                frags.push(Frag::Docs(body));
            }
            SectionKind::Code {
                name,
                continues,
                spans,
                ..
            } => {
                // Resolve the language out of band (§5.5): the config default,
                // else the chunk's own or its root's file extension. A chunk with
                // real code but no known language is highlighted as plain text and
                // earns one warning — never an error.
                let lang = highlight::resolve(doc, name, lang_cfg);
                let has_code = spans.iter().any(|s| !matches!(s, CodeSpan::Nl));
                if lang.is_none() && has_code {
                    lints.push(Lint {
                        code: "W104",
                        message: format!(
                            "chunk @<<{name}@>> resolved to no known language; \
                             rendered as plain text"
                        ),
                        file: section.file.clone(),
                        line: section.line,
                    });
                }
                // The `@<<name@>>=` line is `section.line`; the body opens after it.
                let body = render_code(name, *continues, spans, section.line + 1, doc, lang);
                frags.push(Frag::Code(body));
            }
        }
    }
    Ok(frags)
}

/// Scan every docs chunk for `imports` fences and collect each
/// `\import <name> as <alias>` line (§13). It is a plain line scan, not a full
/// markdown parse, because an import declaration is one fixed shape.
fn collect_import_decls(doc: &DocModel) -> Vec<(String, String)> {
    let mut decls = Vec::new();
    for section in &doc.sections {
        let SectionKind::Docs { spans } = &section.kind else {
            continue;
        };
        let prose = prose::reassemble(spans);
        let mut in_imports = false;
        for line in prose.lines() {
            let t = line.trim();
            if in_imports {
                if t.starts_with("```") {
                    in_imports = false;
                } else if let Some(rest) = t.strip_prefix("\\import ") {
                    if let Some((name, alias)) = rest.split_once(" as ") {
                        decls.push((name.trim().to_string(), alias.trim().to_string()));
                    }
                }
            } else if t.starts_with("```") && t.trim_start_matches('`').trim() == "imports" {
                in_imports = true;
            }
        }
    }
    decls
}
@
The scan pass walks every docs body once, in order, so every labelled float is seen
before any id is assigned. It returns the collected scan and, per fragment, the
first tag it opened — a page boundary the resolver uses to split pages. A code
fragment has no first tag.
<<scan every fragment>>=
/// Step 4a: scan every docs body once, in order, so every labelled float is seen
/// before ids are assigned. Returns the collected `Scan` and the per-fragment
/// first-tag (a page boundary) so `resolve` can split pages.
fn scan_frags(frags: &[Frag]) -> Result<(Scan, Vec<Option<String>>), WeaveError> {
    let mut scan = Scan::default();
    let mut first_tags: Vec<Option<String>> = Vec::with_capacity(frags.len());
    for (i, frag) in frags.iter().enumerate() {
        match frag {
            Frag::Docs(html) => {
                let before = scan.first_tag.len();
                rewrite::scan(html, i, &mut scan).map_err(WeaveError::Rewrite)?;
                first_tags.push(scan.first_tag[before].clone());
            }
            Frag::Code(_) => first_tags.push(None),
        }
    }
    Ok((scan, first_tags))
}
@
The mint-only path is \code{cob lock}. It runs the same render and scan passes so it
sees the same labels the weaver would, then mints a frozen id for each, in document
order, into the caller's lock. It renders no math and writes no HTML — it only
grows the lock so the caller can persist it. The language config is empty because
minting needs labels and floats, not colors.
<<mint the lock without rendering>>=
/// Mint a frozen id (§7.1) for every labelled float, in document order, without
/// rendering the site. This is `cob lock`: it grows the in-memory lock so the
/// caller can persist it; it never renders math or writes HTML.
pub fn mint_lock(
    doc: &DocModel,
    lock: &mut LockFile,
    minter: &mut Minter,
) -> Result<(), WeaveError> {
    let mut math: Vec<Math> = Vec::new();
    let mut defs: BTreeMap<String, String> = BTreeMap::new();
    let mut lints: Vec<Lint> = Vec::new();
    // Minting only needs labels/floats, not colors, so the language config is empty.
    let lang_cfg = LangConfig::default();
    let frags = render_frags(doc, &lang_cfg, &mut math, &mut defs, &mut lints)?;
    let (scan, _first_tags) = scan_frags(&frags)?;
    for (label, kind, section) in mintable(&scan) {
        let file = &doc.sections[section].file;
        lock.mint(file, label, kind, minter);
    }
    Ok(())
}
@
One iterator names every label that earns a frozen id, in document order: each
labelled float first, then each deeper heading the author pinned with a section id.
A top-level heading is its own page and is addressed by the page id, so it needs no
section id and is skipped. Both the mint path and the render path walk this same
iterator, so they agree on which labels exist.
<<every mintable label>>=
/// Every label that earns a frozen opaque id (§7.1), in document order: each
/// labelled float, then each deeper heading the author pinned with a `sec:` id.
/// An h1 is its own page and is addressed by the page id, so it needs no
/// section id and is skipped. Yields `(label, kind, section)`.
fn mintable(scan: &Scan) -> impl Iterator<Item = (&str, Kind, usize)> {
    scan.labels
        .iter()
        .map(|l| (l.id.as_str(), l.kind, l.section))
        .chain(scan.headings.iter().filter_map(|h| {
            let given = h.given_id.as_deref()?;
            (h.level != 1 && Kind::from_label(given) == Some(Kind::Section))
                .then_some((given, Kind::Section, h.section))
        }))
}
@
This is the whole-document render. It renders and scans every fragment, assigns
each labelled float its frozen id (minting on miss, or failing under the locked
mode on any label the committed lock lacks), computes the document-global plan,
then rewrites each docs body against that plan. After that it renders the math, and
wraps each section in its provenance envelope — hoisting sidenotes into the margin
after math substitution, so a note that contains math carries its rendered form.
Finally it splits the wrapped sections into pages at each heading and renders each
page from the template, threading the previous and next links and the nav tree.
<<render the whole document>>=
/// Steps 1–6 (§6.2) for the whole document, then the §5.3 page split. Docs
/// bodies make two passes through the rewriter — scan, then apply — around the
/// document-global `resolve::plan`, because numbering and cross-references
/// cannot be settled until every section has been seen.
#[allow(clippy::too_many_arguments)]
pub fn render(
    doc: &DocModel,
    cache_root: &Path,
    lang_cfg: &LangConfig,
    loaded: &BTreeMap<String, site::ForestRef>,
    embed: &str,
    lock: &mut LockFile,
    mode: LockMode,
    minter: &mut Minter,
) -> Result<Site, WeaveError> {
    let mut math: Vec<Math> = Vec::new();
    let mut defs: BTreeMap<String, String> = BTreeMap::new();
    let mut hl_lints: Vec<Lint> = Vec::new();
    let mut frags = render_frags(doc, lang_cfg, &mut math, &mut defs, &mut hl_lints)?;

    // §13 imports: resolve each `\import … as …` against the loaded forest tables
    // (main reads the files), then merge the content-id macros into the table. A
    // content id colliding with a local macro of different content is E036.
    let decls = collect_import_decls(doc);
    // `import::resolve` reads only the exported macro tables; peel them off the
    // loaded forests, keyed by the `[import.<name>]` name.
    let sources: BTreeMap<String, BTreeMap<String, String>> = loaded
        .iter()
        .map(|(name, fr)| (name.clone(), fr.index.macros.clone()))
        .collect();
    let imp = import::resolve(&sources, &decls).map_err(WeaveError::Import)?;
    // Cross-document `\ref`/`\transclude` resolve against the forest behind an
    // alias, so re-key the loaded forests by the document's alias (from the
    // `imports` fence), not the config name.
    let by_alias: BTreeMap<String, site::ForestRef> = decls
        .iter()
        .filter_map(|(name, alias)| loaded.get(name).map(|fr| (alias.clone(), fr.clone())))
        .collect();
    // The import edges for the page chrome's "Imports" list and for `site.json`.
    let import_links: Vec<site::ImportLink> = decls
        .iter()
        .map(|(name, alias)| site::ImportLink {
            name: name.clone(),
            alias: alias.clone(),
        })
        .collect();
    for (name, expansion) in &imp.macros {
        match defs.get(name) {
            Some(existing) if existing != expansion => {
                return Err(WeaveError::Import(import::ImportError::Collision(name.clone())));
            }
            _ => {
                defs.insert(name.clone(), expansion.clone());
            }
        }
    }

    let (scan, first_tags) = scan_frags(&frags)?;

    // Assign each labelled float its frozen opaque id (§7.1): mint on miss (and
    // let the caller persist the grown lock), or — under `--locked` — fail on any
    // label the committed lock does not already carry.
    let mut label_ids = LabelIds::new();
    for (label, kind, section) in mintable(&scan) {
        let file = &doc.sections[section].file;
        let id = match mode {
            LockMode::Mint => lock.mint(file, label, kind, minter),
            LockMode::Locked => match lock.get(file, label) {
                Some(entry) => entry.id.clone(),
                None => {
                    return Err(WeaveError::Lock(LockError::Missing {
                        file: file.clone(),
                        label: label.to_string(),
                    }))
                }
            },
        };
        label_ids.insert(label.to_string(), id);
    }

    let res = resolve::plan(doc, &scan, &first_tags, &label_ids, &by_alias)
        .map_err(WeaveError::Resolve)?;

    // Step 4b: rewrite each docs body against the resolved plan.
    let mut plan = Plan::new(&res.heading_anchors, &res.heading_uids, &res.refs, &label_ids);
    for frag in frags.iter_mut() {
        if let Frag::Docs(html) = frag {
            *html = rewrite::apply(html, &mut plan).map_err(WeaveError::Rewrite)?;
        }
    }

    // Steps 5–6: serialize is implicit in the rewriter; now render math and
    // wrap each section in its provenance envelope.
    let rendered = Renderer::new(cache_root, &defs, &imp.rewrites)
        .render_all(&math)
        .map_err(WeaveError::Math)?;
    let mut wrapped: Vec<String> = Vec::with_capacity(frags.len());
    // The inner body of each section, before the provenance envelope — the source
    // transclusion cuts node bodies from, at heading boundaries (§10).
    let mut bodies: Vec<String> = Vec::with_capacity(frags.len());
    let mut raws: Vec<site::RawSection> = Vec::with_capacity(frags.len());
    // Document-global so sidenote ids are unique and stable across pages (§8).
    let mut sn = 0usize;
    for (section, frag) in doc.sections.iter().zip(&frags) {
        let (class, chunk, is_docs, body) = match frag {
            Frag::Docs(html) => ("docs", None, true, html.as_str()),
            Frag::Code(html) => {
                let name = match &section.kind {
                    SectionKind::Code { name, .. } => Some(name.as_str()),
                    _ => None,
                };
                ("code", name, false, html.as_str())
            }
        };
        let body = prose::substitute_math(body, &rendered);
        // Sidenotes are hoisted after math substitution so a note that contains
        // math carries the rendered KaTeX into its margin[] entry (§8).
        let (page_body, raw) = if is_docs {
            let h = site::hoist_sidenotes(&body, &mut sn);
            (
                h.page_html,
                site::RawSection {
                    html: h.json_html,
                    margins: h.margins,
                },
            )
        } else {
            (
                body.clone(),
                site::RawSection {
                    html: body,
                    margins: Vec::new(),
                },
            )
        };
        raws.push(raw);
        bodies.push(page_body.clone());
        wrapped.push(wrap_section(
            &section.id,
            class,
            &section.file,
            section.line,
            chunk,
            &page_body,
        ));
    }

    // §10 transclusion: splice each `\transclude` placeholder's node into its
    // host section, recursively, before the page split — so a copy rides on its
    // host's page. Node bodies are cut from the inner section bodies at heading
    // boundaries, so the placeholder's own host section is byte-unchanged unless
    // it carries a directive, and the archival JSON (built above from
    // pre-expansion bodies) is untouched. The scope counter is document-wide, so
    // every copy's scoped ids are unique and the output stays deterministic (§8).
    let mut tx = transclude::Context::build(&scan, &res, &bodies, &by_alias);
    // §10 a `def:` (macros) node is homeless: the table has just captured it, so
    // drop the canonical island from the reading flow and the archival JSON before
    // transclusion runs. No transcluded copy exists yet, so every island is
    // canonical; the exposition now shows only on its `n/` page and where it is
    // transcluded.
    for w in wrapped.iter_mut() {
        *w = rewrite::strip_macros(w).map_err(WeaveError::Rewrite)?;
    }
    for raw in raws.iter_mut() {
        raw.html = rewrite::strip_macros(&raw.html).map_err(WeaveError::Rewrite)?;
    }
    let mut tx_lints: Vec<Lint> = Vec::new();
    for (k, w) in wrapped.iter_mut().enumerate() {
        let sec = &doc.sections[k];
        // A document page reaches a node page under `n/`, so the transclusion `src`
        // takes the `n/` prefix. The body is not spliced; the client fetches it.
        *w = tx.expand(w, "n/", &mut tx_lints, &sec.file, sec.line);
    }
    // §10 node pages: turn their islands into `<cob-transclude>` too and rebase
    // their links for the `n/` directory.
    tx.finish_node_pages();

    // §5.3 page split: group wrapped sections by their assigned page.
    let mut env = minijinja::Environment::new();
    env.add_template("page", include_str!("../templates/page.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    env.add_template("sitemap", include_str!("../templates/sitemap.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    env.add_template("node", include_str!("../templates/node.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    // The shared progressive-enhancement scripts (nav-spy + cob-transclude), so a
    // page and a node page carry the same, single copy (§5.3, §10).
    env.add_template("scripts", include_str!("../templates/scripts.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    let tmpl = env
        .get_template("page")
        .map_err(|e| WeaveError::Template(e.to_string()))?;

    let mut pages = Vec::with_capacity(res.pages.len());
    for (pi, meta) in res.pages.iter().enumerate() {
        let sections: Vec<&str> = wrapped
            .iter()
            .zip(&res.section_page)
            .filter(|(_, p)| **p == pi)
            .map(|(html, _)| html.as_str())
            .collect();
        // The nav marks this page's own landing entry current, so each page ships
        // its own "you are here" (§5.3) — static, no script, every browser.
        let nav = nav_context(&res.nav, &meta.filename);
        let prev = pi.checked_sub(1).map(|j| link_context(&res.pages[j]));
        let next = res.pages.get(pi + 1).map(link_context);
        let html = tmpl
            .render(minijinja::context! {
                title => meta.title,
                sections,
                embed,
                nav,
                prev,
                next,
                imports => &import_links,
            })
            .map_err(|e| WeaveError::Template(e.to_string()))?;
        pages.push(RenderedPage {
            meta: meta.clone(),
            html,
        });
    }

    // One standalone sitemap page: the whole nav tree, styled by cob.css. The
    // title is the first page's, so the sitemap names the document it maps. It
    // highlights nothing — an empty current means no entry is the current page.
    let site_title = res.pages.first().map_or("cob", |m| m.title.as_str());
    let sitemap = env
        .get_template("sitemap")
        .map_err(|e| WeaveError::Template(e.to_string()))?
        .render(minijinja::context! { title => site_title, nav => nav_context(&res.nav, "") })
        .map_err(|e| WeaveError::Template(e.to_string()))?;

    // §10 node pages: one `n/<id>.html` per heading node — the node body on its
    // own, a breadcrumb of parents, a link to the node in context, and the
    // backlinks. Nav and asset links get a `../` prefix because the page sits one
    // directory down. The nav marks nothing current here.
    let node_tmpl = env
        .get_template("node")
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    let based_nav = rebased_nav(&res.nav, "../");
    let mut node_pages = Vec::with_capacity(tx.node_pages().len());
    for np in tx.node_pages() {
        let html = node_tmpl
            .render(minijinja::context! {
                title => np.title,
                body => np.body,
                context => np.context,
                crumbs => links_context(&np.crumbs),
                transcluded_by => links_context(&np.transcluded_by),
                referenced_by => links_context(&np.referenced_by),
                embed,
                nav => based_nav,
            })
            .map_err(|e| WeaveError::Template(e.to_string()))?;
        node_pages.push((format!("n/{}.html", np.id), html));
    }

    let mut json = site::build(doc, &res, &raws, site::Meta::default());
    json.imports = import_links;

    let mut lints = res.lints;
    lints.extend(hl_lints);
    lints.extend(tx_lints);

    Ok(Site {
        pages,
        node_pages,
        sitemap,
        math_count: math.len(),
        lints,
        json,
        macros: defs,
    })
}
@
The template contexts turn a page's metadata into the values the template reads: a
link is a title and a filename; a nav node is a title, an href, its children, and a
\code{current} flag. \code{current} is true when the node is the landing entry of the page now
being woven — an h1's href is exactly that page's filename (\code{resolve.rs}). Because
cob renders every page on its own, it knows which entry is current and marks it
statically, so the nav shows the reader's place with no script and in every browser.
The sitemap passes an empty current, so it highlights nothing.
<<the page link and nav context>>=
fn link_context(meta: &PageMeta) -> minijinja::Value {
    minijinja::context! { title => meta.title, href => meta.filename }
}

fn nav_context(nodes: &[NavNode], current: &str) -> Vec<minijinja::Value> {
    nodes
        .iter()
        .map(|n| {
            minijinja::context! {
                title => n.title,
                href => n.href,
                current => n.href == current,
                children => nav_context(&n.children, current),
            }
        })
        .collect()
}
@
A node page sits one directory down, so its nav links need a \code{../} prefix; it
marks nothing current. A breadcrumb step and a backlink are each a title and an
href, so one helper serves both.
<<the node page context>>=
fn rebased_nav(nodes: &[NavNode], base: &str) -> Vec<minijinja::Value> {
    nodes
        .iter()
        .map(|n| {
            minijinja::context! {
                title => n.title,
                href => format!("{base}{}", n.href),
                current => false,
                children => rebased_nav(&n.children, base),
            }
        })
        .collect()
}

fn links_context(links: &[transclude::Link]) -> Vec<minijinja::Value> {
    links
        .iter()
        .map(|l| minijinja::context! { title => l.title, href => l.href })
        .collect()
}
@
KaTeX's CSS and fonts are mandatory, not decorative: without the stylesheet both
the MathML and HTML layers render and every equation appears twice. They are copied
in from the pinned dist, never linked to a CDN, so the site stays a sealed
artifact. The old copy is cleared first because files from the read-only Nix store
keep their read-only mode. Only the woff2 fonts are shipped — every browser that
renders MathML supports it — and they are sorted before copying, for deterministic
output.
<<copy the katex assets>>=
<<the embedded katex dist>>

/// KaTeX's CSS and fonts are mandatory, not decorative: without the stylesheet
/// the MathML and HTML layers both render and every equation appears twice.
/// They are written in, never CDN-linked, so the site stays a sealed artifact.
///
/// The dist comes from one of two places. `COB_KATEX_ASSETS` (a directory, set by
/// the Nix wrapper/devShell) wins when present — a Nix deployment points it at the
/// pinned store path. Otherwise a standalone binary uses the copy baked in at
/// build time (feature `embed-assets`). A build with neither is an error (E023).
fn copy_katex_assets(out: &Path) -> Result<(), WeaveError> {
    let dst = out.join("katex");
    // Files copied from the read-only Nix store keep their read-only mode, so a
    // second weave into the same directory can't overwrite them. Clear first.
    match std::fs::remove_dir_all(&dst) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(WeaveError::Io(e)),
    }
    std::fs::create_dir_all(dst.join("fonts")).map_err(WeaveError::Io)?;

    match std::env::var("COB_KATEX_ASSETS") {
        Ok(src) => copy_katex_from(&PathBuf::from(src), &dst),
        Err(_) => write_embedded_katex(&dst),
    }
}

/// Copy the dist out of a directory (the Nix store path in `COB_KATEX_ASSETS`).
fn copy_katex_from(src: &Path, dst: &Path) -> Result<(), WeaveError> {
    let css = src.join("katex.min.css");
    std::fs::copy(&css, dst.join("katex.min.css"))
        .map_err(|e| WeaveError::Assets(format!("copying {}: {e}", css.display())))?;

    // woff2 only: every browser that renders MathML supports it, and shipping
    // woff/ttf as well would quadruple the artifact for no reader.
    let fonts = src.join("fonts");
    let entries = std::fs::read_dir(&fonts)
        .map_err(|e| WeaveError::Assets(format!("reading {}: {e}", fonts.display())))?;
    let mut names: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "woff2"))
        .collect();
    names.sort(); // deterministic output (§8)
    for path in names {
        if let Some(name) = path.file_name() {
            std::fs::copy(&path, dst.join("fonts").join(name)).map_err(WeaveError::Io)?;
        }
    }
    Ok(())
}

/// Write the dist baked into the binary. `FILES` is sorted, so output stays
/// deterministic (§8). Only compiled with the `embed-assets` feature.
#[cfg(feature = "embed-assets")]
fn write_embedded_katex(dst: &Path) -> Result<(), WeaveError> {
    for (name, bytes) in embedded_katex::FILES {
        std::fs::write(dst.join(name), bytes).map_err(WeaveError::Io)?;
    }
    Ok(())
}

/// Without `embed-assets` there is nothing baked in, so an unset
/// `COB_KATEX_ASSETS` is E023 — the same as before embedding existed.
#[cfg(not(feature = "embed-assets"))]
fn write_embedded_katex(_dst: &Path) -> Result<(), WeaveError> {
    Err(WeaveError::Assets(
        "COB_KATEX_ASSETS is unset and this build embeds no KaTeX dist; it points \
         at the pinned dist and is set by the devShell and the wrapped package — \
         run inside `nix develop`, or build with `--features embed-assets` for a \
         standalone binary"
            .to_string(),
    ))
}
@
The embedded dist is \code{include_bytes!}d from the pinned \code{COB_KATEX_ASSETS} at build
time, so the version pin stays in the flake (§6.3) and no fonts are vendored in the
source tree. The font list is fixed for the pinned KaTeX version; a bump changes
the list here and the hash in the flake together. This module exists only under
the \code{embed-assets} feature, so a default build never reads the env at compile time.
<<the embedded katex dist>>=
/// The pinned KaTeX dist, baked in at build time from `COB_KATEX_ASSETS` for a
/// standalone binary. Kept sorted for deterministic output (§8).
#[cfg(feature = "embed-assets")]
mod embedded_katex {
    macro_rules! font {
        ($n:literal) => {
            (
                concat!("fonts/", $n),
                include_bytes!(concat!(env!("COB_KATEX_ASSETS"), "/fonts/", $n)) as &[u8],
            )
        };
    }
    pub static FILES: &[(&str, &[u8])] = &[
        (
            "katex.min.css",
            include_bytes!(concat!(env!("COB_KATEX_ASSETS"), "/katex.min.css")) as &[u8],
        ),
        font!("KaTeX_AMS-Regular.woff2"),
        font!("KaTeX_Caligraphic-Bold.woff2"),
        font!("KaTeX_Caligraphic-Regular.woff2"),
        font!("KaTeX_Fraktur-Bold.woff2"),
        font!("KaTeX_Fraktur-Regular.woff2"),
        font!("KaTeX_Main-Bold.woff2"),
        font!("KaTeX_Main-BoldItalic.woff2"),
        font!("KaTeX_Main-Italic.woff2"),
        font!("KaTeX_Main-Regular.woff2"),
        font!("KaTeX_Math-BoldItalic.woff2"),
        font!("KaTeX_Math-Italic.woff2"),
        font!("KaTeX_SansSerif-Bold.woff2"),
        font!("KaTeX_SansSerif-Italic.woff2"),
        font!("KaTeX_SansSerif-Regular.woff2"),
        font!("KaTeX_Script-Regular.woff2"),
        font!("KaTeX_Size1-Regular.woff2"),
        font!("KaTeX_Size2-Regular.woff2"),
        font!("KaTeX_Size3-Regular.woff2"),
        font!("KaTeX_Size4-Regular.woff2"),
        font!("KaTeX_Typewriter-Regular.woff2"),
    ];
}
@
The top-level entry loads the lock, renders the whole document, then writes it to
disk. A dev-time weave writes any newly minted ids back so they freeze; the locked
mode never mints, so it never touches the committed lock. It writes every page, the
sitemap page, the stylesheet, and the KaTeX assets. The archival JSON is opt-in: plain weave stays an
HTML-only artifact, and the archive flag adds the whole-document JSON plus one
per-page file beside its HTML for the annotation layer.
<<write the site to disk>>=
#[allow(clippy::too_many_arguments)]
pub fn write_site(
    doc: &DocModel,
    out: &Path,
    cache_root: &Path,
    lock_path: &Path,
    meta: site::Meta,
    lang_cfg: &LangConfig,
    loaded: &BTreeMap<String, site::ForestRef>,
    archive: bool,
    mode: LockMode,
) -> Result<Site, WeaveError> {
    let mut lock = LockFile::load(lock_path).map_err(WeaveError::Lock)?;
    let mut minter = Minter::from_entropy();
    let mut site = render(doc, cache_root, lang_cfg, loaded, "", &mut lock, mode, &mut minter)?;
    // A dev-time weave writes any newly minted ids back so they freeze (§7.1);
    // `--locked` never mints, so it never touches the committed lock.
    if mode == LockMode::Mint {
        lock.save(lock_path).map_err(WeaveError::Lock)?;
    }
    site.json.meta = meta;
    std::fs::create_dir_all(out).map_err(WeaveError::Io)?;
    for page in &site.pages {
        std::fs::write(out.join(&page.meta.filename), &page.html).map_err(WeaveError::Io)?;
    }
    // §10 node pages live under `n/`; create it once, then write each.
    if !site.node_pages.is_empty() {
        std::fs::create_dir_all(out.join("n")).map_err(WeaveError::Io)?;
        for (path, html) in &site.node_pages {
            std::fs::write(out.join(path), html).map_err(WeaveError::Io)?;
        }
    }
    std::fs::write(out.join("sitemap.html"), &site.sitemap).map_err(WeaveError::Io)?;
    std::fs::write(out.join("cob.css"), include_str!("../templates/cob.css"))
        .map_err(WeaveError::Io)?;
    // The syntax palette is a separate file imported by cob.css via @import; both
    // must be present in the output for the import to resolve offline.
    std::fs::write(out.join("cob-syntax.css"), include_str!("../templates/cob-syntax.css"))
        .map_err(WeaveError::Io)?;
    copy_katex_assets(out)?;
    // The archival JSON (§8) is opt-in: plain `weave` stays an HTML-only
    // artifact. Per-page files sit beside their HTML for the annotation layer.
    if archive {
        std::fs::write(out.join("site.json"), site::to_json(&site.json)).map_err(WeaveError::Io)?;
        for id in site.json.page_ids() {
            let json =
                site::page_json(&site.json, &id).expect("page id came from site.json.pages");
            std::fs::write(out.join(format!("{id}.json")), json).map_err(WeaveError::Io)?;
        }
        // The forest index (§13): the importable macro table and label index, so
        // another forest can `\import`/`\ref`/`\transclude` this one without
        // re-rendering it.
        std::fs::write(
            out.join("cob-exports.json"),
            site::to_exports_json(&site.macros, &site.json.labels),
        )
        .map_err(WeaveError::Io)?;
    }
    Ok(site)
}
@
The tests exercise the whole weaver against the pinned fixtures: the hello fixture
for the single-page invariants and the book fixture for pages, floats, and
cross-references, with the md fixture for the Markdown dialect. Each test is its
own chunk; the shared scaffolding builds a model from a fixture and renders it with
a fixed-seed minter so float ids are deterministic within a run.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;
    use crate::lock::ID_LEN;

    <<test scaffolding>>

    <<a locked weave errors on a missing label>>

    <<assertion helpers over rendered html>>

    <<a page carries provenance and margin slots>>

    <<the continuation marker matches noweb>>

    <<chunk uses link to the first definition>>

    <<math is rendered not left as a placeholder>>

    <<a page carries only the enhancement scripts>>

    <<quoted code renders as escaped code>>

    <<an escaped dollar survives to output>>

    <<a code body is html escaped>>

    <<chunks are collapsible and open by default>>

    <<line numbers are nw coordinates in attributes>>

    <<rust root chunks are highlighted and holes stay opaque>>

    <<a no-language chunk falls back to plain text>>

    <<the chunk terminator adds no empty line>>

    <<an embed snippet is injected>>

    <<output is byte deterministic>>

    <<the book splits into three pages>>

    <<a page-boundary heading becomes the page id>>

    <<floats are identified by opaque id only>>

    <<cross-page refs are page qualified>>

    <<a labelled section carries a clickable uid>>

    <<a chunk ref links into code>>

    <<the nav tree is on every page>>

    <<the sitemap lists every page>>

    <<site json is current schema and hoists sidenotes>>

    <<footer pagination links neighbours>>

    <<the markdown dialect renders prose and fenced math>>

    <<markdown fenced floats are labelled and referenced>>

    <<transclusion cuts a heading node and scopes the copy>>

    <<every node gets a standalone page with context and backlinks>>

    <<a float is a node with its own page and can be transcluded>>
}
@
The scaffolding builds a model from a fixture's markup and renders it. The
fixed-seed minter makes float ids deterministic within a run; their exact value is
arbitrary, since the lock module owns the minting contract.
<<test scaffolding>>=
fn model_of(markup: &str) -> DocModel {
    crate::model::build(&crate::noweb::parse(markup).unwrap()).unwrap()
}

fn fixture() -> DocModel {
    model_of(include_str!("../fixtures/hello.markup"))
}

fn book() -> DocModel {
    model_of(include_str!("../fixtures/book.markup"))
}

fn md() -> DocModel {
    model_of(include_str!("../fixtures/md.markup"))
}

fn tx() -> DocModel {
    model_of(include_str!("../fixtures/tx.markup"))
}

fn txf() -> DocModel {
    model_of(include_str!("../fixtures/txf.markup"))
}

fn cache() -> PathBuf {
    std::env::temp_dir().join("cob-weave-test-cache")
}

/// A dev-time render with an in-memory lock and a fixed-seed minter, so float
/// ids are deterministic within a test run (their exact value is arbitrary —
/// `lock.rs` owns the minting contract).
fn dev_render(doc: &DocModel, embed: &str) -> Site {
    dev_render_lang(doc, None, embed)
}

fn dev_render_lang(doc: &DocModel, lang: Option<Lang>, embed: &str) -> Site {
    let mut lock = LockFile::default();
    let mut minter = Minter::seeded(1);
    let lang_cfg = LangConfig::with_default(lang);
    render(
        doc,
        &cache(),
        &lang_cfg,
        &BTreeMap::new(),
        embed,
        &mut lock,
        LockMode::Mint,
        &mut minter,
    )
    .unwrap()
}
@
A locked weave with an empty lock cannot supply the frozen ids the book's floats
need, so it must fail with the missing-label error rather than mint.
<<a locked weave errors on a missing label>>=
#[test]
fn locked_weave_errors_on_a_label_absent_from_the_lock() {
    // book.cob carries labelled floats; an empty lock under `--locked` cannot
    // supply their frozen ids, so weave must fail with E031 rather than mint.
    let mut lock = LockFile::default();
    let mut minter = Minter::seeded(1);
    let lang_cfg = LangConfig::default();
    let err = match render(
        &book(),
        &cache(),
        &lang_cfg,
        &BTreeMap::new(),
        "",
        &mut lock,
        LockMode::Locked,
        &mut minter,
    ) {
        Ok(_) => panic!("a locked weave with an empty lock must not succeed"),
        Err(e) => e,
    };
    assert!(matches!(err, WeaveError::Lock(LockError::Missing { .. })));
    assert!(err.to_string().contains("E031"));
}
@
Two assertion helpers over rendered HTML. One reads the frozen id off the float
anchored at a given id; ids are exactly four characters. One renders the hello
fixture — a single page — as a string. One strips only the color wrappers, keeping
every structural span and text node, so a structural assertion can ignore coloring.
<<assertion helpers over rendered html>>=
/// The frozen opaque id stamped on the float anchored at `anchor` (§7.1);
/// ids are exactly four characters.
fn id_at(html: &str, anchor: &str) -> String {
    let needle = format!("id=\"{anchor}\" data-id=\"");
    let start = html.find(&needle).expect("anchor carries a data-id") + needle.len();
    html[start..start + 4].to_string()
}

/// The hello fixture opens with a single `<h1>`, so it is one `index` page.
fn hello_html() -> String {
    dev_render(&fixture(), "").all_html()
}

/// Drop only the `tok-*` highlight wrappers, keeping `.line`/`.chunk-name`
/// spans and every text node, so a structural assertion can ignore coloring.
/// Relies on spans being properly nested (they are, by construction).
fn strip_tok(html: &str) -> String {
    let mut out = String::new();
    let mut span_is_tok: Vec<bool> = Vec::new();
    let mut i = 0;
    while i < html.len() {
        let tail = &html[i..];
        if tail.starts_with("<span") {
            let end = i + tail.find('>').unwrap() + 1;
            let tag = &html[i..end];
            let is_tok = tag.contains("class=\"tok-");
            span_is_tok.push(is_tok);
            if !is_tok {
                out.push_str(tag);
            }
            i = end;
        } else if tail.starts_with("</span>") {
            if !span_is_tok.pop().unwrap_or(false) {
                out.push_str("</span>");
            }
            i += "</span>".len();
        } else {
            let c = tail.chars().next().unwrap();
            out.push(c);
            i += c.len_utf8();
        }
    }
    out
}
@
Every section carries its source file and line, a docs section its id, and a code
section its chunk name and a margin slot.
<<a page carries provenance and margin slots>>=
#[test]
fn page_has_provenance_and_margin_slots() {
    let html = hello_html();
    assert!(html.contains(
        "<section class=\"docs\" id=\"sec-1\" data-nw-file=\"fixtures/hello.cob\" data-nw-line=\"1\">"
    ));
    assert!(html.contains("data-nw-line=\"6\" data-chunk=\"lex a token\""));
    assert!(html.contains("<div class=\"margin-slot\" data-for=\"sec-2\"></div>"));
}
@
The definition and continuation markers follow noweb's convention in the chunk
header.
<<the continuation marker matches noweb>>=
#[test]
fn continuation_marker_matches_noweb_convention() {
    let html = hello_html();
    assert!(html.contains("<dfn>lex a token</dfn>&gt;&gt;="));
    assert!(html.contains("<dfn>lex a token</dfn>&gt;&gt;+="));
}
@
A chunk use links to the first section that defines the named chunk, even when the
definition comes later in the document — a forward reference resolved against the
finished model.
<<chunk uses link to the first definition>>=
#[test]
fn chunk_uses_link_to_first_definition() {
    let html = hello_html();
    // `next char` is defined in sec-8 and used in sec-2 — a forward
    // reference, so the link must resolve against the finished model.
    assert!(html.contains("<a href=\"#sec-8\">&lt;<i>next char</i>&gt;</a>"));
    assert!(html.contains("<a href=\"#sec-2\">&lt;<i>lex a token</i>&gt;</a>"));
}
@
Math is rendered by KaTeX at weave time, not left as a placeholder, and the
angle-bracket case survives as an entity rather than becoming a tag.
<<math is rendered not left as a placeholder>>=
#[test]
fn math_is_rendered_not_left_as_placeholder() {
    let site = dev_render(&fixture(), "");
    let html = site.all_html();
    assert_eq!(site.math_count, 2);
    assert!(!html.contains("data-cob-math"));
    assert!(html.contains("katex"));
    // The angle-bracket case must survive as an entity, never a tag.
    assert!(!html.contains("<span>a < b</span>"));
}
@
A page carries only the two progressive-enhancement aids — the \code{nav-spy} and
\code{cob-transclude} scripts — and no other script. This is the §6.3 modularity guard:
math renders at weave time and transclusion is a lazy element, so nothing the
content depends on is ever a script, and none leaks in.
<<a page carries only the enhancement scripts>>=
#[test]
fn a_page_carries_only_the_enhancement_scripts() {
    let html = &dev_render(&fixture(), "").pages[0].html;
    let total = html.matches("<script").count();
    let named = html.matches("<script id=\"nav-spy\">").count()
        + html.matches("<script id=\"cob-transclude\">").count();
    assert_eq!(total, named, "a page carried a script that is not an enhancement aid");
    assert!(html.contains("<script id=\"nav-spy\">"));
    assert!(html.contains("<script id=\"cob-transclude\">"));
}
@
A \code{\code{…}} span in prose renders as an escaped inline code element.
<<quoted code renders as escaped code>>=
#[test]
fn quoted_code_renders_as_escaped_code() {
    let html = hello_html();
    assert!(html.contains("<code>lex()</code>"));
    assert!(html.contains("<code>tokens[0]</code>"));
}
@
An escaped dollar in prose survives to the output as a literal dollar sign, not the
start of a math run.
<<an escaped dollar survives to output>>=
#[test]
fn escaped_dollar_survives_to_output() {
    assert!(hello_html().contains("cost is $5."));
}
@
A code body is HTML-escaped. The hello root is a Rust file, so its chunks highlight
as Rust; stripping the color leaves the escaped plain-text payload intact.
<<a code body is html escaped>>=
#[test]
fn code_body_is_html_escaped() {
    // hello.cob's root is `src/main.rs`, so its chunks now highlight as Rust
    // (§5.5); the escaped plain-text payload must survive under the coloring.
    let html = strip_tok(&hello_html());
    assert!(html.contains("println!(&quot;{count}&quot;);"));
    assert!(html.contains("let mut tokens = vec![];"));
}
@
A chunk is a foldable block, open by default, with its header in the summary so a
collapsed chunk still shows which chunk a cross-reference landed on.
<<chunks are collapsible and open by default>>=
#[test]
fn chunks_are_collapsible_and_open_by_default() {
    let html = hello_html();
    assert!(html.contains("<details class=\"chunk\" open><summary>"));
    // The header lives in the summary, so a collapsed chunk still shows
    // which chunk a cross-reference landed on.
    assert!(html.contains("<dfn>next char</dfn>&gt;&gt;=</span></summary>"));
}
@
Line numbers are source coordinates carried in an attribute, never text. Stripping
the color leaves the coordinate and payload reading the same, and no number appears
as a copyable text node.
<<line numbers are nw coordinates in attributes>>=
#[test]
fn line_numbers_are_nw_coordinates_in_attributes() {
    // Coloring nests inside each `.line`; strip it so the coordinate + payload
    // invariant reads the same whether or not the chunk highlights.
    let html = strip_tok(&hello_html());
    // fixtures/hello.cob: `@<<next char@>>=` is line 22, its one body line 23.
    assert!(html
        .contains("<span class=\"line\" data-line=\"23\">input.next().unwrap()</span></pre>"));
    // src/main.rs opens at line 28; `println!` is the fifth body line.
    assert!(html.contains("<span class=\"line\" data-line=\"29\">fn main() {</span>"));
    assert!(html.contains("data-line=\"33\">    println!(&quot;{count}&quot;);</span>"));
    // Numbers are never text, so they cannot be copied or quoted.
    assert!(!html.contains(">23 input"));
}
@
The Rust root colors its chunks — keywords and strings become tokens — while the
chunk-use hole is spliced back verbatim and never wrapped in a color span.
<<rust root chunks are highlighted and holes stay opaque>>=
#[test]
fn rust_root_chunks_are_highlighted_and_holes_stay_opaque() {
    // hello.cob's root is `src/main.rs`, so tier-3 resolution colors it as Rust
    // (§5.5): `let`/`fn` are keywords, the format string is a string token.
    let html = hello_html();
    assert!(html.contains("class=\"tok-keyword\">let</span>"));
    assert!(html.contains("class=\"tok-string\">&quot;{count}&quot;</span>"));
    // The chunk-use hole is spliced back verbatim and never wrapped in a color
    // span — its `<a>` sits directly inside the `.line`, as §5.4 requires.
    assert!(html.contains("<a href=\"#sec-8\">&lt;<i>next char</i>&gt;</a>"));
    assert!(!html.contains("tok-") || !html.contains("tok-\">&lt;<i>"));
}
@
A root whose name carries no known extension resolves to no language, so its body
is plain escaped text and earns exactly one warning.
<<a no-language chunk falls back to plain text>>=
#[test]
fn a_no_language_chunk_falls_back_to_plain_text_with_one_warning() {
    // A root whose name carries no known extension resolves to no language, so
    // its body is emitted as plain escaped text and earns exactly one W104.
    let doc = model_of(
        "@file plain.cob\n\
         @begin docs 0\n@text # Plain\n@nl\n@end docs 0\n\
         @begin code 1\n@defn notes.txt\n@nl\n\
         @text let x = 1;\n@nl\n@end code 1\n",
    );
    let site = dev_render(&doc, "");
    let html = site.all_html();
    assert!(html.contains("<span class=\"line\" data-line=\"3\">let x = 1;</span>"));
    assert!(!html.contains("tok-"));
    let w104: Vec<_> = site.lints.iter().filter(|l| l.code == "W104").collect();
    assert_eq!(w104.len(), 1);
    assert!(w104[0].message.contains("notes.txt"));
}
@
The newline that terminates a chunk opens a line with no source line, so no empty
trailing line is emitted.
<<the chunk terminator adds no empty line>>=
#[test]
fn chunk_terminator_adds_no_empty_line() {
    let html = hello_html();
    assert!(!html.contains("data-line=\"24\""));
    assert!(!html.contains("data-line=\"35\""));
}
@
The embed snippet passed to the render is injected into the page verbatim.
<<an embed snippet is injected>>=
#[test]
fn embed_snippet_is_injected() {
    let site = dev_render(&fixture(), "<script src=\"x.js\"></script>");
    assert!(site.all_html().contains("<script src=\"x.js\"></script>"));
}
@
Two renders of the same input produce byte-identical HTML.
<<output is byte deterministic>>=
#[test]
fn output_is_byte_deterministic() {
    let a = dev_render(&book(), "");
    let b = dev_render(&book(), "");
    assert_eq!(a.all_html(), b.all_html());
}
@
The book splits into three pages at each top-level heading, and a chunk defined
under one heading lands on that heading's page.
<<the book splits into three pages>>=
#[test]
fn book_splits_into_three_pages_at_h1() {
    let site = dev_render(&book(), "");
    let files: Vec<&str> = site.pages.iter().map(|p| p.meta.filename.as_str()).collect();
    assert_eq!(files, vec!["index.html", "parsing.html", "codegen.html"]);
    // The `lex a token` chunk was defined under Parsing, so it lands there.
    assert!(site.pages[1].html.contains("data-chunk=\"lex a token\""));
    assert!(!site.pages[0].html.contains("data-chunk=\"lex a token\""));
}
@
A page-boundary heading becomes the page id and is stamped on the heading anchor.
<<a page-boundary heading becomes the page id>>=
#[test]
fn page_boundary_h1_becomes_the_page_id() {
    let site = dev_render(&book(), "");
    assert!(site.pages[1].html.contains("<h1 id=\"parsing\">Parsing</h1>"));
    assert!(site.pages[0].html.contains("<h1 id=\"index\">Front matter</h1>"));
}
@
Each labelled float carries its frozen opaque id as an attribute and repeats it on
the caption, with no sequential number anywhere; an opted-out equation keeps no id.
<<floats are identified by opaque id only>>=
#[test]
fn floats_are_identified_by_opaque_id_in_attributes_only() {
    let html = dev_render(&book(), "").all_html();
    // Each labeled float carries its frozen opaque id (§7.1) as data-id, and
    // its caption repeats the same id so CSS can draw "Figure <id>" once.
    let fig = id_at(&html, "fig-pipeline");
    assert!(html.contains(&format!(
        "<figcaption data-id=\"{fig}\">The weave pipeline.\
         <a class=\"node-link\" href=\"n/{fig}.html\" aria-label=\"node page\"></a></figcaption>"
    )));
    let eq = id_at(&html, "eq-cost");
    assert_eq!(eq.len(), ID_LEN as usize);
    // An equation has no caption, so its node-page link (§10) rides the block.
    assert!(html.contains(&format!(
        "<a class=\"node-link\" href=\"n/{eq}.html\" aria-label=\"node page\"></a>"
    )));
    let tbl = id_at(&html, "tbl-opcodes");
    assert!(html.contains(&format!(
        "<caption data-id=\"{tbl}\">Opcodes.\
         <a class=\"node-link\" href=\"n/{tbl}.html\" aria-label=\"node page\"></a></caption>"
    )));
    // No numbers anywhere — identity is the opaque id, never a sequential
    // count injected into a node.
    assert!(!html.contains("data-number"));
    // The opted-out equation keeps no id.
    assert!(html.contains("data-nonumber"));
    assert!(!html.contains("data-nonumber data-id"));
}
@
A cross-page reference names its target page in the href and gets generated text
built from the target's opaque id, keeping author-supplied link text when present.
<<cross-page refs are page qualified>>=
#[test]
fn cross_page_refs_are_page_qualified_and_get_generated_text() {
    let site = dev_render(&book(), "");
    let fig = id_at(&site.pages[1].html, "fig-pipeline");
    // Front matter (index) refers forward to a figure and equation on later
    // pages; both hrefs must name the target page, and the generated text is
    // "Figure <opaque id>" (§7.1), not a sequential number.
    assert!(site.pages[0].html.contains(&format!(
        "<a data-ref=\"fig:pipeline\" href=\"parsing.html#fig-pipeline\">Figure {fig}</a>"
    )));
    // The equation ref uses generated text ("Equation <id>"); the prose names
    // the cost bound around it.
    assert!(site.pages[0].html.contains("the cost"));
    assert!(site.pages[0]
        .html
        .contains("<a data-ref=\"eq:cost\" href=\"parsing.html#eq-cost\">"));
    // Codegen refers back to the same figure on the Parsing page.
    assert!(site.pages[2]
        .html
        .contains(&format!("href=\"parsing.html#fig-pipeline\">Figure {fig}</a>")));
}
@
A labelled section leads with an empty permalink anchor whose opaque id lives in an
attribute, and a cross-page reference back to it reuses the very same id.
<<a labelled section carries a clickable uid>>=
#[test]
fn labelled_section_carries_a_clickable_opaque_uid() {
    let site = dev_render(&book(), "");
    let parsing = &site.pages[1].html;
    // The `sec:lexing` heading leads with an empty <a> permalink whose opaque
    // id (§7.1) lives in data-id — drawn by CSS, never a text node.
    let needle = "id=\"sec-lexing\"><a class=\"sec-uid\" href=\"#sec-lexing\" data-id=\"";
    let start = parsing
        .find(needle)
        .expect("labelled section leads with a sec-uid permalink")
        + needle.len();
    let uid = &parsing[start..start + ID_LEN as usize];
    assert_eq!(uid.len(), ID_LEN as usize);
    // The permalink is followed by an empty node-page link (drawn by CSS), and
    // neither id leaks into the heading's own text run.
    assert!(parsing.contains(&format!(
        "data-id=\"{uid}\"></a>\
         <a class=\"node-link\" href=\"n/{uid}.html\" aria-label=\"node page\"></a>Lexing</h2>"
    )));
    // A cross-page \ref back to the section renders "Section <id>" (§7.1),
    // links to the section anchor, and reuses the very same opaque id.
    assert!(site.pages[2].html.contains(&format!(
        "<a data-ref=\"sec:lexing\" href=\"parsing.html#sec-lexing\">Section {uid}</a>"
    )));
}
@
A chunk reference points at the chunk's defining section, a fragment link when the
definition is on the same page.
<<a chunk ref links into code>>=
#[test]
fn chunk_ref_links_into_code() {
    let site = dev_render(&book(), "");
    // `<a data-ref="chunk:lex a token">` on the Parsing page points at the
    // chunk's defining section (same page → a fragment link).
    assert!(site.pages[1]
        .html
        .contains("href=\"#sec-3\">lex a token</a>"));
}
@
The nav tree is emitted on every page, and a labelled heading's nav link follows
its label anchor rather than its text slug.
<<the nav tree is on every page>>=
#[test]
fn nav_tree_is_emitted_on_every_page() {
    let site = dev_render(&book(), "");
    for page in &site.pages {
        assert!(page.html.contains("<nav"));
        // The author labelled this heading `sec:lexing`, so its anchor is the
        // label's, not the text slug — the nav link follows.
        assert!(page.html.contains("href=\"parsing.html#sec-lexing\">Lexing</a>"));
    }
    // Each page marks its own landing entry current (§5.3) and no other, so the
    // nav shows the reader's place statically. The Parsing page marks Parsing.
    assert!(site.pages[1]
        .html
        .contains("href=\"parsing.html\" aria-current=\"page\">Parsing</a>"));
    assert!(site.pages[1]
        .html
        .contains("href=\"index.html\">Front matter</a>"));
    assert!(!site.pages[1]
        .html
        .contains("href=\"index.html\" aria-current=\"page\""));
}
@
The sitemap page lists every navigation target once. It is a single standalone page,
so a nested link that lives on a child page still resolves through the same href the
nav tree uses.
<<the sitemap lists every page>>=
#[test]
fn sitemap_lists_every_page() {
    let site = dev_render(&book(), "");
    assert!(site.sitemap.contains("<h1>Sitemap</h1>"));
    // Every top-level page and a labelled child section both appear, through the
    // same hrefs the nav tree builds.
    assert!(site.sitemap.contains("href=\"parsing.html\">Parsing</a>"));
    assert!(site.sitemap.contains("href=\"parsing.html#sec-lexing\">Lexing</a>"));
    // The footer of an ordinary page points at the sitemap.
    assert!(site.pages[0].html.contains("href=\"sitemap.html\""));
}
@
The archival JSON is the current schema, round-trips through the per-page narrowing,
and hoists a sidenote into a margin entry — stripped from the JSON prose but kept
inline in the woven HTML.
<<site json is current schema and hoists sidenotes>>=
#[test]
fn site_json_is_current_schema_and_hoists_sidenotes() {
    let site = dev_render(&book(), "");
    let json = &site.json;
    assert_eq!(json.schema, site::SCHEMA);
    // The whole-doc JSON is serialized and re-round-trips through the
    // per-page narrowing without panicking.
    let ids = json.page_ids();
    assert_eq!(ids, vec!["index", "parsing", "codegen"]);
    for id in &ids {
        assert!(site::page_json(json, id).is_some());
    }
    // book.cob carries one sidenote on the Parsing page; it lands in a
    // margin[] entry and is stripped from that section's JSON prose, while
    // the woven HTML keeps it inline with the matching sn- id.
    let whole = site::to_json(json);
    assert!(whole.contains("\"sn-1\""));
    assert!(whole.contains("\"kind\": \"sidenote\""));
    // No aside survives in the JSON prose bodies.
    assert!(!whole.contains("<aside"));
    assert!(site.pages[1].html.contains("<aside id=\"sn-1\""));
}
@
Footer pagination links each page's neighbours: the middle page has both, the first
has no previous, and the last has no next.
<<footer pagination links neighbours>>=
#[test]
fn footer_pagination_links_neighbours() {
    let site = dev_render(&book(), "");
    // Middle page has both neighbours.
    assert!(site.pages[1].html.contains("href=\"index.html\""));
    assert!(site.pages[1].html.contains("href=\"codegen.html\""));
    // First page has no prev; last has no next.
    assert!(!site.pages[0].html.contains("rel=\"prev\""));
    assert!(!site.pages[2].html.contains("rel=\"next\""));
}
@
The Markdown dialect renders prose to HTML — emphasis and strong, not literal
markup — and renders every math run, whether a fenced block or an inline run.
<<the markdown dialect renders prose and fenced math>>=
#[test]
fn markdown_dialect_renders_prose_and_fenced_math() {
    let site = dev_render(&md(), "");
    let html = site.all_html();
    // Prose became HTML: a paragraph with emphasis, not literal asterisks.
    assert!(html.contains("<p>"));
    assert!(html.contains("<em>Markdown</em>"));
    assert!(html.contains("<strong>emphasis</strong>"));
    // Three math runs: the labeled ```math``` fence, the inline `$…$` in the
    // figure caption, and the inline tail — all rendered by KaTeX, none left
    // as a placeholder.
    assert_eq!(site.math_count, 3);
    assert!(!html.contains("data-cob-math"));
    assert!(html.contains("class=\"equation\""));
    assert!(html.contains("katex"));
}
@
A Markdown figure fence becomes a real figure with an anchored id and an opaque id
on its caption; a table fence parses its pipe table; a labelled equation is
identified; and every inline reference resolves to its float's anchor.
<<markdown fenced floats are labelled and referenced>>=
#[test]
fn markdown_fenced_floats_are_labeled_and_referenced() {
    let site = dev_render(&md(), "");
    let html = site.all_html();
    // A `figure` fence became a real <figure> with an anchored id, an opaque
    // id on its caption, and its raw-HTML body passed through.
    let fig = id_at(&html, "fig-diagram");
    assert!(html.contains(&format!("<figcaption data-id=\"{fig}\">")));
    assert!(html.contains("<img src=\"diagram.svg\""));
    // A `table` fence parsed its GFM pipe table and carried id + <caption>.
    let tbl = id_at(&html, "tbl-units");
    assert!(html.contains(&format!("<caption data-id=\"{tbl}\">Symbols and their units.")));
    assert!(html.contains("<th>Symbol</th>"));
    // The labeled equation is identified too.
    let eq = id_at(&html, "eq-mass");
    assert_eq!(eq.len(), ID_LEN as usize);
    // Every `\ref{…}` resolved to its float's anchor.
    assert!(html.contains("href=\"#eq-mass\""));
    assert!(html.contains("href=\"#fig-diagram\""));
    assert!(html.contains("href=\"#tbl-units\""));
}
@
The transclusion fixture puts a title, an intro, and the source heading in one \code{@}
chunk, then transcludes the source into a later section. The directive lowers to a
lazy \code{<cob-transclude>} pointing at the source's own \code{n/} page, with a link
fallback — no server-side copy, so the body is not duplicated and its ids are not
scoped (§10).
<<transclusion cuts a heading node and scopes the copy>>=
#[test]
fn transclusion_lowers_to_a_lazy_element() {
    let site = dev_render(&tx(), "");
    let html = site.all_html();
    // The node lowers to a lazy element that fetches its own n/ page, with a link
    // fallback naming the heading — reachable with no JavaScript (§10).
    assert!(html.contains("<cob-transclude src=\"n/"));
    assert!(html.contains("data-transclude=\"sec:source\">"));
    assert!(html.contains(">The source &rarr;</a></cob-transclude>"));
    // No server-side copy: no spliced section (the `data-transclude` form the old
    // splice used; the enhancement script's own literal has no such attribute) and
    // no scoped ids.
    assert!(!html.contains("<section class=\"transclusion\" data-transclude="));
    assert!(!html.contains("tx1-"));
    // The body is not duplicated: one h1, one canonical id, one chunk body.
    assert_eq!(html.matches("<h1").count(), 1);
    assert_eq!(html.matches("id=\"sec-source\"").count(), 1);
    assert_eq!(html.matches("chunk-body").count(), 1);
    // The target resolves, so no transclusion lint fires.
    assert!(site.lints.iter().all(|l| l.code != "W105" && l.code != "W106"));
}
@
Every uid-bearing node earns a standalone page under \code{n/} (§10). The page carries
the node body, a breadcrumb up to the document \code{h1}, a "read in context" link to
the canonical anchor, and the backlinks that point at the node. The \code{h1} itself
has no uid, so it earns no page.
<<every node gets a standalone page with context and backlinks>>=
#[test]
fn every_node_gets_a_standalone_page_with_context_and_backlinks() {
    let site = dev_render(&tx(), "");
    // The two h2 nodes each get a page; the h1 (no uid) does not.
    assert_eq!(site.node_pages.len(), 2);
    for (path, html) in &site.node_pages {
        assert!(path.starts_with("n/") && path.ends_with(".html"));
        // A node page is archival too: only the nav-spy and cob-transclude aids, so
        // a transclusion inside a node page lazy-loads and nothing else runs.
        for tag in html.match_indices("<script id=") {
            let id = &html[tag.0 + 11..];
            assert!(
                id.starts_with("\"nav-spy\"") || id.starts_with("\"cob-transclude\""),
                "node page has an unexpected script"
            );
        }
        assert_eq!(html.matches("<script").count(), html.matches("<script id=").count());
    }
    // The source node page: found by its "read in context" link to the canonical
    // anchor, which sits one directory up (`../`).
    let source = site
        .node_pages
        .iter()
        .find(|(_, h)| h.contains("href=\"../index.html#sec-source\""))
        .map(|(_, h)| h)
        .expect("source node page exists and links back into context");
    // Its breadcrumb climbs to the document h1, one directory up.
    assert!(source.contains("<a href=\"../index.html\">Transclusion fixture</a>"));
    // It carries the node body — the source heading and its code chunk.
    assert!(source.contains("id=\"sec-source\""));
    assert!(source.contains("chunk-body"));
    // "The reuse" transcludes the source, so the source page lists it as a
    // backlink that points at the reuse node's own page (a sibling in `n/`).
    assert!(source.contains("Transcluded by"));
    let reuse_uid = site
        .node_pages
        .iter()
        .map(|(p, _)| p.trim_start_matches("n/").trim_end_matches(".html"))
        .find(|uid| source.contains(&format!("<a href=\"{uid}.html\">The reuse</a>")))
        .expect("source page backlinks the reuse node page");
    assert_eq!(reuse_uid.len(), ID_LEN as usize);
}
@
A labelled float is a node too (§10). \code{\transclude{fig:…}} lowers to a lazy
\code{<cob-transclude>} pointing at the figure's own page, with a link fallback naming
the caption. The figure and the equation each earn a node page, and each leads with
a node-page link in context.
<<a float is a node with its own page and can be transcluded>>=
#[test]
fn a_float_is_a_node_with_its_own_page_and_can_be_transcluded() {
    let site = dev_render(&txf(), "");
    let idx = &site.pages[0].html;
    let figid = id_at(idx, "fig-demo");
    // \transclude{fig:demo} lowers to a lazy element pointing at the figure's page,
    // with a link fallback naming the caption — no server-side copy.
    assert!(idx.contains(&format!(
        "<cob-transclude src=\"n/{figid}.html\" data-transclude=\"fig:demo\">"
    )));
    assert!(idx.contains(">A tiny schematic. &rarr;</a></cob-transclude>"));
    assert!(!idx.contains("<section class=\"transclusion\" data-transclude="));
    assert!(!idx.contains("tx1-"));
    // The canonical figure still carries its bare id, once.
    assert_eq!(idx.matches("id=\"fig-demo\"").count(), 1);
    // Two headings and two floats each earn a node page.
    assert_eq!(site.node_pages.len(), 4);
    // The figure leads with a node-page link in context (drawn by CSS, no text).
    assert!(idx.contains(&format!("href=\"n/{figid}.html\"")));
    // The figure's node page carries the figure, a breadcrumb to the heading it
    // sits in, a context link, and a backlink to the node that transcludes it.
    let (_, figpage) = site
        .node_pages
        .iter()
        .find(|(p, _)| p == &format!("n/{figid}.html"))
        .expect("the figure earns a node page");
    assert!(figpage.contains("<figure id=\"fig-demo\""));
    assert!(figpage.contains(">The originals</a>"));
    assert!(figpage.contains("href=\"../index.html#fig-demo\""));
    assert!(figpage.contains("Transcluded by"));
    // The equation is a node too: \transclude{eq:demo} inlines it, and it earns
    // its own page.
    assert!(idx.contains("data-transclude=\"eq:demo\""));
    let eqid = id_at(idx, "eq-demo");
    assert!(site.node_pages.iter().any(|(p, _)| p == &format!("n/{eqid}.html")));
}
@
