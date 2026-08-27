//! Steps 3–5 of the prose pipeline (SPEC.md §6.2): parse the (now math-free)
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

use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fmt;
use std::rc::Rc;

use lol_html::html_content::ContentType;
use lol_html::{element, text, ElementContentHandlers, HtmlRewriter, Selector, Settings};

type Handler<'h, 's> = (Cow<'s, Selector>, ElementContentHandlers<'h>);

#[derive(Debug)]
pub struct RewriteError(String);

impl fmt::Display for RewriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error[E026]: rewriting prose: {}", self.0)
    }
}

impl std::error::Error for RewriteError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Figure,
    Table,
    Equation,
    Section,
    Chunk,
}

impl Kind {
    pub fn word(self) -> &'static str {
        match self {
            Kind::Figure => "Figure",
            Kind::Table => "Table",
            Kind::Equation => "Equation",
            Kind::Section => "Section",
            Kind::Chunk => "Chunk",
        }
    }

    /// Lower-case name used in `site.json`'s `labels` table (§8).
    pub fn json_name(self) -> &'static str {
        match self {
            Kind::Figure => "figure",
            Kind::Table => "table",
            Kind::Equation => "equation",
            Kind::Section => "section",
            Kind::Chunk => "chunk",
        }
    }

    /// §7's namespaces. An id without a known prefix is simply not a target.
    pub fn from_label(id: &str) -> Option<Kind> {
        match id.split_once(':')?.0 {
            "fig" => Some(Kind::Figure),
            "tbl" => Some(Kind::Table),
            "eq" => Some(Kind::Equation),
            "sec" => Some(Kind::Section),
            "chunk" => Some(Kind::Chunk),
            _ => None,
        }
    }
}

