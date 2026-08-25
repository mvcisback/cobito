# lit — a web-first literate programming system

**Status:** draft spec, v0.2. Nothing implemented yet.

## 1. Goals

1. **Web-first.** The primary woven artifact is a multi-page website, not a PDF. Print is not a v1 concern.
2. **noweb-compatible.** Source files are genuine `.nw` files. `notangle` consumes them unchanged. We are language-agnostic because noweb is.
3. **Static generator only.** lit is the weaver and tangler; it ships no server. Margin commenting is a **separate tool** with its own spec, `ANNOTATIONS.md`; lit's sole obligation to it is annotation-ready HTML (§9).
4. **JSON is the contract.** Every HTML page is a pure function of a JSON document. No exceptions.
5. **Review loop.** An AI agent reads annotations (W3C Web Annotation JSON, from whichever backend `ANNOTATIONS.md` lands on) and proposes revisions to the `.nw` source.
6. **Self-hosting.** `lit` is eventually written in itself: `lit.nw` tangles to the Rust crate.

## 2. Non-goals

- PDF/print output (a `--tex` backend may come later; §6.6).
- Pretty-printing or syntax-aware code formatting, including syntax highlighting. Code chunks are text — noweb's position, and we keep it. Reconsidered during M1 and reaffirmed; the reasoning is in §5.4.
- cweb's `@d` macros. noweb has no equivalent because `#define` is C-specific. Named chunks cover the need.
- A WYSIWYG authoring UI.
- A comment/annotation server — that is a separate tool (`ANNOTATIONS.md`), and possibly an adopted one rather than ours.
- Multi-user real-time collaboration. Comments are asynchronous.

## 3. Vocabulary

| Term | Meaning |
|---|---|
| **project** | A directory with a `lit.toml`. Contains one or more documents. |
| **document** | An ordered list of `.nw` files woven into one site with unified numbering. Has an id, used in URLs. |
| **chunk** | noweb's unit: a *docs chunk* (prose) or a *code chunk* (named, tangleable). |
| **section** | Our unit of anchoring and rendering. One chunk → one section. |
| **page** | An output HTML file. Contains a contiguous run of sections. |
| **root** | A code chunk that tangles to a file on disk. |

A document is deliberately allowed to span several `.nw` files, because `markup` accepts several and emits `@file` markers between them. Numbering, labels, and chunk resolution are document-wide.

## 4. Architecture

We shell out to noweb's **front end**, not its back end. `markup` converts `.nw` into noweb's line-oriented pipeline format; we consume that as our IR and own everything downstream.

```
  PHASE 1 — static generator (no Python, no server)

  *.nw ──> markup ──> pipeline IR ──┐
                                    │
   ┌────────────────────────────────┴───────────────────────────┐
   │ Rust                                                        │
   │  1. parse IR       → chunk list                             │
   │  2. resolve        → chunk graph, defs/uses, continuations  │
   │  3. prose pipeline → §6.2 (math out, HTML parse, refs, ids) │
   │  4. number         → figures, tables, equations, chunks     │
   │  5. split          → pages, nav tree, prev/next             │
   │  6. serialize      → site.json                              │
   │  7. render         → minijinja + templates/                 │
   └────────────────────────────────┬───────────────────────────┘
                                    │
                              _site/{*.html,*.json,static/}

  *.nw ──> notangle -R'src/main.rs' ──> src/main.rs


  ANNOTATION LAYER — separate tool, separate spec (ANNOTATIONS.md)

  _site/*.html ──(overlay / embed)──> margin comments on woven pages
        │  HTML carries provenance attributes (§9)
        ▼
  annotations (W3C JSON) ──> lit review ──> unified diff against *.nw
```

We do **not** use `noweave`. §6 establishes that we own prose→HTML regardless, and the pipeline format hands us chunk structure as *data* rather than as generated markup we would have to re-derive by scraping anchor names noweb makes no stability promise about.

### 4.1 The IR

`markup` emits one tagged line per token:

```
@file lexer.nw
@begin docs 3
@text <p>The lexer emits one token per call.</p>
@nl
@end docs 3
@begin code 4
@defn lex a token
@nl
@text let c =
@use next char
@nl
@end code 4
```

Tags we consume: `@file`, `@line`, `@begin`/`@end docs|code`, `@text`, `@nl`, `@defn`, `@use`, `@quote`/`@endquote` (from `[[...]]`), `@literal`, `@index defn`, `@fatal`.

`markup` necessarily emits `@defn` and `@use` for chunk definitions and references, because `notangle` is itself just `markup | nt` and `nt` consumes exactly those. So chunk structure is reliable without any filter.

`finduses` and `noidx` serve the *identifier* index (`@ %def` hints, `@index use`), not chunk structure. **v1 skips both** and ships no identifier index; they come back in M-later if we want one.

### 4.2 Verified against noweb 2.13 (nixpkgs)

R1 is retired. Facts established by probing the real toolchain with `fixtures/hello.nw`:

- **The pipeline tools are not on `bin/`.** `markup`, `nt`, `tohtml`, etc. live in `lib/noweb/`; only `notangle`/`noweave`/`noroots`-style drivers are on `bin/`. The Nix wrapper must expose `${noweb}/lib/noweb`.
- **No `@line` markers by default.** Line numbers are derived by counting `@nl` since the last `@file` — the same thing `nt` does for `-L`. Our IR parser tracks this for diagnostics (§12).
- `@ %def c` becomes `@index defn c` (+ `@index nl`) and produces **no docs chunk**.
- Continuations appear as separate `@begin code` blocks sharing a `@defn` name, in source order.
- `[[v[[0]]]]` yields quote content `v[[0]]` — `[[…]]` matches greedily to the last `]]`.
- Blank lines between chunks become **empty docs chunks** (and a leading empty `docs 0`); the section builder merges/drops them.
- Inside code, leading indentation before a `@use` arrives as a separate `@text` — this is how indentation propagation works.
- **Errors:** `markup` prints `file:line: message` to stderr, emits `@fatal` in the stream, and exits nonzero. The wrapper must check both.
- **`<<` unescaped in a docs chunk is a fatal error.** The escape is `@<<…@>>`, which arrives as literal `<<…>>` text.
- `\$` in prose passes through untouched — the `\$` escape in §6.2 is entirely our convention.
- `noweave -index` anchors are content-hash-flavored (`NWy21p0-2uYzsi-1`) and injected into the prose itself, confirming that scraping woven HTML was the wrong layer.

### 4.3 Correction: we do need an HTML parser

An earlier draft claimed the pipeline format lets us avoid one. That was wrong. Phase 1 must find `<h1>` boundaries for page splitting, inject `id` attributes, number `<figure>`/`<table>`, rewrite `data-ref` placeholders, and hoist `<aside>` margin content. All of that is tree surgery on the prose.

Use **`lol_html`** (streaming rewriter, CSS-selector handlers) if the operations stay local, or **`html5ever`/`markup5ever_rcdom`** if we need real tree access for numbering across the document. Numbering is document-global but each rewrite is node-local, so `lol_html` in two passes (collect, then rewrite) is likely sufficient and much lighter.

> **Open question G — resolved (M2): `lol_html`, two passes.** Every rewrite M2 needs is node-local once the *answers* (numbers, anchors, page assignments) are known document-globally. So `src/rewrite.rs::scan` walks each section collecting headings, labels, ref sites, and the section's opening tag; `src/resolve.rs::plan` turns that into the global tables; `src/rewrite.rs::apply` walks each section a second time and stamps the results. No DOM is ever materialized. The one wrinkle: `lol_html` fires handlers on *start* tags, so a figure's number is computed when `<figure>` opens and handed to the `<figcaption>` handler through a one-slot cell — the number must land on the caption because CSS `attr()` cannot read an ancestor's attribute (see §7).

## 5. Surface syntax

Exactly noweb. No extensions.

```
@ <p>This is a documentation chunk. In v1 the prose is HTML.</p>
<p>We refer to [[inline_code()]] and write math like $O(n \log n)$.</p>

<<lex a token>>=
let c = <<next char>>;
@ %def c

<<src/lexer.rs>>=
<<lexer imports>>
<<lex a token>>
@
```

