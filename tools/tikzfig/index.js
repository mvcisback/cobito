#!/usr/bin/env node
// A cob `custom[tikzfig]` handler (cob §6.6): render TikZ/TeX to SVG without a
// LaTeX toolchain. Rendering is web-native — the actual TeX engine compiled to
// WebAssembly (TikZJax, as packaged for Node by node-tikzjax) — run at weave
// time inside this handler, so the woven page itself needs no JavaScript and
// the figure is a plain, cached SVG asset.
//
// cob sends a JSON blob on stdin: the fence `body`, the macros in scope
// (`defs`), the float's `label`/`caption`, the parsed cob.toml (`config`), and
// a writable `outdir`. We return `{"html": ..., "assets": ...}` like tools/
// latexfig does.
//
// Body forms:
//   - a bare existing path (no whitespace): read and inline it. The file may be
//     a .tex/.tikz/.pgf snippet or a full LaTeX document.
//   - inline LaTeX containing \begin{document}: used as-is.
//   - inline LaTeX containing \begin{tikzpicture} or \begin{pgfpicture}: wrapped
//     in a document.
//   - anything else: treated as a bare picture BODY and wrapped
//     `\begin{tikzpicture}...\end{tikzpicture}`.
//
// Project options live under `[fence.tikzfig]` in cob.toml (boldly keyed there,
// since cob forwards the whole parsed config to handlers):
//   cmd        = ["node", "tools/tikzfig/index.js"]   (as for any handler)
//   preamble      (string)  extra LaTeX for the preamble, e.g. \tikzset styles
//   preamble_file (path)    same, but read from a project-relative file
//   tikzLibraries (string)  override the default \usetikzlibrary set
//   texPackages   (table)   extra \usepackage entries, { name = "options" }
//
// The macros cob exports (`defs`) become 0-ary \providecommand-s so the figure
// typesets in the document's own notation — same convention as latexfig.
//
// Determinism: WASM engine + fixed bytecode is bit-stable; cob also runs us
// with SOURCE_DATE_EPOCH=0. The engine sees no wall clock unless the figure
// itself asks for the date.
//
// Fonts: the engine emits <text font-family="cmmi10"> in TeX's classic encodings,
// so each used BaKoMa face is subset-inlined as a base64 @font-face — the asset
// renders correctly anywhere, including as an <img> on a plain static page.

'use strict';

const fs = require('fs');
const path = require('path');

const tex2svg = require('node-tikzjax').default;

const DEFAULT_LIBRARIES = [
  'automata',
  'positioning',
  'patterns',
  'calc',
  'arrows',
  'arrows.meta',
  'shapes',
  'shadows',
  'shapes.misc',
  'shapes.callouts',
  'shapes.multipart',
  'shapes.geometric',
  'shapes.gates.logic.US',
  'fit',
  'backgrounds',
  'trees',
  'decorations.pathmorphing',
  'decorations.pathreplacing',
  'decorations.markings',
  'shadings',
].join(',');

function fail(msg) {
  process.stderr.write(String(msg).slice(-3000) + '\n');
  process.exit(1);
}

// Subset-inline the BaKoMa faces the SVG actually uses, replacing the default
// `@import url(cdn…)` node-tikzjax injects. Returns the rewritten SVG.
function inlineFonts(svg) {
  const fontsDir = path.join(
    path.dirname(require.resolve('node-tikzjax/package.json')), 'css', 'bakoma', 'ttf');
  const used = [...new Set([...svg.matchAll(/font-family="?([a-zA-Z0-9-]+)"?/g)].map(m => m[1]))];
  const rules = used.map(fam => {
    const file = path.join(fontsDir, fam + '.ttf');
    if (!fs.existsSync(file)) return '';
    const b64 = fs.readFileSync(file, 'base64');
    return `@font-face { font-family: ${fam}; src: url(data:font/ttf;base64,${b64}); }`;
  }).filter(Boolean).join('\n');
  if (/@import url\(/.test(svg)) return svg.replace(/@import url\([^)]*\)\s*;?/, rules);
  // No import (e.g. sanitize disabled): prepend our own defs.
  const gt = svg.indexOf('>', svg.indexOf('<svg'));
  return svg.slice(0, gt + 1) + `<defs><style>${rules}</style></defs>` + svg.slice(gt + 1);
}

