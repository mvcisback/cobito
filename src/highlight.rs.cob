# Syntax highlighting (§5.5)

This module is the specification and the implementation of syntax highlighting.
The prose is the specification. The chunks after it are the implementation.

## What highlighting must do {#sec:Zi6G}

Highlighting gives color to the bytes that a reader already sees. It never
changes those bytes (§2). Color is the only thing it adds. This keeps three
promises from §5.4 and §6.3: the copy of a code chunk is the same text as
before, the line numbers stay out of that copy, and the page needs no script.

## The hard part {#sec:QRS0}

A code chunk is not a valid program. It is target-language text with chunk uses
spliced in. A chunk use is cob's own syntax, not the target's. A plain tokenizer
reads the two brackets of a chunk use as a shift operator and chokes. Worse, a
chunk is a fragment: a brace, a string, or a comment can open in one chunk and
close in another, so tokenizing a chunk alone colors it wrong. Three moves make
highlighting safe, and one more makes it correct.

## Move 0 — tokenize the tangled file, map the tokens back {#sec:tangle-hl}

The correct color for a chunk's bytes is the color they have in the finished
program, not in the fragment. So cob tokenizes the whole **tangled** file — which
is valid and has every chunk in context — and maps each token back onto the chunk
that wrote those bytes. The tangler records the provenance (\code{tangle.rs}: which
section's source bytes landed where), the engine returns the flat token runs over
the tangled text (\code{runs}), and the weaver reads each chunk's runs straight out of
that stream (\code{render_runs}). The provenance tangle drops the inserted indentation
and the trailing-newline splice, because whitespace never changes a token class for
cob's grammars — so the mapping is one-to-one.

A chunk used in more than one place has one context per use; cob takes the first
expansion (the common case is one use, and the weave shows the chunk once). A chunk
no root reaches has no context, so cob falls back to tokenizing the fragment alone
(Moves 1–3) — best-effort, never wrong enough to fail.

## Move 1 — a chunk use is an opaque hole {#sec:vXmF}

Section 5.4 already draws each chunk use as an anchor inside its line span. The
reader sees the hole's opaque id (§7.1), never target source. So the tokenizer
gets only the literal runs between the anchors, with the byte offset of each
hole. It never reads across a hole. This is the discipline the math pass uses
(§6.2): take the foreign spans out, tokenize the rest, put the spans back. The
line \code{let c = HOLE;} tokenizes as \code{let}, \code{c}, \code{=}, and \code{;}, and the hole in the
middle stays untouched, so the two brackets never lex as a shift operator.

## Move 2 — cob resolves the language, once, out of band {#sec:50k1}

The engine never guesses the language. cob resolves it in three tiers. The most
specific tier wins.

1. Per-chunk override. A \code{[weave.chunk-lang]} table in \code{cob.toml} maps a chunk
   name to a language. This is the escape hatch for a shell snippet inside a
   Rust document, or for an abstract chunk whose name has no extension. The map
   is out-of-band config, so it survives \code{markup}. An inline tag on the def line
   would not, because \code{markup} folds everything after the chunk name into the
   body.
2. Document default. A \code{[weave] lang} key in \code{cob.toml} sets one language for
   the whole document.
3. Root file extension. With nothing else said, a chunk takes the language of
   the tangle root it flows into. A concrete chunk uses its own extension. An
   abstract chunk has no extension, so cob walks the chunk-use graph to a root
   that reaches it. Most chunks need no configuration.

A chunk that resolves to no known language is plain text and a W104 warning,
never an error; the page still renders. An unknown chunk name in either
\code{[weave]} key is the E033 error.

The grammars live in a **registry**, not a closed set, because cob is
language-agnostic (CLAUDE goal #2) and only highlighting is language-bound. cob
ships Rust, Nix, Bash, and CSS — it needs them to weave itself (CSS presents its own
stylesheet as a literate document, §13) — but a grammar is one registry entry plus
its crate, so a build can add more. The registry is the seam a build-selected
(Nix) or, behind a compile-time feature, dynamically-loaded grammar fills; the
resolver, the names, and the splice never change.

## Move 3 — one resolver, shared by weave and editor {#sec:gGq9}

The three tiers are one function. cob exposes it as `cob language <file>
<chunk>`, which prints the language id or exits nonzero. Weave calls it inside.
An editor plugin runs the same command. So the woven page and the editor can
never disagree on the language of a chunk.

## The weave-time pipeline {#sec:sQwN}

Highlighting runs inside §5.4's render, after the chunk-use anchors exist. The
tokens come from the tangled file (Move 0): the weaver tree-sitters each root's
text once (\code{runs}) and maps the token runs back onto each chunk's bytes. For an
unused chunk, with no tangle context, cob tokenizes the fragment alone as a
fallback (\code{highlight}). Either way, the colored runs are re-split at each newline
into the same self-contained line spans §5.4 emits. Per chunk cob:

- resolves the language by the tiers above (shared with the editor, §5.5 Move 3);
- builds a clean buffer: the literal runs joined by newlines, each hole removed but
  its byte offset and anchor HTML kept;
- takes the token runs (tangle-mapped, or fragment-tokenized in the fallback);
- walks the buffer once, merging the runs. At a newline it closes the open token
  span, closes the line span, opens the next line span with its data-line, and
  reopens. At a hole it closes the span, emits the anchor as-is, and reopens, so a
  hole is never inside a color span. Elsewhere it escapes the bytes into the span.

The engine is tree-sitter, through \code{tree-sitter-highlight}. Each grammar maps a
stable set of highlight names (\code{keyword}, \code{string}, \code{comment}, and so on) to
\code{tok-*} CSS classes in \code{cob.css}. The color is a pure class over the bytes that
are already there. There is no inline style and no script, so the archival rule
(§6.3) and determinism (§8) hold, and a token span adds no text of its own, so
§5.4's copy and quote guarantees stay true.

## How the code implements this {#sec:Hjwm}

The module is the grammar registry and its resolver, the highlight-name tables, a
per-language grammar cache, the token-run engine, and the line-splitting merge.
The banner doc-comment below carries a hole example. In a code chunk a bare hole
is a chunk use, so each bracket pair carries the noweb at-escape; the example
survives tangle as literal text and never expands.
<<src/highlight.rs>>=
<<the module banner>>

<<imports>>

<<the language enum>>

<<language conversions>>

<<the resolved config>>

<<the test config constructor>>

<<resolve a chunk's language>>

<<forward chunk-use edges>>

<<reachability>>

<<the highlight error>>

<<the highlight names>>

<<the token classes>>

<<the per-language grammar cache>>

<<build or fetch a grammar config>>

<<highlight one chunk>>

<<highlight runs from a source>>

<<render per-line html from runs>>

<<the tests>>
@
The banner states the two invariants: holes stay opaque to the tokenizer, and color
is pure CSS so the archival and annotation contracts hold.
<<the module banner>>=
//! Syntax highlighting (§5.5). A code chunk is not a valid program: it is
//! target-language text with *chunk-use holes* (`@<<next char@>>`) spliced in, and
//! those are cob's syntax, not the target's. So the tokenizer never sees a hole —
//! we hand tree-sitter only the literal runs between holes and splice the holes'
//! anchors back afterward, exactly the discipline the math pass uses (§6.2).
//!
//! Color is a CSS `tok-*` class, never injected text, so §5.4's copy-paste and the
//! annotation layer's quote selectors (§9.2) see the same bytes they saw before —
//! and there is no `<script>`, so the archival invariant (§6.3) holds.
@
Interior mutability for the per-thread grammar cache, plus tree-sitter's highlighter
and the model types a chunk is drawn from.
<<imports>>=
use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::rc::Rc;
use std::sync::OnceLock;

use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

use crate::model::{CodeSpan, DocModel, SectionKind};
use crate::prose;
@
cob is language-agnostic except for highlighting (CLAUDE goal #2), so the grammars
live in one **registry**, not a closed enum — and the registry is a **build input**,
not a dependency list (§5.5, the meta-language direction). A grammar is its id, the
file extensions that imply it, a function to the tree-sitter language, and its
highlights query. No grammar is a Cargo dependency: the build script (`build.rs`)
compiles each grammar named in the `COB_GRAMMARS` manifest and makes the registry
entries, so a user adds a grammar by naming its pinned repo to the build — nothing
in cob changes. The Nix build pins Rust, Nix, Bash, and CSS as the default grammars
because cob needs them to weave itself; a grammar whose query uses the standard
tree-sitter capture names maps straight onto cob's `tok-*` classes.
<<the language enum>>=
/// One highlightable grammar (§5.5): its id, the extensions that imply it, the
/// tree-sitter language, and its highlights query. Every entry comes from the
/// build-time manifest (`build.rs`, the meta-language path) — no grammar is a
/// Cargo dependency.
#[derive(Clone, Copy)]
pub struct Grammar {
    pub id: &'static str,
    pub exts: &'static [&'static str],
    pub language: fn() -> tree_sitter::Language,
    pub highlights: &'static str,
}

// The grammars the build compiled in from its `COB_GRAMMARS` manifest — the
// `generated()` function (`build.rs`, §5.5). Empty when no manifest was given.
include!(concat!(env!("OUT_DIR"), "/grammars_generated.rs"));

/// The grammar registry, assembled once from the build manifest. `Lang` is an
/// index into this. With no manifest the registry is empty and every `from_id`
/// / `from_ext` misses — a build with no grammars highlights nothing.
fn registry() -> &'static [Grammar] {
    static REG: OnceLock<Vec<Grammar>> = OnceLock::new();
    REG.get_or_init(generated)
}

/// A resolved language: an index into the grammar registry. `Copy`, so it threads
/// through the weaver as before, and keys the per-language config cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Lang(usize);
@
Four small conversions: the id \code{cob language} prints, parsing an id from config,
mapping a file extension to a language, and reading a language off a chunk or root
name that ends in a known extension.
<<language conversions>>=
impl Lang {
    /// This language's registry entry.
    fn grammar(self) -> &'static Grammar {
        &registry()[self.0]
    }

    /// The id printed by `cob language` and used to select a grammar.
    pub fn id(self) -> &'static str {
        self.grammar().id
    }

    /// Parse a language id from config (`[weave] lang`, `[weave.chunk-lang]`)
    /// against the registry. Unknown ⇒ `None`.
    pub fn from_id(id: &str) -> Option<Lang> {
        registry().iter().position(|g| g.id == id).map(Lang)
    }

    /// A file extension (no dot) ⇒ language, by the registry's `exts` (§5.5 tier 3).
    pub fn from_ext(ext: &str) -> Option<Lang> {
        registry().iter().position(|g| g.exts.contains(&ext)).map(Lang)
    }

    /// A chunk/root *name* that ends in a known extension names its language.
    fn from_name(name: &str) -> Option<Lang> {
        name.rsplit_once('.').and_then(|(_, ext)| Lang::from_ext(ext))
    }
}
@
The resolved highlighting configuration. \code{default} is the document-wide tier-2
language; \code{chunk_lang} is the tier-1 per-chunk map. Both are already parsed to
\code{Lang}, so an unknown id was rejected once at config-load, not here.
<<the resolved config>>=
/// The resolved highlighting configuration for a document (§5.5). `default` is the
/// document-wide `[weave] lang` (tier 2); `chunk_lang` is the `[weave.chunk-lang]`
/// map (tier 1), keyed by chunk name. Both are already parsed to `Lang`, so an
/// unknown id is rejected once, at config-load time, not here.
#[derive(Debug, Default, Clone)]
pub struct LangConfig {
    pub default: Option<Lang>,
    pub chunk_lang: HashMap<String, Lang>,
}
@
A test constructor: a document default with no per-chunk overrides.
<<the test config constructor>>=
impl LangConfig {
    /// A document-wide default with no per-chunk overrides (what tests build).
    #[cfg(test)]
    pub fn with_default(default: Option<Lang>) -> LangConfig {
        LangConfig {
            default,
            chunk_lang: HashMap::new(),
        }
    }
}
@
§5.5 resolution, most specific tier first. A tier-1 entry for this exact chunk wins;
else the tier-2 default; else tier 3 — the chunk's own name extension, or the
extension of a tangle root that transitively uses it. The root walk is in sorted
order, so the winner is stable.
<<resolve a chunk's language>>=
/// §5.5 language resolution, most specific tier first.
///
/// 1. Tier 1 — an explicit `[weave.chunk-lang]` entry for this exact chunk.
/// 2. Tier 2 — the document-wide `[weave] lang` default.
/// 3. Tier 3 — the chunk's own name extension, or the extension of a tangle root
///    that transitively uses it.
pub fn resolve(doc: &DocModel, chunk: &str, cfg: &LangConfig) -> Option<Lang> {
    if let Some(&lang) = cfg.chunk_lang.get(chunk) {
        return Some(lang);
    }
    if let Some(lang) = cfg.default {
        return Some(lang);
    }
    if let Some(lang) = Lang::from_name(chunk) {
        return Some(lang);
    }
    // `roots()` walks the chunk map in sorted order, so the winner is stable.
    let forward = forward_uses(doc);
    for root in doc.roots() {
        if let Some(lang) = Lang::from_name(root) {
            if reaches(&forward, root, chunk) {
                return Some(lang);
            }
        }
    }
    None
}
@
Chunk name to the names it uses, drawn from each code section's spans. \code{ChunkInfo.uses}
is a reverse index of use-site sections, so the forward edges are built here for the
reachability walk.
<<forward chunk-use edges>>=
/// Chunk name → the chunk names it uses, drawn from each code section's spans.
/// `ChunkInfo.uses` is a *reverse* index (use-site section ids), so we build the
/// forward edges here for reachability.
fn forward_uses(doc: &DocModel) -> HashMap<&str, Vec<&str>> {
    let mut fwd: HashMap<&str, Vec<&str>> = HashMap::new();
    for section in &doc.sections {
        if let SectionKind::Code { name, spans, .. } = &section.kind {
            let edges = fwd.entry(name.as_str()).or_default();
            for span in spans {
                if let CodeSpan::Use { name: used } = span {
                    edges.push(used.as_str());
                }
            }
        }
    }
    fwd
}
@
Does \code{root} reach \code{target} by following chunk uses, counting \code{root} itself.
<<reachability>>=
/// Does `root` reach `target` by following chunk uses? (`root == target` counts.)
fn reaches(forward: &HashMap<&str, Vec<&str>>, root: &str, target: &str) -> bool {
    let mut stack = vec![root];
    let mut seen = vec![root];
    while let Some(name) = stack.pop() {
        if name == target {
            return true;
        }
        for &used in forward.get(name).into_iter().flatten() {
            if !seen.contains(&used) {
                seen.push(used);
                stack.push(used);
            }
        }
    }
    false
}
@
A highlighting failure — a grammar that will not configure, or an event-stream error.
<<the highlight error>>=
#[derive(Debug)]
pub struct HlError(String);

