//! Transclusion and the node model (§10).
//!
//! Runs in the weaver after every section is wrapped and before the page split
//! (§5.3). A section that holds no `\transclude` directive is byte-identical to
//! the canonical render, so determinism (§8) and the archival JSON are
//! untouched. A directive splices the named section's finished HTML in place,
//! with scoped ids so two copies never collide, and context chrome that links
//! back to the canonical place.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::Lint;
use crate::prose;
use crate::resolve::Resolution;
use crate::rewrite::{anchor_of, Heading, Scan};

/// The island a dialect lowers `\transclude{addr}` to (§6.4). The expander
/// matches this exact opening and tail, so its own output — a `<section
/// class="transclusion">` with chrome, or a `transclusion-missing`/`-cycle`
/// marker — is never rescanned as a placeholder.
const OPEN: &str = "<div class=\"transclusion\" data-transclude=\"";
const TAIL: &str = "\"></div>";

/// One addressable heading node: its heading text (the chrome's link text), its
/// canonical page, and the rendered HTML of the node body — the heading tag and
/// the content under it, cut at the next heading of the same or a shallower level.
struct Node {
    title: String,
    page: usize,
    body: String,
}

/// The node table plus the page filenames, built once per weave.
pub struct Context {
    /// Anchor (`sec-name`, the resolver's form) → node.
    nodes: BTreeMap<String, Node>,
    page_files: Vec<String>,
    /// One page per heading node, in document order (§10 node pages).
    node_pages: Vec<NodePage>,
    /// Anchor → document page filename, to rebase links that leave a node page.
    link_pages: BTreeMap<String, String>,
}

/// A title and an href: one breadcrumb step or one backlink.
pub struct Link {
    pub title: String,
    pub href: String,
}

/// One per-node page (§10): a heading node shown on its own at `n/<id>.html`.
pub struct NodePage {
    /// The heading's frozen opaque id (§7.1); the filename is `<id>.html`.
    pub id: String,
    pub title: String,
    /// The node body, with links rebased for the `n/` directory.
    pub body: String,
    /// The node's canonical page index; `finish_node_pages` expands with it.
    pub page: usize,
    /// A link to the node in its document page (`../page.html#anchor`).
    pub context: String,
    /// The parent headings, document `h1` first, node last-but-one.
    pub crumbs: Vec<Link>,
    /// Every node that transcludes this one.
    pub transcluded_by: Vec<Link>,
    /// Every node that refers to this one with `\ref`.
    pub referenced_by: Vec<Link>,
}

impl Context {
    /// Build the node table from the scan, the plan, and the final section
    /// bodies. A node runs from its heading to the next heading at the same or a
    /// shallower level (the heading nesting is the node tree); cob cuts the body
    /// at the heading tags, across section bodies when the node spans chunks.
    pub fn build(scan: &Scan, res: &Resolution, bodies: &[String]) -> Context {
        let heads = &scan.headings;
        // (section, byte offset) of each heading's opening tag in the final
        // bodies, found by the `id` that `apply` stamps on every heading.
        let pos: Vec<(usize, usize)> = heads
            .iter()
            .enumerate()
            .map(|(i, h)| (h.section, element_offset(&bodies[h.section], &res.heading_anchors[i])))
            .collect();
        let mut nodes = BTreeMap::new();
        for (i, h) in heads.iter().enumerate() {
            // The next heading at the same or a shallower level ends the node.
            let end = heads[i + 1..]
                .iter()
                .position(|n| n.level <= h.level)
                .map(|k| pos[i + 1 + k]);
            nodes.insert(
                res.heading_anchors[i].clone(),
                Node {
                    title: h.text.clone(),
                    page: res.section_page[h.section],
                    body: slice_body(bodies, pos[i], end),
                },
            );
        }
        // Float nodes (§10): a labelled figure, table, or equation is a node too.
        // Lift its single element out of its section body — balanced by tag name,
        // so a figure's inner tags or an equation's KaTeX `div`s do not cut it
        // short — so it can be transcluded alone and shown on its own page.
        for ld in &scan.labels {
            let Some(label) = res.labels.get(&ld.id) else {
                continue;
            };
            let body = &bodies[ld.section];
            if let Some((s, e)) = cut_element(body, &label.anchor) {
                nodes.insert(
                    label.anchor.clone(),
                    Node {
                        title: float_title(&body[s..e], label.kind),
                        page: label.page,
                        body: body[s..e].to_string(),
                    },
                );
            }
        }
        let link_pages = anchor_pages(heads, res);
        let node_pages = Self::build_node_pages(scan, &pos, res, bodies, &nodes);
        let page_files = res.pages.iter().map(|p| p.filename.clone()).collect();
        Context {
            nodes,
            page_files,
            node_pages,
            link_pages,
        }
    }

