# lit

A web-first literate programming system built on noweb. **The literate document
is the source of truth**: each spec section lives in the module that implements
it, as spec-first prose before the code. Read `lit.nw` (the top-level document:
goals, architecture, the module map, milestones, error codes, conventions) and
`src/noweb.rs.nw` (§4.2, verified noweb behavior) before writing code. Margin
commenting is a **separate tool** specced in `ANNOTATIONS.md`; lit's only
obligation to it is annotation-ready HTML (§9, in `src/rewrite.rs.nw`).

## Commands

Everything runs through the flake; nothing is on the bare PATH.

```sh
nix develop                              # devShell: rust toolchain + noweb
cargo test                               # hermetic unit tests
cargo run -- dump-ir fixtures/hello.nw   # end-to-end against real markup
cargo run -- weave fixtures/hello.nw     # writes _site/ (needs LIT_KATEX_ASSETS)
cargo run -- weave --archive book.nw     # also emit site.json + per-page JSON (§8)
cargo run -- weave --locked book.nw      # never mint; error on a label absent from lit.lock (§7.1)
cargo run -- lock fixtures/book.nw       # mint ids; auto-anchor every unlabelled h2/h3 into the .nw source (§7.1)
cargo run -- rename-label k3f9 lexing    # give an auto section id a human sec: name (rewrites source + lock, keeps id)
cargo run -- labels fixtures/book.nw     # list the file's label → id map from lit.lock
cargo run -- tangle fixtures/hello.nw    # extract roots via notangle (--out, -R, --check)
cargo run -- --explain E014              # long form of a diagnostic (§12)
nix flake check                          # build + tests + drift + determinism + tangle
```

Flakes only see git-tracked files: `git add` new files before any `nix` command
or they silently won't exist. Do not commit unless asked.

## Key facts (details in `src/noweb.rs.nw` §4.2)

- noweb's pipeline tools (`markup`, `nt`, …) live in `${noweb}/lib/noweb`, not
  `bin/`. The devShell and the wrapped package both put it on PATH.
- We consume `markup`'s IR and shell out to `notangle`; we never use `noweave`,
  and we do not reimplement noweb (contingency triggers: `src/tangle.rs.nw` §11).
- `fixtures/*.markup` files are generated, never hand-edited:
  `markup fixtures/NAME.nw > fixtures/NAME.markup` inside the devShell.
- Weave output must be byte-deterministic: no timestamps, no unordered maps.
- Math renders at weave time; the archival **content needs no JavaScript**. The
  only script a page may carry is the inline `nav-spy` navigation aid in
  `templates/page.html` (§5.3) — a single, identical, inline block, no external
  `src`, that injects no content text (so copy-paste and quote selectors survive)
  and only marks/scrolls the nav to the section you are reading. So the rule is "no
  script the content depends on", and the flake checks assert every page carries no
  `<script>` **but** the nav-spy block. KaTeX's CSS and fonts are mandatory (without
  them equations render twice) and are pinned in `flake.nix` to the `katex` crate's
  own version — bump both together. Details and the rejected MathML-only option:
  `src/math.rs.nw` §6.3.
- Code chunk line numbers are `.nw` source lines drawn by CSS from `data-line`,
  never text nodes — text-node numbers would be copy-pasted and would break the
  annotation layer's quote selectors (`src/weave.rs.nw` §5.4).
- Syntax highlighting (`src/highlight.rs.nw` §5.5) colors the existing bytes with `tok-*` CSS
  classes only — no injected text and no script (the nav-spy aid aside), so
  copy-paste, `data-line`, and quote selectors survive. A chunk-use `<<hole>>` stays opaque: tree-sitter tokens
  only the literal runs between holes and the `<a>` anchor is spliced back outside
  any color span. Language is resolved out of band by `highlight::resolve` (the same
  logic `lit language <file> <chunk>` prints), most specific tier first: a
  `[weave.chunk-lang]` per-chunk map in `lit.toml`, else `[weave] lang`, else the
  chunk's own or its tangle root's file extension. A chunk with no known language is
  plain text + a W104 warning, never an error; an unknown id in either `[weave]` key
  is E033. Grammars (Rust, Nix, Bash, CSS) are one dep each (§19.5); CSS self-hosts
  lit's own `templates/lit.css` as a literate document (§13).
- Transclusion (`src/transclude.rs.nw` §10) shows one **node** a second time in
  place. A node is a heading and the content under it, cut at the **markdown
  heading** boundary (the next heading at the same or a shallower level), never at
  the `@`-chunk boundary — so one chunk can hold many nodes and a node can span
  chunks. `\transclude{sec:name}` (Markdown) lowers to an inert
  `<div class="transclusion" data-transclude=…>` island the weaver splices after
  section wrapping and before the page split. The copy keeps the canonical bytes,
  gets scope-prefixed ids (`tx<n>-…`) on every id it defines and every in-copy link,
  a backlink header, and a section with no directive is byte-unchanged. A cycle is
  W105, an unknown target W106 — both inert markers, never an error. The node body
  is cut from the final section bodies by the `id` `apply` stamps on every heading;
  deferred slices (floats as nodes, per-node pages, cross-document) are in §10.
