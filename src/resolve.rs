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
use crate::site::ForestRef;

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

/// The word a `\ref` to a heading reads. A page heading (an h1) takes it from its
/// label's namespace: `ch:` is a "Chapter", `part:` a "Part". Any other heading
/// takes it from the node's taxon (§10): "definition" becomes "Definition". A
/// heading with neither is a "Section".
fn heading_ref_word(taxon: Option<&str>, label: &str, level: u8) -> String {
    if level == 1 {
        match label.split_once(':').map(|(ns, _)| ns) {
            Some("ch") => return "Chapter".to_string(),
            Some("part") => return "Part".to_string(),
            _ => {}
        }
    }
    match taxon {
        Some(t) if !t.is_empty() => {
            let mut c = t.chars();
            let first = c.next().unwrap().to_uppercase().collect::<String>();
            first + c.as_str()
        }
        _ => Kind::Section.word().to_string(),
    }
}

/// `first_tags[i]` is the tag a docs section opens with, or `None` for code
/// sections; it is the sole page-boundary signal (§5.3).
pub fn plan(
    doc: &DocModel,
    scan: &Scan,
    first_tags: &[Option<String>],
    label_ids: &LabelIds,
    imports: &BTreeMap<String, ForestRef>,
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
    // Labels the author declared via a heading id, any node namespace (§10):
    // (id, page, anchor, fallback text, taxon, level). The taxon names the ref word
    // of a section; the level tells a page-heading label from a section label.
    let mut heading_labels: Vec<(String, usize, String, String, Option<String>, u8)> = Vec::new();

    for h in &scan.headings {
        let page = section_page[h.section];
        let mut uid = None;
        let anchor = if h.level == 1 {
            // An h1 is its page and anchors to the page id. A labelled one (`ch:`,
            // `part:`) is also a ref target, so `\ref{ch:x}` reaches the chapter.
            // It earns an id for the ref text but no `uid`: a page is not a node,
            // so it gets no permalink prefix and no `n/` page.
            let a = pages[page].id.clone();
            if let Some(given) = &h.given_id {
                if Kind::label_is_page_heading(given) {
                    heading_labels.push((given.clone(), page, a.clone(), h.text.clone(), None, 1));
                }
            }
            a
        } else if let Some(given) = &h.given_id {
            let a = anchor_of(given);
            if Kind::label_is_heading_node(given) {
                uid = label_ids.get(given).cloned();
                heading_labels.push((given.clone(), page, a.clone(), h.text.clone(), h.taxon.clone(), h.level));
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
        // A `node` fence carries a taxon (§10), which names the word: "Definition".
        // A float takes the word of its kind.
        let word = match &l.taxon {
            Some(_) => heading_ref_word(l.taxon.as_deref(), &l.id, 2),
            None => l.kind.word().to_string(),
        };
        let text = match opaque {
            Some(id) => format!("{word} {id}"),
            None => word,
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
    for (id, page, anchor, text, taxon, level) in heading_labels {
        // §7.1: a `\ref{…}` to a heading renders the kind-qualified opaque id
        // ("Definition k3f9"), not the heading text, which rots on rename. The
        // kind word comes from the node's taxon (§10) — "Definition", "Theorem"
        // — or is "Section" for a plain heading; a page heading reads "Chapter" or
        // "Part" from its `ch:`/`part:` label. The heading text survives only
        // as a fallback if the id was never minted (Mint always mints; `--locked`
        // would already have failed on a missing label).
        let opaque = label_ids.get(&id).cloned();
        let display = match &opaque {
            Some(uid) => format!("{} {uid}", heading_ref_word(taxon.as_deref(), &id, level)),
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
        // A `label@alias` target resolves against an imported forest (§13): its
        // href lands on the deployed page, its text is the kind word plus the
        // target's frozen opaque id.
        if let Some((label, alias)) = r.target.rsplit_once('@') {
            let fr = imports.get(alias).ok_or_else(|| ResolveError::UnknownRef {
                target: r.target.clone(),
            })?;
            let fl = fr.index.labels.get(label).ok_or_else(|| ResolveError::UnknownRef {
                target: r.target.clone(),
            })?;
            let base = fr.url.trim_end_matches('/');
            let href = format!("{base}/{}.html#{}", fl.page, fl.anchor);
            let text = match (Kind::from_label(label).map(Kind::word), &fl.id) {
                (Some(word), Some(id)) => format!("{word} {id}"),
                (_, Some(id)) => id.clone(),
                _ => label.to_string(),
            };
            refs.push(ResolvedRef {
                href,
                text: if r.has_text { None } else { Some(text) },
            });
            continue;
        }
        let info = labels
            .get(&r.target)
            .ok_or_else(|| ResolveError::UnknownRef {
                target: r.target.clone(),
            })?;
        let ref_page = section_page[r.section];
        let href = if info.kind == Kind::Macro {
            // A `def:` node is homeless (§10): it has no in-flow anchor, so a ref
            // points at the node's own page instead of a same-page fragment.
            match &info.id {
                Some(uid) => format!("n/{uid}.html"),
                None => format!("#{}", info.anchor),
            }
        } else if info.page == ref_page {
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

/// Put `node` under the latest node above it in level, at any depth, else beside it.
fn nest(nodes: &mut Vec<NavNode>, node: NavNode) {
    match nodes.last_mut() {
        Some(last) if last.level < node.level => nest(&mut last.children, node),
        _ => nodes.push(node),
    }
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
        nest(&mut roots, node);
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
        let mut label_ids: LabelIds = sc
            .labels
            .iter()
            .map(|l| (l.id.clone(), fake_id(&l.id)))
            .collect();
        // Mirror weave's `mintable`: a labelled heading in a node namespace also
        // earns a frozen id, so a `\ref` to a definition, a theorem, or a chapter
        // resolves.
        for h in &sc.headings {
            if let Some(g) = &h.given_id {
                let earns = if h.level == 1 {
                    Kind::label_is_page_heading(g)
                } else {
                    Kind::label_is_heading_node(g)
                };
                if earns {
                    label_ids.entry(g.clone()).or_insert_with(|| fake_id(g));
                }
            }
        }
        let res = plan(&doc, &sc, &first_tags, &label_ids, &BTreeMap::new()).unwrap();
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
    fn a_taxon_heading_is_a_node_and_its_ref_is_typed() {
        let (_, r) = resolve(&[(
            "<h1>T</h1>\
             <h2 id=\"def:d\" data-taxon=\"definition\">D</h2>\
             <h2 id=\"sec:s\">S</h2>\
             <a data-ref=\"def:d\"></a><a data-ref=\"sec:s\"></a>",
            false,
        )]);
        // The definition ref is typed by its taxon; the plain section ref is not.
        assert_eq!(r.refs[0].href, "#def-d");
        assert_eq!(r.refs[0].text.as_deref(), Some("Definition defd"));
        assert_eq!(r.refs[1].href, "#sec-s");
        assert_eq!(r.refs[1].text.as_deref(), Some("Section secs"));
    }

    #[test]
    fn a_labelled_page_heading_is_a_ref_target_but_not_a_node() {
        let (_, r) = resolve(&[
            (
                "<h1 id=\"part:p\">Intro</h1><a data-ref=\"ch:b\"></a><a data-ref=\"part:p\"></a>",
                false,
            ),
            ("<h1 id=\"ch:b\">Body</h1><h2 id=\"sec:s\">S</h2>", false),
            // A non-page label on an h1 (a `sec:` one) means nothing, as it always
            // did: an existing document is not changed by page labels.
            ("<h1 id=\"sec:old\">Old</h1>", false),
        ]);
        assert!(r.labels.contains_key("ch:b") && !r.labels.contains_key("sec:old"));
        // A cross-page ref lands on the chapter's page; a same-page ref is a fragment.
        assert_eq!(r.refs[0].href, "body.html#body");
        assert_eq!(r.refs[0].text.as_deref(), Some("Chapter chb"));
        assert_eq!(r.refs[1].href, "#index");
        assert_eq!(r.refs[1].text.as_deref(), Some("Part partp"));
        // Only the h2 earns a uid: no h1 is a node.
        let uids: Vec<bool> = r.heading_uids.iter().map(|u| u.is_some()).collect();
        assert_eq!(uids, vec![false, false, true, false]);
    }

    #[test]
    fn a_node_fence_is_a_labelled_typed_node() {
        let (_, r) = resolve(&[(
            "<h1>T</h1><section class=\"taxon-node\" id=\"thm:t\" data-taxon=\"theorem\">\
             <p class=\"node-title\" data-taxon=\"theorem\"></p></section>\
             <a data-ref=\"thm:t\"></a>",
            false,
        )]);
        assert_eq!(r.refs[0].href, "#thm-t");
        assert_eq!(r.refs[0].text.as_deref(), Some("Theorem thmt"));
        assert!(r.labels.contains_key("thm:t"));
        // A node fence is not a heading: it adds no heading uid.
        assert!(r.heading_uids.iter().all(|u| u.is_none()));
    }

    #[test]
    fn a_cross_document_ref_targets_the_imported_forest() {
        use crate::site::{ForestIndex, ForestLabel, ForestRef};
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
        let mut labels = BTreeMap::new();
        labels.insert(
            "eq:cost".to_string(),
            ForestLabel {
                id: Some("k3f9".into()),
                kind: "equation".into(),
                page: "index".into(),
                anchor: "eq-cost".into(),
            },
        );
        let mut imports = BTreeMap::new();
        imports.insert(
            "alg".to_string(),
            ForestRef {
                url: "https://alg.example/".into(),
                index: ForestIndex {
                    macros: BTreeMap::new(),
                    labels,
                    ..Default::default()
                },
            },
        );

        let mut sc = Scan::default();
        scan("<h1>I</h1><a data-ref=\"eq:cost@alg\"></a>", 0, &mut sc).unwrap();
        let r = plan(&doc, &sc, &[Some("h1".into())], &LabelIds::new(), &imports).unwrap();
        // The href lands on the deployed page; the trailing slash on the url does not
        // double. The text is the kind word with the frozen opaque id.
        assert_eq!(r.refs[0].href, "https://alg.example/index.html#eq-cost");
        assert_eq!(r.refs[0].text.as_deref(), Some("Equation k3f9"));

        // An unknown alias is E015, like any other undefined reference.
        let mut sc2 = Scan::default();
        scan("<h1>I</h1><a data-ref=\"eq:cost@ghost\"></a>", 0, &mut sc2).unwrap();
        let err = plan(&doc, &sc2, &[Some("h1".into())], &LabelIds::new(), &imports).unwrap_err();
        assert!(err.to_string().starts_with("error[E015]"));
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
        let err = plan(&doc, &sc, &[Some("figure".into())], &LabelIds::new(), &BTreeMap::new())
            .unwrap_err();
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
        let err = plan(&doc, &sc, &[Some("h1".into())], &LabelIds::new(), &BTreeMap::new())
            .unwrap_err();
        assert!(err.to_string().starts_with("error[E015]"));
    }

    #[test]
    fn uncaptioned_figure_is_w103() {
        let (_, r) = resolve(&[("<h1>I</h1><figure id=\"fig:a\"><img src=\"x\"></figure>", false)]);
        assert_eq!(r.lints.len(), 1);
        assert_eq!(r.lints[0].code, "W103");
    }
}
