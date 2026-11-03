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

use std::collections::BTreeMap;

use serde::Serialize;

use crate::model::{CodeSpan, DocModel, SectionKind};
use crate::resolve::Resolution;
use crate::rewrite::slug;

/// Bumped only on a breaking change to this shape; consumers hard-fail on a
/// mismatch rather than guess (§8). Schema 2 (M11) replaced a label's
/// position-dependent `number` with its frozen opaque `id` (§7.1).
pub const SCHEMA: u32 = 2;

#[derive(Serialize, Clone, Default)]
pub struct Meta {
    pub id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub source_files: Vec<String>,
}

#[derive(Serialize, Clone)]
struct Nav {
    id: String,
    title: String,
    level: u8,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    children: Vec<Nav>,
}

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

impl SiteJson {
    /// Page ids in document order — enough for a caller to drive `page_json`
    /// without reaching into the private page list.
    pub fn page_ids(&self) -> Vec<String> {
        self.pages.iter().map(|p| p.id.clone()).collect()
    }
}

/// One section's rendered body as weave produces it, ready for `site.json`:
/// prose with sidenotes already hoisted out, plus the margin material.
pub struct RawSection {
    pub html: String,
    pub margins: Vec<Margin>,
}

/// Result of lifting sidenotes out of a rendered docs body.
pub struct Hoisted {
    /// The body as it appears on the woven page: each aside replaced by an
    /// inline marker `<sup class="fn-ref" id="fnref-N"><a href="#sn-N"></a></sup>`.
    /// The note body itself moves to the page's footnotes list (see
    /// `footnotes_in`), keyed by the same `sn-N` id.
    pub page_html: String,
    /// The body for `site.json`: asides removed entirely.
    pub json_html: String,
    pub margins: Vec<Margin>,
}

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
        // Page: the aside becomes an inline marker at the note's point. The note
        // body moves to the page's footnotes list (see `footnotes_in`), keyed by
        // this id; the marker links to it and it links back by `fnref-N`. The
        // marker carries no text — CSS draws the number from a counter — so copy,
        // paste, and the annotation layer's quote selectors survive (§5.4).
        page.push_str(&format!(
            "<sup class=\"fn-ref\" id=\"fnref-{next}\"><a href=\"#{id}\"></a></sup>"
        ));
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

/// One note as the page renders it at its foot: the frozen `sn-N` id, the
/// `fnref-N` id of the marker that points here (for the back-link), and the
/// rendered note HTML.
pub struct Footnote {
    pub id: String,
    pub refid: String,
    pub html: String,
}

/// Gather the footnotes a page shows, in marker order. `notes` maps each `sn-N`
/// id to its rendered HTML (built from every section's `margins`). `body` is the
/// page's rendered HTML, carrying the inline markers the hoist left.
pub fn footnotes_in(body: &str, notes: &BTreeMap<String, String>) -> Vec<Footnote> {
    let needle = "href=\"#sn-";
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut i = 0;
    while let Some(rel) = body[i..].find(needle) {
        let start = i + rel + "href=\"#".len();
        let Some(off) = body[start..].find('"') else { break };
        let end = start + off;
        let id = &body[start..end];
        if seen.insert(id.to_string()) {
            if let Some(html) = notes.get(id) {
                out.push(Footnote {
                    id: id.to_string(),
                    refid: id.replacen("sn-", "fnref-", 1),
                    html: html.clone(),
                });
            }
        }
        i = end;
    }
    out
}

/// The next `<h[1-6]` opener at or after `start`: its `<` index and its level.
fn next_heading(body: &str, start: usize) -> Option<(usize, u8)> {
    let bytes = body.as_bytes();
    let mut j = start;
    while let Some(rel) = body[j..].find("<h") {
        let p = j + rel;
        if p + 2 < body.len() && bytes[p + 2].is_ascii_digit() {
            return Some((p, bytes[p + 2] - b'0'));
        }
        j = p + 2;
    }
    None
}

/// The heading opener at `p` as a slice and the index just past its `>`.
fn heading_open(body: &str, p: usize) -> (&str, usize) {
    let end = body[p..].find('>').map_or(body.len(), |x| p + x + 1);
    (&body[p..end], end)
}

/// The `data-taxon` value in a heading opener, if any.
fn taxon_of(open_tag: &str) -> Option<&str> {
    let k = open_tag.find("data-taxon=\"")? + "data-taxon=\"".len();
    let rest = &open_tag[k..];
    let e = rest.find('"')?;
    Some(&rest[..e])
}

