# Reverse backlinks across the forest (§16)

This module is the specification and the implementation of `cob backlinks`. The
prose is the specification. The chunks after it are the implementation.

## Why a separate pass {#sec:bl-why}

A node knows what it points at — its \code{\ref}s, \code{\cite}s, and \code{\transclude}s are in
its own body. It cannot know what points at **it**, because its consumers are other
forests built later and elsewhere. So a reverse backlink ("Cited by", "Referenced
by", "Transcluded by") needs a view of the whole forest, which no single weave has.
\code{cob backlinks} is that view: a separate pass over several built forests that
**inverts** their outgoing edges into reverse backlinks.

## What it reads and writes {#sec:bl-io}

Each forest already records its outgoing cross-forest edges in \code{cob-exports.json}
(§16): every \code{\ref}/\code{\cite}/\code{\transclude} into another forest, with the target
forest's \code{url} (the join key), the target node's id, and the source node. \code{cob
backlinks} reads the \code{cob-exports.json} of each forest it is given, groups the edges
by their target, and writes one **fragment** per targeted node:
\code{n/<id>.backlinks.html}, a small list of the nodes that point at it, each a link
back to its own node page. A node page fetches this fragment lazily (§16, the
\code{<cob-backlinks>} element), so a forest shows its backlinks without re-weaving when
a new consumer appears — the pass is re-run instead.

## The join is by url {#sec:bl-join}

A forest's identity is its deployed \code{url} (\code{[forest] url}). A consumer's edge names
its target by the same url (from the \code{[import.<alias>] url}). So the inversion is a
group-by: every edge whose \code{to_url} equals a forest's own \code{url} is a backlink to
that forest. A forest with no url does not take part — it can be neither named by a
consumer nor linked back to.

## How the code implements this {#sec:bl-impl}

The module is the error, the loaded-forest record, the pure inversion, the fragment
renderer, and the IO driver.
<<src/backlinks.rs>>=
<<the module banner>>

<<imports>>

<<the backlinks error>>

<<an incoming edge>>

<<invert the edges>>

<<render a fragment>>

<<run the pass>>

<<the tests>>
@
The banner states the one idea: invert the forest's outgoing edges, so each node
learns who points at it.
<<the module banner>>=
//! `cob backlinks` (§16): invert several forests' outgoing cross-forest edges
//! (`cob-exports.json`) into reverse-backlink fragments (`n/<id>.backlinks.html`),
//! which node pages fetch lazily. The reverse direction needs a forest-wide view
//! no single weave has, so it is a separate pass.
@
The pass reads `cob-exports.json` through `site::read_exports`, so a forest with a
newer major schema is the same E038 a weave would raise.
<<imports>>=
use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::site::{self, ForestEdge};
@
One error code, E041: a backlink fragment could not be written.
<<the backlinks error>>=
/// E041 — `cob backlinks` could not write a fragment (§16).
#[derive(Debug)]
pub enum BacklinksError {
    Io(String),
}

impl std::fmt::Display for BacklinksError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BacklinksError::Io(m) => write!(f, "error[E041]: backlinks: {m}"),
        }
    }
}