// Insert a white background rect sized to the viewBox (as latexfig does), so
// dark-mode pages still show the figure legibly. Everything cob publishes sits
// on a white sheet.
function whiteBackground(svg) {
  const m = /viewBox="([-\d.eE\s]+)"/.exec(svg);
  if (!m) return svg;
  const [x, y, w, h] = m[1].trim().split(/\s+/);
  const gt = svg.indexOf('>', svg.indexOf('<svg'));
  return svg.slice(0, gt + 1)
    + `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#ffffff"/>`
    + svg.slice(gt + 1);
}

function main() {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => raw += c);
  process.stdin.on('end', () => run(JSON.parse(raw)).catch(e => fail(e && e.message || e)));
}

async function run(d) {
  const body = (d.body || '').trim();
  const defs = d.defs || {};
  const label = d.label || '';
  const caption = d.caption || '';
  const outdir = d.outdir;
  const figCfg = (d.config && d.config.fence && d.config.fence.tikzfig) || {};

  // Project preamble: inline string and/or project-relative file.
  let preamble = figCfg.preamble || '';
  if (figCfg.preamble_file) {
    preamble += '\n' + fs.readFileSync(path.resolve(figCfg.preamble_file), 'utf8');
  }

  // cob's macros as 0-ary \providecommand (parametric ones skipped — latexfig
  // convention).
  const providers = Object.entries(defs)
    .filter(([, exp]) => !String(exp).includes('#'))
    .map(([name, exp]) => `\\providecommand{${name}}{${exp}}`)
    .join('\n');

  // Resolve the body to document content. A bare, existing path is a file to
  // inline; otherwise the body is LaTeX.
  const looksLikePath = !/[\s{}\\]/.test(body);
  let content = body;
  if (looksLikePath) {
    const cand = path.resolve(body);
    if (!fs.existsSync(cand)) fail('tikzfig: body looks like a path but no such file: ' + body);
    content = fs.readFileSync(cand, 'utf8');
  }

  // Assemble the document. TikZJax's format is standalone with documents begun
  // by the caller's input.
  let doc;
  if (/\\begin\{document\}/.test(content)) {
    doc = content;
  } else if (/\\begin\{(tikz|pgf)/.test(content)) {
    doc = '\\begin{document}\n' + content + '\n\\end{document}\n';
  } else {
    doc = '\\begin{document}\n\\begin{tikzpicture}\n' + content
      + '\n\\end{tikzpicture}\n\\end{document}\n';
  }

  const options = {
    addToPreamble: preamble + '\n' + providers,
    tikzLibraries: figCfg.tikzLibraries || DEFAULT_LIBRARIES,
    embedFontCss: true,
    showConsole: !!process.env.TIKZFIG_DEBUG,
  };
  if (figCfg.texPackages) options.texPackages = figCfg.texPackages;

  let svg = await tex2svg(doc, options);
  svg = inlineFonts(svg);
  svg = whiteBackground(svg);

  const rel = (label.replace(/:/g, '-') || 'tikzfig') + '.svg';
  fs.writeFileSync(path.join(outdir, rel), svg);

  const pub = 'imgs/' + rel;
  const cap = caption ? `<figcaption>${caption}</figcaption>` : '';
  const html = `<figure class="tikzfig" id="${label}">${cap}<img src="${pub}" alt=""></figure>`;
  process.stdout.write(JSON.stringify({ html, assets: { [pub]: rel } }));
}

main();
