# lit

A web-first literate programming system built on noweb. **`SPEC.md` is the
source of truth** — read §4.2 (verified noweb behavior) and §19 (implementation
guide / current task list) before writing code. Margin commenting is a
**separate tool** specced in `ANNOTATIONS.md`; lit's only obligation to it is
annotation-ready HTML (SPEC.md §9).

## Commands

Everything runs through the flake; nothing is on the bare PATH.

```sh
nix develop                              # devShell: rust toolchain + noweb
cargo test                               # hermetic unit tests
cargo run -- dump-ir fixtures/hello.nw   # end-to-end against real markup
cargo run -- weave fixtures/hello.nw     # writes _site/ (needs LIT_KATEX_ASSETS)
cargo run -- weave --archive book.nw     # also emit site.json + per-page JSON (§8)
cargo run -- weave --locked book.nw      # never mint; error on a label absent from lit.lock (§7.1)
cargo run -- lock fixtures/book.nw       # mint frozen float ids into lit.lock (§7.1)
cargo run -- labels fixtures/book.nw     # list the file's label → id map from lit.lock
cargo run -- tangle fixtures/hello.nw    # extract roots via notangle (--out, -R, --check)
cargo run -- --explain E014              # long form of a diagnostic (§12)
nix flake check                          # build + tests + drift + determinism + tangle
```

Flakes only see git-tracked files: `git add` new files before any `nix` command
or they silently won't exist. Do not commit unless asked.

## Key facts (details in SPEC.md §4.2)

- noweb's pipeline tools (`markup`, `nt`, …) live in `${noweb}/lib/noweb`, not
  `bin/`. The devShell and the wrapped package both put it on PATH.
- We consume `markup`'s IR and shell out to `notangle`; we never use `noweave`,
  and we do not reimplement noweb (contingency triggers: SPEC.md §11).
- `fixtures/*.markup` files are generated, never hand-edited:
  `markup fixtures/NAME.nw > fixtures/NAME.markup` inside the devShell.
- Weave output must be byte-deterministic: no timestamps, no unordered maps.
- Math renders at weave time; the site must contain **no `<script>`**. KaTeX's
  CSS and fonts are mandatory (without them equations render twice) and are
  pinned in `flake.nix` to the `katex` crate's own version — bump both
  together. Details and the rejected MathML-only option: SPEC.md §6.3.
- Code chunk line numbers are `.nw` source lines drawn by CSS from `data-line`,
  never text nodes — text-node numbers would be copy-pasted and would break the
  annotation layer's quote selectors (SPEC.md §5.4).
- Syntax highlighting (SPEC.md §5.5) colors the existing bytes with `tok-*` CSS
  classes only — no injected text, no `<script>`, so copy-paste, `data-line`, and
  quote selectors survive. A chunk-use `<<hole>>` stays opaque: tree-sitter tokens
  only the literal runs between holes and the `<a>` anchor is spliced back outside
  any color span. Language is resolved out of band by `highlight::resolve` (the same
  logic `lit language <file> <chunk>` prints), most specific tier first: a
  `[weave.chunk-lang]` per-chunk map in `lit.toml`, else `[weave] lang`, else the
  chunk's own or its tangle root's file extension. A chunk with no known language is
  plain text + a W104 warning, never an error; an unknown id in either `[weave]` key
  is E033. Grammars (Rust, Nix, Bash, CSS) are one dep each (§19.5); CSS self-hosts
  lit's own `templates/lit.css` as a literate document (§13).
- `flake.nix` is **generated** from `flake.nix.nw` — lit's own build file told as a
  literate program (the first self-host dogfood, SPEC.md §13). Edit the `.nw` and
  re-tangle (`lit tangle flake.nix.nw --out .`), never hand-edit `flake.nix`. The
  committed `flake.nix` stays the permanent bootstrap (it builds `lit` before any
  tangle can run); `checks.dogfood` runs `lit tangle --check flake.nix.nw` so the two
  never drift, and weaves the page to prove lit highlights its own Nix. Nix is the
  reason the second grammar exists.
- A labelled float's identity is a **frozen opaque id** (four base62 chars),
  minted once and stored in the committed `lit.lock` (keyed `file → label →
  {id, kind}`), never a sequential number — so a reference ("Figure k3f9")
  survives every move and rename (SPEC.md §7.1). CSS draws it from `data-id`
  (like `data-line`, never a text node). Dev-time `weave`/`lit lock` mint on miss
  and write the lock back; `weave --locked` (CI, the read-only Nix sandbox) never
  mints and errors (E031) on any label absent from the lock. Only labelled floats
  get an id — an unreferenceable float has no stable identity, so no `data-id`.
  A heading the author pins with a `sec:` id (`kind = "section"`) joins the same
  scheme: it earns an opaque id and leads with a clickable permalink prefix
  (`<a class="sec-uid" … data-id>`, drawn by CSS). An h1 is its page and is never
  minted; an unlabelled section gets no id or prefix.
- Docs-chunk prose has two dialects, set by `dialect` in `lit.toml` (SPEC.md
  §6.1/§6.4): `markdown` (default — CommonMark plus fenced-float directives) and
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

- Dependencies added one at a time, only when the current task needs one
  (SPEC.md §19.5 has the expected sequence).
- No panics outside tests; user-facing errors use the diagnostic format and
  error codes of SPEC.md §12 / §19.4.
- New noweb-boundary behavior ⇒ new fixture pair + test, and update §4.2.