    /// One page per heading node (§10). A heading with no frozen id — an `h1`,
    /// which is already its own page — is skipped. Bodies are raw here;
    /// `finish_node_pages` expands and rebases them once the context exists.
    fn build_node_pages(
        scan: &Scan,
        pos: &[(usize, usize)],
        res: &Resolution,
        bodies: &[String],
        nodes: &BTreeMap<String, Node>,
    ) -> Vec<NodePage> {
        let heads = &scan.headings;
        let (tx_by, ref_by) = backlink_sources(bodies, pos);
        let mut out = Vec::new();
        for (i, _h) in heads.iter().enumerate() {
            let Some(uid) = res.heading_uids[i].clone() else {
                continue;
            };
            let anchor = &res.heading_anchors[i];
            let node = &nodes[anchor];
            let page_file = &res.pages[node.page].filename;
            out.push(NodePage {
                id: uid,
                title: node.title.clone(),
                body: node.body.clone(),
                page: node.page,
                context: format!("../{page_file}#{anchor}"),
                crumbs: crumbs(heads, res, i),
                transcluded_by: backlinks(tx_by.get(anchor), heads, res),
                referenced_by: backlinks(ref_by.get(anchor), heads, res),
            });
        }
        // A float node's page (§10). Its breadcrumb is the heading it sits in,
        // with that heading's own ancestors before it, so the reader keeps the
        // context the float belongs to.
        for ld in &scan.labels {
            let Some(label) = res.labels.get(&ld.id) else {
                continue;
            };
            let Some(uid) = label.id.clone() else {
                continue;
            };
            let anchor = &label.anchor;
            let Some(node) = nodes.get(anchor) else {
                continue;
            };
            let page_file = &res.pages[label.page].filename;
            let off = element_offset(&bodies[ld.section], anchor);
            let crumbs = match containing_head(pos, (ld.section, off)) {
                Some(h) => {
                    let mut c = crumbs(heads, res, h);
                    c.push(head_link(heads, res, h));
                    c
                }
                None => Vec::new(),
            };
            out.push(NodePage {
                id: uid,
                title: node.title.clone(),
                body: node.body.clone(),
                page: label.page,
                context: format!("../{page_file}#{anchor}"),
                crumbs,
                transcluded_by: backlinks(tx_by.get(anchor), heads, res),
                referenced_by: backlinks(ref_by.get(anchor), heads, res),
            });
        }
        out
    }

    /// Expand the transclusions inside each node page, then rebase its links for
    /// the `n/` directory. A node that holds a directive shows the same inlined
    /// content its canonical page does. The scope counter continues the
    /// document's, so ids stay unique and the output is deterministic (§8). A
    /// transclusion fault here is already counted on the canonical page, so its
    /// lint is discarded.
    pub fn finish_node_pages(&mut self, scope: &mut usize) {
        let pages = std::mem::take(&mut self.node_pages);
        self.node_pages = pages
            .into_iter()
            .map(|mut np| {
                let mut discard = Vec::new();
                let mut stack = Vec::new();
                let body = self.expand_inner(&np.body, np.page, scope, &mut discard, "", 0, &mut stack);
                np.body = qualify_hrefs(&body, &self.link_pages);
                np
            })
            .collect();
    }

