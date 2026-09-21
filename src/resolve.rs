//! Document-global planning: turn the raw scan (§6.2 step 4 inputs)
//! into everything the second rewrite pass and the templates need — page
//! assignment, the nav tree, the label table, and one resolved target per
//! `data-ref` site.
//!
//! This is where "numbering is document-global" (§7) actually lives: pages are
//! a presentation split applied *after* numbers and anchors are fixed, so a
//! reference reads the same regardless of which page its target landed on.

use std::collections::BTreeMap;
use std::fmt;

use crate::model::{DocModel, Lint};
use crate::rewrite::{anchor_of, slug, Kind, ResolvedRef, Scan};

/// Human label → frozen opaque id (§7.1), covering every labelled float in the
/// document. Weave builds this from `cob.lock` before planning.
pub type LabelIds = BTreeMap<String, String>;

#[derive(Debug)]
pub enum ResolveError {
    /// E014 — the same label id defined twice.
    DuplicateLabel { id: String },
    /// E015 — a `data-ref` whose target is no known label.
    UnknownRef { target: String },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ResolveError::DuplicateLabel { id } => {
                write!(f, "error[E014]: duplicate label `{id}`")
            }
            ResolveError::UnknownRef { target } => {
                write!(f, "error[E015]: reference to undefined label `{target}`")
            }
        }
    }
}

impl std::error::Error for ResolveError {}

#[derive(Debug, Clone)]
pub struct PageMeta {
    pub id: String,
    pub title: String,
    pub filename: String,
}

#[derive(Debug, Clone)]
pub struct NavNode {
    /// `site.json` id: the page id for an h1, `page#anchor` for deeper headings.
    pub id: String,
    pub level: u8,
    pub title: String,
    pub href: String,
    pub children: Vec<NavNode>,
}

/// A resolved label, as `site.json`'s `labels` table records it (§8). Chunk
/// targets are excluded — they have their own `chunks` section.
#[derive(Debug, Clone)]
pub struct Label {
    /// Page index into `pages`; the serializer maps it to the page id.
    pub page: usize,
    pub anchor: String,
    pub kind: &'static str,
    /// The frozen opaque id (§7.1), present for floats, absent for section and
    /// chunk targets (which are addressed by heading text / chunk name).
    pub id: Option<String>,
}

#[derive(Debug)]
pub struct Resolution {
    pub pages: Vec<PageMeta>,
    /// `section_page[i]` is the page index of `doc.sections[i]`.
    pub section_page: Vec<usize>,
    pub nav: Vec<NavNode>,
    /// The §8 label table, keyed by id, chunk targets excluded.
    pub labels: BTreeMap<String, Label>,
    /// Anchor to stamp on each heading, in `scan.headings` order.
    pub heading_anchors: Vec<String>,
    /// Parallel to `heading_anchors`: the frozen opaque id (§7.1) of a
    /// `sec:`-labelled heading, or `None` for an unlabelled one.
    pub heading_uids: Vec<Option<String>>,
    /// One entry per `scan.refs` site, in order.
    pub refs: Vec<ResolvedRef>,
    pub lints: Vec<Lint>,
}

struct LabelInfo {
    page: usize,
    anchor: String,
    kind: Kind,
    /// The frozen opaque id (§7.1), for floats.
    id: Option<String>,
    /// Link text when the author supplied none.
    text: String,
}

/// A per-page set that turns a slug into a page-unique one by suffixing.
fn uniquify(used: &mut BTreeMap<String, u32>, base: &str) -> String {
    let base = if base.is_empty() { "x".to_string() } else { base.to_string() };
    let n = used.entry(base.clone()).or_insert(0);
    *n += 1;
    if *n == 1 {
        base
    } else {
        format!("{base}-{n}")
    }
}

