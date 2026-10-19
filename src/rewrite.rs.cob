# Prose rewriting (§4.3, §9)

This module is steps 3 through 5 of the prose pipeline (§6.2). It parses the
now math-free prose, rewrites it, and serializes it. The prose after this is the
specification. The chunks after the prose are the implementation.

## Why cob needs an HTML parser {#sec:9k7W}

An early draft claimed the pipeline format lets cob avoid a parser. That claim
was wrong. This phase must find the \code{h1} boundaries for page splitting, add \code{id}
attributes, number the figures and tables, rewrite the \code{data-ref} placeholders,
and hoist the aside margin content. Each of these operations is tree surgery on
the prose. Prose is HTML by this point, so cob must read HTML as a tree.

cob uses \code{lol_html}, a streaming rewriter with CSS-selector handlers. The numbers
are document-global, but each single rewrite is node-local. So two passes are
enough: one pass collects the answers, the second pass stamps them in. cob never
builds a full DOM. This keeps the pass light.

One wrinkle drives the shape of the code. \code{lol_html} fires a handler on the
*start* tag. So cob computes a figure's number when the figure opens, then hands
that number to the caption handler through a one-slot cell. The number must land
on the caption element, because CSS \code{attr()} cannot read an ancestor's attribute
(§7).

## The two-pass discipline {#sec:poyA}

Two passes run over identical bytes. The first pass, \code{scan}, collects what the
numbering and the cross-referencing must know about the whole document: the
headings, the figure and table and equation labels in document order, their kind,
and each \code{data-ref} site. It changes nothing. The resolver (§7) turns that into
the global tables. The second pass, \code{apply}, walks each section a second time and
stamps the results.

Both passes walk the same input in the same order. So the counters and the
per-site indices stay in lockstep. That agreement is what lets \code{apply} avoid a
re-derivation of anything.

## Identity is an attribute, never text {#sec:SAwZ}

Identity lands in a \code{data-id} attribute — the frozen opaque id of §7.1 — never in
a text node. The stylesheet draws the kind-and-id label from that attribute. Only
the cross-reference link text is real text, because a link with no text is no link
at all.

This rule is a contract with the annotation layer (§9.2). Nothing decorative is a
text node. So a quote selector over the prose sees the final words, not a number
that shifts each time an earlier figure is added. A renumber changes the generated
reference *text* but never an element id, so a quote selector on the nearby prose
still holds.

## The annotation contract (§9) {#sec:9p9p}

Commenting is not cob's job. It belongs to a separate tool, specced in
\code{ANNOTATIONS.md}. What cob owes that tool is HTML it can anchor to, plus room in
the layout to render. cob meets three obligations.

First, provenance. Every rendered section element carries its identity and its
source coordinates, so an annotation on the woven page maps back to the \code{.cob}
source that a review agent must patch:

```verbatim \lang{html}
<section class="code" id="sec-4" data-nw-file="parser.cob" data-nw-line="47"
         data-chunk="lex a token">…</section>
```

Second, stable anchors. A section id and a chunk slug come from \code{markup}'s chunk
numbering and chunk names, never from the layout or the page assignment. So they
survive a re-weave. KaTeX renders server-side (§6.3), so the text a selector sees
is final at page load.

Third, margin room. Every section renders an empty margin slot that an annotation
overlay may mount into. \code{cob.toml} can also inject an embed snippet into every
page, so a hosted annotator needs no code change. The archival site stays fully
readable with the overlay absent — annotation is progressive enhancement by
construction.

## How the code implements this {#sec:G7pc}

The module is the error and kind types, the anchor and slug helpers, the scan's
input and state types, the rewriter runner, the two passes, and the plan cursor
between them.
<<src/rewrite.rs>>=
<<the module banner>>

<<imports>>

<<the handler type>>

<<the rewrite error>>

<<reference kinds>>

<<anchors and slugs>>

<<the scan outputs>>

<<the scan state>>

<<run the rewriter>>

<<pass 1: scan>>

<<a resolved ref>>

<<the plan cursor>>

<<pass 2: apply>>

<<strip the macros islands>>

<<the tests>>
@
The banner states the two-pass discipline and the attribute-not-text rule.
<<the module banner>>=
//! Steps 3–5 of the prose pipeline (§6.2): parse the (now math-free)
//! prose, rewrite it, serialize.
//!
//! Two passes over identical bytes. `scan` collects what numbering and
//! cross-referencing need to know about the *whole* document; `apply` rewrites
//! each section once the answers exist. Both walk the same input in the same
//! order, so the counters and the per-site indices they keep stay in lockstep —
//! that agreement is what lets `apply` avoid re-deriving anything.
//!
//! Identity lands in a `data-id` attribute (the frozen opaque id of §7.1), never
//! in a text node; the stylesheet draws "Figure <id>" from it. Only
//! cross-reference *link text* is generated as real text, because a link with no
//! text is no link at all. §9.2 explains why the distinction matters to the
//! annotation layer.
@
Standard library plus lol_html, the streaming HTML rewriter both passes drive.
<<imports>>=
use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fmt;
use std::rc::Rc;