| Construct | Meaning |
|---|---|
| `@` + space/newline | begin documentation chunk |
| `<<name>>=` | begin code chunk definition |
| `<<name>>` (in code) | chunk reference, expanded by tangle |
| `[[...]]` | quoted code inside prose → `@quote` in the IR |
| `@ %def x y` | index hints (parsed, unused in v1) |
| `@<<`, `@>>` | literal `<<`/`>>` in prose — **required**: an unescaped `<<` in a docs chunk is a fatal `markup` error |

### 5.1 Chunk continuation

noweb allows `<<name>>=` to appear repeatedly; later definitions **append**. This matters in three places and is easy to get wrong:

- **Tangle:** concatenate in source order. `notangle` handles it.
- **JSON:** `chunks[name].defs` is an ordered list; each section carries `continues: true` when it is not the first.
- **Render:** show `<<name>>+=` for continuations, matching noweb's convention, and link back to the first definition.

### 5.2 Root chunks

A chunk whose name is path-shaped (contains `/`, or matches `*.<ext>`) is a **root**. `lit.toml` overrides and, critically, sets the line-pragma format per root:

```toml
[[document]]
id = "lit"
title = "lit: a literate programming system"
authors = ["…"]
files = ["intro.nw", "parser.nw", "weave.nw"]
dialect = "markdown"   # or "html"; default "markdown" (§6.1)

[tangle]
outdir = "."

[[tangle.root]]
chunk = "src/lexer.rs"
# Rust has no line-pragma syntax; emit none.
line-pragma = false

[[tangle.root]]
chunk = "server/app.py"
line-pragma = '# %L "%F"%N'
```

`notangle -L` takes a printf-ish format, and the correct format is **language-specific** — its default is C's `#line`. A single boolean `line-pragmas = true` (as in v0.1 of this spec) is wrong: it would emit `#line` into Python and Rust. Per-root format, defaulting to *off*.

Verified caveat: **`-L` disables indentation propagation** (inner chunk lines land at column 0) and splits code around chunk uses onto separate lines with column-preserving padding, so pragma'd output is differently shaped, not just annotated. Acceptable for generated code; the default-off choice stands.

### 5.3 Page boundaries

noweb has no starred-section concept — cweb's section levels don't exist here. We split on the prose:

```toml
[weave]
split-at = "h1"       # the rendered heading level; Markdown `#` and HTML <h1> both
nav-depth = 3         # nav tree includes h1..h3
```

Everything before the first boundary is the index page. A code chunk always belongs to the page of the most recent preceding boundary — chunks never start a page.

### 5.4 Rendering a code chunk

```html
<section class="code" id="sec-2" data-nw-file="…" data-nw-line="6" data-chunk="lex a token">
  <div class="margin-slot" data-for="sec-2"></div>
  <details class="chunk" open>
    <summary><span class="chunk-name">&lt;&lt;<dfn>lex a token</dfn>&gt;&gt;=</span></summary>
    <pre class="chunk-body">
      <span class="line" data-line="7">let c = <a href="#sec-8">&lt;<i>next char</i>&gt;</a>;</span>
      <span class="line" data-line="8">tokens.push(c);</span>
    </pre>
  </details>
</section>
```

Three decisions, all satisfiable with zero client JS:

**Collapsible, open by default.** `<details open>`. The reader folds a chunk away; nothing is hidden from someone who never touches it, and the collapsed state is not persisted (no JS, no storage). The header lives in the `<summary>`, which matters for cross-references: `<a href="#sec-8">` targets the `<section>`, not the `<details>`, so a link into a *collapsed* chunk still scrolls to a visible element that names the chunk. Auto-expanding a closed `<details>` on fragment navigation is currently Chromium-only, so we do not depend on it — that structure is what makes the Gecko/WebKit behavior merely suboptimal rather than broken.

**Line numbers are `.nw` source lines,** not per-chunk 1..n. The number a reader sees is the number they type into an editor, and it matches `data-nw-line` provenance and any `notangle -L` pragma. A continuation chunk therefore restarts at its own source line (16 in the fixture), which is the honest answer: the two halves of `lex a token` are not contiguous in the source.

They are rendered as **CSS generated content** — `data-line` on the span, `content: attr(data-line)` in the stylesheet — never as text nodes. This is not cosmetic. Text-node numbers would be copied along with a code selection, and they would appear inside the exact-quote selectors the annotation layer anchors with (§9.2), so re-weaving a file after an edit above it would orphan every annotation on the code below. Generated content is invisible to both.

**No syntax highlighting.** The §2 non-goal stands as written. Highlighting is feasible (syntect has a pure-Rust engine) but it buys colored keywords at the cost of a lexer that does not understand chunk uses — `let c = <<next char>>;` is not Rust, and `<<` lexes as a shift operator — plus a dependency, a theme decision, and a per-root language configuration. Considered and declined; revisit only if reader feedback demands it.

## 6. The prose layer

noweb does not solve this. `tohtml` passes prose through **verbatim** — it assumes you wrote HTML. `l2h` translates a hardcoded LaTeX subset, does not expand user macros, and approximates math as italics.

### 6.1 Two prose dialects

A docs chunk is authored in one of two dialects, selected per document by
`dialect` in `lit.toml` (§5.2):

- **`markdown`** (the default) — prose is CommonMark. Paragraphs, emphasis,
  lists, links, headings, and backtick code become HTML; the fenced directives
  ```` ```math ````/```` ```figure ````/```` ```table ```` are labelled, numbered
  floats and `\ref{…}` is a cross-reference. This is the ergonomic dialect (§6.4).
- **`html`** — prose is raw HTML, which is exactly what noweb's HTML path is
  designed for. This is the escape hatch, and it is what any construct the
  Markdown directives don't cover (e.g. a `<aside class="sidenote">`) falls back
  to as a *raw-HTML island* (§6.4).

Both dialects share one pipeline (§6.2): Markdown is a **post-`markup`
transform** on already-reassembled prose, slotting in after math extraction and
before the HTML rewrite. Everything downstream — numbering, refs, math render,
sidenote hoist, `site.json` — is dialect-agnostic and byte-identical.

### 6.2 The prose pipeline (ordering is load-bearing)

Per docs chunk, in this order:

