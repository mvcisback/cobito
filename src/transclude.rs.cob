# Transclusion and the node model (§10)

This module is the specification and the implementation of transclusion. The
prose is the specification. The chunks after it are the implementation.

## Why a node model {#sec:9dZ2}

cob is a living document, and a forest in time (§13). An author must be able to
pull one part of a document into another place and show it there. This is
**transclusion**: the target text appears where the author asks for it, not a
link to it.

The unit that moves is a **node**. A node is an addressable part of the document.
cob already gives every part an address. Every \code{h2}/\code{h3} section earns an opaque
\code{sec:} id (§7.1); every labelled float earns an opaque id. So the document is
already a tree of nodes: the heading nesting *is* the node tree, and the woven
nav tree already draws it. A \code{.cob} file is sugar for a root node that holds its
child nodes in document order. The node model needs almost no new identity
machinery — it reuses the anchors the resolver already stamps.

## What this first slice does {#sec:K4mP}

This slice does **same-document** transclusion of a **section node**. The author
writes \code{\transclude{sec:name}} (Markdown) or the raw island a dialect lowers it
to (§6.4). A node is a heading and the content under it: the heading, its own
text, and its child headings, up to the next heading at the same or a shallower
level. cob cuts the node at these heading boundaries, not at the chunk
boundaries, and puts the node where the directive sits. So one \code{@} chunk can hold
many nodes, and a node can run across several chunks.

The copy is safe by construction, because the weaver never copies the body. A
\code{\transclude} lowers to a lazy \code{<cob-transclude>} element (below): the client
fetches the node's own page and lifts its body into a **shadow root**. So:

- **Ids are isolated.** The shadow root scopes every id, so two copies of one node
  on one page never collide — with no id prefixing.
- **A cycle cannot loop the build.** The weaver resolves no body and emits an inert
  element, so a self-transclusion is a client concern, not a build-time loop.
- **The body is stored once.** The node's own \code{n/} page is the one copy; every
  transclusion references it, so a big forest does not multiply the bytes (§13).

The element carries **context chrome**: a fallback link that names the node and
points at its page. The link shows until — and unless — the client inlines the
body. So a reader with no JavaScript still reaches the node; the inline copy is the
enhancement.

## Where transclusion runs {#sec:7qWt}

Transclusion runs in the weaver, after every section is rendered and wrapped in
its provenance envelope, and before the page split (§5.3). The weaver replaces each
\code{\transclude} island with a \code{<cob-transclude>} element: its \code{src} is the target
node's own page, its fallback is a link to that page. It copies no body, so a
section with no directive is byte-identical to today, and the archival \code{site.json}
still records the canonical nodes once (§8). The client does the inlining at view
time, so the woven bytes stay deterministic and small.

## Floats are nodes too {#sec:Fx3r}

A figure, a table, and an equation are nodes too. Each one already earns an
opaque id (§7.1), so each one is addressable. cob cuts a float node by its tag,
not by heading boundaries: it finds the element that carries the float's anchor
and balances that tag, so a figure's inner tags and an equation's KaTeX \code{div}s do
not cut the element short. So \code{\transclude{fig:name}} lowers to the same lazy
\code{<cob-transclude>} a section does; its fallback link reads the float's caption, and
the client lifts the figure from the float's own page into a shadow root.

A float also earns its own page, at \code{n/<id>.html}, the same as a section node.
Its breadcrumb is the heading it sits in, with that heading's own parents before
it, so the reader keeps the context the float belongs to. Its backlinks are the
nodes that transclude it and the nodes that \code{\ref} it. In its section, the float
leads with the same ⧉ node-page link a heading gets: on a figure or a table the
link rides the caption; an equation has no caption, so the link rides the block
and CSS drops it in the left margin.

## Foreign (cross-document) transclusion {#sec:foreign-tx}

The forest (§13) lets one project transclude another's node. The author writes
\code{\transclude{sec:name@alias}}, where \code{alias} is an imported forest (a
\code{[import.<alias>]} table, §6.1). cob reads that forest's label index (from its
\code{cob-exports.json}) to get the node's frozen opaque id, then points the
\code{<cob-transclude>} \code{src} at the other forest's own node page,
\code{<url>/n/<id>.html}. The element and its shadow-root isolation are exactly the
same as for a local node; only the \code{src} is foreign. So the body stays stored
once, in the forest that owns it, and a reader with no JavaScript still reaches it
by the fallback link. An unknown alias or an unknown label is W106, an inert
marker, the same as a local unknown target.