/// `fig:pipeline` → `fig-pipeline`. Colons are legal in HTML ids but need
/// escaping in every CSS selector that touches them, so the rendered anchor
/// uses a dash and §8's `labels` table records it.
pub fn anchor_of(label: &str) -> String {
    label.replace(':', "-")
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

#[derive(Debug, Clone)]
pub struct Heading {
    pub section: usize,
    pub level: u8,
    pub text: String,
    /// Author-supplied `id`, if any; otherwise assigned from the text later.
    pub given_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct LabelDef {
    /// The author's note-local human label (e.g. `fig:pipeline`).
    pub id: String,
    pub kind: Kind,
    pub section: usize,
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

#[derive(Default)]
struct ScanState {
    first_tag: Option<String>,
    headings: Vec<Heading>,
    labels: Vec<LabelDef>,
    refs: Vec<RefSite>,
    uncaptioned: usize,
    /// Heading being accumulated: (level, given id, text so far).
    heading: Option<(u8, Option<String>, String)>,
    /// Ref site being accumulated: (target, saw text).
    reference: Option<(String, bool)>,
}

impl ScanState {
    fn flush_heading(&mut self, section: usize) {
        if let Some((level, given_id, text)) = self.heading.take() {
            self.headings.push(Heading {
                section,
                level,
                text: text.trim().to_string(),
                given_id,
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
                        st.heading = Some((level, el.get_attribute("id"), String::new()));
                        Ok(())
                    }
                }),
                text!("h1,h2,h3", {
                    let st = st.clone();
                    move |t| {
                        if let Some(h) = st.borrow_mut().heading.as_mut() {
                            h.2.push_str(t.as_str());
                        }
                        Ok(())
                    }
                }),
                element!("figure,table", {
                    let st = st.clone();
                    move |el| {
                        let kind = if el.tag_name() == "figure" {
                            Kind::Figure
                        } else {
                            Kind::Table
                        };
                        let mut st = st.borrow_mut();
                        st.uncaptioned += 1;
                        if let Some(id) = el.get_attribute("id") {
                            if Kind::from_label(&id) == Some(kind) {
                                st.labels.push(LabelDef { id, kind, section });
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
                                });
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

/// What pass 1 concluded about one `data-ref` site, in document order.
#[derive(Debug, Clone)]
pub struct ResolvedRef {
    pub href: String,
    /// `None` when the author supplied their own link text.
    pub text: Option<String>,
}

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
                        let tag = format!(
                            "<a class=\"sec-uid\" href=\"#{anchor}\" data-id=\"{uid}\"></a>"
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
                    }
                    Ok(())
                }
            }),
            element!("caption", {
                let pending_tbl = pending_tbl.clone();
                move |el| {
                    if let Some(opaque) = pending_tbl.borrow_mut().take() {
                        el.set_attribute("data-id", &opaque).ok();
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
                }
                if let Some(label) = el.get_attribute("id") {
                    if Kind::from_label(&label).is_some() {
                        el.set_attribute("id", &anchor_of(&label)).ok();
                    }
                }
                Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_one(html: &str) -> Scan {
        let mut s = Scan::default();
        scan(html, 0, &mut s).unwrap();
        s
    }

    #[test]
    fn slugs_are_url_safe_and_trimmed() {
        assert_eq!(slug("Front matter"), "front-matter");
        assert_eq!(slug("  A/B testing! "), "a-b-testing");
        assert_eq!(slug("Ünïcode"), "n-code");
    }

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

    #[test]
    fn first_tag_identifies_a_page_boundary() {
        let s = scan_one("<h1>Parsing</h1><p>x</p>");
        assert_eq!(s.first_tag[0].as_deref(), Some("h1"));
        let s = scan_one("<p>x</p><h1>Buried</h1>");
        assert_eq!(s.first_tag[0].as_deref(), Some("p"));
    }

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

    #[test]
    fn nonumber_equations_are_not_labelled_but_labelled_ones_are() {
        let s = scan_one(
            "<div class=\"equation\" data-nonumber>a</div>\
             <div class=\"equation\" id=\"eq:one\">b</div>",
        );
        assert_eq!(s.labels.len(), 1);
        assert_eq!((s.labels[0].id.as_str(), s.labels[0].kind), ("eq:one", Kind::Equation));
    }

    #[test]
    fn ref_sites_record_whether_the_author_wrote_text() {
        let s = scan_one(
            "<a data-ref=\"fig:a\"></a> and <a data-ref=\"eq:c\">the bound</a>",
        );
        let got: Vec<(&str, bool)> = s.refs.iter().map(|r| (r.target.as_str(), r.has_text)).collect();
        assert_eq!(got, vec![("fig:a", false), ("eq:c", true)]);
    }

    #[test]
    fn uncaptioned_figures_are_reported() {
        let s = scan_one("<figure id=\"fig:a\"><img src=\"x\"></figure>");
        assert_eq!(s.uncaptioned, vec![0]);
        let s = scan_one("<figure><figcaption>ok</figcaption></figure>");
        assert!(s.uncaptioned.is_empty());
    }

    /// Build a `label → opaque id` map from `(label, id)` pairs for `apply`.
    fn ids(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(l, i)| (l.to_string(), i.to_string())).collect()
    }

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
        // caption *text* is untouched.
        assert!(out.contains("<figcaption data-id=\"k3f9\">The pipeline.</figcaption>"));
        assert!(!out.contains("Figure k3f9"));
    }

    #[test]
    fn apply_leaves_an_unlabelled_float_without_an_id() {
        let anchors: Vec<String> = vec![];
        let refs: Vec<ResolvedRef> = vec![];
        let label_ids = BTreeMap::new();
        let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
        let out = apply("<figure><figcaption>Anon.</figcaption></figure>", &mut plan).unwrap();
        assert!(!out.contains("data-id"));
    }

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
            "<h2 id=\"sec-lexing\"><a class=\"sec-uid\" href=\"#sec-lexing\" data-id=\"k3f9\"></a>Lexing</h2>"
        ));
        assert!(!out.contains(">k3f9<"));
    }

    #[test]
    fn author_markup_outside_handlers_is_untouched() {
        let anchors: Vec<String> = vec![];
        let refs: Vec<ResolvedRef> = vec![];
        let label_ids = BTreeMap::new();
        let mut plan = Plan::new(&anchors, &[], &refs, &label_ids);
        let src = "<p class='x'>a &amp; b <br> <span data-lit-math=\"0\"></span></p>";
        assert_eq!(apply(src, &mut plan).unwrap(), src);
    }
}
