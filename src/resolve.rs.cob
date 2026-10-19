# Labels, numbering, and cross-references (§7)

This module is the specification and the implementation of document-global
planning. The prose is the specification. The chunks after it are the
implementation. Planning turns the raw scan (§6.2 step 4 inputs) into what the
second rewrite pass and the templates need: page assignment, the nav tree, the
label table, and one resolved target for each \code{data-ref} site.

## Identity is document-global {#sec:iBsg}

Identity is document-global, so a reference works across pages. cob assigns every
number and anchor first, then splits the document into pages. A page is a
presentation choice, so it must not change what a reference reads. This is why
planning lives in its own pass, before the split.

§7.1 supersedes the display half of this section (the lock module). A reference
shows a stable opaque id, not a position-dependent "Figure 3". The anchoring and
caption mechanics here are unchanged; what changed is what the id is, and the
attribute that carries it (\code{data-id}, not \code{data-number}).

## Labels and references {#sec:fnwt}

Prose carries a label on the target and a reference at the use site. In \code{html}
mode these are attributes; in \code{markdown} mode \code{\label} and \code{\ref} lower to the
same attributes (§6.4). At weave time cob turns each \code{data-ref} into an anchor
whose text comes from the target's kind and its opaque id, such as
\code{<a href="parsing.html#fig-pipeline">Figure k3f9</a>}. cob keeps author-supplied
link text if there is any. An href is relative: a same-page target is a bare
\code{#anchor}; a cross-page target is \code{page.html#anchor}. A colon in a label id
becomes a dash in the emitted anchor, because a colon needs escaping in every CSS
selector that touches it.

- Namespaces are by prefix: \code{eq:}, \code{fig:}, \code{tbl:} name floats; \code{chunk:} names
  a chunk; \code{cite:} a citation. A heading takes any other namespace — \code{sec:},
  \code{def:}, \code{thm:}, \code{ex:}, and so on — and becomes a referenceable node (§10);
  its taxon names the word a \code{\ref} to it reads. A float-only ref id on a
  heading is not a heading node.
- A page heading (an h1) may carry a \code{ch:} or \code{part:} label: \code{# Title {#ch:name}}. It is
  then a target for \code{\ref}, which reads "Chapter" or "Part" with a frozen id and links to
  the page. A page is not a node, so it gets no permalink prefix and no \code{n/} page. A book
  needs this to refer to its own chapters. \code{\ref{ch:name}{Title}} keeps the author's link text,
  so a table of contents can name a chapter by its title.
- The numbering scheme is \code{flat} or \code{by-page}; the default is \code{flat}, so a page
  boundary does not leak into a stable reference. M2 implements \code{flat}.
- cob numbers an equation by default. A \code{data-nonumber} equation div opts out.
- A figure and a table need a caption. A missing caption is the W103 lint, not an
  error.
- A duplicate label is the E014 error. A \code{data-ref} to an unknown label is E015.

A \code{chunk:} target is synthesized from a chunk name, so prose can link to code.
Its anchor is the chunk's first defining section, and the default link text is
the chunk name.

## Identity never enters a text node {#sec:m11o}

Like a code line number (§5.4), a float's id lands in an attribute and the
stylesheet draws it. Because CSS \code{attr()} reads only the element's own
attributes, the id is stamped on the caption element, not on the container, and
an equation carries it on the equation div itself. This keeps the annotation
layer's quote selectors (§9.2) stable when a figure moves, and the opaque id does
not change at all when it moves.

cob rejects CSS counters. A counter resets per document, and each cob page is a
separate HTML file, so a counter could not give a document-global id on the
second page. The attribute holds the globally-assigned id instead — which under
§7.1 is minted once and frozen, so it is stable across documents too.

## How the code implements this {#sec:XwSp}

The module is the label-id map, the error type, the resolution's data types, a
slug-uniquifier, the \code{plan} entry point (walked in phases), and the nav builder.
<<src/resolve.rs>>=
<<the module banner>>

<<imports>>

<<the label id map>>

<<the resolve error>>

<<page and nav metadata>>

<<a resolved label and the resolution>>

<<internal label info>>

<<make a slug page-unique>>

<<plan the document>>

<<build the nav tree>>

<<the tests>>
@
The banner states what planning produces and why pages do not affect references.
<<the module banner>>=
//! Document-global planning: turn the raw scan (§6.2 step 4 inputs)
//! into everything the second rewrite pass and the templates need — page
//! assignment, the nav tree, the label table, and one resolved target per
//! `data-ref` site.
//!
//! This is where "numbering is document-global" (§7) actually lives: pages are
//! a presentation split applied *after* numbers and anchors are fixed, so a
//! reference reads the same regardless of which page its target landed on.
@
Maps, formatting, the model types, and the rewrite scan this planner consumes.
<<imports>>=
use std::collections::BTreeMap;
use std::fmt;

use crate::model::{DocModel, Lint};
use crate::rewrite::{anchor_of, slug, Kind, ResolvedRef, Scan};
use crate::site::ForestRef;
@
The label-id map carries every labelled float's human label to its frozen opaque
id (§7.1). Weave builds it from \code{cob.lock} before planning.
<<the label id map>>=
/// Human label → frozen opaque id (§7.1), covering every labelled float in the
/// document. Weave builds this from `cob.lock` before planning.
pub type LabelIds = BTreeMap<String, String>;
@
Two failures: the same label id defined twice (E014), and a \code{data-ref} whose
target is no known label (E015).
<<the resolve error>>=
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
@
\code{PageMeta} is one output page's id, title, and filename. \code{NavNode} is one
table-of-contents entry: its \code{site.json} id, level, title, link href, and
children.
<<page and nav metadata>>=
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
@
\code{Label} is a resolved label as the §8 table records it — a page index, an anchor,
a kind, and (for a float) its opaque id. \code{Resolution} is the whole plan: the
pages, each section's page, the nav, the label table, the per-heading anchors and
their optional opaque ids, one resolved ref per site, and the lints.
<<a resolved label and the resolution>>=
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
@
\code{LabelInfo} is the planner's private working record for one label: its page,
anchor, kind, opaque id, and the link text to use when the author gave none.
<<internal label info>>=
struct LabelInfo {
    page: usize,
    anchor: String,
    kind: Kind,
    /// The frozen opaque id (§7.1), for floats.
    id: Option<String>,
    /// Link text when the author supplied none.
    text: String,
}
@
Slugs must be unique within a page, so this suffixes a repeat with \code{-2}, \code{-3},
and so on; an empty base becomes \code{x}.
<<make a slug page-unique>>=
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
@
\code{plan} runs in five phases. It first indexes the h1 text per section, then assigns
each section to a page (Pass A), stamps heading anchors and builds the nav, fills
the label table from floats, headings, and chunk targets, resolves every ref to an
href and display text, and finally collects lints and assembles the result.
<<plan the document>>=
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

<<pass a: assign each section to a page>>

<<stamp heading anchors and build the nav>>

<<fill the label table>>

<<resolve every ref>>

<<collect lints and assemble the resolution>>
}
@
The first page is always \code{index}, whatever it opens with. After that, each h1
starts a new page whose slug is derived from its title and made unique.
<<pass a: assign each section to a page>>=
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
@
An h1 anchors to its page id; a deeper heading gets a page-unique slug unless the
author pinned an id. A pinned id in a node namespace (§10) makes the heading a
referenceable node: it is recorded for the label table with its taxon, and its
opaque id is carried out so \code{apply} can stamp the permalink and node link.
<<stamp heading anchors and build the nav>>=
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
@
The label table draws from three sources: scanned float labels (each with its
kind-and-opaque-id display text), heading section labels (which render as a
kind-qualified opaque id, not the rot-prone heading text), and synthetic \code{chunk:}
targets that point at a chunk's first defining section so prose can link into
code. A repeat id is E014.
<<fill the label table>>=
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
@
Each ref resolves to an href — a bare fragment when the target is on the same
page, page-qualified when it crosses — and to display text, kept from the author
if present, otherwise the label's own text. An unknown target is E015.

A target of the form \code{label@alias} points into an imported forest (§13). cob
reads that forest's label index (from its \code{cob-exports.json}), so the href lands on the
deployed page \code{<url>/<page>.html#<anchor>}, and the display text is the kind word
and the target's frozen opaque id, the same shape a local ref shows. An unknown
alias or an unknown label in a known forest is E015, the same as any other
undefined reference.
<<resolve every ref>>=
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
@
An uncaptioned figure or table cannot be numbered meaningfully, so it is W103. The
public §8 label table then keeps everything but the synthetic chunk targets, which
the \code{chunks} section already represents.
<<collect lints and assemble the resolution>>=
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
@
The nav builder folds the flat heading list into a tree: h1s are roots, h2s nest
under the last h1, h3s under the last h2, with a graceful fallback when a level is
skipped. An h1's href is the page file; a deeper heading's is a fragment within
it.
<<build the nav tree>>=
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
@
The tests build resolutions from raw prose fragments and assert the plan: pages
open on h1, the first page is always \code{index}, nav nests, refs cross pages or stay
fragments, chunk refs target the defining section, author ref text wins, and the
E014/E015/W103 diagnostics fire.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SectionKind;
    use crate::rewrite::scan;

    <<a readable fake id>>

    <<resolve prose fragments>>

    <<h1 sections start pages, code inherits>>

    <<the first page is index even with a heading>>

    <<nav nests h2 and h3 under h1>>

    <<cross-page refs qualify, same-page refs are fragments>>

    <<a taxon heading is a node and its ref is typed>>

    <<a labelled page heading is a ref target but not a node>>

    <<a node fence is a labelled typed node>>

    <<a cross-document ref targets the imported forest>>

    <<chunk refs target the defining section>>

    <<author ref text is kept>>

    <<a duplicate label is e014>>

    <<an unknown ref is e015>>

    <<an uncaptioned figure is w103>>
}
@
A readable stand-in id lets tests assert generated link text without the RNG.
<<a readable fake id>>=
/// A readable stand-in id for a label, so tests can assert generated link
/// text without depending on the RNG (which `lock.rs` tests cover). E.g.
/// `fig:p` → `figp`.
fn fake_id(label: &str) -> String {
    label.replace(':', "")
}
@
The harness mirrors what weave feeds in: prose or code fragments paired with a
section id and line, scanned for labels and refs, with every float label given a
readable opaque id.
<<resolve prose fragments>>=
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
@
An h1 starts a page; a code section inherits the page open when it appeared.
<<h1 sections start pages, code inherits>>=
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
@
The first page is \code{index} even when it opens with a heading, taking the heading's
text as its title.
<<the first page is index even with a heading>>=
#[test]
fn first_page_is_index_even_with_a_heading() {
    let (_, r) = resolve(&[("<h1>Front matter</h1>", false)]);
    assert_eq!(r.pages[0].id, "index");
    assert_eq!(r.pages[0].title, "Front matter");
}
@
h2 and h3 nest under their h1 in the nav tree.
<<nav nests h2 and h3 under h1>>=
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
@
A ref to a target on another page is page-qualified; a ref to a target on the same
page is a bare fragment. The link text is the kind-qualified opaque id.
A heading with a non-float label in any namespace is a node (§10): it earns an
opaque id, so a \code{\ref} to it resolves, and the link text takes the node's
taxon as its word — "Definition", not "Section" — while a plain labelled heading
stays "Section".
<<a taxon heading is a node and its ref is typed>>=
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
@
A node fence (§10) is a labelled typed node that is not a heading. Its label is any
node namespace, and its taxon names the word a \code{\ref} to it reads. It is an element, so
it earns an opaque id like a float but adds no heading uid, and its anchor is the
colon-free label.
<<a node fence is a labelled typed node>>=
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
@
A page heading (an h1) with a \code{ch:} or \code{part:} label is a target for \code{\ref}: the
thesis refers to its chapters and parts about sixty times. The ref reads "Chapter" or
"Part" with the frozen id, and links to the chapter's page. But a page is not a node,
so the heading earns no permalink uid and no \code{n/} page.
<<a labelled page heading is a ref target but not a node>>=
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
@
<<cross-page refs qualify, same-page refs are fragments>>=
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
@
A \code{label@alias} ref resolves against the imported forest's label index: the href
lands on the deployed page, and the text is the kind word with the frozen opaque
id. An unknown alias (or an unknown label in a known forest) is E015.
<<a cross-document ref targets the imported forest>>=
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
@
A \code{chunk:} ref points at the chunk's defining section, with the chunk name as
text.
<<chunk refs target the defining section>>=
#[test]
fn chunk_refs_target_the_defining_section() {
    let (_, r) = resolve(&[
        ("<h1>Intro</h1><a data-ref=\"chunk:lex a token\"></a>", false),
        ("lex a token", true),
    ]);
    assert_eq!(r.refs[0].href, "#sec-2");
    assert_eq!(r.refs[0].text.as_deref(), Some("lex a token"));
}
@
When the author supplied ref text, the resolver keeps it (leaving the generated
text \code{None}).
<<author ref text is kept>>=
#[test]
fn author_ref_text_is_kept() {
    let (_, r) = resolve(&[(
        "<h1>I</h1><figure id=\"fig:p\"><figcaption>P</figcaption></figure>\
         <a data-ref=\"fig:p\">see the diagram</a>",
        false,
    )]);
    assert_eq!(r.refs[0].text, None);
}
@
Two floats with the same label id are E014.
<<a duplicate label is e014>>=
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
@
A ref to a label that does not exist is E015.
<<an unknown ref is e015>>=
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
@
An uncaptioned figure is W103.
<<an uncaptioned figure is w103>>=
#[test]
fn uncaptioned_figure_is_w103() {
    let (_, r) = resolve(&[("<h1>I</h1><figure id=\"fig:a\"><img src=\"x\"></figure>", false)]);
    assert_eq!(r.lints.len(), 1);
    assert_eq!(r.lints[0].code, "W103");
}
@