## A homeless macro node {#sec:SJwf}

A \code{macros} fence is a node too (§6.4). It carries a \code{def:} label, so it earns a
frozen id, a page under \code{n/}, and the transclusion and ref machinery, the same as
a float. It differs in one way: it is homeless. A float renders where the author
writes it and also gets a node page. A macro node does not render where the author
writes it. The weaver cuts the node for the table, then removes the block from the
reading flow (\code{rewrite::strip_macros}). So the reader sees the macros only on the
node page, or where the author puts a \code{\transclude}. A \code{\ref{def:name}} links to
the node page, not to a place in the text.

A cited work (§14) is a homeless node too. The weaver injects one \code{RefNode} per
cited key: its anchor is \code{cite-<key>}, its body the formatted reference, its page
name the frozen id. It never renders in the reading flow — the inline \code{[id]}
marker and the References list stand in for it — but it earns the same node page and
the transclusion machinery, so \code{\transclude{cite:name}} inlines it. Its backlinks
are the nodes that cite it ("Cited by"), found by the same scan that powers
"Transcluded by" and "Referenced by", over the \code{data-cite} markers.

## A page for every node {#sec:node-pages}

A node is a place a reader can go to. So every heading node and every labelled
float gets its own page, at \code{n/<id>.html}, where \code{<id>} is the node's frozen
opaque id (§7.1). The page shows one node on its own, the way a forester wiki
shows one tree. A heading with no id — an \code{h1}, which is already its own page —
gets no node page.

The page has three parts. First a **breadcrumb**: the chain of parent headings,
from the document \code{h1} down to the node, so the reader keeps the context the
node sits in. Each parent links to its own node page (or, for the \code{h1}, to its
document page). Then the **node body** itself, the same bytes the canonical page
shows, with a link back to the node in context. Last the **backlinks**: every
node that transcludes this one ("Transcluded by") and every node that refers to
it with \code{\ref} ("Referenced by"). So the reader sees where the node is used, not
only what it says.

cob finds the backlinks by one scan of the section bodies, before the page
split. A \code{\transclude} island names its target; a resolved \code{\ref} keeps its
label in \code{data-ref}. For each, cob finds the innermost heading above it — the
node the use sits in — and records the pair. So a backlink names a node, and
links to that node's page.

A node page lives one directory down, in \code{n/}, so its links to the document
pages and the shared assets get a \code{../} prefix. A link inside the node body that
points *out* of the node is made page-qualified, so it still lands on the right
document page; a link that points *inside* the node stays a bare fragment. The
page is static HTML, like every other: the only script is the shared nav aid,
and it carries no content text (§5.3), so copy-paste and the annotation quote
selectors survive.

## How the code implements this {#sec:Lm2S}

The module is the placeholder shape, the node table, the context that expands a
host body, the id-scoping helpers, and the per-node pages.
<<src/transclude.rs>>=
<<the module banner>>

<<imports>>

<<the placeholder shape>>

<<a node and the context>>

<<the node page>>

<<build the node table>>

<<build the node pages>>

<<expand islands into cob-transclude>>

<<cut a node body from the section bodies>>

<<qualify links for a node page>>

<<the tests>>
@
The banner states the pass-through decision and the one guarantee a reader needs:
a section with no directive is byte-unchanged.
<<the module banner>>=
//! Transclusion and the node model (§10).
//!
//! Runs in the weaver after every section is wrapped and before the page split
//! (§5.3). A section that holds no `\transclude` directive is byte-identical to
//! the canonical render, so determinism (§8) and the archival JSON are
//! untouched. A directive splices the named section's finished HTML in place,
//! with scoped ids so two copies never collide, and context chrome that links
//! back to the canonical place.
@
Maps and sets for the node table and the scope set; the model's lint type, the
resolver's plan, and the rewriter's \code{anchor_of} (a \code{:} in an id becomes a \code{-} in
an anchor, the same rule the resolver uses).
<<imports>>=
use std::collections::{BTreeMap, BTreeSet};