    /// The per-node pages, in document order.
    pub fn node_pages(&self) -> &[NodePage] {
        &self.node_pages
    }

    /// Replace every `\transclude` placeholder in `html` with the named node's
    /// finished HTML, recursively. `host_page` decides whether a backlink is a
    /// bare fragment or page-qualified; `scope` is the document-wide counter that
    /// makes each copy's id prefix unique and deterministic.
    pub fn expand(
        &self,
        html: &str,
        host_page: usize,
        scope: &mut usize,
        lints: &mut Vec<Lint>,
        file: &str,
        line: u32,
    ) -> String {
        let mut stack: Vec<String> = Vec::new();
        self.expand_inner(html, host_page, scope, lints, file, line, &mut stack)
    }

    #[allow(clippy::too_many_arguments)]
    fn expand_inner(
        &self,
        html: &str,
        host_page: usize,
        scope: &mut usize,
        lints: &mut Vec<Lint>,
        file: &str,
        line: u32,
        stack: &mut Vec<String>,
    ) -> String {
        if !html.contains(OPEN) {
            return html.to_string();
        }
        let mut out = String::new();
        let mut i = 0;
        while let Some(rel) = html[i..].find(OPEN) {
            let p = i + rel;
            out.push_str(&html[i..p]);
            let astart = p + OPEN.len();
            let Some(q) = html[astart..].find('"') else {
                // Malformed placeholder: copy the rest verbatim and stop.
                out.push_str(&html[p..]);
                return out;
            };
            let addr = &html[astart..astart + q];
            out.push_str(&self.render(addr, host_page, scope, lints, file, line, stack));
            i = astart + q + TAIL.len();
        }
        out.push_str(&html[i..]);
        out
    }

    #[allow(clippy::too_many_arguments)]
    fn render(
        &self,
        addr: &str,
        host_page: usize,
        scope: &mut usize,
        lints: &mut Vec<Lint>,
        file: &str,
        line: u32,
        stack: &mut Vec<String>,
    ) -> String {
        let anchor = anchor_of(addr);
        let Some(node) = self.nodes.get(&anchor) else {
            lints.push(Lint {
                code: "W106",
                message: format!("transclusion of unknown target `{addr}`"),
                file: file.to_string(),
                line,
            });
            return format!(
                "<div class=\"transclusion-missing\" data-transclude=\"{}\">unknown transclusion target</div>",
                prose::escape(addr)
            );
        };
        if stack.contains(&anchor) {
            lints.push(Lint {
                code: "W105",
                message: format!("transclusion cycle through `{addr}`"),
                file: file.to_string(),
                line,
            });
            return format!(
                "<div class=\"transclusion-cycle\" data-transclude=\"{}\">transclusion cycle</div>",
                prose::escape(addr)
            );
        }

        stack.push(anchor.clone());
        let body = self.expand_inner(&node.body, host_page, scope, lints, file, line, stack);
        stack.pop();

        *scope += 1;
        let prefix = format!("tx{scope}");
        let scoped = scope_ids(&body, &prefix);
        let href = if node.page == host_page {
            format!("#{anchor}")
        } else {
            format!("{}#{anchor}", self.page_files[node.page])
        };
        format!(
            "<section class=\"transclusion\" data-transclude=\"{addr}\">\
             <header class=\"transclusion-from\"><a href=\"{href}\">{title}</a></header>\
             {scoped}</section>",
            addr = prose::escape(addr),
            title = prose::escape(&node.title)
        )
    }
}

/// The byte offset of an element's opening tag in the final section `body`, found
/// by the `id` that `apply` stamps on every heading and labelled float (§5.4).
/// The nearest `<` before that id is the tag start; `None` if the id is absent.
fn element_start(body: &str, anchor: &str) -> Option<usize> {
    let needle = format!("id=\"{anchor}\"");
    let p = body.find(&needle)?;
    body[..p].rfind('<')
}