1. **Reassemble.** Concatenate `@text`/`@nl`; convert `@quote…@endquote` to `<code>` with the contents HTML-escaped. Escaping here, before anything else, is what makes `[[<div>]]` safe.
2. **Extract math.** Scan for `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, replacing each with an opaque placeholder token. Must happen **before** HTML parsing so that `$a < b$` is not read as a malformed tag.
   - **Not** scanned: inside `<code>` produced in step 1, or inside any `<pre>`/`<code>` the author wrote. A literal `$` elsewhere is escaped `\$` — our convention, not noweb's; `markup` passes `\$` through untouched and the extractor unescapes it.
   - Delimiter set is configurable; `\(`/`\[` are accepted but `$` is idiomatic in HTML mode.
3. **Parse HTML.** Now the input is well-formed and math-free.
4. **Rewrite.** Inject section `id`s, assign numbers to `<figure>`/`<table>`/equations, resolve `data-ref`, hoist `<aside class="sidenote">` into the section's `margin` array.
5. **Serialize.**
6. **Render math.** Replace placeholders with KaTeX output.

Steps 4–6 need document-global numbering, so the whole document is processed through step 3 before any section reaches step 4. Weave cannot stream.

**Where Markdown slots in.** In `markdown` mode the CommonMark render runs
*between steps 2 and 3*, on the reassembled prose: fenced blocks are protected
first (so neither the math scanner nor CommonMark touches their bodies), then
step 2's `extract_math` runs on the remaining text, then CommonMark renders. The
math placeholders and any raw-HTML islands are inert HTML that CommonMark passes
through untouched, so step 3 onward sees the same shape as HTML mode. Ordering
detail lives in §6.4.

**Sanitization.** Not applied to prose — the author is the trusted party. Comment bodies are the annotation layer's problem (`ANNOTATIONS.md`), rendered in its overlay, never merged into lit's output.

### 6.3 Math rendering

KaTeX, rendered **server-side at weave time**, so the archival site needs no JavaScript.

The `katex` Rust crate bundles a JS engine to run `katex.js`. That is a meaningful build-weight and Nix-closure cost. Alternatives: shell out to a `katex` CLI (another runtime dep, worse), or a native Rust TeX-math renderer (immature). Take the crate, and **cache rendered output keyed by `hash(math_source + display_mode + macros)`** in `.lit-cache/`, since re-rendering every equation on every weave will dominate build time otherwise.

Failures are hard errors with the offending source and location, never silent fallback to raw text.

**Verified (2026-08-23), and the reason assets are not optional.** "No client-side
JavaScript" and "no client-side assets" are different claims; we get the first
for free and must work for the second.

- The crate runs `katex.js` inside our binary at weave time. Output is inert
  markup — a hidden `<span class="katex-mathml">` carrying MathML, plus a
  `<span class="katex-html" aria-hidden="true">` visual layer. No `<script>`
  reaches the site. `checks.determinism` asserts this.
- The default `htmlAndMathml` output **requires `katex.min.css` and the woff2
  fonts, for correctness, not looks**: the stylesheet is what hides the MathML
  layer, so without it *both* layers render and every equation appears twice.
- Therefore assets are **copied into `_site/katex/`, never CDN-linked** —
  otherwise the archival artifact silently depends on the network. woff2 only
  (~330 KB); shipping woff/ttf too would multiply that for no reader.
- **Version coupling.** KaTeX's HTML, CSS, and font metrics move together. The
  crate embeds KaTeX **0.16.4**, while nixpkgs' `katex` is a different release
  (0.16.25 at time of writing), so the assets are pinned in `flake.nix` by
  `fetchzip` at the crate's version and exposed as `LIT_KATEX_ASSETS`. Bump the
  crate and the pin together.

**Considered and rejected for v1:** `OutputType::Mathml` emits pure MathML
(292 bytes vs 867 for our sample), needing no CSS, no fonts, and no JS — a
genuinely single-file artifact. Rejected because browser-native math typography
is markedly weaker than KaTeX's CSS layout, and typographic quality is the
point of a Tufte-styled site. Revisit if a zero-asset artifact ever outranks
typography. Note the `<annotation encoding="application/x-tex">` element
preserves the original TeX in every output mode, which is what makes math
copy-pasteable and is relevant to `ANNOTATIONS.md` AN-2.

### 6.4 The Markdown dialect

The ergonomic prose dialect is **CommonMark**, not LaTeX. Hand-wrapping every
paragraph in `<p>…</p>` and every display equation in `<div class="equation">`
is the dominant keystroke cost of HTML mode (§18 R5); Markdown removes it while
keeping the pipeline shape unchanged. It **replaces** the originally-specced
bounded LaTeX expander: Markdown is more ergonomic than raw HTML and lets us
drop the hardest part of the plan — the bounded TeX *text* expander — entirely.
Only the math-only macro table survives, as roadmap (§6.5).

Rendering is CommonMark core via `pulldown-cmark`, run as a post-`markup`
transform (§6.2). GFM tables are enabled **only** inside a `table` fence, never
in bare prose (a stray `|` stays literal). In order:

1. **Protect fenced blocks.** The fence info line is `<kind> [\label{ns:name}]`.
   Three *directives* are recognised — `math`, `figure`, `table`; any other info
   is an ordinary code fence (`<pre><code class="language-…">`, stashed so step 2
   never scans it for `$`). Each float is rendered now and either emitted in
   place (`math`) or stashed behind a placeholder (`figure`/`table`, since their
   bodies are multi-line HTML the outer CommonMark must not reflow).
   - ```` ```math ```` — display-math sugar. Body is bare LaTeX (the fence *is*
     the delimiter, so `$` is not scanned), pushed as `Math{display:true}` and
     emitted as `<div class="equation"[ id]><span data-lit-math="N"></span></div>`.
   - ```` ```figure ```` — an optional leading brace-balanced `\caption{…}`
     (rendered inline Markdown+math), then block-Markdown body → `<figure[ id]>…
     [<figcaption>…</figcaption>]</figure>`.
   - ```` ```table ```` — an optional `\caption{…}`, then a GFM pipe table; the
     `id` and a `<caption>` are spliced into the `<table>` pulldown-cmark emits.
2. **Lower `\ref{ns:name}`** to `<a data-ref="ns:name"></a>` — the very site the
   HTML dialect and resolver (§7) already handle, so fence- and hand-authored
   references are identical. Runs on raw prose skipping `<code>`/`<pre>`; a `\ref`
   inside a *backtick* span is a documented no-op (write it in `html` mode).
3. **Extract math** (§6.2 step 2) on the remaining prose: inline `$…$` etc.
   Float-derived math indices come first, inline after; both resolve at render.
4. **Render CommonMark → HTML.** Backtick spans and reassembled `[[…]]` both
   become `<code>`; math placeholders, stashed floats, and raw-HTML islands pass
   through; stashed floats are then swapped back in.

**Labelling and namespaces.** `\label{ns:name}`'s namespace must match the fence
kind — `eq:` for `math`, `fig:` for `figure`, `tbl:` for `table` — because the
rewrite pass keys a label off its `id` prefix (§7); a mismatch would be silently
dropped, so it is caught as **E030** at render time. A float without a `\label`
gets no id and is not referenceable — an unreferenceable float has no stable
identity (§7.1). Because a fenced float emits exactly the same
`<figure id>` / `<table id><caption>` / `<div class="equation" id>` an island
would, all downstream identity/resolution is unchanged from HTML mode.

**Raw-HTML islands still work.** CommonMark passes block-level raw HTML through
untouched, so anything a directive does not cover — most commonly a
`<aside class="sidenote">` — is written as raw HTML dropped inside the Markdown.
`examples/ring.nw` is the worked example; `fixtures/md.nw` is the end-to-end
fixture exercising all three directives and `\ref`.

### 6.5 The macro split (roadmap)

Math is **never** touched by lit — captured verbatim, handed to KaTeX. When
math macros arrive (roadmap, §16), `\def` (global) / `\let` (file-scoped)
bodies that are math-only are harvested into a document-level table and passed
to KaTeX as its `macros` option; KaTeX has its own expander. Because Markdown
replaced the text-mode expander, this math-only table is the *entire* remaining
macro story — lit owns no text-mode macros.

### 6.6 Optional `.tex` backend

Deferred, and lower priority now that the prose dialect is Markdown rather than
LaTeX: a `.tex` backend would have to translate CommonMark, not pass a shared
LaTeX source through. Revisit only if print output becomes a goal.

## 7. Labels, numbering, cross-references

Identity is **document-global**, so references work across pages. This section
describes the model as built through M2. **§7.1 (M11, now implemented) supersedes
the display-numbering half of it** for the living-document/forest goal: a
reference shows a *stable opaque id* (Forester-style), not a position-dependent
"Figure 3". The anchoring/caption mechanics below survive unchanged; what changed
is what the id *is* (an assigned sequential number → a frozen random id) and the
attribute that carries it (`data-number` → `data-id`). Read the v1 prose below
for the mechanism, then §7.1 for the identity it now stamps.

v1 spelling uses attributes, since prose is HTML:

```html
<figure id="fig:pipeline">
  <img src="pipeline.svg">
  <figcaption>The weave pipeline.</figcaption>
</figure>

See <a data-ref="fig:pipeline"></a>.
```

At weave time `data-ref` becomes `<a href="parsing.html#fig-pipeline">Figure k3f9</a>`, with link text supplied from the target's kind and its opaque id (§7.1; v1 used a sequential number). Author-supplied link text is preserved if present. Hrefs are **relative**: a same-page target is a bare `#anchor`; a cross-page target is `page.html#anchor`. The colon in a label id (`fig:pipeline`) becomes a dash in the emitted anchor (`fig-pipeline`), because a colon needs escaping in every CSS selector that touches it.

- **Namespaces by prefix:** `eq:`, `fig:`, `tbl:`, `sec:`, `chunk:`. An id without a known prefix is not a numbered target.
- **Numbering scheme:** configurable `flat` (Figure 7) or `by-page` (Figure 3.2); default flat, since page boundaries are a presentation choice and should not leak into stable references. M2 implements `flat`.
- Equations are numbered by default; `<div class="equation" data-nonumber>` opts out.
- Figures and tables require a caption. Missing caption is a lint warning (W103), not an error.
- **Duplicate labels are a hard error (E014).** So is a `data-ref` to an unknown label (E015).

`chunk:` targets are synthesized from chunk names, so prose can link to code; the anchor is the chunk's first defining section (`sec-N`) and the default link text is the chunk name.

**Identity never enters a text node.** Like code line numbers (§5.4), a float's id lands in an attribute and the stylesheet draws it — under M11 that attribute is `data-id` (the frozen opaque id of §7.1; v1 used `data-number`): `figcaption[data-id]::before { content: "Figure " attr(data-id) }`. This keeps the annotation layer's quote selectors (§9.2) stable when a figure moves earlier in the document — and, crucially, the opaque id does not change at all when it moves. Because `attr()` reads only the element's own attributes, the id is stamped on the *caption* (`<figcaption>`, `<caption>`), not the `<figure>`/`<table>` container; equations carry it on the `.equation` div itself and render it with `::after`.

CSS counters were rejected: they reset per document, and each lit **page is a separate HTML file**, so a counter could not produce a document-global identity on the second page. The attribute holds the globally-assigned id instead — which under §7.1 is minted once and frozen, so it is stable across documents too, not merely across pages.

### 7.1 Stable opaque ids and the lock file (M11)

lit is meant to be a **living document**, and eventually a **forest**: separate
projects import and transclude each other's notes (§16, M12). A
position-dependent "Figure 3" cannot survive that — it changes the moment content
moves within a document or is pulled into another one. So the **identity** of a
figure, table, or equation is not its position but a **frozen opaque id**, and a
reference renders **kind-qualified with that id** ("Figure k3f9"), Forester-style,
not "Figure 3". This subsection supersedes the numbering half of §7; the
anchoring, `data-*`, and caption mechanics there survive unchanged.

**The id.** A random **4-character base62** string (`[0-9A-Za-z]`, case-sensitive,
≈14.8M space). It is minted once and never recomputed. It is deliberately **not**
derived from the label, path, or content — a derived id would change under exactly
the renames and moves it exists to survive. Namespacing the id space is a future
discussion (§16); 4 chars is enough for a hobby-scale forest.

**Author-facing labels stay.** Authors keep writing a human-readable
`\label{fig:pipeline}` / `\ref{fig:pipeline}` (§6.4). The label is **note-local**:
two notes may both use `fig:pipeline` without colliding, because the label is only
ever resolved relative to its own file. The opaque id is **global**.

**Reference scope split.**
- *Within a file*, a `\ref{fig:pipeline}` resolves by the human label.
- *Across files* (import/transclude, M12), a reference names the target by its
  **opaque id** — the id is rename- and move-proof, whereas a note-qualified human
  label would break the moment the target's author renamed it.

**The lock file (`lit.lock`).** A committed, human-readable, greppable file mapping
`label → { id, kind }`, keyed by source file so note-local labels stay distinct:

```toml
# lit.lock — generated; edit only to delete a retired label.
["parser.nw"]
"fig:pipeline" = { id = "k3f9", kind = "figure" }
"tbl:api"      = { id = "7g2A", kind = "table" }
"eq:wrap"      = { id = "Qx0m", kind = "equation" }
```

`kind` is carried from the fence/tag (the fence already knows it is
figure/table/math), **not** parsed off the id. The `fig:`/`tbl:`/`eq:` label prefix
survives only as the E030 human sanity check (§6.4); it no longer determines
numbering or identity.

**Mint on miss, write back.** A normal `weave` mints an id for any label missing
from the lock and rewrites `lit.lock` (a dev-time side effect, like updating a
dependency lockfile). On a collision with an existing id it re-rolls.

**`--locked` frozen mode.** Weave must stay a byte-deterministic function of its
inputs (§8), and CI / the Nix sandbox run against a read-only source tree. `weave
--locked` therefore **never mints**: a label absent from `lit.lock` is a hard error
(E031), mirroring `cargo --locked` against `Cargo.lock`. `nix flake check` weaves
`--locked`; the committed lock is what makes the RNG mint reconcile with
determinism.

**Discovery — "how do I know the id before the first weave?"** By construction the
id is random and persisted, so it cannot be computed; discovery is via tooling, not
derivation. Minting is its own fast pass (`lit lock`, no full weave) that populates
`lit.lock`, and the committed lock is greppable. Lookups: `lit labels <file>` lists
a file's `label → id`, `lit id <file> <label>` prints one id for scripting.

## 8. Document model (the JSON contract)

`site.json` is the single source of truth, produced by Phase 1 and consumed unchanged by Phase 2.

```jsonc
{
  "schema": 2,
  "meta": {
    "id": "lit",
    "title": "…",
    "authors": ["…"],
    "source_files": ["intro.nw", "parser.nw"]
  },
  "nav": [
    { "id": "parsing", "title": "Parsing", "level": 1,
      "children": [ { "id": "parsing#lexing", "title": "Lexing", "level": 2 } ] }
  ],
  "labels": {
    "fig:pipeline": { "id": "k3f9", "page": "parsing", "anchor": "fig-pipeline",
                      "kind": "figure" }
  },
  "chunks": {
    "lex a token": {
      "slug": "lex-a-token",
      "root": false,
      "defs": [ { "page": "parsing", "anchor": "sec-4", "continues": false } ],
      "uses": [ { "page": "parsing", "anchor": "sec-7" } ]
    }
  },
  "pages": [
    {
      "id": "parsing",
      "title": "Parsing",
      "prev": "intro", "next": "codegen",
      "sections": [
        { "id": "sec-3", "kind": "docs",
          "source": { "file": "parser.nw", "line": 41 },
          "html": "<p>The lexer emits…</p>",
          "margin": [ { "kind": "sidenote", "id": "sn-1", "html": "…" } ] },

        { "id": "sec-4", "kind": "code",
          "name": "lex a token", "continues": false,
          "source": { "file": "parser.nw", "line": 47 },
          "html": "<pre class=\"chunk\">…</pre>",
          "defines": ["c"], "uses": ["next char"] }
      ]
    }
  ]
}
```

**`schema` is versioned** and checked by any consumer (the review agent, external tools) before use; a mismatch is a hard failure, not a runtime surprise. **Schema 2 (M11)** replaces each label entry's position-dependent `"number"` with the frozen `"id"` from `lit.lock` (§7.1); the entry now carries `{ id, page, anchor, kind }`. A reference's display text ("Figure k3f9") is derived from `kind` + `id`, so no numeric field remains in the contract.

**No `generated` timestamp.** A wall-clock field would make output non-reproducible, defeating Nix caching and turning every re-weave into a noisy diff of the archival artifact. Weave must be a deterministic function of its inputs — this is a testable property and M0 asserts it. (A commit/revision provenance field was considered and cut from v1: it is not load-bearing, and under a colocated jj+git repo there is no reliably-exported git ref to read.)

Per-page JSON is this object with `pages` narrowed to one entry; `nav`, `labels`, and `chunks` are retained in full so a page renders standalone. Nothing else ever writes into `site.json` — annotations live entirely outside it (`ANNOTATIONS.md`).

## 9. Annotation-ready HTML (the contract with the annotation layer)

Commenting is **not lit's job**. It belongs to a separate tool — adopted or built — specced in `ANNOTATIONS.md`. What lit owes that layer is HTML it can anchor to reliably, plus room in the layout to render. Three obligations:

### 9.1 Provenance attributes

Every rendered section element carries its identity and source coordinates:

```html
<section class="docs" id="sec-3" data-nw-file="parser.nw" data-nw-line="41">…</section>
<section class="code" id="sec-4" data-nw-file="parser.nw" data-nw-line="47"
         data-chunk="lex a token">…</section>
```

These are the bridge from an annotation on the *woven page* back to the *`.nw` source* the review agent must patch. From M4 on they are part of the frozen contract, alongside `site.json`.

### 9.2 Anchoring-friendly rendering

The annotation layer anchors with W3C selectors (exact text quotes with prefix/suffix context, hinted by text positions — see `ANNOTATIONS.md`). lit keeps that reliable by construction:

- Section `id`s and chunk slugs are stable across re-weaves: they derive from `markup`'s chunk numbering and chunk names, never from layout or page assignment.
- Nothing decorative is a text node. Code line numbers are CSS generated content (§5.4), so a quote selector over a code chunk sees exactly the program text — not text that shifts every time a line is inserted earlier in the file.
- KaTeX renders server-side (§6.3), so the text a selector sees is final at page load — no JS-timing dependence.
- Renumbering (a new figure shifting "Figure 3" to "Figure 4") changes only generated reference *text*, never element ids, so quote-based selectors on surrounding prose survive.

### 9.3 Margin room and embed slot

- The Tufte layout reserves the right margin, and every section renders an empty `<div class="margin-slot" data-for="sec-N">` that an annotation overlay may mount into. How sidenotes and comment threads share that space is the overlay's problem (`ANNOTATIONS.md`), but the slot guarantees it has somewhere to live.
- `lit.toml` can inject an embed snippet into every page, so adopting a hosted annotator is zero-code:

```toml
[weave.annotate]
embed = '<script src="https://hypothes.is/embed.js" async></script>'
```

The archival site stays fully readable with the overlay absent — annotation is progressive enhancement by construction.

## 10. AI review agent

`lit review` (CLI):

1. Fetch open annotations as **W3C Web Annotation JSON** from the configured backend. Backends are adapters (`[review] source = "hypothesis"` with group id + API token, or whatever `ANNOTATIONS.md` lands on); the agent codes against the W3C shape only.
2. Map each annotation to source: its exact-quote selector locates the text on the woven page; the enclosing section's `data-nw-file`/`data-nw-line` (§9.1) locate the `.nw` region. Build context: `.nw` source, the anchored section's rendered prose, the thread text.
3. Ask for a **unified diff against the `.nw` source** — never against woven HTML.
4. **Validate:** patch applies cleanly; `lit weave` still succeeds; `lit tangle` output is unchanged unless a thread explicitly asked for a code change.
5. Present as a reviewable diff. **Nothing auto-commits.**
6. On acceptance, addressed threads resolve with a pointer to the resulting revision.

The tangle-unchanged check in step 4 is the important safety property: prose feedback must not silently alter the program.

> **Open question C.** One patch per run, or per thread? Per-thread accepts granularly but conflicts when threads touch the same prose. Lean toward one per run with per-thread attribution in the diff.

## 11. Tangle

v1 shells out to `notangle`:

```
lit tangle <file.nw>…   # every root chunk, to --out (default .)
lit tangle -R 'name'    # single chunk to stdout
lit tangle --check      # tangle to memory, diff against disk, nonzero if drift
```

`--check` exists for CI and for the self-hosting flip (§13).

Roots are the path-shaped chunk names the model already detects and files come
from the CLI (as `weave`). Per-root `-L` line-pragma formats are read from
`lit.toml` (M4, §5.2) and default off; `[tangle] outdir` supplies the default
output directory when `--out` is absent. Reading the root/file *set* from
`lit.toml` (rather than the model + CLI) is still deferred — no task needs it.

Writes go through a temp-file-and-rename, and are skipped when content is unchanged, so build systems watching mtimes do not rebuild spuriously (noweb ships `cpif` for exactly this reason).

Correct by construction, zero implementation risk. Cost: a runtime dependency on noweb, and no single static binary.

**noweb stays in the pipeline indefinitely.** Reimplementing `markup` and `notangle` in Rust is a *contingency*, not a scheduled milestone — we do it only when the dependency actually costs us something. Concrete triggers, any one of which justifies the work:

- Process-spawn latency dominates weave time on a real document (measure; caching may fix it first).
- We need distribution to non-Nix users where a static binary is the difference between adoption and not.
- A noweb version difference breaks the golden tests (R1) and upstream is unresponsive — noweb is stable and largely unmaintained, which cuts both ways.
- We need IR information `markup` does not expose, and preprocessing around it becomes more code than replacing it.

Until one of those bites, the dependency is a feature: it is a correct, battle-tested implementation we did not write, and it keeps `.nw` compatibility honest by construction rather than by test. When the time comes, the fixture corpus in §15 is already the acceptance test — differential byte-equality against `notangle`.

## 12. Diagnostics

One format for every error, from every stage:

```
error[E014]: duplicate label `fig:pipeline`
  --> parser.nw:118:6
   |
   = note: first defined at intro.nw:42:6
```

- Errors carry a stable code so they can be tested and suppressed individually.
- Source locations come from the IR's `@file`/`@line`, which is why those tags are consumed even though tangle handles pragmas itself.
- **Lints** (missing caption label, chunk defined but never used, empty docs chunk) are warnings; `--deny-warnings` for CI.
- `lit weave --explain E014` prints the long form.

## 13. Self-hosting path

1. `lit` written normally in Rust.
2. Once weave and tangle are stable, port module by module into `lit.nw`, tangling into the existing tree. CI runs `lit tangle --check`, asserting the committed source matches what the literate source produces.
3. Flip: `lit.nw` becomes the source of truth; checked-in tangle output is the bootstrap, regenerated by the previous release.

The bootstrap must always be buildable without a working `lit`, so the tangled output stays committed permanently.

## 14. Nix

Flake-based (implemented — see `flake.nix`). `pkgs.noweb` is a genuine **runtime** dependency in Phase 1 (`markup` and `notangle`), not merely a test oracle, so the CLI is wrapped to put both `${noweb}/bin` *and* `${noweb}/lib/noweb` on `PATH` — the pipeline stages are not on `bin/` (§4.2).

Current shape, deliberately minimal (plain `rustPlatform.buildRustPackage`, no extra flake inputs; crane/rust-overlay only if a concrete need appears):

```
flake.nix
  devShells.default   # cargo, rustc, rustfmt, clippy, rust-analyzer, noweb
                      # shellHook prepends ${noweb}/lib/noweb to PATH
  packages.lit        # buildRustPackage + wrapProgram; also packages.default
  checks.build        # package build, runs the hermetic cargo tests
  checks.noweb-drift  # markup output for fixtures/*.nw diffed against pinned *.markup
```

A `checks.determinism` (weave twice, byte-diff — the property §8 depends on) is added the moment `lit weave` produces output, i.e. during M1. If the in-house annotation tool is ever built it gets its own flake (or a `packages.annotations` here) per `ANNOTATIONS.md`.

Because flakes only see git-tracked files, new files must be `git add`ed before `nix build`/`nix flake check` will see them.

## 15. Testing

| Layer | Strategy |
|---|---|
| IR parser | Golden tests over pinned `markup` output; guards against noweb version drift (R1). |
| Prose pipeline | Snapshot tests per stage, especially math-extraction edge cases: `$` in `<pre>`, `$` in `[[…]]`, `\$`, `$a < b$`, unbalanced delimiters. |
| Numbering/refs | Property test — every `data-ref` resolves; numbers are dense and monotonic in source order. |
| Split | Property test — concatenating all pages' sections reproduces the document section list exactly. |
| Tangle | Differential against `notangle` on a fixture corpus. Becomes the acceptance test for the Rust reimplementation. |
| Determinism | Weave twice, diff. |
| §9 contract | Assert every section carries `id`/`data-nw-file`/`data-nw-line` and a margin slot; provenance line numbers cross-checked against `notangle -L`. |

## 16. Milestones

**Phase 1 — static generator**

| | Deliverable |
|---|---|
| **M0** | Flake; pin `markup` output for fixtures (R1); IR parser → chunk list; determinism check — **done** |
| **M1** | Prose pipeline §6.2; math → KaTeX with cache; single-page HTML — **done** |
| **M2** | Numbering, labels, xrefs; page splitting; nav tree; Tufte templates; footer pagination — **done** |
| **M3** | `lit tangle` via notangle; `--check` — **done** (per-root line pragmas deferred to M4 with the `lit.toml` parser; §5.2, §19.5) |
| **M4** | `site.json` frozen at `schema: 1`; `--archive`; sidenote hoist to `margin[]`; `lit.toml` (meta + per-root tangle pragma); `--explain`/`--deny-warnings` — **done** |

**Phase 2 — annotation integration** (the annotation layer itself is a separate tool: `ANNOTATIONS.md`)

| | Deliverable |
|---|---|
| **M5** | §9 contract: provenance attributes, margin slots, embed slot; validate end-to-end with a hosted annotator on a woven page |
| **M6** | `lit review`: Hypothesis-API adapter → W3C annotation JSON → `.nw` diff |
| **M7** | Reserved for the annotation-layer fallback — self-hosted `h` or the in-house tool, depending on which trigger fires (`ANNOTATIONS.md` §4) |

**Phase 3**

| | Deliverable |
|---|---|
| **M8** | Markdown prose dialect (§6.4): CommonMark prose + fenced ```` ```math ```` display equations; raw-HTML islands for labeled/numbered elements; `dialect` in `lit.toml` — **done** (first slice; roadmap below pulled forward from R5) |
| **M9** | Math macros (§6.5): `\def` (global) / `\let` (file-scoped) math-only definitions harvested into KaTeX's `macros` table |
| **M10** | Citations: a `cite:` numbered namespace resolved by §7's machinery, plus an auto reference list from a bib source |
| **M11** | Stable ids & the lock file (§7.1): frozen 4-char base62 id per label, committed `lit.lock` (`label → { id, kind }`), references render kind-qualified with the id, weave mints-on-miss + writes back, `--locked` frozen mode (E031), `lit lock`/`lit labels`/`lit id` tooling; `site.json` → `schema: 2` |
| **M12** | Import vs include/transclude (Forester-inspired): `import` brings another note's *definitions* into scope without rendering; `include`/`transclude` inlines another note's *rendered* content — composed at the model/prose layer, never a pre-`markup` `.nw` preprocessor (§11). Cross-note references use the opaque id (§7.1) |
| **M13** | Self-host |

**Not scheduled.** Replacing noweb with a Rust `markup`/`notangle` is a contingency with explicit triggers (§11), not a planned milestone. It is listed nowhere in this table on purpose.

## 17. Open questions

- **A** ~~Shared minijinja/Jinja2 templates?~~ **Resolved:** moot. lit has no server (commenting split into a separate tool), so minijinja is the only renderer.
- **B** ~~Section-level or character-range anchors?~~ **Resolved:** superseded by W3C selectors — annotations target arbitrary text selections; sections matter only for provenance mapping (§9.1). Residual re-anchoring concerns live in `ANNOTATIONS.md`.
- **C** (§10) One review patch per run or per thread?
- **D** Margin contention between sidenotes and comment threads — **moved** to `ANNOTATIONS.md`; lit's obligation ends at the margin slot (§9.3).
- **E** ~~Do we need `noweave`?~~ **Resolved:** no. We consume `markup`'s pipeline format and own weave entirely.
- **F** ~~v1 prose is HTML, v2 is LaTeX. Migration, or a per-document mode flag accepting both?~~ **Resolved:** a per-document `dialect` flag (§5.2/§6.1) accepting `markdown` (default) or `html`. v2 became **Markdown**, not LaTeX; the two dialects coexist and share one pipeline, so no migration is forced.
- **G** (§4.2) `lol_html` two-pass vs full DOM for prose rewriting.
- **H** Should `lit` watch and rebuild (`lit serve --watch`, a local static file server) in Phase 1? Authoring feedback loop is bad without it.

## 18. Risks

- **R1** ~~noweb IR details unverified.~~ **Retired** — verified against noweb 2.13 from nixpkgs; findings recorded in §4.2. Golden tests over pinned `markup` output remain the guard against future version drift.
- **R2** (§6.3) KaTeX-via-JS-engine build weight and weave latency. Mitigated by caching; measure at M1.
- **R3** Re-anchoring quality — **transferred** to `ANNOTATIONS.md`. Anchoring is now done by the annotation layer's selector machinery (battle-tested in Hypothesis) rather than heuristics we invent; the residual orphan-rate risk is tracked there.
- **R4** (§13) Self-hosting makes every weaver bug a bootstrap risk. The permanently-committed tangle output is the mitigation.
- **R5** ~~HTML-as-prose (v1) may prove unpleasant enough to author that it distorts judgment about the rest of the design.~~ **Fired and mitigated.** Authoring `examples/ring.nw` in HTML confirmed the `<p>`-tax; M8 (Markdown, §6.4) was pulled forward as R5 prescribed, and the LaTeX expander was dropped in favor of the more ergonomic CommonMark.

## 19. Implementation guide

This section is the handoff: enough detail to continue without the design
conversation that produced this spec. Read §4.2 first — it records verified
behavior of the real toolchain that the code already depends on.

### 19.1 State of the repo

Done (**M0, M1, M2, M3, M4 complete; M8 first slice complete**):

- `src/markdown.rs` — the Markdown dialect (§6.4). `render(prose, &mut Vec<Math>)` protects fenced blocks (```` ```math ```` → numbered equation island; other fences → `<pre><code>`), reuses `prose::extract_math` for inline `$…$`, then renders CommonMark via `pulldown-cmark` (`Options::empty()`, no GFM). Selected per document by `Dialect` in `src/config.rs` (`markdown` default, `html` escape hatch), threaded through `weave::write_site`/`render`. `examples/ring.nw` is authored in it; `fixtures/md.nw`+`md.markup` is the end-to-end pair. Existing `hello`/`book` fixtures stay pinned in `html` mode so their byte-assertions hold.

- `src/site.rs` — the §8 `site.json` model (serde), written only under `lit weave --archive`: `schema: 2` (label entries carry the frozen `id` of §7.1, not a `number`), `meta`, `nav`, `labels`, `chunks`, and `pages[].sections[]` with per-section prose `html` and (for docs) a `margin[]`. Owns the sidenote hoist — `<aside class="sidenote">` is lifted out of the JSON prose into `margin[]` with document-global `sn-N` ids, while the woven HTML keeps it inline with the same id. `to_json` is pretty + deterministic (`BTreeMap`s, no timestamps); `page_json` narrows `pages` to one, keeping `nav`/`labels`/`chunks` whole so a page stands alone.
- `src/config.rs` — `lit.toml` parser (§5.2). Reads `[[document]]` (id/title/authors/files → `site.json` `meta`, plus `dialect` §6.1) and `[[tangle.root]]` `line-pragma` (a format string or `false`; the correct format is per-language, so a boolean can only disable). Absence is not an error. E029.
- `src/lock.rs` — the §7.1 lock: `LockFile` is committed TOML keyed `file → label → { id, kind }`, with a derived `used` id-set (rebuilt on load) for O(1) collision checks. `mint` is idempotent per label and re-rolls on collision; `Minter` is a hand-rolled SplitMix64 → four base62 chars (no `rand` dep), seeded from entropy in production and `seeded()` in tests so the minting contract is deterministic there. `LockMode::{Mint, Locked}` selects mint-on-miss vs. fail-on-miss (E031). `load` treats an absent file as empty; `save` is header-commented and byte-stable. E032. `lit lock`/`labels`/`id` and `weave`'s minting loop all go through it.
- `src/diag.rs` — long-form text for `lit --explain <CODE>` (§12), keyed on the stable error registry.
- `src/tangle.rs` — `lit tangle` shells out to `notangle` (SPEC §11). Whole-document mode enumerates roots from the model and writes each via temp-file+rename, skipping unchanged content (`created`/`updated`/`unchanged`). `-R name` passes straight through to notangle and prints to stdout (the name is glued to the flag — a separate `-R name` arg is read as a file). `--check` tangles to memory and diffs against disk, exit 1 on drift. Per-root line pragmas (`-L<fmt>`, glued like `-R`) come from `lit.toml`, off by default (§5.2). E027, E028. Covered by `checks.tangle` (differential vs. notangle) since the hermetic build has no noweb on PATH.


- `src/prose.rs` — §6.2 steps 1–2 and 6: reassembly, `[[…]]` escaping, math extraction to placeholders, `\$` unescape, substitution. E022.
- `src/math.rs` — KaTeX at weave time with the FNV-1a content-hash disk cache. Cache writes are atomic (unique temp file + rename) so parallel weaves never read a half-written entry. E020.
- `src/rewrite.rs` — §6.2 steps 3–5, the two-pass `lol_html` rewriter (open question G, §4.3). Pass one (`scan`) collects headings, fig/tbl/eq labels (in document order) and their kind, and `data-ref` sites without mutating; pass two (`apply`) stamps `data-id` (the frozen opaque id from the lock, §7.1), heading ids/anchors, and resolved `href`/generated link text from the plan. E026.
- `src/resolve.rs` — document-global planning between the two passes: page assignment (first page always `index`, every later docs section opening with `<h1>` starts a page; code inherits), dash-escaped anchors, relative hrefs (`#anchor` same-page, `page.html#anchor` cross-page), the nav tree, and the W103 uncaptioned lint. E014 (duplicate label), E015 (unresolved ref).
- `src/weave.rs` — model → multi-page site: build frags → scan pass → `resolve::plan` → apply pass → math render/substitute → sidenote hoist → group sections into pages → template each. §9.1 provenance attributes and §9.3 margin slots included from the start. Always assembles the §8 `SiteJson`; `--archive` writes `site.json` + one `<page>.json` per page beside the HTML. `lit weave <files> [--out dir] [--archive] [--locked] [--deny-warnings]`; between the scan and resolve passes it mints a frozen id per label into `lit.lock` (or, under `--locked`, requires each already present — E031; §7.1). `--deny-warnings` still writes the site but exits nonzero if any lint fired (CI). Idempotent into a populated `--out` (KaTeX dst removed first, since Nix-store copies are read-only). E023–E025, E031/E032. A sibling `lit lock` mints without rendering, and `lit labels`/`lit id` read the committed lock back.
- `templates/page.html`, `templates/lit.css` — external Tufte templates via minijinja, `include_str!`'d so the binary stays self-contained. `page.html` has the recursive nav-tree macro and footer pagination; `lit.css` draws every float's identity from `data-id` (the opaque id of §7.1) and code line numbers from `data-line` (§5.4).
- `fixtures/book.nw` + `fixtures/book.markup` — the M2 golden pair: three `<h1>` boundaries, nested `<h2>/<h3>` nav, labelled figure/table/equation (plus a `data-nonumber` equation), a forward `data-ref`, a `chunk:` ref, and a sidenote. Regenerate the `.markup` the usual way (§4.2).
- `flake.nix` — KaTeX dist pinned by `fetchzip` at the crate's version, exposed as `LIT_KATEX_ASSETS`. `checks.determinism` weaves `book.nw` twice **with `--archive`**, diffs bytes (HTML *and* JSON), asserts the three page files exist, that a cross-page ref resolves to `parsing.html#fig-pipeline`, that `site.json` is `schema: 1` with per-page JSON and a hoisted `sidenote` (no `<aside>` in the JSON prose), and fails if any `<script>` appears. `checks.tangle` is the notangle differential.

- `flake.nix` — devShell, `packages.lit`, `checks.{build,noweb-drift}`. All green via `nix flake check`.
- `src/noweb.rs` — complete, tested parser for the `markup` IR (`Event` enum, `parse`, `run_markup`). `run_markup` finds `markup` on `PATH` (`LIT_MARKUP` overrides), fails on nonzero exit or `@fatal`, and surfaces noweb's own `file:line:` diagnostics.
- `src/main.rs` — CLI skeleton. `lit dump-ir <file.nw>` works end to end; `weave`/`tangle` exit 2 with a pointer here.
- `src/model.rs` — the §19.2 fold, complete and tested (`build`, `DocModel::lints`, `DocModel::roots`). E010 and W102 implemented. `lit dump-model <files>` prints it.
- `fixtures/hello.nw` + `fixtures/hello.markup` — the pinned golden pair. The `.markup` file is generated, never hand-edited: `markup fixtures/hello.nw > fixtures/hello.markup` (inside the devShell).

Verified while implementing §19.2, worth keeping: **chunk continuation must be
computed from "already has defs", not "name already in the map"** — a forward
`@use` creates the map entry before the definition is seen, which silently
marks the *first* definition of a forward-referenced chunk as a continuation.
The fixture catches this because `next char` is used in `sec-2` and defined in
`sec-8`.

Commands: `nix develop` then `cargo test` / `cargo run -- dump-ir fixtures/hello.nw`; `nix flake check` for the lot. **`git add` new files first** or nix will not see them.

### 19.2 Task: doc model (finishes M0) — **done**

Kept as the reference description of `src/model.rs`. Folds `Vec<Event>` into:

```rust
pub struct DocModel {
    pub files: Vec<String>,
    pub sections: Vec<Section>,
    pub chunks: BTreeMap<String, ChunkInfo>,   // BTreeMap: deterministic order
}
pub struct Section {
    pub id: String,          // "sec-N" where N is markup's own chunk number
    pub file: String,        // from the governing @file event
    pub line: u32,           // see counting rule below
    pub kind: SectionKind,
}
pub enum SectionKind {
    Docs { spans: Vec<ProseSpan> },
    Code { name: String, continues: bool, spans: Vec<CodeSpan> },
}
pub enum ProseSpan { Text(String), Nl, Quote(String) }
pub enum CodeSpan  { Text(String), Nl, Use { name: String } }
pub struct ChunkInfo {
    pub defs: Vec<String>,   // section ids, source order; len > 1 ⇒ continued
    pub uses: Vec<String>,   // section ids of code sections that reference it
    pub root: bool,          // path-shaped name (contains '/' or matches *.ext)
}
```

Algorithm, in event order:

1. **Line counting.** `line = 1` at each `File`; increment on **both** `Nl` and `IndexNl` (an `@ %def` line is a source line whose newline arrives as `IndexNl` — verified). A section's `line` is the counter's value at its `Begin` event. Cross-check available in the fixture: `<lex a token>` body starts at line 7, matching `notangle -L` output.
2. **Docs sections.** Collect `Text`/`Nl`/`Quote…EndQuote` runs. Drop any docs section whose spans are only whitespace `Text`/`Nl` — blank lines between chunks arrive as empty docs chunks (verified), including a leading empty `docs 0`.
3. **Code sections.** `Defn` gives the name (first event inside `begin code`, followed by one `Nl` that belongs to the definition line, not the body). Record `continues = name already seen`. Keep leading-indent `Text` before a `Use` as its own span — that is noweb's indentation-propagation mechanism; do not merge or trim it.
4. **Chunks map.** Populate `defs`/`uses` as encountered. After the walk: a `Use` of a name with no defs is **E010** (hard error, with the using section's file:line); a non-root chunk with zero uses is lint **W102**.
5. `IndexDefn` values attach to the enclosing code section (store them; unused until the identifier index lands).
6. Ignore `Line`/`Literal`/`Other` for now, but keep them parsed.

Tests: unit tests against the pinned fixture asserting — 4 code sections; `"lex a token".defs.len() == 2` with `continues == [false, true]`; `src/main.rs` is the only root; every `data` assertion from §4.2 that touches the model. Then wire `lit dump-model <files>` (debug-print the model) into main.rs alongside `dump-ir`.

### 19.3 Task: M1 — prose pipeline and first HTML — **done**

Kept as the reference description. Follow §6.2's six steps exactly; the ordering is load-bearing. Scope was:

- Reassemble docs spans; `Quote(s)` → `<code>escaped</code>` (escape `&<>"` only).
- Math extraction per §6.2 step 2, including the `\$` unescape (ours, not noweb's — §4.2). Store `(placeholder, source, display: bool)`.
- KaTeX render via the `katex` crate; content-hash cache in `.lit-cache/` keyed by `hash(source + display + macros)`. First real dependency — add with `cargo add` in the devShell; the committed `Cargo.lock` feeds the nix build automatically.
- Single-page output to `_site/index.html` through a minimal template. Choose `minijinja` now (second dependency) so templates are external files from day one: `templates/page.html`.
- Code sections render with the `<dfn>`/`+=` convention from §5.1; chunk uses inside code become links (to defs) styled like noweave's `<i>&lt;name&gt;</i>`. The chunk shell — `<details open>` plus per-line spans carrying `.nw` coordinates — was settled mid-M1 and is specified in §5.4.
- Add `checks.determinism` to the flake (weave the fixture twice into two dirs, `diff -r`).

Defer to M2: page splitting, nav, numbering, `data-ref`, Tufte CSS. M1's acceptance test is: `lit weave fixtures/hello.nw` produces an HTML file where the two math expressions render, `[[v[[0]]]]` shows as code, and the four chunks appear with correct `+=` marks.

### 19.4 Error codes allocated so far

| Code | Meaning | Where |
|---|---|---|
| E001 | malformed IR line from `markup` | `noweb.rs` (implemented) |
| E002 | `markup` failed / `@fatal` / not found | `noweb.rs` (implemented) |
| E010 | use of undefined chunk | model (19.2) |
| E014 | duplicate label | `resolve.rs` (implemented) |
| E015 | unresolved `data-ref` | `resolve.rs` (implemented) |
| E020 | math render failure | M1 |
| E021 | ~~undefined control sequence~~ (dropped — no text expander, §6.4) | — |
| E022 | unterminated math delimiter | `prose.rs` (implemented) |
| E023 | KaTeX assets missing (`LIT_KATEX_ASSETS`) | `weave.rs` (implemented) |
| E024 | writing the site failed | `weave.rs` (implemented) |
| E025 | template render failure | `weave.rs` (implemented) |
| E026 | rewriting prose HTML failed (`lol_html`) | `rewrite.rs` (implemented) |
| E027 | `notangle` failed / not found | `tangle.rs` (implemented) |
| E028 | writing tangled output failed | `tangle.rs` (implemented) |
| E029 | `lit.toml` unreadable or malformed | `config.rs` (implemented) |
| E030 | malformed fenced-float directive (`\label`/`\caption`, namespace) | `markdown.rs` (implemented) |
| E031 | label absent from `lit.lock` under `--locked` (§7.1) | `lock.rs`/`weave.rs` (implemented) |
| E032 | `lit.lock` unreadable, malformed, or unwritable (§7.1) | `lock.rs` (implemented) |
| W102 | chunk defined but never used (non-root) | model (19.2) |
| W103 | figure or table without a caption | `resolve.rs` (implemented) |

Follow the §12 format. New codes: claim the next free number here when you add one.

### 19.5 Conventions

- **Dependencies are added reluctantly**, one at a time, when a task needs them. Sequence to date: `katex`, `minijinja`, then `serde`/`serde_json`/`toml` at M4 (`serde` for `site.json`, `toml` for `lit.toml`), then `pulldown-cmark` at M8 (CommonMark, `default-features = false`, `html` feature only — no GFM/CLI). Never add speculatively.
- **No panics outside tests.** Everything user-facing goes through the §12 diagnostic format with a code.
- **Every noweb-boundary discovery gets a fixture.** If you find new `markup` behavior, extend `fixtures/` with a minimal `.nw` + regenerated `.markup` pair and a test — that is how §4.2 stays true. `checks.noweb-drift` picks up new pairs automatically.
- **noweb stays.** Do not reimplement `markup` or `notangle`; the removal triggers are in §11 and none have fired.
- **Determinism is a feature.** No timestamps, no HashMap iteration order in output paths — `BTreeMap` or sort explicitly.
- When a decision here conflicts with observed reality, §4.2-style verification wins: probe the real binary, record the finding, update the spec.

### 19.6 Task: M11 — stable ids & the lock file

Implements §7.1. The current model numbers labels sequentially in
`resolve.rs`/`rewrite.rs` and renders "Figure 3"; M11 replaces the *number* with a
frozen opaque id while leaving anchoring/`data-*`/caption mechanics untouched. Build
in slices, gates green after each.

1. **`src/lock.rs` (new) — the lock model.** `LockFile` = `BTreeMap<String,
   BTreeMap<String, LockEntry>>` (file → label → `{ id, kind }`); `LockEntry { id:
   String, kind: Kind }`. `load(path) -> Result<LockFile>` (absent = empty, not an
   error), `save(path, &LockFile)` deterministic TOML (BTree order, no timestamps).
   `mint(&mut self, file, label, kind, &mut Rng) -> &str` returns the existing id or
   rolls a fresh 4-char base62 unique across *all* files, re-rolling on collision.
   `Kind` already exists (`rewrite.rs`); move or re-export it so `lock.rs` and
   `resolve.rs` share one. New dependency: a small deterministic RNG — add `rand`
   (one at a time, §19.5) or hand-roll a seeded xorshift to avoid the dep; the mint
   only needs base62-from-u64, so **prefer hand-rolling** and add no crate. Seed from
   OS entropy at mint time (ids are persisted, so reproducibility comes from the
   committed lock, not from a fixed seed).

2. **Thread the lock through weave.** `weave::write_site` gains a `LockMode`
   (`Mint` | `Locked`). In the resolve/scan pass, where a label is registered, look
   it up in the lock: found → use its id; missing under `Mint` → `mint`; missing
   under `Locked` → **E031**. Kind comes from the fence/tag already known at that
   site (§7.1), *not* from the id. After the weave, `Mint` writes the (possibly
   grown) lock back to `lit.lock` beside `lit.toml`; `Locked` never writes. Keep the
   whole pass a pure function of (model, lock-in) → (site, lock-out) so determinism
   holds: with a populated lock, no mint fires and output is byte-stable.

3. **Rendering: id, not number.** In `resolve.rs`/`rewrite.rs`, replace the running
   per-kind counter with the id from the lock. `data-number` becomes `data-id`
   (frozen id string); the CSS `::before`/`::after` rules in `templates/lit.css`
   render `"Figure " attr(data-id)` instead of `attr(data-number)`. Reference link
   text becomes kind-qualified with the id ("Figure k3f9"). The dense/monotonic
   numbering property test (§15) is replaced by "every label has a lock id and every
   `data-ref` resolves to one".

4. **`site.json` → `schema: 2`.** `src/site.rs`: bump the constant, replace each
   label entry's `number` with `id` (§8). Update the `--archive` writer and the
   `checks.determinism` grep in `flake.nix` (`"schema": 2`, and assert a label
   entry carries `"id"`). No other schema field moves.

5. **CLI.** `src/main.rs`: `lit weave … --locked` (frozen). `lit lock <files>` — a
   mint-only pass that loads the model, registers labels, mints, writes `lit.lock`,
   and stops before any HTML (fast; no KaTeX). `lit labels <file>` prints the file's
   `label → id` table; `lit id <file> <label>` prints one id (exit 1 if unknown, for
   scripting).

6. **`\ref`-in-backticks fix (folded in).** Today `substitute_refs` (`markdown.rs`)
   runs before CommonMark turns backticks into `<code>`, so a `` `\ref{x}` `` is
   lowered *then* escaped, emitting visible `<a data-ref…>` garbage inside the code
   span (only raw-HTML `<code>` is skipped). Since M11 reworks the ref path anyway,
   teach `substitute_refs`/`skip_code` to also skip backtick runs (single- and
   multi-backtick spans, CommonMark's matching-length rule) so a `\ref` inside
   backticks is a true no-op. Update the CLAUDE.md/§6.4 note from "documented no-op"
   (currently inaccurate) once fixed, and add a `ref_inside_backtick_span_is_literal`
   test.

7. **Fixtures & docs.** Add a committed `lit.lock` for `fixtures/md.nw` (and
   `examples/ring.nw`); `checks.determinism` weaves `--locked` and diffs. A new
   flake check `checks.lock`: `lit lock` on a copy, assert the lock is byte-stable on
   a second run, and that `weave --locked` against a *missing* label exits nonzero
   (E031). Update CLAUDE.md's dialect note and §6.4 to reference §7.1 for identity.

**Order of gates:** unit-test `lock.rs` (mint idempotence, collision re-roll,
round-trip TOML) → thread through weave with a fixture lock → flip rendering → schema
bump + flake greps → CLI + `\ref` fix. `cargo test`, `cargo clippy`, `nix flake
check` green at each slice. Deploy a `--locked` preview of `ring.nw` to the pages
`tmp/` tier and confirm references read "Figure <id>".
