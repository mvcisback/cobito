# Annotations — the margin commenting layer for lit sites

**Status:** draft spec, v0.1. Split out of `SPEC.md` (which retains only lit's
side of the contract, its §9). Research findings below are from 2026-08-23.

**Not a v1 blocker — do not re-litigate before M5.** The ecosystem is surveyed
(§3) and the fallback routing is decided (§4); what remains are judgments that
require annotating a real woven page, which does not exist yet. lit's only
obligation until then is the §9 contract in `SPEC.md`: provenance attributes,
anchorable markup, margin slots, embed hook. Build that, ship v1, then choose.

## 1. Purpose

Reviewers read a woven lit site, select prose or code, and leave margin
comments; threads are collapsible; an AI agent (`lit review`, specced in
`SPEC.md` §10) reads all open annotations and proposes revisions to the `.nw`
source. This tool is **separate from lit**: lit emits annotation-ready HTML
(`SPEC.md` §9) and otherwise knows nothing about comments.

Requirements:

- **A1** Anchor to arbitrary text selections on the woven pages, surviving
  re-weaves (edits, renumbering, page resplits).
- **A2** Margin presentation: collapsed pill per commented region, expanding
  in the right margin; inline disclosure on narrow viewports.
- **A3** Threads: replies, open/resolved state (or an equivalent convention).
- **A4** Machine-readable export of all annotations for a document, retrievable
  by the review agent without scraping.
- **A5** Identity sufficient to attribute comments and restrict writes.
- **A6** Archival: annotations exportable to flat JSON beside the static site.
- **A7** The static site must remain fully functional with the layer absent.

## 2. Fixed decisions (independent of adopt vs build)

These hold no matter which backend wins, and the review agent codes against
them only:

1. **Interchange format: W3C Web Annotation Data Model** (JSON-LD). Not our
   own thread/comment schema — the earlier draft's bespoke SQLite model is
   superseded.
2. **Anchoring: W3C selector bundles**, following Hypothesis practice: a
   `TextQuoteSelector` (exact text + prefix/suffix context) plus a
   `TextPositionSelector` (character offsets), stored together. Position hints
   where to search; quote is the arbiter; fuzzy matching recovers from edits;
   a quote that cannot be found anywhere marks the annotation **orphaned**
   (surfaced, never dropped). This machinery exists as maintained libraries —
   we do not write it: `dom-anchor-text-quote` / `dom-anchor-text-position`
   (battle-tested, used by Hypothesis) and Apache Annotator (incubating, the
   W3C-blessed successor).
3. **Target:** the woven HTML. Mapping back to `.nw` source uses lit's
   provenance attributes (`data-nw-file`/`data-nw-line`, `SPEC.md` §9.1) —
   the annotation layer itself never reads `.nw` files.

## 3. Options researched

### 3.1 Adopt hosted hypothes.is