/// `first_tags[i]` is the tag a docs section opens with, or `None` for code
/// sections; it is the sole page-boundary signal (§5.3).
pub fn plan(
    doc: &DocModel,
    scan: &Scan,
    first_tags: &[Option<String>],
    label_ids: &LabelIds,
) -> Result<Resolution, ResolveError> {
    let n = doc.sections.len();

    // The h1 text that opens a section, keyed by section index.
    let h1_text: BTreeMap<usize, &str> = scan
        .headings
        .iter()
        .filter(|h| h.level == 1)
        .map(|h| (h.section, h.text.as_str()))
        .collect();

    // --- Pass A: page assignment ------------------------------------------
    let default_title = doc
        .files
        .first()
        .map(|f| f.trim_end_matches(".cob").to_string())
        .unwrap_or_else(|| "index".to_string());

    let mut pages: Vec<PageMeta> = Vec::new();
    let mut section_page = vec![0usize; n];
    let mut page_slugs: BTreeMap<String, u32> = BTreeMap::new();
    let mut cur = 0usize;
    for (i, slot) in section_page.iter_mut().enumerate() {
        let is_h1 = first_tags.get(i).and_then(|t| t.as_deref()) == Some("h1");
        if pages.is_empty() || is_h1 {
            let (id, title) = if pages.is_empty() {
                // The first page is always the entry point, whatever it opens with.
                let title = h1_text.get(&i).copied().unwrap_or(&default_title);
                ("index".to_string(), title.to_string())
            } else {
                let title = h1_text.get(&i).copied().unwrap_or("section");
                (uniquify(&mut page_slugs, &slug(title)), title.to_string())
            };
            let filename = if id == "index" {
                "index.html".to_string()
            } else {
                format!("{id}.html")
            };
            pages.push(PageMeta { id, title, filename });
            cur = pages.len() - 1;
        }
        *slot = cur;
    }

    // --- Heading anchors + nav --------------------------------------------
    // An h1 anchors to its page id; deeper headings get a page-unique slug,
    // unless the author pinned an id (which a `sec:` ref may target).
    let mut per_page_anchors: Vec<BTreeMap<String, u32>> =
        (0..pages.len()).map(|_| BTreeMap::new()).collect();
    let mut heading_anchors: Vec<String> = Vec::with_capacity(scan.headings.len());
    // Parallel to `heading_anchors`: the frozen opaque id (§7.1) a `sec:`-labelled
    // heading carries, so `apply` can stamp its clickable permalink prefix.
    let mut heading_uids: Vec<Option<String>> = Vec::with_capacity(scan.headings.len());
    // (page, level, anchor, text) for nav construction.
    let mut nav_flat: Vec<(usize, u8, String, String)> = Vec::new();
    // Section-namespace labels the author declared via a heading id.
    let mut heading_labels: Vec<(String, usize, String, String)> = Vec::new();

    for h in &scan.headings {
        let page = section_page[h.section];
        let mut uid = None;
        let anchor = if h.level == 1 {
            pages[page].id.clone()
        } else if let Some(given) = &h.given_id {
            let a = anchor_of(given);
            if Kind::from_label(given) == Some(Kind::Section) {
                uid = label_ids.get(given).cloned();
                heading_labels.push((given.clone(), page, a.clone(), h.text.clone()));
            }
            a
        } else {
            uniquify(&mut per_page_anchors[page], &slug(&h.text))
        };
        nav_flat.push((page, h.level, anchor.clone(), h.text.clone()));
        heading_anchors.push(anchor);
        heading_uids.push(uid);
    }

    let nav = build_nav(&pages, &nav_flat);

    // --- Label table ------------------------------------------------------
    let mut labels: BTreeMap<String, LabelInfo> = BTreeMap::new();
    let mut insert = |id: String, info: LabelInfo| -> Result<(), ResolveError> {
        if labels.insert(id.clone(), info).is_some() {
            return Err(ResolveError::DuplicateLabel { id });
        }
        Ok(())
    };

    for l in &scan.labels {
        let page = section_page[l.section];
        // The opaque id is the reference's display id ("Figure k3f9"). It is
        // minted before planning, so a labelled float always has one; a missing
        // entry degrades to the bare kind word rather than panicking.
        let opaque = label_ids.get(&l.id);
        let text = match opaque {
            Some(id) => format!("{} {id}", l.kind.word()),
            None => l.kind.word().to_string(),
        };
        insert(
            l.id.clone(),
            LabelInfo {
                page,
                anchor: anchor_of(&l.id),
                kind: l.kind,
                id: opaque.cloned(),
                text,
            },
        )?;
    }
    for (id, page, anchor, text) in heading_labels {
        // §7.1: a `\ref{sec:…}` renders the kind-qualified opaque id ("Section
        // k3f9"), not the heading text, which rots on rename. The heading text
        // survives only as a fallback if the id was never minted (Mint always
        // mints; `--locked` would already have failed on a missing label).
        let opaque = label_ids.get(&id).cloned();
        let display = match &opaque {
            Some(uid) => format!("{} {uid}", Kind::Section.word()),
            None => text,
        };
        insert(
            id,
            LabelInfo {
                page,
                anchor,
                kind: Kind::Section,
                id: opaque,
                text: display,
            },
        )?;
    }
    // `chunk:` targets are synthesized from chunk names and point at the first
    // defining section (§7), so prose can link into code.
    let sec_index: BTreeMap<&str, usize> = doc
        .sections
        .iter()
        .enumerate()
        .map(|(i, s)| (s.id.as_str(), i))
        .collect();
    for (name, info) in &doc.chunks {
        let Some(def) = info.defs.first() else { continue };
        let Some(&si) = sec_index.get(def.as_str()) else { continue };
        insert(
            format!("chunk:{name}"),
            LabelInfo {
                page: section_page[si],
                anchor: def.clone(),
                kind: Kind::Chunk,
                id: None,
                text: name.clone(),
            },
        )?;
    }

    // --- Resolve refs -----------------------------------------------------
    let mut refs = Vec::with_capacity(scan.refs.len());
    for r in &scan.refs {
        let info = labels
            .get(&r.target)
            .ok_or_else(|| ResolveError::UnknownRef {
                target: r.target.clone(),
            })?;
        let ref_page = section_page[r.section];
        let href = if info.page == ref_page {
            format!("#{}", info.anchor)
        } else {
            format!("{}#{}", pages[info.page].filename, info.anchor)
        };
        refs.push(ResolvedRef {
            href,
            text: if r.has_text { None } else { Some(info.text.clone()) },
        });
    }

    // --- Lints ------------------------------------------------------------
    // A figure or table without a caption cannot be numbered meaningfully (§7).
    let mut lints = Vec::new();
    for &si in &scan.uncaptioned {
        let s = &doc.sections[si];
        lints.push(Lint {
            code: "W103",
            message: "figure or table without a caption".to_string(),
            file: s.file.clone(),
            line: s.line,
        });
    }

    // The §8 label table: everything but the synthetic chunk targets, which
    // the `chunks` section already represents.
    let pub_labels = labels
        .iter()
        .filter(|(_, info)| info.kind != Kind::Chunk)
        .map(|(id, info)| {
            (
                id.clone(),
                Label {
                    page: info.page,
                    anchor: info.anchor.clone(),
                    kind: info.kind.json_name(),
                    id: info.id.clone(),
                },
            )
        })
        .collect();

    Ok(Resolution {
        pages,
        section_page,
        nav,
        labels: pub_labels,
        heading_anchors,
        heading_uids,
        refs,
        lints,
    })
}

