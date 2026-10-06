# The site.json contract (§5.3, §8)

This module is the archival document model. The prose is the specification. The
chunks after it are the implementation. Phase 1, this weaver, writes \code{site.json}.
Phase 2, the annotation and review tooling, reads it unchanged. cob emits it only
under \code{cob weave --archive}.

## Page boundaries {#sec:pzpT}

noweb has no starred-section concept. cweb's section levels do not exist here. So
cob splits on the prose instead. A \code{[weave] spcob-at} key names the heading level
to split on — a Markdown \code{#} and an HTML \code{h1} both count. A \code{nav-depth} key sets
how deep the nav tree goes.

```verbatim \lang{toml}
[weave]
spcob-at = "h1"
nav-depth = 3
```

Everything before the first boundary is the index page. A code chunk always
belongs to the page of the nearest preceding boundary. A chunk never starts a
page.

## The JSON is the single source of truth {#sec:Tjx4}

\code{site.json} is the one contract between the two phases. Phase 1 writes it. Phase 2
reads it and writes nothing back — annotations live entirely outside it
(\code{ANNOTATIONS.md}). The shape holds the metadata, the nav tree, the label tables,
the chunk graph, and the pages:

```verbatim \lang{jsonc}
{
  "schema": 2,
  "meta": { "id": "cob", "title": "…", "authors": ["…"] },
  "nav": [ { "id": "parsing", "title": "Parsing", "level": 1, "children": [] } ],
  "labels": {
    "fig:pipeline": { "id": "k3f9", "page": "parsing", "anchor": "fig-pipeline",
                      "kind": "figure" }
  },
  "chunks": {
    "lex a token": { "slug": "lex-a-token", "root": false,
      "defs": [ { "page": "parsing", "anchor": "sec-4", "continues": false } ],
      "uses": [ { "page": "parsing", "anchor": "sec-7" } ] }
  },
  "pages": [ { "id": "parsing", "title": "Parsing", "prev": "intro",
               "next": "codegen", "sections": [] } ]
}
```

## Why the shape looks like this {#sec:5Q9y}

The \code{schema} field is versioned. Any consumer — the review agent, an external tool
— checks it before use. A mismatch is a hard failure, not a runtime surprise.
Schema 2 replaces each label's position-dependent number with the frozen \code{id} from
\code{cob.lock} (§7.1). A reference's display text, such as "Figure k3f9", comes from
\code{kind} plus \code{id}, so no numeric field is left in the contract.

There is no \code{generated} timestamp. A wall-clock field would make the output
non-reproducible. That would defeat Nix caching and turn every re-weave into a
noisy diff of the archival artifact. Weave must be a deterministic function of its
inputs. So every map is a \code{BTreeMap} for a stable key order, and nothing reads the
clock.

Per-page JSON is this same object with \code{pages} narrowed to one entry. The \code{nav},
\code{labels}, and \code{chunks} stay in full, so one page can render standalone.

## How the code implements this {#sec:Cafo}

This module also owns the sidenote hoist. The contract keeps a section's prose and
its margin material disjoint, so each \code{sidenote} aside is lifted out of the
rendered body into a structured \code{margin[]} entry with a stable \code{sn-N} id.

The module is the JSON shape (a tree of serialize structs), the sidenote hoist,
the document builder that fills the shape from the model, and the two serializers
that write the whole document and one page.
<<src/site.rs>>=
<<the module banner>>

<<imports>>

<<the schema version>>

<<document metadata>>

<<the nav tree>>

<<the cross-reference tables>>

<<the per-section shape>>

<<the page and the whole document>>

<<page ids for the caller>>

<<a rendered section>>

<<the hoist result>>

<<hoist sidenotes out of a body>>

<<find the matching close>>

<<build the document>>

<<a section's chunk uses>>

<<lower one nav node>>

<<serialize the whole document>>

<<serialize one page>>

<<the forest index>>

<<the tests>>
@
The banner states the contract, the determinism rule, and the sidenote hoist —
the three things a maintainer must not break.
<<the module banner>>=
//! The `site.json` contract (§8): a `schema: 2` document model that
//! Phase 1 produces and Phase 2 (annotation/review tooling) consumes unchanged.
//!
//! It is written only under `cob weave --archive`. Determinism is a hard
//! requirement — no timestamps, and every map is a `BTreeMap` so key order is
//! stable — because the archival artifact is diffed and Nix-cached (§8).
//!
//! This module also owns the sidenote hoist: §8 keeps a section's prose and its
//! margin material disjoint, so `<aside class="sidenote">` is lifted out of the
//! rendered body into structured `margin[]` entries with stable `sn-N` ids.
@
Serde does the serializing; the model, the resolution, and the slug helper supply
the content.
<<imports>>=
use std::collections::BTreeMap;

use serde::Serialize;

use crate::model::{CodeSpan, DocModel, SectionKind};
use crate::resolve::Resolution;
use crate::rewrite::slug;
@
The schema version is bumped only on a breaking shape change, and consumers
hard-fail on a mismatch rather than guess. Schema 2 (M11) replaced a label's
position-dependent number with its frozen opaque id (§7.1).
<<the schema version>>=
/// Bumped only on a breaking change to this shape; consumers hard-fail on a
/// mismatch rather than guess (§8). Schema 2 (M11) replaced a label's
/// position-dependent `number` with its frozen opaque `id` (§7.1).
pub const SCHEMA: u32 = 2;
@
\code{Meta} is the document header: its id, title, authors, and the source files it
was woven from.
<<document metadata>>=
#[derive(Serialize, Clone, Default)]
pub struct Meta {
    pub id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub source_files: Vec<String>,
}
@
\code{Nav} is one node of the table-of-contents tree. An empty \code{children} list is
dropped from the JSON so a leaf stays compact.
<<the nav tree>>=
#[derive(Serialize, Clone)]
struct Nav {
    id: String,
    title: String,
    level: u8,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    children: Vec<Nav>,
}
@
Three tables let a consumer resolve any cross reference. \code{Label} is a reference
target — its page, anchor, kind, and (for a float) its frozen opaque id. \code{Def}
and \code{Use} are the two ends of a chunk edge, each a page plus an anchor; a \code{Def}
also records whether the chunk continues an earlier definition. \code{Chunk} gathers a
chunk's defs and uses under its slug.
<<the cross-reference tables>>=
#[derive(Serialize, Clone)]
pub struct Label {
    pub page: String,
    pub anchor: String,
    pub kind: &'static str,
    /// The frozen opaque id (§7.1); absent for section/chunk targets.
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
}

#[derive(Serialize, Clone)]
struct Def {
    page: String,
    anchor: String,
    continues: bool,
}

#[derive(Serialize, Clone)]
struct Use {
    page: String,
    anchor: String,
}

#[derive(Serialize, Clone)]
struct Chunk {
    slug: String,
    root: bool,
    defs: Vec<Def>,
    uses: Vec<Use>,
}
@
The per-section shape. \code{Margin} is one hoisted sidenote. \code{Source} pins the
section to its \code{.cob} file and line. \code{Section} is the rendered unit: docs sections
carry a (possibly empty) \code{margin}, code sections carry a chunk \code{name}, a
\code{continues} flag, and the chunk names they define and use. Absent optional fields
are dropped so docs and code sections each serialize only what applies.
<<the per-section shape>>=
#[derive(Serialize, Clone)]
pub struct Margin {
    pub kind: &'static str,
    pub id: String,
    pub html: String,
}

#[derive(Serialize, Clone)]
struct Source {
    file: String,
    line: u32,
}

#[derive(Serialize, Clone)]
struct Section {
    id: String,
    kind: &'static str,
    source: Source,
    html: String,
    /// Present (possibly empty) for docs, omitted for code.
    #[serde(skip_serializing_if = "Option::is_none")]
    margin: Option<Vec<Margin>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    continues: Option<bool>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    defines: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    uses: Vec<String>,
}
@
\code{Page} is one output page with its neighbours for prev/next links; \code{SiteJson} is
the whole document — schema, metadata, nav, the two tables, and the pages.
<<the page and the whole document>>=
#[derive(Serialize, Clone)]
struct Page {
    id: String,
    title: String,
    prev: Option<String>,
    next: Option<String>,
    sections: Vec<Section>,
}

/// One import edge (§13): a forest this document depends on, under a local alias.
/// It feeds the "Imports" list in the page chrome and is recorded in `site.json`
/// for a forest index to compute reverse "imported by" backlinks later.
#[derive(Serialize, Clone)]
pub struct ImportLink {
    pub name: String,
    pub alias: String,
}

#[derive(Serialize)]
pub struct SiteJson {
    pub schema: u32,
    pub meta: Meta,
    nav: Vec<Nav>,
    pub labels: BTreeMap<String, Label>,
    chunks: BTreeMap<String, Chunk>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub imports: Vec<ImportLink>,
    pages: Vec<Page>,
}
@
The page list is private, so this exposes just the page ids in document order —
enough for a caller to drive \code{page_json} without reaching inside.
<<page ids for the caller>>=
impl SiteJson {
    /// Page ids in document order — enough for a caller to drive `page_json`
    /// without reaching into the private page list.
    pub fn page_ids(&self) -> Vec<String> {
        self.pages.iter().map(|p| p.id.clone()).collect()
    }
}
@
\code{RawSection} is what weave hands this module for one section: the rendered body
with sidenotes already hoisted, plus the margin material.
<<a rendered section>>=
/// One section's rendered body as weave produces it, ready for `site.json`:
/// prose with sidenotes already hoisted out, plus the margin material.
pub struct RawSection {
    pub html: String,
    pub margins: Vec<Margin>,
}
@
\code{Hoisted} is the split output of the hoist: the page body keeps each aside inline
(now id-tagged), the JSON body drops asides entirely, and \code{margins} collects them
as structured entries. The page and JSON bodies share ids so a note lines up in
both views.
<<the hoist result>>=
/// Result of lifting sidenotes out of a rendered docs body.
pub struct Hoisted {
    /// The body as it appears on the woven page: asides kept inline, each now
    /// carrying its `id="sn-N"` so page and JSON share ids.
    pub page_html: String,
    /// The body for `site.json`: asides removed entirely.
    pub json_html: String,
    pub margins: Vec<Margin>,
}
@
The hoist is deliberate string surgery, not a parse: the input is well-formed
lol_html output, sidenote asides do not nest in authored prose, and any literal
aside opener in prose text is entity-escaped so it cannot match. The \code{next}
counter is document-global, so ids stay unique across sections. A non-sidenote
aside is copied through untouched; an unbalanced aside stops the walk and copies
the remainder verbatim.
<<hoist sidenotes out of a body>>=
/// Lift every `<aside class="sidenote">` out of `body`. `next` is a
/// document-global counter so ids are stable and unique across sections.
///
/// This is deliberate string surgery, not a general parse: the input is
/// well-formed lol_html output, asides do not nest in authored prose, and any
/// literal `<aside` inside prose text is entity-escaped and so cannot match.
pub fn hoist_sidenotes(body: &str, next: &mut usize) -> Hoisted {
    let mut page = String::with_capacity(body.len());
    let mut json = String::with_capacity(body.len());
    let mut margins = Vec::new();
    let mut i = 0;
    while let Some(rel) = body[i..].find("<aside") {
        let open = i + rel;
        let tag_end = match body[open..].find('>') {
            Some(x) => open + x,
            None => break,
        };
        let open_tag = &body[open..=tag_end];
        // Everything up to this aside is common to both outputs.
        page.push_str(&body[i..open]);
        json.push_str(&body[i..open]);
        if !open_tag.contains("sidenote") {
            // Some other aside — leave it untouched in both.
            page.push_str(open_tag);
            json.push_str(open_tag);
            i = tag_end + 1;
            continue;
        }
        let Some(close) = matching_close(body, tag_end + 1) else {
            // Unbalanced; copy the rest verbatim and stop.
            page.push_str(&body[open..]);
            json.push_str(&body[open..]);
            i = body.len();
            break;
        };
        let inner = &body[tag_end + 1..close];
        *next += 1;
        let id = format!("sn-{next}");
        // Page: reopen the aside with its new id, keep it inline.
        page.push_str(&format!("<aside id=\"{id}\"{}", &open_tag["<aside".len()..]));
        page.push_str(inner);
        page.push_str("</aside>");
        // JSON: the aside is gone from prose; its content is structured margin.
        margins.push(Margin {
            kind: "sidenote",
            id,
            html: inner.to_string(),
        });
        i = close + "</aside>".len();
    }
    page.push_str(&body[i..]);
    json.push_str(&body[i..]);
    Hoisted {
        page_html: page,
        json_html: json,
        margins,
    }
}
@
Finding an aside's close counts nesting, so an inner sidenote does not close the
outer one early. It returns the index of the \code{<} that begins the balancing
\code{</aside>}.
<<find the matching close>>=
/// Index of the `<` beginning the `</aside>` that closes the aside whose body
/// starts at `from`, accounting for nested asides.
fn matching_close(body: &str, mut pos: usize) -> Option<usize> {
    let mut depth = 1;
    while pos < body.len() {
        let next_open = body[pos..].find("<aside").map(|x| pos + x);
        let next_close = body[pos..].find("</aside>").map(|x| pos + x);
        match (next_open, next_close) {
            (_, None) => return None,
            (Some(o), Some(c)) if o < c => {
                depth += 1;
                pos = o + "<aside".len();
            }
            (_, Some(c)) => {
                depth -= 1;
                if depth == 0 {
                    return Some(c);
                }
                pos = c + "</aside>".len();
            }
        }
    }
    None
}
@
The builder fills the JSON shape from three inputs: the model, the resolution,
and weave's per-section bodies aligned to \code{doc.sections}. It first indexes each
section to its page and continues-flag, then maps the label table, the chunk
table, the sections, and finally the pages — narrowing the flat section list to
each page and wiring prev/next.
<<build the document>>=
/// Assemble the whole-document `site.json` from the model, the resolution, and
/// weave's per-section rendered bodies (aligned to `doc.sections`).
pub fn build(doc: &DocModel, res: &Resolution, raw: &[RawSection], meta: Meta) -> SiteJson {
    let page_id = |i: usize| res.pages[res.section_page[i]].id.clone();

    // section id → (page id, continues) for the chunks table.
    let mut sec_of: BTreeMap<&str, (String, bool)> = BTreeMap::new();
    for (i, s) in doc.sections.iter().enumerate() {
        let cont = matches!(&s.kind, SectionKind::Code { continues, .. } if *continues);
        sec_of.insert(s.id.as_str(), (page_id(i), cont));
    }

    let labels = res
        .labels
        .iter()
        .map(|(id, l)| {
            (
                id.clone(),
                Label {
                    page: res.pages[l.page].id.clone(),
                    anchor: l.anchor.clone(),
                    kind: l.kind,
                    id: l.id.clone(),
                },
            )
        })
        .collect();

    let chunks = doc
        .chunks
        .iter()
        .map(|(name, info)| {
            let defs = info
                .defs
                .iter()
                .map(|sid| {
                    let (page, continues) = sec_of.get(sid.as_str()).cloned().unwrap_or_default();
                    Def {
                        page,
                        anchor: sid.clone(),
                        continues,
                    }
                })
                .collect();
            let uses = info
                .uses
                .iter()
                .map(|sid| Use {
                    page: sec_of.get(sid.as_str()).map(|(p, _)| p.clone()).unwrap_or_default(),
                    anchor: sid.clone(),
                })
                .collect();
            (
                name.clone(),
                Chunk {
                    slug: slug(name),
                    root: info.root,
                    defs,
                    uses,
                },
            )
        })
        .collect();

    let sections: Vec<Section> = doc
        .sections
        .iter()
        .zip(raw)
        .map(|(s, r)| match &s.kind {
            SectionKind::Docs { .. } => Section {
                id: s.id.clone(),
                kind: "docs",
                source: Source {
                    file: s.file.clone(),
                    line: s.line,
                },
                html: r.html.clone(),
                margin: Some(r.margins.clone()),
                name: None,
                continues: None,
                defines: Vec::new(),
                uses: Vec::new(),
            },
            SectionKind::Code {
                name,
                continues,
                spans,
                index_defs,
            } => Section {
                id: s.id.clone(),
                kind: "code",
                source: Source {
                    file: s.file.clone(),
                    line: s.line,
                },
                html: r.html.clone(),
                margin: None,
                name: Some(name.clone()),
                continues: Some(*continues),
                defines: index_defs.clone(),
                uses: chunk_uses(spans),
            },
        })
        .collect();

    let pages = res
        .pages
        .iter()
        .enumerate()
        .map(|(pi, pm)| Page {
            id: pm.id.clone(),
            title: pm.title.clone(),
            prev: pi.checked_sub(1).map(|j| res.pages[j].id.clone()),
            next: res.pages.get(pi + 1).map(|p| p.id.clone()),
            sections: sections
                .iter()
                .zip(&res.section_page)
                .filter(|(_, p)| **p == pi)
                .map(|(sec, _)| sec.clone())
                .collect(),
        })
        .collect();

    SiteJson {
        schema: SCHEMA,
        meta,
        nav: res.nav.iter().map(nav_of).collect(),
        labels,
        chunks,
        imports: Vec::new(),
        pages,
    }
}
@
A code section's \code{uses} are the distinct chunk names it references, kept in
first-use order so the table reads the way the code does.
<<a section's chunk uses>>=
/// Distinct chunk names a code section references, in first-use order.
fn chunk_uses(spans: &[CodeSpan]) -> Vec<String> {
    let mut seen = Vec::new();
    for span in spans {
        if let CodeSpan::Use { name } = span {
            if !seen.contains(name) {
                seen.push(name.clone());
            }
        }
    }
    seen
}
@
Lowering a nav node to its JSON form is a plain recursive copy.
<<lower one nav node>>=
fn nav_of(n: &crate::resolve::NavNode) -> Nav {
    Nav {
        id: n.id.clone(),
        title: n.title.clone(),
        level: n.level,
        children: n.children.iter().map(nav_of).collect(),
    }
}
@
The whole document serializes to pretty JSON with a trailing newline — pretty
because a human diffs it, deterministic because serde walks fields and
\code{BTreeMap}s in a fixed order.
<<serialize the whole document>>=
/// Pretty JSON with a trailing newline. Pretty because the archival artifact is
/// read and diffed by humans; deterministic because serde walks fields and
/// `BTreeMap`s in a fixed order.
pub fn to_json(site: &SiteJson) -> String {
    let mut s = serde_json::to_string_pretty(site).expect("SiteJson serializes");
    s.push('\n');
    s
}
@
The per-page JSON is the whole object with \code{pages} narrowed to one entry. Nav,
labels, and chunks stay in full so a page stands alone (§8).
<<serialize one page>>=
/// The per-page JSON: the whole object with `pages` narrowed to one entry.
/// `nav`, `labels`, and `chunks` are retained in full so a page stands alone
/// (§8).
pub fn page_json(site: &SiteJson, page_id: &str) -> Option<String> {
    let page = site.pages.iter().find(|p| p.id == page_id)?;
    let one = SiteJson {
        schema: site.schema,
        meta: site.meta.clone(),
        nav: site.nav.clone(),
        labels: site.labels.clone(),
        chunks: site.chunks.clone(),
        imports: site.imports.clone(),
        pages: vec![page.clone()],
    };
    Some(to_json(&one))
}
@
A forest's importable index (§13) is a separate, small artifact: what another
forest reads to \code{\import} this one. It carries the exported macro table (name →
expansion) and the label index — each public label's id, kind, page, and anchor —
so a cross-document \code{\ref}/\code{\transclude} can resolve against it. The label index
reuses \code{site.json}'s own label table. \code{schema} is a semver string: a consumer
accepts the same major (a newer minor only adds fields it ignores) and rejects a
newer major (E038), so a forest cannot be read by a cob too old to understand it.
<<the forest index>>=
/// The current `cob-exports.json` schema (§13). Semver: a consumer rejects a newer
/// major (E038).
pub const EXPORTS_SCHEMA: &str = "1.2.0";
const EXPORTS_SCHEMA_MAJOR: u64 = 1;

/// One cited work another forest may cite (§14): the frozen id naming its node page
/// and the formatted reference HTML, so a consumer renders the `[id]` marker and the
/// References entry without re-reading the producer's `.bib`.
#[derive(Serialize, serde::Deserialize, Clone, Debug)]
pub struct ForestCite {
    pub id: String,
    pub html: String,
}

/// One outgoing cross-forest edge (§16): a `\ref`/`\cite`/`\transclude` this forest
/// makes into another. `to_url` names the target forest (the join key) and `to_id`
/// its node; `from_id`/`from_title` are this forest's node that made the edge, so a
/// reverse backlink can link back. The aggregator inverts these.
#[derive(Serialize, serde::Deserialize, Clone, Debug)]
pub struct ForestEdge {
    pub kind: String,
    pub to_url: String,
    pub to_id: String,
    pub from_id: String,
    pub from_title: String,
}

/// The importable index of a forest (§13, §14, §16): the macro table, the label
/// table, the cited works, this forest's own deployed url, and its outgoing
/// cross-forest edges. The labels reuse `site.json`'s own.
#[derive(Serialize)]
struct ExportsJson<'a> {
    schema: &'static str,
    url: &'a str,
    macros: &'a BTreeMap<String, String>,
    labels: &'a BTreeMap<String, Label>,
    citations: &'a BTreeMap<String, ForestCite>,
    edges: &'a [ForestEdge],
}