/// Wrap each taxon node in a `<section class="taxon-node" data-taxon="NAME">` so
/// CSS can box the whole node. Runs on one rendered docs body.
pub fn wrap_taxa(body: &str) -> String {
    let mut out = String::with_capacity(body.len() + 64);
    let mut i = 0;
    while let Some((p, level)) = next_heading(body, i) {
        let (open, open_end) = heading_open(body, p);
        match taxon_of(open) {
            // A heading inside a `node` fence (§10) already sits in its fence's box.
            Some(_) if open.contains(" data-rel=") => {
                out.push_str(&body[i..open_end]);
                i = open_end;
            }
            // Not a taxon, or an h1 page title: copy through the opener and go on.
            None => {
                out.push_str(&body[i..open_end]);
                i = open_end;
            }
            Some(_) if level == 1 => {
                out.push_str(&body[i..open_end]);
                i = open_end;
            }
            Some(name) => {
                out.push_str(&body[i..p]);
                // The node ends at the next heading at this level or shallower.
                let mut end = body.len();
                let mut j = open_end;
                while let Some((q, lv)) = next_heading(body, j) {
                    if lv <= level {
                        end = q;
                        break;
                    }
                    j = q + 2;
                }
                out.push_str(&format!(
                    "<section class=\"taxon-node\" data-taxon=\"{name}\">"
                ));
                out.push_str(&body[p..end]);
                out.push_str("</section>");
                i = end;
            }
        }
    }
    out.push_str(&body[i..]);
    out
}

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

fn nav_of(n: &crate::resolve::NavNode) -> Nav {
    Nav {
        id: n.id.clone(),
        title: n.title.clone(),
        level: n.level,
        children: n.children.iter().map(nav_of).collect(),
    }
}

/// Pretty JSON with a trailing newline. Pretty because the archival artifact is
/// read and diffed by humans; deterministic because serde walks fields and
/// `BTreeMap`s in a fixed order.
pub fn to_json(site: &SiteJson) -> String {
    let mut s = serde_json::to_string_pretty(site).expect("SiteJson serializes");
    s.push('\n');
    s
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hoist_lifts_sidenote_and_ids_both_sides() {
        let mut n = 0;
        let h = hoist_sidenotes(
            "<p>before<aside class=\"sidenote\">note body</aside>after</p>",
            &mut n,
        );
        // Page replaces the aside with an inline marker that links to the note.
        assert_eq!(
            h.page_html,
            "<p>before<sup class=\"fn-ref\" id=\"fnref-1\"><a href=\"#sn-1\"></a></sup>after</p>"
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

    #[test]
    fn footnotes_in_collects_marked_notes_in_order() {
        let mut notes = BTreeMap::new();
        notes.insert("sn-1".to_string(), "first".to_string());
        notes.insert("sn-2".to_string(), "second".to_string());
        // A body that marks sn-2 then sn-1: the list follows marker order, and each
        // footnote carries its back-link id.
        let body = "<p>a<sup class=\"fn-ref\" id=\"fnref-2\"><a href=\"#sn-2\"></a></sup>\
                    b<sup class=\"fn-ref\" id=\"fnref-1\"><a href=\"#sn-1\"></a></sup></p>";
        let fns = footnotes_in(body, &notes);
        assert_eq!(fns.len(), 2);
        assert_eq!((fns[0].id.as_str(), fns[0].refid.as_str(), fns[0].html.as_str()),
                   ("sn-2", "fnref-2", "second"));
        assert_eq!((fns[1].id.as_str(), fns[1].refid.as_str(), fns[1].html.as_str()),
                   ("sn-1", "fnref-1", "first"));
        // A scope-prefixed marker from a transcluded copy does not pull the note.
        let scoped = "<a href=\"#tx1-sn-1\"></a>";
        assert!(footnotes_in(scoped, &notes).is_empty());
    }

    #[test]
    fn wrap_taxa_boxes_a_node_to_its_boundary() {
        // One taxon h3, its body, then a shallower h2 that ends the node.
        let body = "<h2>Intro</h2><p>a</p>\
                    <h3 id=\"def:x\" data-taxon=\"definition\">X</h3><p>b</p><p>c</p>\
                    <h2 id=\"next\">Next</h2><p>d</p>";
        let out = wrap_taxa(body);
        assert!(out.contains(
            "<section class=\"taxon-node\" data-taxon=\"definition\">\
             <h3 id=\"def:x\" data-taxon=\"definition\">X</h3><p>b</p><p>c</p></section>"
        ));
        // Content before the node and the boundary heading stay outside the box.
        assert!(out.starts_with("<h2>Intro</h2><p>a</p><section"));
        assert!(out.ends_with("</section><h2 id=\"next\">Next</h2><p>d</p>"));
        // A heading with no taxon is never wrapped; an h1 title is left alone.
        let plain = "<h1 data-taxon=\"definition\">Title</h1><h2>S</h2><p>x</p>";
        assert_eq!(wrap_taxa(plain), plain);
    }

    #[test]
    fn counter_spans_sections() {
        let mut n = 0;
        let a = hoist_sidenotes("<aside class=\"sidenote\">a</aside>", &mut n);
        let b = hoist_sidenotes("<aside class=\"sidenote\">b</aside>", &mut n);
        assert_eq!(a.margins[0].id, "sn-1");
        assert_eq!(b.margins[0].id, "sn-2");
    }

    #[test]
    fn non_sidenote_aside_is_left_untouched() {
        let mut n = 0;
        let h = hoist_sidenotes("<aside class=\"warning\">x</aside>", &mut n);
        assert_eq!(h.page_html, "<aside class=\"warning\">x</aside>");
        assert_eq!(h.json_html, "<aside class=\"warning\">x</aside>");
        assert!(h.margins.is_empty());
        assert_eq!(n, 0);
    }

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
}