use lol_html::html_content::ContentType;
use lol_html::{element, text, ElementContentHandlers, HtmlRewriter, Selector, Settings};
@
A \code{Handler} pairs a selector with its content handlers — the unit both passes
assemble into lol_html settings.
<<the handler type>>=
type Handler<'h, 's> = (Cow<'s, Selector>, ElementContentHandlers<'h>);
@
Any rewrite failure is E026, wrapping lol_html's own message.
<<the rewrite error>>=
#[derive(Debug)]
pub struct RewriteError(String);

impl fmt::Display for RewriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error[E026]: rewriting prose: {}", self.0)
    }
}

impl std::error::Error for RewriteError {}
@
\code{Kind} is a reference namespace. It maps to a display word, a lowercase
\code{site.json} name, and — going the other way — from a label's prefix. An id with no
known prefix is simply not a target.
<<reference kinds>>=
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Figure,
    Table,
    Equation,
    Algorithm,
    Section,
    Chunk,
    Macro,
    Citation,
}

impl Kind {
    pub fn word(self) -> &'static str {
        match self {
            Kind::Figure => "Figure",
            Kind::Table => "Table",
            Kind::Equation => "Equation",
            Kind::Algorithm => "Algorithm",
            Kind::Section => "Section",
            Kind::Chunk => "Chunk",
            Kind::Macro => "Notation",
            Kind::Citation => "Citation",
        }
    }

    /// Lower-case name used in `site.json`'s `labels` table (§8).
    pub fn json_name(self) -> &'static str {
        match self {
            Kind::Figure => "figure",
            Kind::Table => "table",
            Kind::Equation => "equation",
            Kind::Algorithm => "algorithm",
            Kind::Section => "section",
            Kind::Chunk => "chunk",
            Kind::Macro => "macro",
            Kind::Citation => "citation",
        }
    }

    /// §7's namespaces. An id without a known prefix is simply not a target.
    pub fn from_label(id: &str) -> Option<Kind> {
        match id.split_once(':')?.0 {
            "fig" => Some(Kind::Figure),
            "tbl" => Some(Kind::Table),
            "eq" => Some(Kind::Equation),
            "alg" => Some(Kind::Algorithm),
            "sec" => Some(Kind::Section),
            "chunk" => Some(Kind::Chunk),
            "def" => Some(Kind::Macro),
            "cite" => Some(Kind::Citation),
            _ => None,
        }
    }

    /// Is a heading with this id a referenceable node (§10)? Every namespaced
    /// heading is — `sec:`, `def:`, `thm:`, `ex:`, `prob:`, and any other — so
    /// a typed node is reachable by its own page and `\ref`. A float, chunk, or
    /// citation namespace is not a heading, so it is excluded. The taxon, not the
    /// namespace, names the kind (the `def:` prefix also tags a notation fence).
    /// Is a label one a page heading (an h1) may carry (§7)? Only `ch:` and
    /// `part:`. An h1 is a page, not a node, so these labels make it a `\ref`
    /// target and nothing more. Any other label on an h1 (a `sec:` one, say) means
    /// nothing, as it always did, so an existing document is not changed by this.
    pub fn label_is_page_heading(id: &str) -> bool {
        matches!(id.split_once(':').map(|(ns, _)| ns), Some("ch" | "part"))
    }

    pub fn label_is_heading_node(id: &str) -> bool {
        id.contains(':')
            && !matches!(
                Kind::from_label(id),
                Some(Kind::Figure | Kind::Table | Kind::Equation | Kind::Algorithm | Kind::Chunk | Kind::Citation)
            )
    }
}
@
A label's rendered anchor swaps the colon for a dash, because a colon is legal in
an HTML id but needs escaping in every CSS selector. The slug helper lowercases
and dash-joins arbitrary text for use in an anchor or filename.
<<anchors and slugs>>=
/// `fig:pipeline` → `fig-pipeline`. Colons are legal in HTML ids but need
/// escaping in every CSS selector that touches them, so the rendered anchor
/// uses a dash and §8's `labels` table records it.
pub fn anchor_of(label: &str) -> String {
    label.replace(':', "-")
}

/// The empty node-page link stamped on a node in context (§10): an `<a>` to
/// `n/<id>.html`, drawn by CSS as the ⧉ glyph. It carries no text node, so
/// copy-paste and the annotation quote selectors survive (§5.4).
pub fn node_link(uid: &str) -> String {
    format!("<a class=\"node-link\" href=\"n/{uid}.html\" aria-label=\"node page\"></a>")
}