/// Pretty, deterministic JSON for `cob-exports.json` (§13, §14, §16): schema, this
/// forest's url, the macro table, the label index (`site.json`'s own), the cited
/// works, and the outgoing cross-forest edges the backlink aggregator inverts.
pub fn to_exports_json(
    url: &str,
    macros: &BTreeMap<String, String>,
    labels: &BTreeMap<String, Label>,
    citations: &BTreeMap<String, ForestCite>,
    edges: &[ForestEdge],
) -> String {
    let fj = ExportsJson {
        schema: EXPORTS_SCHEMA,
        url,
        macros,
        labels,
        citations,
        edges,
    };
    let mut s = serde_json::to_string_pretty(&fj).expect("ExportsJson serializes");
    s.push('\n');
    s
}

/// One label as another forest reads it (§13): owned, because the producer's
/// `Label.kind` is a `&'static str` that serializes to a string the consumer
/// deserializes into an owned one. Read by cross-document `\ref`/`\transclude`.
#[derive(serde::Deserialize, Clone, Debug)]
pub struct ForestLabel {
    #[serde(default)]
    pub id: Option<String>,
    #[allow(dead_code)]
    pub kind: String,
    pub page: String,
    pub anchor: String,
}

/// An imported forest's index (§13): its schema, exported macros, and label table.
/// A file that does not parse yields `None`; the import then surfaces as E036 when
/// a document actually `\import`s it.
#[derive(serde::Deserialize, Default, Clone, Debug)]
pub struct ForestIndex {
    /// The producer's `cob-exports.json` schema (semver); checked by `read_exports`.
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub macros: BTreeMap<String, String>,
    /// The label index, read by cross-document `\ref`/`\transclude` (§13).
    #[serde(default)]
    pub labels: BTreeMap<String, ForestLabel>,
    /// The cited works, read by cross-document `\cite{key@alias}` (§14).
    #[serde(default)]
    pub citations: BTreeMap<String, ForestCite>,
    /// This forest's own deployed url (§16): the join key the backlink aggregator
    /// matches an incoming edge's `to_url` against.
    #[serde(default)]
    pub url: String,
    /// This forest's outgoing cross-forest edges (§16), inverted into reverse
    /// backlinks by the aggregator.
    #[serde(default)]
    pub edges: Vec<ForestEdge>,
}