impl std::error::Error for BacklinksError {}
@
One incoming edge, as a target node records it: the kind (so the fragment groups
"Cited by" apart from "Referenced by"), and the source node's forest url, id, and
title, so the backlink links back to its node page.
<<an incoming edge>>=
/// One edge pointing at a node, from the target's point of view (§16): the edge
/// kind and the source node (its forest url, id, and title), so a backlink links to
/// `<from_url>/n/<from_id>.html`.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Incoming {
    kind: String,
    from_url: String,
    from_id: String,
    from_title: String,
}
@
Inverting walks every forest's edges once. An edge from forest `C` to `(to_url,
to_id)` becomes an incoming edge on the forest whose url is `to_url`, naming `C` as
the source. The result is keyed by target forest url, then by target node id. An
edge with no source or target url is skipped — it cannot be linked.
<<invert the edges>>=
/// Invert outgoing edges into incoming backlinks (§16): `to_url → to_id →
/// [incoming]`. Each forest is `(own_url, its outgoing edges)`.
fn invert(forests: &[(String, Vec<ForestEdge>)]) -> BTreeMap<String, BTreeMap<String, Vec<Incoming>>> {
    let mut out: BTreeMap<String, BTreeMap<String, Vec<Incoming>>> = BTreeMap::new();
    for (from_url, edges) in forests {
        if from_url.is_empty() {
            continue;
        }
        for e in edges {
            if e.to_url.is_empty() || e.to_id.is_empty() {
                continue;
            }
            out.entry(e.to_url.clone())
                .or_default()
                .entry(e.to_id.clone())
                .or_default()
                .push(Incoming {
                    kind: e.kind.clone(),
                    from_url: from_url.clone(),
                    from_id: e.from_id.clone(),
                    from_title: e.from_title.clone(),
                });
        }
    }
    out
}
@
A fragment is one `<section>` with a list per kind, in a fixed order so the output
is deterministic. The incoming edges are deduplicated and sorted, so the same
source cited twice makes one backlink. Each link points at the source node's own
page in its forest. The section is inert HTML a node page fetches and shows (§16).
<<render a fragment>>=
/// The `n/<id>.backlinks.html` fragment for one targeted node (§16): a `<section>`
/// with a deduplicated, sorted list per kind ("Transcluded by", "Referenced by",
/// "Cited by"), each a link to the source node's page.
fn render_fragment(mut links: Vec<Incoming>) -> String {
    links.sort();
    links.dedup();
    let mut out = String::from("<section class=\"backlinks forest-backlinks\">\n");
    for (kind, heading) in [
        ("transclude", "Transcluded by"),
        ("ref", "Referenced by"),
        ("cite", "Cited by"),
    ] {
        let group: Vec<&Incoming> = links.iter().filter(|l| l.kind == kind).collect();
        if group.is_empty() {
            continue;
        }
        out.push_str(&format!("<h2>{heading}</h2>\n<ul>"));
        for l in group {
            let base = l.from_url.trim_end_matches('/');
            out.push_str(&format!(
                "<li><a href=\"{base}/n/{id}.html\">{title}</a></li>",
                id = crate::prose::escape(&l.from_id),
                title = crate::prose::escape(&l.from_title),
            ));
        }
        out.push_str("</ul>\n");
    }
    out.push_str("</section>\n");
    out
}
@
Running the pass loads each forest's `cob-exports.json` (skipping a directory that
has none, so a non-forest path is harmless), inverts the edges, and writes one
fragment per targeted node into that forest's `n/` directory. It returns how many
fragments it wrote. A directory's own url comes from its exports, so the pass needs
only the built sites, nothing else.
<<run the pass>>=
/// Invert the edges of the forests in `dirs` and write a `n/<id>.backlinks.html`
/// fragment for every targeted node (§16). A directory with no `cob-exports.json`
/// is skipped. Returns the number of fragments written.
pub fn run(dirs: &[PathBuf]) -> Result<usize, BacklinksError> {
    let mut loaded: Vec<(PathBuf, String, Vec<ForestEdge>)> = Vec::new();
    for dir in dirs {
        let Ok(text) = std::fs::read_to_string(dir.join("cob-exports.json")) else {
            continue;
        };
        if let Ok(Some(index)) = site::read_exports(&text) {
            loaded.push((dir.clone(), index.url, index.edges));
        }
    }
    let forests: Vec<(String, Vec<ForestEdge>)> = loaded
        .iter()
        .map(|(_, url, edges)| (url.clone(), edges.clone()))
        .collect();
    let incoming = invert(&forests);

    let mut written = 0;
    for (dir, url, _) in &loaded {
        let Some(by_id) = incoming.get(url) else {
            continue;
        };
        let ndir = dir.join("n");
        std::fs::create_dir_all(&ndir).map_err(|e| BacklinksError::Io(e.to_string()))?;
        for (to_id, links) in by_id {
            let html = render_fragment(links.clone());
            std::fs::write(ndir.join(format!("{to_id}.backlinks.html")), html)
                .map_err(|e| BacklinksError::Io(e.to_string()))?;
            written += 1;
        }
    }
    Ok(written)
}
@
The tests cover the inversion (an edge becomes an incoming backlink on its target,
keyed by url and id; a url-less forest is skipped) and the fragment (grouped by
kind, deduplicated, linking to the source node page).
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn edge(kind: &str, to_url: &str, to_id: &str, from_id: &str, from_title: &str) -> ForestEdge {
        ForestEdge {
            kind: kind.to_string(),
            to_url: to_url.to_string(),
            to_id: to_id.to_string(),
            from_id: from_id.to_string(),
            from_title: from_title.to_string(),
        }
    }

    #[test]
    fn an_edge_inverts_to_a_backlink_on_its_target() {
        // Forest B (url b) cites forest A's node `aaaa`.
        let forests = vec![
            ("https://a.example".to_string(), vec![]),
            (
                "https://b.example".to_string(),
                vec![edge("cite", "https://a.example", "aaaa", "bbbb", "B's Node")],
            ),
        ];
        let inv = invert(&forests);
        let on_a = &inv["https://a.example"]["aaaa"];
        assert_eq!(on_a.len(), 1);
        assert_eq!(on_a[0].from_url, "https://b.example");
        assert_eq!(on_a[0].from_id, "bbbb");
    }

    #[test]
    fn a_url_less_forest_is_skipped() {
        // A forest with no url cannot be linked back to, so its edges are dropped.
        let forests = vec![(
            String::new(),
            vec![edge("ref", "https://a.example", "aaaa", "xxxx", "X")],
        )];
        assert!(invert(&forests).is_empty());
    }

    #[test]
    fn a_fragment_groups_dedups_and_links_back() {
        let links = vec![
            edge_in("cite", "https://b.example", "bbbb", "Cite One"),
            edge_in("cite", "https://b.example", "bbbb", "Cite One"), // duplicate
            edge_in("ref", "https://c.example/", "cccc", "Ref Two"),
        ];
        let html = render_fragment(links);
        assert!(html.contains("<h2>Cited by</h2>"));
        assert!(html.contains("<h2>Referenced by</h2>"));
        // The duplicate collapses to one backlink.
        assert_eq!(html.matches("Cite One").count(), 1);
        // A link points at the source node's page; a trailing slash does not double.
        assert!(html.contains("<a href=\"https://b.example/n/bbbb.html\">Cite One</a>"));
        assert!(html.contains("<a href=\"https://c.example/n/cccc.html\">Ref Two</a>"));
    }

    fn edge_in(kind: &str, from_url: &str, from_id: &str, from_title: &str) -> Incoming {
        Incoming {
            kind: kind.to_string(),
            from_url: from_url.to_string(),
            from_id: from_id.to_string(),
            from_title: from_title.to_string(),
        }
    }
}
@