/// Like `element_start`, but `0` when the id is absent — for a heading, which is
/// always present, so the position table never carries a hole.
fn element_offset(body: &str, anchor: &str) -> usize {
    element_start(body, anchor).unwrap_or(0)
}

/// The rendered HTML between two heading tags, joined across section bodies when
/// the node spans more than one chunk. `end` is the next shallower-or-equal
/// heading's `(section, offset)`, or `None` for a node that runs to the end of
/// the document.
fn slice_body(bodies: &[String], start: (usize, usize), end: Option<(usize, usize)>) -> String {
    let (ss, so) = start;
    let (es, eo) = end.unwrap_or_else(|| {
        let last = bodies.len() - 1;
        (last, bodies[last].len())
    });
    if ss == es {
        return bodies[ss][so..eo].to_string();
    }
    let mut out = String::from(&bodies[ss][so..]);
    for b in &bodies[ss + 1..es] {
        out.push_str(b);
    }
    out.push_str(&bodies[es][..eo]);
    out
}
/// The byte range of the element whose opening tag carries `id="anchor"`, its
/// nested same-name tags balanced. `None` if the id is not in `body`.
fn cut_element(body: &str, anchor: &str) -> Option<(usize, usize)> {
    let start = element_start(body, anchor)?;
    let name = tag_name(&body[start..])?;
    let end = balance(body, start, &name)?;
    Some((start, end))
}

/// The tag name at the start of `s` (`s` begins with `<`): the run of name
/// characters after the `<`.
fn tag_name(s: &str) -> Option<String> {
    let b = s.as_bytes();
    if b.first() != Some(&b'<') {
        return None;
    }
    let mut j = 1;
    while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'-') {
        j += 1;
    }
    (j > 1).then(|| s[1..j].to_string())
}

/// The byte offset just past the `</name>` that closes the element opened at
/// `start`. Counts nested `<name …>` opens and `</name>` closes; a `<name` match
/// counts only when a boundary byte follows it, so `<table` never matches inside
/// `<tablefoo`.
fn balance(body: &str, start: usize, name: &str) -> Option<usize> {
    let bytes = body.as_bytes();
    let open = format!("<{name}");
    let close = format!("</{name}>");
    let (ob, cb) = (open.as_bytes(), close.as_bytes());
    let mut depth = 0usize;
    let mut i = start;
    while i < bytes.len() {
        if bytes[i..].starts_with(cb) {
            depth = depth.saturating_sub(1);
            i += cb.len();
            if depth == 0 {
                return Some(i);
            }
            continue;
        }
        if bytes[i..].starts_with(ob) {
            let after = bytes.get(i + ob.len()).copied();
            let boundary = matches!(after, None | Some(b' ' | b'>' | b'/' | b'\n' | b'\t' | b'\r'));
            if boundary {
                depth += 1;
                i += ob.len();
                continue;
            }
        }
        i += 1;
    }
    None
}

/// A short title for a float node: its caption text, or the kind word when there
/// is no caption. A figure reads its `figcaption`, a table its `caption`, an
/// equation has none.
fn float_title(html: &str, kind: &str) -> String {
    let cap = match kind {
        "figure" => inner_text(html, "figcaption"),
        "table" => inner_text(html, "caption"),
        _ => None,
    };
    match cap {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => match kind {
            "figure" => "Figure",
            "table" => "Table",
            "equation" => "Equation",
            _ => "Float",
        }
        .to_string(),
    }
}

/// The tag-stripped text inside the first `<tag>…</tag>` in `html`, or `None`.
fn inner_text(html: &str, tag: &str) -> Option<String> {
    let s = html.find(&format!("<{tag}"))?;
    let open_end = html[s..].find('>')? + s + 1;
    let close = format!("</{tag}>");
    let e = html[open_end..].find(&close)? + open_end;
    Some(strip_tags(&html[open_end..e]))
}