/// An imported forest the consumer resolves against (§13): the `url` its pages
/// are deployed at (from `cob.toml`), plus the index it exports. A cross-document
/// `\ref{x@alias}` lands on `<url>/<page>.html#<anchor>`; a `\transclude{x@alias}`
/// points a `<cob-transclude src>` at `<url>/n/<id>.html`.
#[derive(Clone, Default)]
pub struct ForestRef {
    pub url: String,
    pub index: ForestIndex,
}

/// Parse a `cob-exports.json`. A file that does not parse is `Ok(None)` — a
/// lenient skip, as before. A file whose major schema is newer than this cob
/// understands is a hard error (E038), so a forest is never read by a cob too old
/// to understand it; a newer minor only adds fields cob ignores, so it is accepted.
pub fn read_exports(json: &str) -> Result<Option<ForestIndex>, String> {
    let index = match serde_json::from_str::<ForestIndex>(json) {
        Ok(i) => i,
        Err(_) => return Ok(None),
    };
    if let Ok(v) = semver::Version::parse(&index.schema) {
        if v.major > EXPORTS_SCHEMA_MAJOR {
            return Err(format!(
                "error[E038]: cob-exports.json schema {} is newer than this cob \
                 supports ({EXPORTS_SCHEMA}); upgrade cob",
                index.schema
            ));
        }
    }
    Ok(Some(index))
}
@
The tests pin the hoist: one sidenote is lifted and id-tagged on both sides, the
counter carries across sections, a non-sidenote aside is untouched, and nested
asides collapse into a single outer margin.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    <<hoist lifts one sidenote>>

    <<the counter spans sections>>

    <<a non-sidenote aside is untouched>>

    <<nested asides match the outer close>>

    <<the forest index carries the macros>>
}
@
The forest index (§13) serializes the schema and the exported macro table, sorted
and deterministic, so another forest can \code{\import} it.
<<the forest index carries the macros>>=
#[test]
fn forest_index_carries_the_macros() {
    let mut macros = BTreeMap::new();
    macros.insert("\\RR".to_string(), "\\mathbb{R}".to_string());
    macros.insert("\\abs".to_string(), "\\lvert #1 \\rvert".to_string());
    let mut labels = BTreeMap::new();
    labels.insert(
        "eq:cost".to_string(),
        Label {
            page: "index.html".to_string(),
            anchor: "eq-cost".to_string(),
            kind: "equation",
            id: Some("k3f9".to_string()),
        },
    );
    let json = to_exports_json("", &macros, &labels, &BTreeMap::new(), &[]);
    assert!(json.contains("\"schema\": \"1.2.0\""));
    // A consumer accepts the same major and rejects a newer one.
    assert!(read_exports(&json).unwrap().is_some());
    let newer = json.replace("1.2.0", "2.0.0");
    assert!(read_exports(&newer).unwrap_err().starts_with("error[E038]"));
    assert!(json.contains("\"\\\\RR\": \"\\\\mathbb{R}\""));
    assert!(json.contains("\"\\\\abs\": \"\\\\lvert #1 \\\\rvert\""));
    // Deterministic: BTreeMap fixes the order by byte, so `\RR` (uppercase R,
    // 0x52) sorts before `\abs` (lowercase a, 0x61).
    assert!(json.find("\\\\RR").unwrap() < json.find("\\\\abs").unwrap());
    // The label index is carried too, so a cross-document ref can resolve.
    assert!(json.contains("\"eq:cost\""));
    assert!(json.contains("\"anchor\": \"eq-cost\""));
    assert!(json.contains("\"kind\": \"equation\""));
}
@
A single sidenote is removed from the JSON body, kept inline on the page with its
new id, captured as a margin, and the counter advances.
<<hoist lifts one sidenote>>=
#[test]
fn hoist_lifts_sidenote_and_ids_both_sides() {
    let mut n = 0;
    let h = hoist_sidenotes(
        "<p>before<aside class=\"sidenote\">note body</aside>after</p>",
        &mut n,
    );
    // Page keeps the aside inline, now carrying its id.
    assert_eq!(
        h.page_html,
        "<p>before<aside id=\"sn-1\" class=\"sidenote\">note body</aside>after</p>"
    );
    // JSON prose has the aside removed entirely.
    assert_eq!(h.json_html, "<p>beforeafter</p>");
    assert_eq!(h.margins.len(), 1);
    assert_eq!(h.margins[0].id, "sn-1");
    assert_eq!(h.margins[0].kind, "sidenote");
    assert_eq!(h.margins[0].html, "note body");
    // The counter advanced so the next section's ids stay unique.
    assert_eq!(n, 1);
}
@
The shared counter means two sections get distinct ids.
<<the counter spans sections>>=
#[test]
fn counter_spans_sections() {
    let mut n = 0;
    let a = hoist_sidenotes("<aside class=\"sidenote\">a</aside>", &mut n);
    let b = hoist_sidenotes("<aside class=\"sidenote\">b</aside>", &mut n);
    assert_eq!(a.margins[0].id, "sn-1");
    assert_eq!(b.margins[0].id, "sn-2");
}
@
An aside that is not a sidenote passes through both outputs and does not consume a
counter value.
<<a non-sidenote aside is untouched>>=
#[test]
fn non_sidenote_aside_is_left_untouched() {
    let mut n = 0;
    let h = hoist_sidenotes("<aside class=\"warning\">x</aside>", &mut n);
    assert_eq!(h.page_html, "<aside class=\"warning\">x</aside>");
    assert_eq!(h.json_html, "<aside class=\"warning\">x</aside>");
    assert!(h.margins.is_empty());
    assert_eq!(n, 0);
}
@
A nested sidenote does not close the outer one early: the whole outer aside
becomes one margin and the id advances only once.
<<nested asides match the outer close>>=
#[test]
fn nested_asides_match_the_outer_close() {
    let mut n = 0;
    let h = hoist_sidenotes(
        "<aside class=\"sidenote\">outer<aside class=\"sidenote\">inner</aside>tail</aside>",
        &mut n,
    );
    // The whole outer aside (including its nested one) becomes one margin;
    // the inner does not double-count because ids advance once here.
    assert_eq!(h.json_html, "");
    assert_eq!(h.margins.len(), 1);
    assert_eq!(h.margins[0].id, "sn-1");
    assert!(h.margins[0].html.contains("inner"));
}
@
