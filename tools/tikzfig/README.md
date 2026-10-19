# tikzfig — web-native TikZ for cob's `custom[tikzfig]` fence

A cob custom-fence handler (cob §6.6) that renders TikZ / pgf / raw LaTeX
figures to SVG **without a LaTeX toolchain**. Rendering is web-native: the real
TeX engine compiled to WebAssembly (TikZJax, via
[node-tikzjax](https://github.com/prinsss/node-tikzjax)) runs inside this
handler at weave time, so woven pages stay pure static HTML/SVG — no viewer
JavaScript, no external CDN.

## Registration

In the project's `cob.toml`, after `npm ci` in this directory:

```toml
[fence.tikzfig]
cmd = ["node", "tools/tikzfig/index.js"]
# optional project options (cob forwards the parsed cob.toml to handlers):
preamble_file = "tools/tikz-preamble.tex"   # project \tikzset styles etc.
# preamble      = "\\usetikzlibrary{petri}"  # or inline
# tikzLibraries = "automata,arrows.meta"     # override the default set
# texPackages   = { pgfplots = "" }          # extra \usepackage-s
```

## Usage in a `.cob` file

```` cob
```{.figure .backings .custom[tikzfig] #fig:aut}
\node[sstate, initial, initial text=] (s0) {$s_0$};
\node[sstate, right=of s0] (s1) {$s_1$};
\draw[->] (s0) -- node[elab,above] {$a$} (s1);
```

```{.figure .backings .custom[tikzfig] #fig:plot}
imgs/score_decay.pgf
```
````

Body forms:

- a bare existing path (`.tex` / `.tikz` / `.pgf`, including matplotlib's
  raw-pgfpicture exports) — the file is read and inlined;
- inline LaTeX containing `\begin{tikzpicture}` / `\begin{pgfpicture}` — used as content;
- inline LaTeX with `\begin{document}` — a full document, used as-is;
- anything else — treated as a bare picture body and wrapped in
  `\begin{tikzpicture} … \end{tikzpicture}` automatically.

The macros cob exports to the handler become 0-ary `\providecommand`-s, so the
figure typesets in the book's own notation (same convention as `tools/latexfig`
for Inkscape `.pdf_tex`).

## Output

`<figure class="tikzfig" id="LABEL"><img src="imgs/LABEL.svg">` with the SVG as
a cob-managed asset. BaKoMa faces actually used are subset-inlined as base64
`@font-face`, and a white background rect is inserted so dark-mode pages keep
the figure legible. Output is deterministic (fixed engine bytecode, no wall
clock) and content-addressed through cob's normal custom-fence cache.

## Debugging

Set `TIKZFIG_DEBUG=1` to stream the TeX engine's console log to stderr.

Common failures:

- **runaway argument / file ended while scanning** → the project preamble or
  body usually has unbalanced braces (e.g. a `\tikzset` copied without its
  closing lines).
- **undefined control sequence** → a macro the figure needs is not in scope;
  add it to a `macros` fence (so cob forwards it), or to the project preamble
  if it is figure-only notation.
- **missing shapes/style** → a TikZ library is not in the default set; override
  via `tikzLibraries` in `cob.toml`.

## Notes and limits

- Do not run two instances concurrently in one process (WASM engine state); cob
  runs handlers sequentially, so normal weaves are fine.
- pgfplots is supported (bundled). Full `graphicx`/PDF inclusion is not — for
  Inkscape `.pdf_tex` exports keep using `tools/latexfig` (pdflatex path).
- LaTeX picture-mode edges: `-Latex[-]` style arrow-tail modifiers from tikz's
  `bending`-era syntax need `arrows.meta` (in the default set).