pub fn slug(s: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !out.is_empty() && !dash {
            out.push('-');
            dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}
@
The scan's outputs. A \code{Heading} records its section, level, text, and any
author-given id. A \code{LabelDef} is one labelled float. A \code{RefSite} is one
cross-reference, noting whether the author wrote link text. \code{Scan} accumulates all
three across the document, plus each section's opening tag and the sections whose
floats never got a caption.
<<the scan outputs>>=
#[derive(Debug, Clone)]
pub struct Heading {
    pub section: usize,
    pub level: u8,
    pub text: String,
    /// Author-supplied `id`, if any; otherwise assigned from the text later.
    pub given_id: Option<String>,
    /// The `data-taxon` the heading carries (§10), if any. It names the typed
    /// node — "definition", "theorem" — and so the word a `\ref` to it reads.
    pub taxon: Option<String>,
}

#[derive(Debug, Clone)]
pub struct LabelDef {
    /// The author's note-local human label (e.g. `fig:pipeline`).
    pub id: String,
    pub kind: Kind,
    pub section: usize,
    /// The taxon of a `node` fence (§10), which names the word a `\ref` to it reads
    /// ("Definition"). `None` for a float or a `macros` node.
    pub taxon: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RefSite {
    pub target: String,
    /// The author wrote link text; §7 says preserve it.
    pub has_text: bool,
    pub section: usize,
}

#[derive(Debug, Default)]
pub struct Scan {
    pub headings: Vec<Heading>,
    pub labels: Vec<LabelDef>,
    pub refs: Vec<RefSite>,
    /// Per docs section: the tag the fragment opens with, if any.
    pub first_tag: Vec<Option<String>>,
    /// Figures and tables that never got a caption (§7 requires one).
    pub uncaptioned: Vec<usize>,
}
@
\code{ScanState} is the per-section working state. Headings and refs accumulate
incrementally — text arrives in pieces across nested tags — so each is flushed
lazily when the next one starts or the section ends, which keeps the walk off
lol_html's end-tag handlers.
<<the scan state>>=
#[derive(Default)]
struct ScanState {
    first_tag: Option<String>,
    headings: Vec<Heading>,
    labels: Vec<LabelDef>,
    refs: Vec<RefSite>,
    uncaptioned: usize,
    /// Heading being accumulated: (level, given id, taxon, text so far).
    heading: Option<(u8, Option<String>, Option<String>, String)>,
    /// Ref site being accumulated: (target, saw text).
    reference: Option<(String, bool)>,
}

impl ScanState {
    fn flush_heading(&mut self, section: usize) {
        if let Some((level, given_id, taxon, text)) = self.heading.take() {
            self.headings.push(Heading {
                section,
                level,
                text: text.trim().to_string(),
                given_id,
                taxon,
            });
        }
    }

    fn flush_ref(&mut self, section: usize) {
        if let Some((target, has_text)) = self.reference.take() {
            self.refs.push(RefSite {
                target,
                has_text,
                section,
            });
        }
    }
}
@
Both passes funnel through one runner: fold the handlers into settings, stream the
bytes through lol_html, and return the serialized result.
<<run the rewriter>>=
fn run(html: &str, handlers: Vec<Handler>) -> Result<String, RewriteError> {
    let settings = handlers
        .into_iter()
        .fold(Settings::new(), |s, h| s.append_element_content_handler(h));
    let mut out = Vec::new();
    let mut rw = HtmlRewriter::new(settings, |c: &[u8]| out.extend_from_slice(c));
    rw.write(html.as_bytes())
        .map_err(|e| RewriteError(e.to_string()))?;
    rw.end().map_err(|e| RewriteError(e.to_string()))?;
    String::from_utf8(out).map_err(|e| RewriteError(e.to_string()))
}
@
Pass 1 walks a section and records its structure: the first tag (a page-boundary
signal), every heading, every labelled float, every ref site, and a caption tally
so uncaptioned floats surface. It mints no ids — that happens later — so it keeps
no counter. Results append to the document-wide \code{Scan}.
<<pass 1: scan>>=
/// Pass 1. Accumulates into `out` across sections. Records every labelled
/// figure/table/equation so weave can mint/resolve its opaque id (§7.1); the id
/// itself is assigned later, so this pass keeps no counter.
pub fn scan(html: &str, section: usize, out: &mut Scan) -> Result<(), RewriteError> {
    let st = Rc::new(RefCell::new(ScanState::default()));
    // Headings and refs are flushed lazily — when the next one starts, or at
    // the end of the section — which keeps us off lol_html's end-tag handlers.
    {
        let handlers: Vec<Handler> = vec![
                element!("*", {
                    let st = st.clone();
                    move |el| {
                        let mut st = st.borrow_mut();
                        if st.first_tag.is_none() {
                            st.first_tag = Some(el.tag_name());
                        }
                        Ok(())
                    }
                }),
                element!("h1,h2,h3", {
                    let st = st.clone();
                    move |el| {
                        let mut st = st.borrow_mut();
                        st.flush_heading(section);
                        let level = el.tag_name().as_bytes()[1] - b'0';
                        st.heading = Some((
                            level,
                            el.get_attribute("id"),
                            el.get_attribute("data-taxon"),
                            String::new(),
                        ));
                        Ok(())
                    }
                }),
                text!("h1,h2,h3", {
                    let st = st.clone();
                    move |t| {
                        if let Some(h) = st.borrow_mut().heading.as_mut() {
                            h.3.push_str(t.as_str());
                        }
                        Ok(())
                    }
                }),
                element!("figure,table", {
                    let st = st.clone();
                    move |el| {
                        let kind = if el.tag_name() == "figure" {
                            // An `algorithm` fence is a `<figure class="algorithm">`
                            // (§6.5), a distinct float kind from an ordinary figure.
                            if el.get_attribute("class").as_deref() == Some("algorithm") {
                                Kind::Algorithm
                            } else {
                                Kind::Figure
                            }
                        } else {
                            Kind::Table
                        };
                        let mut st = st.borrow_mut();
                        st.uncaptioned += 1;
                        if let Some(id) = el.get_attribute("id") {
                            if Kind::from_label(&id) == Some(kind) {
                                st.labels.push(LabelDef { id, kind, section, taxon: None });
                            }
                        }
                        Ok(())
                    }
                }),
                element!("figcaption,caption", {
                    let st = st.clone();
                    move |_| {
                        st.borrow_mut().uncaptioned -= 1;
                        Ok(())
                    }
                }),
                element!(".equation", {
                    let st = st.clone();
                    move |el| {
                        if el.has_attribute("data-nonumber") {
                            return Ok(());
                        }
                        if let Some(id) = el.get_attribute("id") {
                            if Kind::from_label(&id) == Some(Kind::Equation) {
                                st.borrow_mut().labels.push(LabelDef {
                                    id,
                                    kind: Kind::Equation,
                                    section,
                                    taxon: None,
                                });
                            }
                        }
                        Ok(())
                    }
                }),
                element!(".macros", {
                    let st = st.clone();
                    move |el| {
                        // A `macros` exposition is a `def:` node (§10). Record it so
                        // weave mints its opaque id, the same as a float.
                        if let Some(id) = el.get_attribute("id") {
                            if Kind::from_label(&id) == Some(Kind::Macro) {
                                st.borrow_mut().labels.push(LabelDef {
                                    id,
                                    kind: Kind::Macro,
                                    section,
                                    taxon: None,
                                });
                            }
                        }
                        Ok(())
                    }
                }),
                element!("section.taxon-node", {
                    let st = st.clone();
                    move |el| {
                        // A `node` fence (§10) is a labelled typed node. Record it
                        // like a float so weave mints its opaque id, with its taxon
                        // so a `\ref` to it reads "Definition <id>". Its kind is
                        // Section whatever its namespace: `def:` also tags a
                        // notation fence, but this element is a normal in-flow node.
                        // An unlabelled node has no id and so no identity.
                        if let Some(id) = el.get_attribute("id") {
                            st.borrow_mut().labels.push(LabelDef {
                                id,
                                kind: Kind::Section,
                                section,
                                taxon: el.get_attribute("data-taxon"),
                            });
                        }
                        Ok(())
                    }
                }),
                element!("cob-custom", {
                    let st = st.clone();
                    move |el| {
                        // §6.6 In the mint pass a `custom` fence is still a
                        // `<cob-custom>` placeholder (the handler has not run). If
                        // its `data-label` is a float namespace, record it so `cob
                        // lock` mints the id without the tool; at weave the handler
                        // emits the real element and the id is already frozen.
                        if let Some(id) = el.get_attribute("data-label") {
                            if let Some(kind) = Kind::from_label(&id) {
                                st.borrow_mut().labels.push(LabelDef { id, kind, section, taxon: None });
                            }
                        }
                        Ok(())
                    }
                }),
                element!("a[data-ref]", {
                    let st = st.clone();
                    move |el| {
                        let mut st = st.borrow_mut();
                        st.flush_ref(section);
                        st.reference = Some((el.get_attribute("data-ref").unwrap_or_default(), false));
                        Ok(())
                    }
                }),
                text!("a[data-ref]", {
                    let st = st.clone();
                    move |t| {
                        if !t.as_str().trim().is_empty() {
                            if let Some(r) = st.borrow_mut().reference.as_mut() {
                                r.1 = true;
                            }
                        }
                        Ok(())
                    }
                }),
        ];
        run(html, handlers)?;
    }

    let mut st = st.borrow_mut();
    st.flush_heading(section);
    st.flush_ref(section);
    out.first_tag.push(st.first_tag.take());
    if st.uncaptioned > 0 {
        out.uncaptioned.push(section);
    }
    out.headings.append(&mut st.headings);
    out.labels.append(&mut st.labels);
    out.refs.append(&mut st.refs);
    Ok(())
}
@
A \code{ResolvedRef} is what pass 1 concluded about one ref site: the href and, unless
the author supplied their own, the link text to fill in.
<<a resolved ref>>=
/// What pass 1 concluded about one `data-ref` site, in document order.
#[derive(Debug, Clone)]
pub struct ResolvedRef {
    pub href: String,
    /// `None` when the author supplied their own link text.
    pub text: Option<String>,
}
@
\code{Plan} is the cursor carried across \code{apply} calls so the per-site heading and ref
indices keep advancing section to section. It holds the resolved anchors, the
section opaque ids, the resolved refs, and the float id map.
<<the plan cursor>>=
/// Cursor shared across `apply` calls so per-site indices keep advancing.
pub struct Plan<'a> {
    pub heading_anchors: &'a [String],
    /// Parallel to `heading_anchors`: a `sec:`-labelled heading's frozen opaque
    /// id (§7.1), stamped as a clickable permalink prefix; `None` otherwise.
    pub heading_uids: &'a [Option<String>],
    pub refs: &'a [ResolvedRef],
    /// Human label → frozen opaque id (§7.1), for the floats being stamped.
    pub label_ids: &'a BTreeMap<String, String>,
    heading: usize,
    reference: usize,
}

impl<'a> Plan<'a> {
    pub fn new(
        heading_anchors: &'a [String],
        heading_uids: &'a [Option<String>],
        refs: &'a [ResolvedRef],
        label_ids: &'a BTreeMap<String, String>,
    ) -> Self {
        Plan {
            heading_anchors,
            heading_uids,
            refs,
            label_ids,
            heading: 0,
            reference: 0,
        }
    }
}
@
Pass 2 rewrites one section against the plan: it stamps heading anchors (and a
clickable permalink prefix on a labelled section), sets a float's \code{data-id} and
carries it to the caption where CSS can draw the label, and fills each ref's href
and generated text. The float id rides the caption because CSS \code{attr()} reads only
an element's own attributes. The plan's cursors are written back so the next
section continues where this one left off.
<<pass 2: apply>>=
/// Pass 2.
pub fn apply(html: &str, plan: &mut Plan) -> Result<String, RewriteError> {
    let heading_idx = RefCell::new(plan.heading);
    let ref_idx = RefCell::new(plan.reference);
    let heading_anchors = plan.heading_anchors;
    let heading_uids = plan.heading_uids;
    let refs = plan.refs;
    let label_ids = plan.label_ids;
    // The id a figure/table just took, so its caption — the next element — can
    // carry it. CSS `attr()` reads only the element's own attributes, so the
    // rendered "Figure <id>" label has to live on the caption, not the container.
    let pending_fig: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    let pending_tbl: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    // The (opaque id, anchor) a `node` fence just took, for its title paragraph.
    let pending_node: Rc<RefCell<Option<(String, String)>>> = Rc::new(RefCell::new(None));

    // The opaque id for a float, keyed by its human label, when one was minted.
    let id_of = |el: &lol_html::html_content::Element| -> Option<String> {
        let label = el.get_attribute("id")?;
        (Kind::from_label(&label).is_some())
            .then(|| label_ids.get(&label).cloned())
            .flatten()
    };

    let handlers: Vec<Handler> = vec![
            element!("h1,h2,h3", |el| {
                let mut i = heading_idx.borrow_mut();
                if let Some(anchor) = heading_anchors.get(*i) {
                    el.set_attribute("id", anchor).ok();
                    if let Some(Some(uid)) = heading_uids.get(*i) {
                        // Two empty anchors, drawn by CSS (no text node, so
                        // copy-paste and quote selectors survive, §5.4): a
                        // permalink to this section, and a link to the node's own
                        // page at `n/<id>.html` (§10 node pages).
                        let tag = format!(
                            "<a class=\"sec-uid\" href=\"#{anchor}\" data-id=\"{uid}\"></a>{}",
                            node_link(uid)
                        );
                        el.prepend(&tag, ContentType::Html);
                    }
                }
                *i += 1;
                Ok(())
            }),
            element!("figure,table", {
                let pending_fig = pending_fig.clone();
                let pending_tbl = pending_tbl.clone();
                move |el| {
                let is_fig = el.tag_name() == "figure";
                let id = id_of(el);
                if let Some(opaque) = &id {
                    el.set_attribute("data-id", opaque).ok();
                }
                if is_fig {
                    *pending_fig.borrow_mut() = id;
                } else {
                    *pending_tbl.borrow_mut() = id;
                }
                if let Some(label) = el.get_attribute("id") {
                    if Kind::from_label(&label).is_some() {
                        el.set_attribute("id", &anchor_of(&label)).ok();
                    }
                }
                Ok(())
            }}),
            element!("figcaption", {
                let pending_fig = pending_fig.clone();
                move |el| {
                    if let Some(opaque) = pending_fig.borrow_mut().take() {
                        el.set_attribute("data-id", &opaque).ok();
                        // A link to the float's own node page (§10), drawn by CSS.
                        el.append(&node_link(&opaque), ContentType::Html);
                    }
                    Ok(())
                }
            }),
            element!("caption", {
                let pending_tbl = pending_tbl.clone();
                move |el| {
                    if let Some(opaque) = pending_tbl.borrow_mut().take() {
                        el.set_attribute("data-id", &opaque).ok();
                        el.append(&node_link(&opaque), ContentType::Html);
                    }
                    Ok(())
                }
            }),
            element!(".equation", move |el| {
                if el.has_attribute("data-nonumber") {
                    return Ok(());
                }
                if let Some(opaque) = id_of(el) {
                    el.set_attribute("data-id", &opaque).ok();
                    // An equation has no caption, so its node link rides the
                    // block itself; CSS places it at the left margin (§10).
                    el.prepend(&node_link(&opaque), ContentType::Html);
                }
                if let Some(label) = el.get_attribute("id") {
                    if Kind::from_label(&label).is_some() {
                        el.set_attribute("id", &anchor_of(&label)).ok();
                    }
                }
                Ok(())
            }),
            element!(".macros", move |el| {
                // A `def:` node (§10). Stamp its opaque id and rewrite the colon
                // anchor, the same as a float. It carries no node link, because it
                // is homeless: the weaver removes it from the flow after cutting it.
                if let Some(opaque) = id_of(el) {
                    el.set_attribute("data-id", &opaque).ok();
                }
                if let Some(label) = el.get_attribute("id") {
                    if Kind::from_label(&label).is_some() {
                        el.set_attribute("id", &anchor_of(&label)).ok();
                    }
                }
                Ok(())
            }),
            element!("section.taxon-node", {
                let pending_node = pending_node.clone();
                move |el| {
                    // A `node` fence (§10). A labelled one takes its opaque id and its
                    // colon-free anchor, like a float. The id and anchor wait in a
                    // one-slot cell for the title paragraph, its first child, which
                    // carries the permalink and node link: CSS `attr()` reads only an
                    // element's own attributes, the same wrinkle as a figure caption.
                    if let Some(label) = el.get_attribute("id") {
                        let anchor = anchor_of(&label);
                        if let Some(opaque) = label_ids.get(&label) {
                            el.set_attribute("data-id", opaque).ok();
                            *pending_node.borrow_mut() = Some((opaque.clone(), anchor.clone()));
                        }
                        el.set_attribute("id", &anchor).ok();
                    }
                    Ok(())
                }
            }),
            element!("p.node-title", {
                let pending_node = pending_node.clone();
                move |el| {
                    if let Some((opaque, anchor)) = pending_node.borrow_mut().take() {
                        let tag = format!(
                            "<a class=\"sec-uid\" href=\"#{anchor}\" data-id=\"{opaque}\"></a>{}",
                            node_link(&opaque)
                        );
                        el.prepend(&tag, ContentType::Html);
                    }
                    Ok(())
                }
            }),
            element!("a[data-ref]", |el| {
                let mut i = ref_idx.borrow_mut();
                if let Some(r) = refs.get(*i) {
                    el.set_attribute("href", &r.href).ok();
                    if let Some(text) = &r.text {
                        el.set_inner_content(text, ContentType::Text);
                    }
                }
                *i += 1;
                Ok(())
            }),
    ];
    let out = run(html, handlers)?;
    plan.heading = heading_idx.into_inner();
    plan.reference = ref_idx.into_inner();
    Ok(out)
}
@
A \code{def:} node is homeless (§10): once the node table cuts its \code{macros} island,
the weaver drops the island from the reading flow, so the exposition shows only on
its own page and where it is transcluded. \code{strip_macros} removes every canonical
\code{.macros} island from a body. The weaver runs it before the transclusion pass, so
no transcluded copy exists yet — every island it sees is canonical.
<<strip the macros islands>>=
pub fn strip_macros(html: &str) -> Result<String, RewriteError> {
    run(html, vec![element!(".macros", |el| {
        el.remove();
        Ok(())
    })])
}
@
The tests pin both passes: slugging, what scan collects (headings, first tag,
labels in order, numbered vs unnumbered equations, ref text, uncaptioned floats),
and what apply stamps (ids into attributes not text, unlabelled floats left alone,
refs filled while author text is kept, heading anchors in order, a clickable
section uid, and author markup outside the handlers left untouched).
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    <<scan one fragment>>

    <<slugs are url-safe and trimmed>>

    <<scan collects headings>>

    <<the first tag marks a page boundary>>

    <<scan collects labels in order>>

    <<numbered and unnumbered equations>>

    <<ref sites record author text>>

    <<uncaptioned figures are reported>>

    <<a label-to-id map for apply>>

    <<apply stamps ids into attributes>>

    <<apply leaves an unlabelled float alone>>

    <<apply fills refs and keeps author text>>

    <<apply assigns heading anchors in order>>

    <<apply prepends a clickable section uid>>

    <<author markup outside handlers is untouched>>
}
@
A one-shot scan of a single fragment.
<<scan one fragment>>=
fn scan_one(html: &str) -> Scan {
    let mut s = Scan::default();
    scan(html, 0, &mut s).unwrap();
    s
}
@
Slugs lowercase, dash-join, trim, and drop non-alphanumerics.
<<slugs are url-safe and trimmed>>=
#[test]
fn slugs_are_url_safe_and_trimmed() {
    assert_eq!(slug("Front matter"), "front-matter");
    assert_eq!(slug("  A/B testing! "), "a-b-testing");
    assert_eq!(slug("Ünïcode"), "n-code");
}
@
Headings carry their level, trimmed text (including nested-element text), and any
author id.
<<scan collects headings>>=
#[test]
fn scan_collects_headings_with_text_and_level() {
    let s = scan_one("<h1>Parsing</h1><p>x</p><h2 id=\"sec:lex\">Lex<em>ing</em></h2>");
    assert_eq!(s.headings.len(), 2);
    assert_eq!((s.headings[0].level, s.headings[0].text.as_str()), (1, "Parsing"));
    assert_eq!(s.headings[0].given_id, None);
    // Text from nested elements is part of the heading.
    assert_eq!((s.headings[1].level, s.headings[1].text.as_str()), (2, "Lexing"));
    assert_eq!(s.headings[1].given_id.as_deref(), Some("sec:lex"));
}
@
The first tag is the opening element, so an h1 marks a page boundary but a buried
h1 does not.
<<the first tag marks a page boundary>>=
#[test]
fn first_tag_identifies_a_page_boundary() {
    let s = scan_one("<h1>Parsing</h1><p>x</p>");
    assert_eq!(s.first_tag[0].as_deref(), Some("h1"));
    let s = scan_one("<p>x</p><h1>Buried</h1>");
    assert_eq!(s.first_tag[0].as_deref(), Some("p"));
}
@
Labels accumulate in document order across sections, each tagged with its section.
<<scan collects labels in order>>=
#[test]
fn scan_collects_labels_in_document_order() {
    let mut s = Scan::default();
    scan("<figure id=\"fig:a\"><figcaption>A</figcaption></figure>", 0, &mut s).unwrap();
    scan("<table id=\"tbl:t\"><caption>T</caption></table>\
          <figure id=\"fig:b\"><figcaption>B</figcaption></figure>", 1, &mut s).unwrap();
    let got: Vec<(&str, Kind)> = s.labels.iter().map(|l| (l.id.as_str(), l.kind)).collect();
    assert_eq!(
        got,
        vec![("fig:a", Kind::Figure), ("tbl:t", Kind::Table), ("fig:b", Kind::Figure)]
    );
    // The second figure was collected on a later section.
    assert_eq!(s.labels[2].section, 1);
}
@
An equation marked \code{data-nonumber} is not labelled; a labelled one is.
<<numbered and unnumbered equations>>=
#[test]
fn nonumber_equations_are_not_labelled_but_labelled_ones_are() {
    let s = scan_one(
        "<div class=\"equation\" data-nonumber>a</div>\
         <div class=\"equation\" id=\"eq:one\">b</div>",
    );
    assert_eq!(s.labels.len(), 1);
    assert_eq!((s.labels[0].id.as_str(), s.labels[0].kind), ("eq:one", Kind::Equation));
}
@
A ref site records whether the author wrote link text.
<<ref sites record author text>>=
#[test]
fn ref_sites_record_whether_the_author_wrote_text() {
    let s = scan_one(
        "<a data-ref=\"fig:a\"></a> and <a data-ref=\"eq:c\">the bound</a>",
    );
    let got: Vec<(&str, bool)> = s.refs.iter().map(|r| (r.target.as_str(), r.has_text)).collect();
    assert_eq!(got, vec![("fig:a", false), ("eq:c", true)]);
}
@
A float with no caption is reported; a captioned one is not.
<<uncaptioned figures are reported>>=
#[test]
fn uncaptioned_figures_are_reported() {
    let s = scan_one("<figure id=\"fig:a\"><img src=\"x\"></figure>");
    assert_eq!(s.uncaptioned, vec![0]);
    let s = scan_one("<figure><figcaption>ok</figcaption></figure>");
    assert!(s.uncaptioned.is_empty());
}
@
A small helper to build the label-to-id map apply needs.
<<a label-to-id map for apply>>=
/// Build a `label → opaque id` map from `(label, id)` pairs for `apply`.
fn ids(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(l, i)| (l.to_string(), i.to_string())).collect()
}
@
apply stamps the opaque id onto the float and its caption as attributes, and never
as text.
<<apply stamps ids into attributes>>=
#[test]
fn apply_stamps_ids_into_attributes_never_text() {
    let anchors: Vec<String> = vec![];
    let refs: Vec<ResolvedRef> = vec![];
    let label_ids = ids(&[("fig:pipeline", "k3f9")]);
    let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
    let out = apply(
        "<figure id=\"fig:pipeline\"><figcaption>The pipeline.</figcaption></figure>",
        &mut plan,
    )
    .unwrap();
    assert!(out.contains("id=\"fig-pipeline\" data-id=\"k3f9\""));
    // The id rides on the caption so CSS can draw "Figure k3f9" there; the
    // caption *text* is untouched, and an empty node-page link (§10) follows it.
    assert!(out.contains(
        "<figcaption data-id=\"k3f9\">The pipeline.\
         <a class=\"node-link\" href=\"n/k3f9.html\" aria-label=\"node page\"></a></figcaption>"
    ));
    assert!(!out.contains("Figure k3f9"));
}
@
An unlabelled float gets no id.
<<apply leaves an unlabelled float alone>>=
#[test]
fn apply_leaves_an_unlabelled_float_without_an_id() {
    let anchors: Vec<String> = vec![];
    let refs: Vec<ResolvedRef> = vec![];
    let label_ids = BTreeMap::new();
    let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
    let out = apply("<figure><figcaption>Anon.</figcaption></figure>", &mut plan).unwrap();
    assert!(!out.contains("data-id"));
}
@
apply fills an empty ref's href and text, and leaves an author-written ref's text.
<<apply fills refs and keeps author text>>=
#[test]
fn apply_fills_empty_refs_and_preserves_author_text() {
    let anchors: Vec<String> = vec![];
    let refs = vec![
        ResolvedRef { href: "#fig-a".into(), text: Some("Figure k3f9".into()) },
        ResolvedRef { href: "parsing.html#eq-c".into(), text: None },
    ];
    let label_ids = BTreeMap::new();
    let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
    let out = apply(
        "<a data-ref=\"fig:a\"></a><a data-ref=\"eq:c\">the bound</a>",
        &mut plan,
    )
    .unwrap();
    assert!(out.contains("href=\"#fig-a\""));
    assert!(out.contains(">Figure k3f9</a>"));
    assert!(out.contains("href=\"parsing.html#eq-c\""));
    assert!(out.contains(">the bound</a>"));
}
@
Heading anchors are assigned in scan order.
<<apply assigns heading anchors in order>>=
#[test]
fn apply_assigns_heading_anchors_in_order() {
    let anchors = vec!["parsing".to_string(), "lexing".to_string()];
    let refs: Vec<ResolvedRef> = vec![];
    let label_ids = BTreeMap::new();
    let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
    let out = apply("<h1>Parsing</h1><h2>Lexing</h2>", &mut plan).unwrap();
    assert!(out.contains("<h1 id=\"parsing\">"));
    assert!(out.contains("<h2 id=\"lexing\">"));
}
@
A labelled section gets a clickable permalink prefix carrying its opaque id, and
the id never appears as text.
<<apply prepends a clickable section uid>>=
#[test]
fn apply_prepends_a_clickable_uid_to_a_labelled_section() {
    let anchors = vec!["parsing".to_string(), "sec-lexing".to_string()];
    let uids = vec![None, Some("k3f9".to_string())];
    let refs: Vec<ResolvedRef> = vec![];
    let label_ids = BTreeMap::new();
    let mut plan = Plan::new(&anchors, &uids, &refs, &label_ids);
    let out = apply("<h1>Parsing</h1><h2>Lexing</h2>", &mut plan).unwrap();
    assert!(out.contains("<h1 id=\"parsing\">Parsing</h1>"));
    assert!(out.contains(
        "<h2 id=\"sec-lexing\"><a class=\"sec-uid\" href=\"#sec-lexing\" data-id=\"k3f9\"></a>\
         <a class=\"node-link\" href=\"n/k3f9.html\" aria-label=\"node page\"></a>Lexing</h2>"
    ));
    assert!(!out.contains(">k3f9<"));
}
@
Markup the handlers do not select passes through byte-for-byte.
<<author markup outside handlers is untouched>>=
#[test]
fn author_markup_outside_handlers_is_untouched() {
    let anchors: Vec<String> = vec![];
    let refs: Vec<ResolvedRef> = vec![];
    let label_ids = BTreeMap::new();
    let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
    let src = "<p class='x'>a &amp; b <br> <span data-cob-math=\"0\"></span></p>";
    assert_eq!(apply(src, &mut plan).unwrap(), src);
}
@