fn build_nav(pages: &[PageMeta], flat: &[(usize, u8, String, String)]) -> Vec<NavNode> {
    let mut roots: Vec<NavNode> = Vec::new();
    for (page, level, anchor, text) in flat {
        let filename = &pages[*page].filename;
        let page_id = &pages[*page].id;
        let node = NavNode {
            // §8 id: the page id for an h1, `page#anchor` within a page.
            id: if *level == 1 {
                page_id.clone()
            } else {
                format!("{page_id}#{anchor}")
            },
            level: *level,
            title: text.clone(),
            // An h1 is the page itself; deeper headings are fragments within it.
            href: if *level == 1 {
                filename.clone()
            } else {
                format!("{filename}#{anchor}")
            },
            children: Vec::new(),
        };
        match level {
            1 => roots.push(node),
            2 => {
                if let Some(h1) = roots.last_mut() {
                    h1.children.push(node);
                } else {
                    roots.push(node);
                }
            }
            _ => {
                if let Some(h2) = roots.last_mut().and_then(|h1| h1.children.last_mut()) {
                    h2.children.push(node);
                } else if let Some(h1) = roots.last_mut() {
                    h1.children.push(node);
                } else {
                    roots.push(node);
                }
            }
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SectionKind;
    use crate::rewrite::scan;

    /// A readable stand-in id for a label, so tests can assert generated link
    /// text without depending on the RNG (which `lock.rs` tests cover). E.g.
    /// `fig:p` → `figp`.
    fn fake_id(label: &str) -> String {
        label.replace(':', "")
    }

    /// Build a resolution from raw prose fragments paired with their section id
    /// and source line, mirroring what weave feeds in. Every scanned float label
    /// is assigned a readable opaque id via `fake_id`.
    fn resolve(frags: &[(&str, bool)]) -> (DocModel, Resolution) {
        let mut sc = Scan::default();
        let mut sections = Vec::new();
        let mut first_tags = Vec::new();
        let mut chunks = BTreeMap::new();
        for (i, (html, is_code)) in frags.iter().enumerate() {
            let id = format!("sec-{}", i + 1);
            if *is_code {
                sections.push(crate::model::Section {
                    id: id.clone(),
                    file: "t.cob".into(),
                    line: i as u32 + 1,
                    kind: SectionKind::Code {
                        name: html.to_string(),
                        continues: false,
                        spans: vec![],
                        index_defs: vec![],
                    },
                });
                chunks.insert(
                    html.to_string(),
                    crate::model::ChunkInfo {
                        defs: vec![id],
                        uses: vec![],
                        root: false,
                    },
                );
                first_tags.push(None);
            } else {
                let before = sc.first_tag.len();
                scan(html, i, &mut sc).unwrap();
                first_tags.push(sc.first_tag[before].clone());
                sections.push(crate::model::Section {
                    id,
                    file: "t.cob".into(),
                    line: i as u32 + 1,
                    kind: SectionKind::Docs { spans: vec![] },
                });
            }
        }
        let doc = DocModel {
            files: vec!["t.cob".into()],
            sections,
            chunks,
        };
        let label_ids: LabelIds = sc
            .labels
            .iter()
            .map(|l| (l.id.clone(), fake_id(&l.id)))
            .collect();
        let res = plan(&doc, &sc, &first_tags, &label_ids).unwrap();
        (doc, res)
    }

    #[test]
    fn h1_sections_start_pages_code_inherits() {
        let (_, r) = resolve(&[
            ("<h1>Intro</h1><p>x</p>", false),
            ("lex a token", true),
            ("<h1>Parsing</h1><p>y</p>", false),
        ]);
        assert_eq!(r.pages.len(), 2);
        assert_eq!(r.pages[0].filename, "index.html");
        assert_eq!(r.pages[1].filename, "parsing.html");
        // The code section belongs to the page open when it appeared.
        assert_eq!(r.section_page, vec![0, 0, 1]);
    }

    #[test]
    fn first_page_is_index_even_with_a_heading() {
        let (_, r) = resolve(&[("<h1>Front matter</h1>", false)]);
        assert_eq!(r.pages[0].id, "index");
        assert_eq!(r.pages[0].title, "Front matter");
    }

    #[test]
    fn nav_nests_h2_and_h3_under_h1() {
        let (_, r) = resolve(&[(
            "<h1>Parsing</h1><h2>Lexing</h2><h3>Cost</h3><h2>Layout</h2>",
            false,
        )]);
        // One page-boundary h1 → first page is index here.
        assert_eq!(r.nav.len(), 1);
        assert_eq!(r.nav[0].title, "Parsing");
        assert_eq!(r.nav[0].href, "index.html");
        assert_eq!(r.nav[0].children.len(), 2);
        assert_eq!(r.nav[0].children[0].title, "Lexing");
        assert_eq!(r.nav[0].children[0].href, "index.html#lexing");
        assert_eq!(r.nav[0].children[0].children[0].title, "Cost");
    }

    #[test]
    fn cross_page_ref_is_page_qualified_same_page_is_a_fragment() {
        let (_, r) = resolve(&[
            (
                "<h1>Intro</h1><a data-ref=\"fig:p\"></a><a data-ref=\"eq:c\"></a>",
                false,
            ),
            (
                "<h1>Body</h1><figure id=\"fig:p\"><figcaption>P</figcaption></figure>\
                 <div class=\"equation\" id=\"eq:c\">e</div><a data-ref=\"eq:c\"></a>",
                false,
            ),
        ]);
        // fig:p and eq:c live on page 1; the refs on page 0 must cross.
        assert_eq!(r.refs[0].href, "body.html#fig-p");
        // The link text is kind-qualified with the frozen opaque id, not "Figure 1".
        assert_eq!(r.refs[0].text.as_deref(), Some("Figure figp"));
        assert_eq!(r.refs[1].href, "body.html#eq-c");
        // The third ref is on the same page as eq:c.
        assert_eq!(r.refs[2].href, "#eq-c");
    }

    #[test]
    fn chunk_refs_target_the_defining_section() {
        let (_, r) = resolve(&[
            ("<h1>Intro</h1><a data-ref=\"chunk:lex a token\"></a>", false),
            ("lex a token", true),
        ]);
        assert_eq!(r.refs[0].href, "#sec-2");
        assert_eq!(r.refs[0].text.as_deref(), Some("lex a token"));
    }

    #[test]
    fn author_ref_text_is_kept() {
        let (_, r) = resolve(&[(
            "<h1>I</h1><figure id=\"fig:p\"><figcaption>P</figcaption></figure>\
             <a data-ref=\"fig:p\">see the diagram</a>",
            false,
        )]);
        assert_eq!(r.refs[0].text, None);
    }

    #[test]
    fn duplicate_label_is_e014() {
        let mut sc = Scan::default();
        scan(
            "<figure id=\"fig:a\"><figcaption>1</figcaption></figure>\
             <figure id=\"fig:a\"><figcaption>2</figcaption></figure>",
            0,
            &mut sc,
        )
        .unwrap();
        let doc = DocModel {
            files: vec!["t.cob".into()],
            sections: vec![crate::model::Section {
                id: "sec-1".into(),
                file: "t.cob".into(),
                line: 1,
                kind: SectionKind::Docs { spans: vec![] },
            }],
            chunks: BTreeMap::new(),
        };
        let err = plan(&doc, &sc, &[Some("figure".into())], &LabelIds::new()).unwrap_err();
        assert!(err.to_string().starts_with("error[E014]"));
    }

    #[test]
    fn unknown_ref_is_e015() {
        let mut sc = Scan::default();
        scan("<h1>I</h1><a data-ref=\"fig:ghost\"></a>", 0, &mut sc).unwrap();
        let doc = DocModel {
            files: vec!["t.cob".into()],
            sections: vec![crate::model::Section {
                id: "sec-1".into(),
                file: "t.cob".into(),
                line: 1,
                kind: SectionKind::Docs { spans: vec![] },
            }],
            chunks: BTreeMap::new(),
        };
        let err = plan(&doc, &sc, &[Some("h1".into())], &LabelIds::new()).unwrap_err();
        assert!(err.to_string().starts_with("error[E015]"));
    }

    #[test]
    fn uncaptioned_figure_is_w103() {
        let (_, r) = resolve(&[("<h1>I</h1><figure id=\"fig:a\"><img src=\"x\"></figure>", false)]);
        assert_eq!(r.lints.len(), 1);
        assert_eq!(r.lints[0].code, "W103");
    }
}
