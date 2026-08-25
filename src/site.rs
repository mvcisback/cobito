//! The `site.json` contract (SPEC.md §8): a `schema: 2` document model that
//! Phase 1 produces and Phase 2 (annotation/review tooling) consumes unchanged.
//!
//! It is written only under `lit weave --archive`. Determinism is a hard
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
struct Label {
    page: String,
    anchor: String,
    kind: &'static str,
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

#[derive(Serialize)]
pub struct SiteJson {
    pub schema: u32,
    pub meta: Meta,
    nav: Vec<Nav>,
    labels: BTreeMap<String, Label>,
    chunks: BTreeMap<String, Chunk>,
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
    /// The body as it appears on the woven page: asides kept inline, each now
    /// carrying its `id="sn-N"` so page and JSON share ids.
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
        pages: vec![page.clone()],
    };
    Some(to_json(&one))
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
}