- `flake.nix` is **generated** from `flake.nix.nw` — lit's own build file told as a
  literate program (the first self-host dogfood, `lit.nw` §13). Edit the `.nw` and
  re-tangle (`lit tangle flake.nix.nw --out .`), never hand-edit `flake.nix`. The
  committed `flake.nix` is the **one** generated file that stays tracked, because Nix
  must read it before any tangle can run; `checks.dogfood` runs `lit tangle --check
  flake.nix.nw` so the two never drift, and weaves the page to prove lit highlights
  its own Nix. Nix is the reason the second grammar exists.
- **The `.nw` files are the only source of truth (§13).** No `.rs` or `.css` is
  committed — `src/*.rs`, `templates/lit.css`, and `templates/lit-syntax.css` are
  gitignored generated files. Edit the `.nw`, re-tangle (`lit tangle X.nw --out .`),
  never hand-edit the generated `.rs`/`.css`. On a fresh checkout the devShell
  `shellHook` notangle-bootstraps them, so `cargo` works after `nix develop`. The
  flake builds in **two stages**: `packages.litBootstrap` (stage 0) compiles from a
  `notangle`-tangled tree (`bootstrapSource` — no `lit` needed, `notangle` ships with
  noweb), tangles every `.nw` into `packages.litSource`, and `packages.lit` (stage 1,
  the `default`) compiles from that lit-tangled tree. `checks.selfhost` proves
  `notangle` and `lit tangle` make byte-identical output for every module — two
  independent tanglers agreeing is what makes the seedless bootstrap safe.
- A labelled float's identity is a **frozen opaque id** (four base62 chars),
  minted once and stored in the committed `lit.lock` (keyed `file → label →
  {id, kind}`), never a sequential number — so a reference ("Figure k3f9")
  survives every move and rename (`src/lock.rs.nw` §7.1). CSS draws it from `data-id`
  (like `data-line`, never a text node). Dev-time `weave`/`lit lock` mint on miss
  and write the lock back; `weave --locked` (CI, the read-only Nix sandbox) never
  mints and errors (E031) on any label absent from the lock. Only labelled floats
  get an id — an unreferenceable float has no stable identity, so no `data-id`.
  A `sec:`-labelled heading (`kind = "section"`) joins the same scheme: it earns
  an opaque id and leads with a clickable permalink prefix (`<a class="sec-uid" …
  data-id>`, drawn by CSS). The author need not label by hand: `lit lock`
  auto-anchors every unlabelled h2/h3 by minting an id and writing `{#sec:<id>}`
  (Markdown) / `id="sec:<id>"` (HTML) into the `.nw` heading line, so every section
  is linkable and the id is source-anchored (survives a reword). `lit rename-label
  <id> <name>` gives an auto id a human `sec:` name — rewrites source + rekeys the
  lock, frozen id unchanged. Source-side anchoring lives in `src/section.rs.nw`; the
  weave path is untouched (an auto-anchored heading is just a `sec:` heading).
  Markdown heading attributes are enabled (`ENABLE_HEADING_ATTRIBUTES`) so
  `{#sec:name}` parses. An h1 is its page and is never minted. Anchoring happens
  only in the dev-time `lit lock` pass; `weave --locked` never edits source.
- Docs-chunk prose has two dialects, set by `dialect` in `lit.toml`
  (`src/config.rs.nw` §6.1, `src/markdown.rs.nw` §6.4): `markdown` (default —
  CommonMark plus fenced-float directives) and
  `html` (the raw-HTML escape hatch). The float directives are ```` ```math ````,
  ```` ```figure ````, and ```` ```table ````, each taking an optional
  `\label{ns:name}` on the fence line (`eq:`/`fig:`/`tbl:`; a mismatched
  namespace is E030) and — for figure/table — a leading brace-balanced
  `\caption{…}`. GFM pipe tables parse *only* inside a `table` fence. Inline
  `\ref{ns:name}` lowers to the same `<a data-ref>` the resolver already handles
  (a `\ref` inside a backtick span is a documented no-op). Sidenote `<aside>`s
  stay raw-HTML islands. Markdown is a post-`markup` transform
  (`src/markdown.rs`), so it is *not* noweb-boundary behavior — no §4.2 change.
  `hello`/`book` fixtures are pinned in `html` mode; `md.nw` is the Markdown
  end-to-end pair.

## Conventions

- **Write all literate `.nw` prose in ASD-STE100 Simplified Technical English
  (STE).** This is the house style for every `.nw` document (the flake, the crate,
  the stylesheet, and any future spec-bearing document). Follow the STE rules:
  short sentences (one instruction per sentence; keep procedural sentences to ~20
  words, descriptive to ~25), the active voice, the present tense, one meaning per
  word, and approved simple verbs — prefer "make", "use", "get", "give" over
  latinate near-synonyms ("generate", "utilise", "obtain", "provide"). No noun
  clusters over three words. Say *why* a chunk exists, in plain words, before you
  say how. STE keeps the woven document readable to a non-native and non-expert
  reader, which is the point of telling the program as a document.
- Dependencies added one at a time, only when the current task needs one (the
  `lit.nw` conventions section records the sequence to date).
- No panics outside tests; user-facing errors use the diagnostic format
  (`src/diag.rs.nw` §12) and the error-code registry in `lit.nw`.
- New noweb-boundary behavior ⇒ new fixture pair + test, and update the verified-
  noweb prose in `src/noweb.rs.nw` (§4.2).