use crate::model::Lint;
use crate::prose;
use crate::resolve::Resolution;
use crate::rewrite::{anchor_of, strip_macros, Heading, Scan};
use crate::site::ForestRef;
@
A dialect lowers \code{\transclude{addr}} to one exact island: an empty \code{div} that
carries the address. The expander scans for this exact opening and tail, so its own
output — a \code{<cob-transclude>} element, or a \code{transclusion-missing} marker — is
never rescanned as a placeholder.
<<the placeholder shape>>=
/// The island a dialect lowers `\transclude{addr}` to (§6.4). The expander
/// matches this exact opening and tail, so its own output — a `<cob-transclude>`
/// element, or a `transclusion-missing` marker — is never rescanned as a
/// placeholder.
const OPEN: &str = "<div class=\"transclusion\" data-transclude=\"";
const TAIL: &str = "\"></div>";
@
A node is one addressable heading and its content: the heading text (the fallback
link text), the page it lands on, and the rendered HTML of the node body. cob cuts
the body once, at build time, from the final section bodies; the body feeds the
node's own \code{n/} page, which every transclusion then references. The context holds
each node keyed by its anchor, plus the anchor→id map a transclusion needs to name
that page.
<<a node and the context>>=
/// One addressable heading node: its heading text (the fallback link text), its
/// canonical page, and the rendered HTML of the node body — the heading tag and
/// the content under it, cut at the next heading of the same or a shallower level.
struct Node {
    title: String,
    page: usize,
    body: String,
}

/// The node table and the per-node pages, built once per weave.
pub struct Context {
    /// Anchor (`sec-name`, the resolver's form) → node.
    nodes: BTreeMap<String, Node>,
    /// Anchor → the node's frozen opaque id, which names its `n/<id>.html` page.
    /// A transclusion points its `<cob-transclude src>` at that page (§10).
    uids: BTreeMap<String, String>,
    /// One page per heading node, in document order (§10 node pages).
    node_pages: Vec<NodePage>,
    /// Anchor → document page filename, to rebase links that leave a node page.
    link_pages: BTreeMap<String, String>,
    /// Alias → imported forest (§13). A `\transclude{addr@alias}` points its
    /// `<cob-transclude src>` at that forest's own node page.
    imports: BTreeMap<String, ForestRef>,
}
@
A node page is the data the \code{node} template reads: the node's opaque id (its
filename), its heading text, the node body with links fixed for the \code{n/}
directory, a link back to the node in context, the breadcrumb of parents, and
the two backlink lists. A \code{Link} is a title and an href — a breadcrumb step or a
backlink both need only that.
<<the node page>>=
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
    /// A link to the node in its document page (`../page.html#anchor`).
    pub context: String,
    /// The parent headings, document `h1` first, node last-but-one.
    pub crumbs: Vec<Link>,
    /// Every node that transcludes this one.
    pub transcluded_by: Vec<Link>,
    /// Every node that refers to this one with `\ref`.
    pub referenced_by: Vec<Link>,
    /// Every node that cites this one with `\cite` — only a reference node has
    /// these (§14).
    pub cited_by: Vec<Link>,
}