impl fmt::Display for HlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "highlighting: {}", self.0)
    }
}

impl std::error::Error for HlError {}
@
The highlight names recognized, in fixed order. tree-sitter matches a grammar's
dotted capture to the longest of these that is a prefix, so listing base names is
enough; each maps to a \code{tok-} class.
<<the highlight names>>=
/// The highlight names we recognize, in a fixed order. tree-sitter matches a
/// grammar's dotted capture (`punctuation.bracket`) to the longest of these that
/// is a prefix (`punctuation`), so listing base names is enough; each maps to the
/// `tok-<name>` class the stylesheet colors.
const HL_NAMES: &[&str] = &[
    "attribute",
    "comment",
    "constant",
    "constructor",
    "escape",
    "function",
    "keyword",
    "label",
    "module",
    "number",
    "operator",
    "property",
    "punctuation",
    "string",
    "tag",
    "type",
    "variable",
];
@
The \code{tok-} class for each name, same order. An index out of range falls back to
\code{tok-variable}, the plainest colored class.
<<the token classes>>=
/// The `tok-*` class for each `HL_NAMES` entry, same order. A highlight index out
/// of range falls back to `tok-variable` (the plainest colored class).
const TOK_CLASSES: &[&str] = &[
    "tok-attribute",
    "tok-comment",
    "tok-constant",
    "tok-constructor",
    "tok-escape",
    "tok-function",
    "tok-keyword",
    "tok-label",
    "tok-module",
    "tok-number",
    "tok-operator",
    "tok-property",
    "tok-punctuation",
    "tok-string",
    "tok-tag",
    "tok-type",
    "tok-variable",
];
@
One configured grammar per language, built on first use and confined to the weave
thread. Determinism is unaffected — the config is a pure function of the pinned
grammar and query.
<<the per-language grammar cache>>=
thread_local! {
    // One configured grammar per language, built on first use. Confined to the
    // weave thread; determinism is unaffected (the config is a pure function of
    // the pinned grammar + query).
    static CONFIGS: RefCell<HashMap<Lang, Rc<HighlightConfiguration>>> =
        RefCell::new(HashMap::new());
}
@
Fetch or build the grammar configuration for a language, caching it. Building applies
\code{HL_NAMES} so capture indices line up with \code{TOK_CLASSES}.
<<build or fetch a grammar config>>=
fn config(lang: Lang) -> Result<Rc<HighlightConfiguration>, HlError> {
    if let Some(cfg) = CONFIGS.with(|m| m.borrow().get(&lang).cloned()) {
        return Ok(cfg);
    }
    let g = lang.grammar();
    let mut cfg = HighlightConfiguration::new((g.language)(), g.id, g.highlights, "", "")
        .map_err(|e| HlError(e.to_string()))?;
    cfg.configure(HL_NAMES);
    let cfg = Rc::new(cfg);
    CONFIGS.with(|m| m.borrow_mut().insert(lang, cfg.clone()));
    Ok(cfg)
}
@
Highlight one chunk. The source is the raw code with holes removed and lines joined
by newline; \code{holes} gives each removed hole's byte offset and its anchor HTML. The
walk keeps a stack of open \code{tok-} classes so it can close them in reverse and reopen
them across a line break or around a hole — a hole is always emitted outside every
color span, and each line is left self-contained so the caller can wrap and number
it. The returned strings are the inner HTML of each line.
<<highlight one chunk>>=
/// Highlight one chunk. `source` is the raw code with lines joined by `\n` and the
/// holes removed; `holes` is `(byte offset into `source`, anchor HTML)` in ascending
/// offset order. Returns the inner HTML of each line (no `<span class="line">`
/// wrapper — the caller owns that and the `data-line` numbering).
pub fn highlight(source: &str, holes: &[(usize, &str)], lang: Lang) -> Result<Vec<String>, HlError> {
    let cfg = config(lang)?;
    let mut hl = Highlighter::new();
    let events = hl
        .highlight(&cfg, source.as_bytes(), None, |_| None)
        .map_err(|e| HlError(e.to_string()))?;

    let bytes = source.as_bytes();
    let mut lines: Vec<String> = vec![String::new()];
    // Open `tok-*` classes, outermost first, so we can close in reverse and reopen
    // in order across a line break or around a hole.
    let mut open: Vec<&'static str> = Vec::new();
    let mut hole = 0usize;

    // Emit the holes sitting exactly at `pos`, each outside any color span.
    let flush_holes = |pos: usize,
                       hole: &mut usize,
                       open: &[&'static str],
                       lines: &mut Vec<String>| {
        while *hole < holes.len() && holes[*hole].0 == pos {
            let line = lines.last_mut().unwrap();
            for _ in open {
                line.push_str("</span>");
            }
            line.push_str(holes[*hole].1);
            for class in open {
                line.push_str(&format!("<span class=\"{class}\">"));
            }
            *hole += 1;
        }
    };

    for event in events {
        match event.map_err(|e| HlError(e.to_string()))? {
            HighlightEvent::HighlightStart(h) => {
                let class = TOK_CLASSES.get(h.0).copied().unwrap_or("tok-variable");
                lines
                    .last_mut()
                    .unwrap()
                    .push_str(&format!("<span class=\"{class}\">"));
                open.push(class);
            }
            HighlightEvent::HighlightEnd => {
                if open.pop().is_some() {
                    lines.last_mut().unwrap().push_str("</span>");
                }
            }
            HighlightEvent::Source { start, end } => {
                let mut pos = start;
                while pos < end {
                    flush_holes(pos, &mut hole, &open, &mut lines);
                    if bytes[pos] == b'\n' {
                        // Close spans, break the line, reopen on the next line so
                        // every `<span class="line">` is self-contained.
                        let line = lines.last_mut().unwrap();
                        for _ in &open {
                            line.push_str("</span>");
                        }
                        lines.push(String::new());
                        let line = lines.last_mut().unwrap();
                        for class in &open {
                            line.push_str(&format!("<span class=\"{class}\">"));
                        }
                        pos += 1;
                        continue;
                    }
                    // Literal run up to the next hole, newline, or run end.
                    let next_hole = holes
                        .get(hole)
                        .map(|h| h.0)
                        .filter(|&o| o > pos && o < end)
                        .unwrap_or(end);
                    let next_nl = bytes[pos..end]
                        .iter()
                        .position(|&b| b == b'\n')
                        .map(|i| pos + i)
                        .unwrap_or(end);
                    let stop = next_hole.min(next_nl);
                    lines
                        .last_mut()
                        .unwrap()
                        .push_str(&prose::escape(&source[pos..stop]));
                    pos = stop;
                }
            }
        }
    }
    // Holes pinned to the very end of the buffer.
    flush_holes(source.len(), &mut hole, &open, &mut lines);
    Ok(lines)
}
@
Highlighting per chunk is improper: a chunk is a fragment, not a valid program, so a
brace, string, or comment that opens in one chunk and closes in another tokenizes
wrong (§5.5, #1). The fix is to tokenize the whole *tangled* file, which is valid,
and map its tokens back onto each chunk. \code{runs} is the token source for that: it
tokenizes any source and returns the flat, innermost highlight run per byte — \code{(start,
end, name index)}, ascending and coalesced — without splicing or splitting. Nesting
collapses to the innermost run, which is the visible color. The weave runs this once per
tangled root and maps the runs back to each chunk (\code{weave.rs}).
<<highlight runs from a source>>=
/// The flat, innermost highlight runs over `source` (§5.5): `(start, end, name
/// index)`, ascending and coalesced, no splice or split. The token source for the
/// tangle-based path — run once per tangled root, then mapped back onto each chunk.
pub fn runs(source: &str, lang: Lang) -> Result<Vec<(usize, usize, usize)>, HlError> {
    let cfg = config(lang)?;
    let mut hl = Highlighter::new();
    let events = hl
        .highlight(&cfg, source.as_bytes(), None, |_| None)
        .map_err(|e| HlError(e.to_string()))?;
    let mut stack: Vec<usize> = Vec::new();
    let mut out: Vec<(usize, usize, usize)> = Vec::new();
    for event in events {
        match event.map_err(|e| HlError(e.to_string()))? {
            HighlightEvent::HighlightStart(h) => stack.push(h.0),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                if let Some(&name) = stack.last() {
                    if let Some(last) = out.last_mut() {
                        if last.1 == start && last.2 == name {
                            last.1 = end;
                            continue;
                        }
                    }
                    out.push((start, end, name));
                }
            }
        }
    }
    Ok(out)
}

/// The `tok-*` class for a run's token index (the third field of a `runs` tuple),
/// so another module can map it to its own scheme (the LSP token legend, §14).
/// An index past the table is `tok-variable`, the same floor the weave uses.
pub fn tok_class(index: usize) -> &'static str {
    TOK_CLASSES.get(index).copied().unwrap_or("tok-variable")
}
@
\code{render_runs} is the other half: it renders one chunk's per-line inner HTML from the
chunk's clean \code{source}, its \code{holes}, and the flat \code{runs} mapped onto that source. It
is the same splice shape as \code{highlight} — a hole is emitted outside any color span, a
line is left self-contained — but the color comes from the given runs (the tangle),
not from tokenizing the fragment. With empty runs it emits exactly the plain-text
payload, so an un-highlighted span is byte-identical to the no-language path.
<<render per-line html from runs>>=
/// Render one chunk's per-line inner HTML from its clean `source`, its `holes`
/// (`(offset, anchor HTML)`, ascending), and the flat highlight `runs` mapped onto
/// `source` (§5.5, #1). Same splice as `highlight`; the color is the runs'.
pub fn render_runs(source: &str, holes: &[(usize, &str)], runs: &[(usize, usize, usize)]) -> Vec<String> {
    let bytes = source.as_bytes();
    // The `tok-*` class of each byte, from the runs (non-overlapping, ascending).
    let mut cls: Vec<Option<&'static str>> = vec![None; bytes.len()];
    for &(s, e, name) in runs {
        let c = TOK_CLASSES.get(name).copied().unwrap_or("tok-variable");
        for slot in cls.iter_mut().take(e.min(bytes.len())).skip(s.min(bytes.len())) {
            *slot = Some(c);
        }
    }
    let mut lines = vec![String::new()];
    let mut open: Option<&'static str> = None;
    let mut hole = 0usize;
    let mut pos = 0usize;
    while pos < bytes.len() {
        // A hole sits outside every color span.
        while hole < holes.len() && holes[hole].0 == pos {
            if open.take().is_some() {
                lines.last_mut().unwrap().push_str("</span>");
            }
            lines.last_mut().unwrap().push_str(holes[hole].1);
            hole += 1;
        }
        if pos >= bytes.len() {
            break;
        }
        if bytes[pos] == b'\n' {
            if open.take().is_some() {
                lines.last_mut().unwrap().push_str("</span>");
            }
            lines.push(String::new());
            pos += 1;
            continue;
        }
        if cls[pos] != open {
            if open.take().is_some() {
                lines.last_mut().unwrap().push_str("</span>");
            }
            if let Some(c) = cls[pos] {
                lines.last_mut().unwrap().push_str(&format!("<span class=\"{c}\">"));
                open = Some(c);
            }
        }
        // Extend to the next class change, newline, or hole.
        let next_hole = holes
            .get(hole)
            .map(|h| h.0)
            .filter(|&o| o > pos)
            .unwrap_or(bytes.len());
        let mut stop = pos + 1;
        while stop < bytes.len() && stop < next_hole && bytes[stop] != b'\n' && cls[stop] == open {
            stop += 1;
        }
        lines.last_mut().unwrap().push_str(&prose::escape(&source[pos..stop]));
        pos = stop;
    }
    if open.is_some() {
        lines.last_mut().unwrap().push_str("</span>");
    }
    while hole < holes.len() && holes[hole].0 == bytes.len() {
        lines.last_mut().unwrap().push_str(holes[hole].1);
        hole += 1;
    }
    lines
}
@
The tests cover both halves: real grammars produce token classes with a byte-
identical plain-text payload, a hole splices back outside any color span, a construct
spanning a line break stays self-contained per line, and the resolver honors each
tier.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model;
    use crate::noweb::parse;

    // The four shipped grammars, by registry id, for the tests.
    fn rust() -> Lang {
        Lang::from_id("rust").unwrap()
    }
    fn nix() -> Lang {
        Lang::from_id("nix").unwrap()
    }
    fn bash() -> Lang {
        Lang::from_id("bash").unwrap()
    }
    fn css() -> Lang {
        Lang::from_id("css").unwrap()
    }

    <<strip tags for the payload check>>

    <<rust keyword and string get classes>>

    <<nix highlights too>>

    <<a hole splices back outside color>>

    <<a line break keeps each line self-contained>>

    <<build a model from markup>>

    <<resolve prefers a chunk-lang override>>

    <<resolve prefers the document default>>

    <<resolve uses the chunk-name extension>>

    <<resolve follows an abstract chunk to its root>>

    <<resolve gives up on an unknown language>>

    <<bash highlights>>

    <<css highlights>>
}
@
Strip every tag, leaving the plain-text payload — used to prove color adds no text.
<<strip tags for the payload check>>=
fn strip_tags(html: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}
@
Rust keywords and strings get classes, and the payload is byte-identical to the old
escape path.
<<rust keyword and string get classes>>=
#[test]
fn rust_keyword_and_string_get_classes() {
    let lines = highlight("let s = \"hi\";", &[], rust()).unwrap();
    assert_eq!(lines.len(), 1);
    assert!(lines[0].contains("tok-keyword"), "{}", lines[0]);
    assert!(lines[0].contains("tok-string"), "{}", lines[0]);
    // The payload is byte-identical to the old escape path — color is a class,
    // not injected text — so `"` is still `&quot;` and nothing else is added.
    assert_eq!(strip_tags(&lines[0]), "let s = &quot;hi&quot;;");
}
@
Nix produces token spans too.
<<nix highlights too>>=
#[test]
fn nix_highlights_too() {
    let lines = highlight("{ x = 1; }", &[], nix()).unwrap();
    assert!(lines[0].contains("tok-"), "{}", lines[0]);
    assert_eq!(strip_tags(&lines[0]), "{ x = 1; }");
}
@
A hole's anchor is spliced back verbatim and never sits inside an open color span.
<<a hole splices back outside color>>=
#[test]
fn a_hole_is_spliced_back_outside_any_color_span() {
    // `let c = ` then a hole then `;` — offset 8 is between the two literals.
    let anchor = "<a href=\"#x\">&lt;<i>next</i>&gt;</a>";
    let lines = highlight("let c = ;", &[(8, anchor)], rust()).unwrap();
    assert_eq!(lines.len(), 1);
    assert!(lines[0].contains(anchor), "{}", lines[0]);
    // The anchor is never inside a tok span.
    let before = &lines[0][..lines[0].find(anchor).unwrap()];
    assert!(
        !before.contains("<span class=\"tok") || before.rmatch_indices("</span>").count() >= before.matches("<span class=\"tok").count(),
        "hole must not sit inside an open tok span: {}",
        lines[0]
    );
}
@
A block comment across two lines opens and closes its own span on each line.
<<a line break keeps each line self-contained>>=
#[test]
fn a_line_break_keeps_each_line_self_contained() {
    // A block comment spans two lines; each line must open and close its own span.
    let lines = highlight("/* a\n b */", &[], rust()).unwrap();
    assert_eq!(lines.len(), 2);
    for l in &lines {
        assert_eq!(l.matches("<span").count(), l.matches("</span>").count(), "{l}");
    }
    assert_eq!(strip_tags(&lines[0]), "/* a");
    assert_eq!(strip_tags(&lines[1]), " b */");
}
@
Build a document model from raw markup IR, for the resolver tests.
<<build a model from markup>>=
fn model_from(markup: &str) -> DocModel {
    model::build(&parse(markup).unwrap()).unwrap()
}
@
Tier 1 beats the chunk's own extension and the default.
<<resolve prefers a chunk-lang override>>=
#[test]
fn resolve_prefers_a_chunk_lang_override() {
    // Tier 1 wins over the chunk's own `.rs` extension (tier 3) and the default.
    let doc = model_from("@file t.cob\n@begin code 0\n@defn build.rs\n@nl\n@text x\n@nl\n@end code 0\n");
    let mut cfg = LangConfig::with_default(Some(rust()));
    cfg.chunk_lang.insert("build.rs".to_string(), bash());
    assert_eq!(resolve(&doc, "build.rs", &cfg), Some(bash()));
}
@
Tier 2 is used when there is no per-chunk entry.
<<resolve prefers the document default>>=
#[test]
fn resolve_prefers_the_document_default() {
    let doc = model_from("@file t.cob\n@begin code 0\n@defn a.rs\n@nl\n@text x\n@nl\n@end code 0\n");
    let cfg = LangConfig::with_default(Some(nix()));
    assert_eq!(resolve(&doc, "a.rs", &cfg), Some(nix()));
}
@
Tier 3 reads the language off the chunk's own name.
<<resolve uses the chunk-name extension>>=
#[test]
fn resolve_uses_the_chunk_name_extension() {
    let doc = model_from("@file t.cob\n@begin code 0\n@defn flake.nix\n@nl\n@text x\n@nl\n@end code 0\n");
    let cfg = LangConfig::default();
    assert_eq!(resolve(&doc, "flake.nix", &cfg), Some(nix()));
}
@
An abstract chunk with no extension inherits its root's language by reachability.
<<resolve follows an abstract chunk to its root>>=
#[test]
fn resolve_follows_an_abstract_chunk_to_its_root() {
    // `main.rs` uses `helper`; `helper` has no extension of its own.
    let ir = "@file t.cob\n\
              @begin code 0\n@defn src/main.rs\n@nl\n@text f(\n@use helper\n@text )\n@nl\n@end code 0\n\
              @begin code 1\n@defn helper\n@nl\n@text 1\n@nl\n@end code 1\n";
    let doc = model_from(ir);
    let cfg = LangConfig::default();
    assert_eq!(resolve(&doc, "helper", &cfg), Some(rust()));
}
@
An unknown extension resolves to nothing, which the weaver treats as plain text.
<<resolve gives up on an unknown language>>=
#[test]
fn resolve_gives_up_on_an_unknown_language() {
    let ir = "@file t.cob\n@begin code 0\n@defn notes.txt\n@nl\n@text x\n@nl\n@end code 0\n";
    let doc = model_from(ir);
    let cfg = LangConfig::default();
    assert_eq!(resolve(&doc, "notes.txt", &cfg), None);
}
@
Bash produces token spans.
<<bash highlights>>=
#[test]
fn bash_highlights() {
    let lines = highlight("if true; then\n  echo hi\nfi", &[], bash()).unwrap();
    let all = lines.join("\n");
    assert!(all.contains("tok-"), "bash produced no token spans: {all}");
}
@
CSS produces token spans, with a byte-identical plain-text payload.
<<css highlights>>=
#[test]
fn css_highlights() {
    let lines = highlight(".chunk { color: red; }", &[], css()).unwrap();
    let all = lines.join("\n");
    assert!(all.contains("tok-"), "css produced no token spans: {all}");
    assert_eq!(strip_tags(&lines[0]), ".chunk { color: red; }");
}
@