One script tag (lit's `[weave.annotate] embed`), a **private group** for the
review circle, REST API v1 for A4. The client already implements selection,
anchoring, sidebar UI, threads, and orphan handling.

- For: zero code, zero ops; the API returns annotations with W3C-style
  selector bundles, exactly what `lit review` needs; groups give a usable
  A5 without us building auth.
- Against: data lives with a third party (mitigated by A6 export via API);
  accounts required; UI is their sidebar, not Tufte margins (A2 partially
  unmet — annotations highlight in-text and open in a right-hand sidebar,
  which is close in spirit); no "resolved" state in their model (convention:
  agent replies + adds a `lit:resolved` tag, and the review adapter filters
  on it).

### 3.2 Self-host the Hypothesis `h` server

Supported and documented: provision an OAuth client, set `CLIENT_OAUTH_ID` /
`CLIENT_URL`, and point the client at the custom authority via
`window.hypothesisConfig` → `services: [{apiUrl, authority, grantToken}]`.

- For: full data locality **and** the entire mature client for free —
  selection UI, anchoring, threads, orphan handling. This is the only option
  that gets both; §3.3 buys locality by making us build and maintain all of
  that ourselves.
- Against: **heavy ops** — Postgres + Elasticsearch + RabbitMQ, three stateful
  services for a single-tenant review tool. No official `docker-compose.yml`
  (issue #4899 is still the reference; working examples are community gists).
  The `services` client-config key is documented as experimental. UI is still
  their sidebar, so this does nothing for A2.

**Not dominated by §3.3.** An earlier draft said so; that was wrong. The two
compare on different axes — §3.2 costs ops and keeps the client, §3.3 costs
client development and keeps the margin UI. Which one wins depends entirely on
*which* trigger fires (§4).

### 3.3 Build a thin tool

The research changes what "build" means: anchoring (the genuinely hard part)
is a solved library problem, and the HTTP shape is standardized (W3C Web
Annotation Protocol). Building shrinks to: a small CRUD server storing
selector-bearing W3C JSON, plus a margin overlay client.

- For: true Tufte-margin UI (A2 fully), local data, no accounts (token list),
  archival by construction, and the overlay can mount into lit's
  `margin-slot`s.
- Against: it is still a real project — selection UI, thread rendering,
  sanitization of untrusted comment bodies, auth, ops. The graveyard of
  half-maintained self-hosted comment systems (Isso, Commento, Remark42, …)
  is a warning about undercosting this.

### 3.4 Other self-hosted candidates (surveyed, not adopted)

- **Elucidate** (Digirati/DLCS): a genuine W3C Web Annotation Protocol server
  (Java + PostgreSQL), but storage only — no selection UI or margin client —
  and largely dormant. Adopting it would still mean building the whole client
  while running a heavier server than §3.3's sketch.
- **Recogito Studio**: actively maintained, self-hosted, W3C-compliant, but a
  *destination platform* — documents are imported into its app and annotated
  there. It cannot overlay the woven lit site, so A1/A2 fail structurally.
  Its `text-annotator-js` library is a candidate client building block for
  §3.3, alongside Apache Annotator.

Net: there is no *lightweight* maintained self-hosted W3C annotation server
with a page-overlay client. Self-hosting is available (§3.2) but heavy;
lightweight self-hosting means building (§3.3). Note also that a hosted
private group gives content privacy but not data locality — hence the first
trigger in §4.

## 4. Decision: adopt first; the fallback depends on which trigger fires

Same policy as lit's noweb dependency (`SPEC.md` §11): **start with hosted
hypothes.is** (private group + embed + API adapter). The contingency is *not*
always the thin tool — each trigger routes to whichever of §3.2/§3.3 actually
addresses it:

| Trigger | Fallback | Why |
|---|---|---|
| Data locality / privacy that API-export cannot satisfy | **§3.2 self-host `h`** | Same client, same API, data on our box. Building would be strictly more work for the same outcome. |
| Sidebar UX materially hurts review quality vs. true margin comments (judge after real use, not in the abstract) | **§3.3 build** | Self-hosting ships the same sidebar; only a custom overlay gives A2. |
| Annotation must work offline / inside the sealed archival artifact | **§3.3 build** | Neither hosted nor self-hosted `h` can live in a static archive. |
| Service dependence untenable (pricing, availability, API changes) | **§3.2 self-host `h`** | The dependency is the *service*, not the software. |
| Selection/anchoring fails on KaTeX output or code chunks (AN-2) | **§3.3 build** | Needs custom anchoring they won't ship; self-hosting inherits the same client behavior. |

The load-bearing consequence: *lightweight* and *self-hosted* are the axes in
tension, not *adopt* and *self-host*. If locality is the only concern, §3.2 is
the cheaper answer despite the ops; the thin tool is justified by wanting the
**margin UI** or the **sealed archive**, both of which are judgments to make
after M5, not now.

Validation for the adopt path happens in lit's M5/M6: embed on a real woven
page, annotate math-adjacent prose and code chunks, pull via API, map to
`.nw` via provenance attributes, and run the full review loop.

## 5. If built: design sketch

Kept deliberately short until a trigger fires. Inherits intent from the
pre-split lit spec (v0.2 §9), updated for the W3C decisions:

- **Server:** FastAPI + SQLite (WAL), packaged with uv2nix in its own flake.
  Stores annotations as W3C JSON documents (one row per annotation: id, doc,
  json, status, created, author); no bespoke thread/selector schema — threads
  are annotations whose target is another annotation, per the W3C model.
- **API:** W3C Web Annotation Protocol (annotation containers, CRUD) plus a
  convenience `GET /docs/{doc}/annotations.json`. The HTML/JSON duality
  convention from the pre-split spec applies to any UI pages: every HTML
  endpoint is a pure function of a JSON endpoint (`P.json` canonical).
- **Client:** selection → selector bundle via Apache Annotator /
  `dom-anchor-*`; overlay mounts threads into lit's
  `<div class="margin-slot">`s; collapsed pills expand in the margin, pushing
  subsequent margin content down; inline disclosure under a viewport
  breakpoint. Sidenote/comment margin contention is resolved here — lit only
  guarantees the slot.
- **Comment bodies are untrusted:** Markdown subset, sanitized, `$…$` math
  KaTeX-rendered from extracted source only, no raw HTML.
- **Auth:** static token → display-name map; unauthenticated = read-only;
  rate-limit writes.
- **Archival:** `--export` dumps the annotation containers as flat JSON
  beside `_site/`, satisfying A6 identically to the adopt path.

## 6. Review-loop dataflow (both paths)

```
reviewer selects text on woven page
        │  client stores W3C annotation {TextQuoteSelector, TextPositionSelector}
        ▼
backend (hypothes.is group │ thin tool)
        │  lit review: backend adapter fetches W3C JSON (A4)
        ▼
map: quote selector → location in page → enclosing section
     → data-nw-file/data-nw-line → .nw region
        ▼
unified diff against .nw  →  human accepts  →  re-weave
        │
        └─ agent marks addressed annotations (thin tool: status=resolved;
           hypothes.is: reply + tag lit:resolved) — orphans surface, never vanish
```

## 7. Open questions

- **AN-1** (was lit's D) Margin contention between Tufte sidenotes and
  comment threads — build-path only; the adopt path uses the Hypothesis
  sidebar as-is.
- **AN-2** Does quote-selector anchoring behave acceptably on KaTeX-rendered
  math (selection inside rendered spans) and inside `<pre>` code chunks?
  Test explicitly during M5 validation; this is also a build trigger (§4).
- **AN-3** Adopt path: is reply-plus-tag a tolerable "resolved" convention,
  or does filtering open threads become too noisy?
- **AN-4** Should annotations made against revision *N* of a document be
  shown on revision *N+1* at all when their quote still anchors, or pinned
  to the revision they were made on (`meta.rev` in `site.json`)?

## Sources

- [Hypothesis `h` server](https://github.com/hypothesis/h) and
  [client](https://github.com/hypothesis/client)
- [Embedding Hypothesis](https://web.hypothes.is/help/embedding-hypothesis-in-websites-and-platforms/)
- [Hypothesis API docs](https://h.readthedocs.io/en/latest/api/)
- [Self-hosting `h` docker-compose discussion](https://github.com/hypothesis/h/issues/4899)
- [Jon Udell, Notes for an annotation SDK](https://blog.jonudell.net/2021/09/03/notes-for-an-annotation-sdk/)
  (selector strategy: quote as arbiter, position as hint)
- [W3C Web Annotation Data Model](https://www.w3.org/TR/annotation-model/) and
  [Protocol](https://www.w3.org/TR/annotation-protocol/)
- [Apache Annotator (incubating)](https://annotator.apache.org/docs/)
- [dom-anchor-text-quote](https://github.com/akprasad/dom-anchor-text-quote)
- [Survey of self-hosted static-site comment systems](https://lisakov.com/projects/open-source-comments/)
- [Elucidate server](https://github.com/dlcs/elucidate-server)
- [Recogito Studio](https://recogitostudio.org/) and
  [text-annotator-js](https://github.com/recogito/text-annotator-js)