/// A reference node to inject (§14): a cited work, which is a node like any other.
/// `key` is the cite key (its anchor is `cite-<key>`), `id` its frozen opaque id,
/// `title` a short label, and `body` the formatted reference HTML.
pub struct RefNode {
    pub key: String,
    pub id: String,
    pub title: String,
    pub body: String,
}
@
Building the table walks the scanned headings in document order. A node runs from
its own heading to the next heading at the same or a shallower level; a heading
with nothing shallower after it runs to the end of the document. cob finds each
heading in the final section bodies by the \code{id} that \code{apply} stamps on every
heading (§5.4), then cuts the body between the two heading tags — across section
bodies when the node spans more than one chunk. The anchor is the one the
resolver already stamped for that heading, so a \code{\transclude{sec:name}} and a
\code{\ref{sec:name}} name the very same place.
<<build the node table>>=
impl Context {
    /// Build the node table from the scan, the plan, and the final section
    /// bodies. A node runs from its heading to the next heading at the same or a
    /// shallower level (the heading nesting is the node tree); cob cuts the body
    /// at the heading tags, across section bodies when the node spans chunks.
    pub fn build(
        scan: &Scan,
        res: &Resolution,
        bodies: &[String],
        imports: &BTreeMap<String, ForestRef>,
        ref_nodes: &[RefNode],
    ) -> Context {
        let heads = &scan.headings;
        // (section, byte offset) of each heading's opening tag in the final
        // bodies, found by the `id` that `apply` stamps on every heading.
        let pos: Vec<(usize, usize)> = heads
            .iter()
            .enumerate()
            .map(|(i, h)| (h.section, element_offset(&bodies[h.section], &res.heading_anchors[i])))
            .collect();
        let mut nodes = BTreeMap::new();
        let mut uids: BTreeMap<String, String> = BTreeMap::new();
        for (i, h) in heads.iter().enumerate() {
            if let Some(uid) = &res.heading_uids[i] {
                uids.insert(res.heading_anchors[i].clone(), uid.clone());
            }
            // The next heading at the same or a shallower level ends the node.
            let end = heads[i + 1..]
                .iter()
                .position(|n| n.level <= h.level)
                .map(|k| pos[i + 1 + k]);
            // A `macros` island is a homeless node (§10): it shows only on its own
            // page and where it is transcluded, so strip it from a heading node's
            // body too — not just the reading flow.
            let raw = slice_body(bodies, pos[i], end);
            nodes.insert(
                res.heading_anchors[i].clone(),
                Node {
                    title: h.text.clone(),
                    page: res.section_page[h.section],
                    body: strip_macros(&raw).unwrap_or(raw),
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
                if let Some(uid) = &label.id {
                    uids.insert(label.anchor.clone(), uid.clone());
                }
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
        // Reference nodes (§14): a cited work is a homeless node, like a `macros`
        // node. Its anchor is `cite-<key>` (so `\transclude{cite:key}` resolves and
        // `\ref{cite:key}` could too), its page name its frozen id, its body the
        // formatted reference.
        for rn in ref_nodes {
            let anchor = anchor_of(&format!("cite:{}", rn.key));
            uids.insert(anchor.clone(), rn.id.clone());
            nodes.insert(
                anchor,
                Node {
                    title: rn.title.clone(),
                    page: 0,
                    body: rn.body.clone(),
                },
            );
        }
        let link_pages = anchor_pages(heads, res);
        let node_pages = Self::build_node_pages(scan, &pos, res, bodies, &nodes, ref_nodes);
        Context {
            nodes,
            uids,
            node_pages,
            link_pages,
            imports: imports.clone(),
        }
    }
@
Building the node pages walks the same headings. Only a heading with a frozen id
gets a page — an \code{h1} is its own page, so it is skipped. Each page takes the node
title and body, its breadcrumb of parents, and its two backlink lists. The
bodies are raw at this point: \code{finish_node_pages} expands the directives inside
them and rebases their links once the context exists, so a node that holds a
directive shows the same inlined content its canonical page does.
<<build the node pages>>=
    /// One page per heading node (§10). A heading with no frozen id — an `h1`,
    /// which is already its own page — is skipped. Bodies are raw here;
    /// `finish_node_pages` expands and rebases them once the context exists.
    fn build_node_pages(
        scan: &Scan,
        pos: &[(usize, usize)],
        res: &Resolution,
        bodies: &[String],
        nodes: &BTreeMap<String, Node>,
        ref_nodes: &[RefNode],
    ) -> Vec<NodePage> {
        let heads = &scan.headings;
        let (tx_by, ref_by, cite_by) = backlink_sources(bodies, pos);
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
                context: format!("../{page_file}#{anchor}"),
                crumbs: crumbs(heads, res, i),
                transcluded_by: backlinks(tx_by.get(anchor), heads, res),
                referenced_by: backlinks(ref_by.get(anchor), heads, res),
                cited_by: Vec::new(),
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
                // A homeless macro node has no in-flow anchor (§10), so it has no
                // "read in context" link; every other float links to its place.
                context: if label.kind == "macro" {
                    String::new()
                } else {
                    format!("../{page_file}#{anchor}")
                },
                crumbs,
                transcluded_by: backlinks(tx_by.get(anchor), heads, res),
                referenced_by: backlinks(ref_by.get(anchor), heads, res),
                cited_by: Vec::new(),
            });
        }
        // A reference node's page (§14): the formatted work on its own, with the
        // nodes that cite it as backlinks ("Cited by"). It is homeless — no
        // breadcrumb, no "read in context" — like a macro node.
        for rn in ref_nodes {
            let anchor = anchor_of(&format!("cite:{}", rn.key));
            out.push(NodePage {
                id: rn.id.clone(),
                title: rn.title.clone(),
                body: rn.body.clone(),
                context: String::new(),
                crumbs: Vec::new(),
                transcluded_by: backlinks(tx_by.get(&anchor), heads, res),
                referenced_by: Vec::new(),
                cited_by: backlinks(cite_by.get(&anchor), heads, res),
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
    pub fn finish_node_pages(&mut self) {
        let pages = std::mem::take(&mut self.node_pages);
        self.node_pages = pages
            .into_iter()
            .map(|mut np| {
                // A node page lives in `n/`, so a transclusion inside it points at a
                // sibling `<uid>.html` (prefix ""). Then rebase its links for `n/`.
                let mut discard = Vec::new();
                let body = self.expand(&np.body, "", &mut discard, "", 0);
                np.body = qualify_hrefs(&body, &self.link_pages);
                np
            })
            .collect();
    }

    /// The per-node pages, in document order.
    pub fn node_pages(&self) -> &[NodePage] {
        &self.node_pages
    }
@
A \code{\transclude} island lowers to a lazy \code{<cob-transclude>} element (§10). The
client fetches the node's own page into a shadow root, so the body is stored once
and loaded on demand. The weaver copies no body: it resolves the address to the
node-page URL and title, and leaves a link fallback that works with no JavaScript.
\code{prefix} is the path to the \code{n/} directory from the host page ("n/" from a
document page, "" from a node page). An unknown target is W106, an inert marker; a
cycle is now a client-side guard, not a build-time lint.
<<expand islands into cob-transclude>>=
    /// Replace every `\transclude` island in `html` with a lazy `<cob-transclude>`
    /// (§10): a link fallback plus the node-page `src` the client lifts into a
    /// shadow root. `prefix` is the path to `n/` from the host page. No body is
    /// copied here; an unknown target is W106.
    pub fn expand(
        &self,
        html: &str,
        prefix: &str,
        lints: &mut Vec<Lint>,
        file: &str,
        line: u32,
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
                out.push_str(&html[p..]);
                return out;
            };
            let addr = &html[astart..astart + q];
            out.push_str(&self.element(addr, prefix, lints, file, line));
            i = astart + q + TAIL.len();
        }
        out.push_str(&html[i..]);
        out
    }

    /// One `<cob-transclude>` for a resolved address, or a W106 marker for an
    /// unknown one. `src` is the node's own page under `n/`; the fallback link is
    /// the same page, so the content is reachable with no JavaScript (§6.3).
    fn element(&self, addr: &str, prefix: &str, lints: &mut Vec<Lint>, file: &str, line: u32) -> String {
        // A `addr@alias` target lives in an imported forest (§13): point the `src`
        // at that forest's own node page (`<url>/n/<id>.html`), which the client
        // lifts into a shadow root exactly as for a local node. The fallback link
        // names the target by its kind and frozen opaque id. An unknown alias, an
        // unknown label, or a label with no node id falls through to the W106
        // marker, the same as any other unknown target.
        if let Some((label, alias)) = addr.rsplit_once('@') {
            if let Some(uid) = self
                .imports
                .get(alias)
                .and_then(|fr| fr.index.labels.get(label).map(|fl| (fr, fl)))
                .and_then(|(fr, fl)| fl.id.as_ref().map(|id| (fr, id)))
            {
                let (fr, id) = uid;
                let base = fr.url.trim_end_matches('/');
                let url = format!("{base}/n/{id}.html");
                let title = match crate::rewrite::Kind::from_label(label) {
                    Some(k) => format!("{} {id}", k.word()),
                    None => addr.to_string(),
                };
                return format!(
                    "<cob-transclude src=\"{url}\" data-transclude=\"{a}\">\
                     <a href=\"{url}\">{t} &rarr;</a></cob-transclude>",
                    a = prose::escape(addr),
                    t = prose::escape(&title)
                );
            }
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
        }
        let anchor = anchor_of(addr);
        match (self.nodes.get(&anchor), self.uids.get(&anchor)) {
            (Some(node), Some(uid)) => {
                let url = format!("{prefix}{uid}.html");
                format!(
                    "<cob-transclude src=\"{url}\" data-transclude=\"{a}\">\
                     <a href=\"{url}\">{t} &rarr;</a></cob-transclude>",
                    a = prose::escape(addr),
                    t = prose::escape(&node.title)
                )
            }
            _ => {
                lints.push(Lint {
                    code: "W106",
                    message: format!("transclusion of unknown target `{addr}`"),
                    file: file.to_string(),
                    line,
                });
                format!(
                    "<div class=\"transclusion-missing\" data-transclude=\"{}\">unknown transclusion target</div>",
                    prose::escape(addr)
                )
            }
        }
    }
}
@
Two helpers cut a heading node body. The first finds an element's opening tag in a
final section body by the \code{id} that \code{apply} stamps on it (§5.4): the nearest \code{<}
before that id is the tag start. The second joins the bytes between two heading
tags; when the node spans more than one chunk, it takes the tail of the first
section body, every whole body between, and the head of the last. A node with no
shallower heading after it runs to the end of the last body.
<<cut a node body from the section bodies>>=
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
@
A float is one element, not a run between headings, so cob cuts it by balancing
its tag. \code{cut_element} finds the element's opening tag by its \code{id}, reads the tag
name, then walks the bytes counting nested opens and closes of that name until the
depth returns to zero — so a figure's inner \code{img} or an equation's KaTeX \code{div}s do
not end the cut too soon. Working on bytes keeps the scan safe over the UTF-8 the
body may hold; every match is on ASCII tag bytes, so the returned range always
lands on a char boundary.
<<cut a node body from the section bodies>>=
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
            "macro" => "Notation",
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
@
The node-page helpers make the breadcrumb, the backlinks, and the link rebasing.
A breadcrumb or a backlink is one link to a node — to its own node page, or, for
an \code{h1}, to its document page. Backlinks come from one scan of the bodies: a
\code{\transclude} island and a resolved \code{\ref} both name a target, and the innermost
heading above the use is the node it sits in. Rebasing fixes a node body for the
\code{n/} directory: a link inside the node stays a bare fragment; a link out of it
becomes \code{../page.html#anchor}, so it lands on the right document page.
<<qualify links for a node page>>=
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

/// Scan every body once for `\transclude` islands, resolved `\ref`s, and `\cite`
/// markers, mapping each target anchor to the heading indices of the nodes that use
/// it — the "transcluded by", "referenced by", and "cited by" backlinks.
fn backlink_sources(
    bodies: &[String],
    pos: &[(usize, usize)],
) -> (
    BTreeMap<String, Vec<usize>>,
    BTreeMap<String, Vec<usize>>,
    BTreeMap<String, Vec<usize>>,
) {
    let mut tx = BTreeMap::new();
    let mut rf = BTreeMap::new();
    let mut ci = BTreeMap::new();
    for (s, body) in bodies.iter().enumerate() {
        collect_sites(body, s, OPEN, pos, "", &mut tx);
        collect_sites(body, s, " data-ref=\"", pos, "", &mut rf);
        // A `data-cite="key"` names a reference node whose anchor is `cite-<key>`,
        // so the key is prefixed before `anchor_of` to match the node (§14).
        collect_sites(body, s, " data-cite=\"", pos, "cite:", &mut ci);
    }
    (tx, rf, ci)
}

/// Record each `pat"label"` site in `body`: its target anchor (the label with
/// `prefix` prepended, then `anchor_of`) and the node it sits in. A use above any
/// heading (a preamble) is skipped.
fn collect_sites(
    body: &str,
    section: usize,
    pat: &str,
    pos: &[(usize, usize)],
    prefix: &str,
    map: &mut BTreeMap<String, Vec<usize>>,
) {
    let mut i = 0;
    while let Some(rel) = body[i..].find(pat) {
        let p = i + rel;
        let vstart = p + pat.len();
        let Some(q) = body[vstart..].find('"') else { break };
        let label = &body[vstart..vstart + q];
        if let Some(h) = containing_head(pos, (section, p)) {
            map.entry(anchor_of(&format!("{prefix}{label}")))
                .or_default()
                .push(h);
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

/// Every value of an ` id="…"` attribute in `html` — the ids local to this node
/// body, so a link into it stays a fragment while a link out is page-qualified.
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
@
The tests build a small context by hand — the node table and page files are the
only inputs the expander reads — and exercise the happy path, the scoping rules,
a cycle, and an unknown target.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    <<a context over two sections>>

    <<a transclusion splices the node with chrome>>

    <<an unknown target is flagged>>

    <<node-page links rebase for the n directory>>

    <<the containing head is the last at or above a use>>

    <<a float element is cut by balancing its tag>>

    <<a float title reads its caption or its kind>>
}
@
The harness builds a context with one node, \code{sec:foo}, whose body is a heading, a
margin slot, an in-copy link, and a link out of the copy, on a single page.
<<a context over two sections>>=
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
    let mut uids = BTreeMap::new();
    uids.insert("sec-foo".to_string(), "abcd".to_string());
    Context {
        nodes,
        uids,
        node_pages: Vec::new(),
        link_pages: BTreeMap::new(),
        imports: BTreeMap::new(),
    }
}

/// A host body that transcludes `sec:foo`, with its own text around the directive.
fn host() -> String {
    format!("host {OPEN}sec:foo{TAIL} tail")
}

fn run(host: &str) -> (String, Vec<Lint>) {
    let c = ctx();
    let mut lints = Vec::new();
    let out = c.expand(host, "n/", &mut lints, "t.cob", 1);
    (out, lints)
}
@
A transclusion lowers to a lazy \code{<cob-transclude>} whose \code{src} is the node's own
page under \code{n/} and whose fallback link is the same page, so the content is
reachable with no JavaScript (§10). The weaver copies no body and scopes no ids —
the shadow root isolates them. The host's own text is kept around the element.
<<a transclusion splices the node with chrome>>=
#[test]
fn transclusion_lowers_to_a_lazy_element() {
    let (out, lints) = run(&host());
    assert!(lints.is_empty());
    assert!(out.contains(
        "<cob-transclude src=\"n/abcd.html\" data-transclude=\"sec:foo\">\
         <a href=\"n/abcd.html\">Foo &rarr;</a></cob-transclude>"
    ));
    // No server-side copy: the node body is not spliced, and no scoped id appears.
    assert!(!out.contains("<section class=\"transclusion\""));
    assert!(!out.contains("tx1-"));
    // The host's own text is kept around the element.
    assert!(out.contains("host <cob-transclude"));
    assert!(out.contains("</cob-transclude> tail"));
}
@
A directive whose target is no known node is flagged W106 and replaced with an
inert marker.
<<an unknown target is flagged>>=
#[test]
fn an_unknown_target_is_flagged() {
    let host = format!("<section id=\"sec-1\">{OPEN}sec:ghost{TAIL}</section>");
    let (out, lints) = run(&host);
    assert_eq!(lints.len(), 1);
    assert_eq!(lints[0].code, "W106");
    assert!(out.contains("class=\"transclusion-missing\""));
    assert!(out.contains("data-transclude=\"sec:ghost\""));
}
@
A node page lives one level down, in \code{n/}, so \code{rebase_href} fixes each link by
kind (see \code{qualify_hrefs}). A fragment to an id the body defines stays bare; a
fragment to an id elsewhere gets its page and a \code{../} prefix; a sibling node-page
link loses its \code{n/}; any other document-relative link gets \code{../}; an absolute
link or a scheme is left alone.
<<node-page links rebase for the n directory>>=
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
@
\code{containing_head} finds the node a use sits in: the last heading at or before the
use in document order. A use above every heading (a preamble) has no node.
<<the containing head is the last at or above a use>>=
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
@
A float is one element, cut by balancing its tag. The cut must count nested tags
of the same name — an equation's KaTeX \code{div}s, a figure's inner tags — so it does
not end early, and must leave a float with a different anchor alone.
<<a float element is cut by balancing its tag>>=
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
@
A float title reads the caption text, tags stripped, or falls back to the kind
word when the float has none.
<<a float title reads its caption or its kind>>=
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
@