/// `html` with every `<…>` tag removed, leaving the text.
fn strip_tags(html: &str) -> String {
    let mut out = String::new();
    let mut depth = 0u32;
    for c in html.chars() {
        match c {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

/// Prefix every id the copy defines, and every intra-copy reference to one, with
/// `prefix-`, so two copies of a node never collide on a page and an in-copy link
/// still lands in the copy. A reference whose target is *not* defined in the copy
/// is left alone, so it keeps pointing at the canonical node.
fn scope_ids(html: &str, prefix: &str) -> String {
    let defined = collect_ids(html);
    // An id is always local to the copy; a data-for / intra-page href only when
    // it names an id the copy defines.
    let a = prefix_attr(html, " id=\"", prefix, None);
    let b = prefix_attr(&a, " data-for=\"", prefix, Some(&defined));
    prefix_attr(&b, "href=\"#", prefix, Some(&defined))
}

/// Every value of an ` id="…"` attribute in `html`.
fn collect_ids(html: &str) -> BTreeSet<String> {
    let pat = " id=\"";
    let mut set = BTreeSet::new();
    let mut i = 0;
    while let Some(rel) = html[i..].find(pat) {
        let s = i + rel + pat.len();
        let Some(q) = html[s..].find('"') else { break };
        set.insert(html[s..s + q].to_string());
        i = s + q;
    }
    set
}

/// Rewrite every `pat"value"` in `html` to `pat"prefix-value"`. With a `gate`,
/// only values the gate contains are prefixed; without one, every value is.
fn prefix_attr(html: &str, pat: &str, prefix: &str, gate: Option<&BTreeSet<String>>) -> String {
    let mut out = String::new();
    let mut i = 0;
    while let Some(rel) = html[i..].find(pat) {
        let p = i + rel;
        out.push_str(&html[i..p]);
        out.push_str(pat);
        let vstart = p + pat.len();
        let Some(q) = html[vstart..].find('"') else {
            out.push_str(&html[vstart..]);
            return out;
        };
        let val = &html[vstart..vstart + q];
        if gate.is_none_or(|set| set.contains(val)) {
            out.push_str(prefix);
            out.push('-');
        }
        out.push_str(val);
        i = vstart + q;
    }
    out.push_str(&html[i..]);
    out
}

/// Anchor → document page filename, for every heading and every labelled float,
/// so a link that leaves a node page can be made page-qualified.
fn anchor_pages(heads: &[Heading], res: &Resolution) -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    for (i, h) in heads.iter().enumerate() {
        m.insert(
            res.heading_anchors[i].clone(),
            res.pages[res.section_page[h.section]].filename.clone(),
        );
    }
    for label in res.labels.values() {
        m.insert(label.anchor.clone(), res.pages[label.page].filename.clone());
    }
    m
}

/// The innermost heading at or above `at` in document order — the node a use
/// sits in. `pos` is in document order, so the last heading not after `at` wins.
fn containing_head(pos: &[(usize, usize)], at: (usize, usize)) -> Option<usize> {
    let mut found = None;
    for (i, p) in pos.iter().enumerate() {
        if *p <= at {
            found = Some(i);
        } else {
            break;
        }
    }
    found
}

/// Scan every body once for `\transclude` islands and resolved `\ref`s, mapping
/// each target anchor to the heading indices of the nodes that use it.
fn backlink_sources(
    bodies: &[String],
    pos: &[(usize, usize)],
) -> (BTreeMap<String, Vec<usize>>, BTreeMap<String, Vec<usize>>) {
    let mut tx = BTreeMap::new();
    let mut rf = BTreeMap::new();
    for (s, body) in bodies.iter().enumerate() {
        collect_sites(body, s, OPEN, pos, &mut tx);
        collect_sites(body, s, " data-ref=\"", pos, &mut rf);
    }
    (tx, rf)
}

/// Record each `pat"label"` site in `body`: its target anchor and the node it
/// sits in. A use above any heading (a preamble) is skipped.
fn collect_sites(
    body: &str,
    section: usize,
    pat: &str,
    pos: &[(usize, usize)],
    map: &mut BTreeMap<String, Vec<usize>>,
) {
    let mut i = 0;
    while let Some(rel) = body[i..].find(pat) {
        let p = i + rel;
        let vstart = p + pat.len();
        let Some(q) = body[vstart..].find('"') else { break };
        let label = &body[vstart..vstart + q];
        if let Some(h) = containing_head(pos, (section, p)) {
            map.entry(anchor_of(label)).or_default().push(h);
        }
        i = vstart + q;
    }
}

/// The breadcrumb of parent headings for node `i`: document `h1` first, the
/// node's immediate parent last. Each parent walks up one level at a time, so a
/// skipped level does not break the chain.
fn crumbs(heads: &[Heading], res: &Resolution, i: usize) -> Vec<Link> {
    let mut anc = Vec::new();
    let mut floor = heads[i].level;
    for j in (0..i).rev() {
        if heads[j].level < floor {
            anc.push(j);
            floor = heads[j].level;
            if floor == 1 {
                break;
            }
        }
    }
    anc.reverse();
    anc.into_iter().map(|j| head_link(heads, res, j)).collect()
}

/// Turn source heading indices into links, deduped and in document order.
fn backlinks(src: Option<&Vec<usize>>, heads: &[Heading], res: &Resolution) -> Vec<Link> {
    let mut idx: Vec<usize> = src.cloned().unwrap_or_default();
    idx.sort_unstable();
    idx.dedup();
    idx.into_iter().map(|j| head_link(heads, res, j)).collect()
}

/// A link to heading `j`: its own node page (`<id>.html`, a sibling in `n/`), or
/// — for an `h1`, which has no node page — its document page (`../page.html`).
fn head_link(heads: &[Heading], res: &Resolution, j: usize) -> Link {
    let title = heads[j].text.clone();
    let href = match &res.heading_uids[j] {
        Some(uid) => format!("{uid}.html"),
        None => format!("../{}", res.pages[res.section_page[heads[j].section]].filename),
    };
    Link { title, href }
}

/// Rebase every link in a node-page body for the `n/` directory. A node page
/// lives one level down, so its links need fixing by kind:
/// - a fragment to an id the body defines stays bare (an in-node link);
/// - a fragment to an id elsewhere becomes `../page.html#anchor`;
/// - a sibling node-page link (`n/<id>.html`) loses its `n/` prefix;
/// - any other document-relative link gets a `../` prefix.
///
/// An absolute link, a scheme, or an already-rebased link is left alone.
fn qualify_hrefs(body: &str, link_pages: &BTreeMap<String, String>) -> String {
    let local = collect_ids(body);
    let pat = "href=\"";
    let mut out = String::new();
    let mut i = 0;
    while let Some(rel) = body[i..].find(pat) {
        let p = i + rel;
        out.push_str(&body[i..p]);
        out.push_str(pat);
        let vstart = p + pat.len();
        let Some(q) = body[vstart..].find('"') else {
            out.push_str(&body[vstart..]);
            return out;
        };
        let v = &body[vstart..vstart + q];
        out.push_str(&rebase_href(v, &local, link_pages));
        i = vstart + q;
    }
    out.push_str(&body[i..]);
    out
}

/// One link value, rebased for the `n/` directory (see `qualify_hrefs`).
fn rebase_href(v: &str, local: &BTreeSet<String>, link_pages: &BTreeMap<String, String>) -> String {
    if let Some(anchor) = v.strip_prefix('#') {
        return match link_pages.get(anchor) {
            Some(file) if !local.contains(anchor) => format!("../{file}#{anchor}"),
            _ => v.to_string(),
        };
    }
    if let Some(sibling) = v.strip_prefix("n/") {
        return sibling.to_string();
    }
    let absolute = v.starts_with('/')
        || v.starts_with("../")
        || v.starts_with('#')
        || v.contains("://")
        || v.starts_with("mailto:");
    if absolute {
        v.to_string()
    } else {
        format!("../{v}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A context with one node `sec-foo`, on page 0 (`index.html`). The body is a
    /// heading, a margin slot that points at it, an in-copy link, and a link out of
    /// the copy — enough to exercise every scoping rule.
    fn ctx() -> Context {
        let mut nodes = BTreeMap::new();
        nodes.insert(
            "sec-foo".to_string(),
            Node {
                title: "Foo".to_string(),
                page: 0,
                body: "<h2 id=\"sec-foo\">Foo</h2>\
                       <div class=\"margin-slot\" data-for=\"sec-foo\"></div>\
                       <a href=\"#sec-foo\">self</a><a href=\"#elsewhere\">out</a>"
                    .to_string(),
            },
        );
        Context {
            nodes,
            page_files: vec!["index.html".to_string()],
            node_pages: Vec::new(),
            link_pages: BTreeMap::new(),
        }
    }

    /// A host body that transcludes `sec:foo`, with its own text around the directive.
    fn host() -> String {
        format!("host {OPEN}sec:foo{TAIL} tail")
    }

    fn run(host: &str) -> (String, Vec<Lint>) {
        let c = ctx();
        let mut scope = 0;
        let mut lints = Vec::new();
        let out = c.expand(host, 0, &mut scope, &mut lints, "t.cob", 1);
        (out, lints)
    }

    #[test]
    fn transclusion_splices_the_node_with_chrome() {
        let (out, lints) = run(&host());
        assert!(lints.is_empty());
        assert!(out.contains("<section class=\"transclusion\" data-transclude=\"sec:foo\">"));
        assert!(out.contains("<header class=\"transclusion-from\"><a href=\"#sec-foo\">Foo</a></header>"));
        // The host's own text is kept around the spliced node.
        assert!(out.contains("host <section class=\"transclusion\""));
        assert!(out.contains("</section> tail"));
    }

    #[test]
    fn transcluded_copy_has_scoped_ids() {
        let (out, _) = run(&host());
        // The defined id and the margin slot that points at it are prefixed.
        assert!(out.contains("id=\"tx1-sec-foo\""));
        assert!(out.contains("data-for=\"tx1-sec-foo\""));
        // An in-copy link follows the copy; a link out of the copy does not.
        assert!(out.contains("<a href=\"#tx1-sec-foo\">self</a>"));
        assert!(out.contains("<a href=\"#elsewhere\">out</a>"));
        // The canonical copy is untouched: no bare sec-foo id remains in the body.
        assert!(!out.contains("<h2 id=\"sec-foo\">"));
    }

    #[test]
    fn a_cycle_is_flagged_not_looped() {
        // sec:foo's body transcludes sec:foo — a direct cycle.
        let mut nodes = BTreeMap::new();
        nodes.insert(
            "sec-foo".to_string(),
            Node {
                title: "Foo".to_string(),
                page: 0,
                body: format!("<h2 id=\"sec-foo\">Foo</h2>{OPEN}sec:foo{TAIL}"),
            },
        );
        let c = Context {
            nodes,
            page_files: vec!["index.html".to_string()],
            node_pages: Vec::new(),
            link_pages: BTreeMap::new(),
        };
        let mut scope = 0;
        let mut lints = Vec::new();
        let out = c.expand(&host(), 0, &mut scope, &mut lints, "t.cob", 1);
        assert_eq!(lints.len(), 1);
        assert_eq!(lints[0].code, "W105");
        assert!(out.contains("class=\"transclusion-cycle\""));
        // The first copy still rendered; only the inner self-reference is a marker.
        assert!(out.contains("<h2 id=\"tx1-sec-foo\">Foo</h2>"));
    }

    #[test]
    fn an_unknown_target_is_flagged() {
        let host = format!("<section id=\"sec-1\">{OPEN}sec:ghost{TAIL}</section>");
        let (out, lints) = run(&host);
        assert_eq!(lints.len(), 1);
        assert_eq!(lints[0].code, "W106");
        assert!(out.contains("class=\"transclusion-missing\""));
        assert!(out.contains("data-transclude=\"sec:ghost\""));
    }

    #[test]
    fn node_page_links_rebase_for_the_n_directory() {
        let mut local = BTreeSet::new();
        local.insert("sec-here".to_string());
        let mut pages = BTreeMap::new();
        pages.insert("sec-there".to_string(), "parsing.html".to_string());
        let r = |v: &str| rebase_href(v, &local, &pages);
        // An in-node fragment stays bare.
        assert_eq!(r("#sec-here"), "#sec-here");
        // A fragment to an id on another page is qualified up a directory.
        assert_eq!(r("#sec-there"), "../parsing.html#sec-there");
        // A sibling node-page link drops its `n/` prefix.
        assert_eq!(r("n/5QKY.html"), "5QKY.html");
        // A bare document-relative link climbs one directory.
        assert_eq!(r("index.html"), "../index.html");
        // Absolutes, schemes, and already-rebased links are untouched.
        assert_eq!(r("../katex/katex.min.css"), "../katex/katex.min.css");
        assert_eq!(r("https://example.org"), "https://example.org");
        assert_eq!(r("mailto:a@b.c"), "mailto:a@b.c");
    }

    #[test]
    fn the_containing_head_is_the_last_at_or_above_a_use() {
        // Headings at document positions (section, offset), in document order.
        let pos = vec![(0usize, 10usize), (0, 50), (1, 0)];
        // A use in the preamble, before the first heading, belongs to no node.
        assert_eq!(containing_head(&pos, (0, 5)), None);
        // A use between the first two headings sits in the first.
        assert_eq!(containing_head(&pos, (0, 30)), Some(0));
        // A use at a heading's own offset sits in that heading.
        assert_eq!(containing_head(&pos, (0, 50)), Some(1));
        // A use on a later section sits in the last heading at or above it.
        assert_eq!(containing_head(&pos, (1, 99)), Some(2));
    }

    #[test]
    fn a_float_element_is_cut_by_balancing_its_tag() {
        // An equation wraps nested `div`s; the cut balances them, not stops at the
        // first `</div>`.
        let body = "<p>a</p><div class=\"equation\" id=\"eq-x\">\
                    <div class=\"katex\"><div>y</div></div></div><p>b</p>";
        let (s, e) = cut_element(body, "eq-x").unwrap();
        assert_eq!(
            &body[s..e],
            "<div class=\"equation\" id=\"eq-x\"><div class=\"katex\"><div>y</div></div></div>"
        );
        // A figure with an inner img and a caption; `<figcaption` must not be read
        // as a nested `<figure`.
        let fig = "x<figure id=\"fig-y\"><img src=\"a\">\
                   <figcaption>Cap</figcaption></figure>z";
        let (s, e) = cut_element(fig, "fig-y").unwrap();
        assert_eq!(
            &fig[s..e],
            "<figure id=\"fig-y\"><img src=\"a\"><figcaption>Cap</figcaption></figure>"
        );
        // An anchor that is not in the body yields nothing.
        assert!(cut_element(body, "fig-none").is_none());
    }

    #[test]
    fn a_float_title_reads_its_caption_or_its_kind() {
        let fig = "<figure id=\"fig-y\"><figcaption data-id=\"ab\">A <em>tiny</em> map.\
                   </figcaption></figure>";
        assert_eq!(float_title(fig, "figure"), "A tiny map.");
        let tbl = "<table id=\"tbl-z\"><caption>Units.</caption></table>";
        assert_eq!(float_title(tbl, "table"), "Units.");
        // An equation has no caption, so the kind word is the title.
        let eq = "<div class=\"equation\" id=\"eq-x\">y</div>";
        assert_eq!(float_title(eq, "equation"), "Equation");
    }
}
