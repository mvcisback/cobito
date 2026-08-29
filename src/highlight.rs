//! Syntax highlighting (§5.5). A code chunk is not a valid program: it is
//! target-language text with *chunk-use holes* (`<<next char>>`) spliced in, and
//! those are lit's syntax, not the target's. So the tokenizer never sees a hole —
//! we hand tree-sitter only the literal runs between holes and splice the holes'
//! anchors back afterward, exactly the discipline the math pass uses (§6.2).
//!
//! Color is a CSS `tok-*` class, never injected text, so §5.4's copy-paste and the
//! annotation layer's quote selectors (§9.2) see the same bytes they saw before —
//! and there is no `<script>`, so the archival invariant (§6.3) holds.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::rc::Rc;

use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

use crate::model::{CodeSpan, DocModel, SectionKind};
use crate::prose;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lang {
    Rust,
    Nix,
    Bash,
    Css,
}

impl Lang {
    /// The id printed by `lit language` and used to select a grammar.
    pub fn id(self) -> &'static str {
        match self {
            Lang::Rust => "rust",
            Lang::Nix => "nix",
            Lang::Bash => "bash",
            Lang::Css => "css",
        }
    }

    /// Parse a language id from config (`[weave] lang`, `[weave.chunk-lang]`).
    /// Unknown ⇒ `None`.
    pub fn from_id(id: &str) -> Option<Lang> {
        match id {
            "rust" => Some(Lang::Rust),
            "nix" => Some(Lang::Nix),
            "bash" => Some(Lang::Bash),
            "css" => Some(Lang::Css),
            _ => None,
        }
    }

    /// A file extension (no dot) ⇒ language (§5.5 tier 3).
    pub fn from_ext(ext: &str) -> Option<Lang> {
        match ext {
            "rs" => Some(Lang::Rust),
            "nix" => Some(Lang::Nix),
            "sh" | "bash" => Some(Lang::Bash),
            "css" => Some(Lang::Css),
            _ => None,
        }
    }

    /// A chunk/root *name* that ends in a known extension names its language.
    fn from_name(name: &str) -> Option<Lang> {
        name.rsplit_once('.').and_then(|(_, ext)| Lang::from_ext(ext))
    }
}

/// The resolved highlighting configuration for a document (§5.5). `default` is the
/// document-wide `[weave] lang` (tier 2); `chunk_lang` is the `[weave.chunk-lang]`
/// map (tier 1), keyed by chunk name. Both are already parsed to `Lang`, so an
/// unknown id is rejected once, at config-load time, not here.
#[derive(Debug, Default, Clone)]
pub struct LangConfig {
    pub default: Option<Lang>,
    pub chunk_lang: HashMap<String, Lang>,
}

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

#[derive(Debug)]
pub struct HlError(String);

impl fmt::Display for HlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "highlighting: {}", self.0)
    }
}

impl std::error::Error for HlError {}

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

thread_local! {
    // One configured grammar per language, built on first use. Confined to the
    // weave thread; determinism is unaffected (the config is a pure function of
    // the pinned grammar + query).
    static CONFIGS: RefCell<HashMap<Lang, Rc<HighlightConfiguration>>> =
        RefCell::new(HashMap::new());
}

fn config(lang: Lang) -> Result<Rc<HighlightConfiguration>, HlError> {
    if let Some(cfg) = CONFIGS.with(|m| m.borrow().get(&lang).cloned()) {
        return Ok(cfg);
    }
    let (language, query) = match lang {
        Lang::Rust => (tree_sitter_rust::LANGUAGE, tree_sitter_rust::HIGHLIGHTS_QUERY),
        Lang::Nix => (tree_sitter_nix::LANGUAGE, tree_sitter_nix::HIGHLIGHTS_QUERY),
        Lang::Bash => (tree_sitter_bash::LANGUAGE, tree_sitter_bash::HIGHLIGHT_QUERY),
        Lang::Css => (tree_sitter_css::LANGUAGE, tree_sitter_css::HIGHLIGHTS_QUERY),
    };
    let mut cfg = HighlightConfiguration::new(language.into(), lang.id(), query, "", "")
        .map_err(|e| HlError(e.to_string()))?;
    cfg.configure(HL_NAMES);
    let cfg = Rc::new(cfg);
    CONFIGS.with(|m| m.borrow_mut().insert(lang, cfg.clone()));
    Ok(cfg)
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model;
    use crate::noweb::parse;

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

    #[test]
    fn rust_keyword_and_string_get_classes() {
        let lines = highlight("let s = \"hi\";", &[], Lang::Rust).unwrap();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("tok-keyword"), "{}", lines[0]);
        assert!(lines[0].contains("tok-string"), "{}", lines[0]);
        // The payload is byte-identical to the old escape path — color is a class,
        // not injected text — so `"` is still `&quot;` and nothing else is added.
        assert_eq!(strip_tags(&lines[0]), "let s = &quot;hi&quot;;");
    }

    #[test]
    fn nix_highlights_too() {
        let lines = highlight("{ x = 1; }", &[], Lang::Nix).unwrap();
        assert!(lines[0].contains("tok-"), "{}", lines[0]);
        assert_eq!(strip_tags(&lines[0]), "{ x = 1; }");
    }

    #[test]
    fn a_hole_is_spliced_back_outside_any_color_span() {
        // `let c = ` then a hole then `;` — offset 8 is between the two literals.
        let anchor = "<a href=\"#x\">&lt;<i>next</i>&gt;</a>";
        let lines = highlight("let c = ;", &[(8, anchor)], Lang::Rust).unwrap();
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

    #[test]
    fn a_line_break_keeps_each_line_self_contained() {
        // A block comment spans two lines; each line must open and close its own span.
        let lines = highlight("/* a\n b */", &[], Lang::Rust).unwrap();
        assert_eq!(lines.len(), 2);
        for l in &lines {
            assert_eq!(l.matches("<span").count(), l.matches("</span>").count(), "{l}");
        }
        assert_eq!(strip_tags(&lines[0]), "/* a");
        assert_eq!(strip_tags(&lines[1]), " b */");
    }

    fn model_from(markup: &str) -> DocModel {
        model::build(&parse(markup).unwrap()).unwrap()
    }

    #[test]
    fn resolve_prefers_a_chunk_lang_override() {
        // Tier 1 wins over the chunk's own `.rs` extension (tier 3) and the default.
        let doc = model_from("@file t.nw\n@begin code 0\n@defn build.rs\n@nl\n@text x\n@nl\n@end code 0\n");
        let mut cfg = LangConfig::with_default(Some(Lang::Rust));
        cfg.chunk_lang.insert("build.rs".to_string(), Lang::Bash);
        assert_eq!(resolve(&doc, "build.rs", &cfg), Some(Lang::Bash));
    }

    #[test]
    fn resolve_prefers_the_document_default() {
        let doc = model_from("@file t.nw\n@begin code 0\n@defn a.rs\n@nl\n@text x\n@nl\n@end code 0\n");
        let cfg = LangConfig::with_default(Some(Lang::Nix));
        assert_eq!(resolve(&doc, "a.rs", &cfg), Some(Lang::Nix));
    }

    #[test]
    fn resolve_uses_the_chunk_name_extension() {
        let doc = model_from("@file t.nw\n@begin code 0\n@defn flake.nix\n@nl\n@text x\n@nl\n@end code 0\n");
        let cfg = LangConfig::default();
        assert_eq!(resolve(&doc, "flake.nix", &cfg), Some(Lang::Nix));
    }

    #[test]
    fn resolve_follows_an_abstract_chunk_to_its_root() {
        // `main.rs` uses `helper`; `helper` has no extension of its own.
        let ir = "@file t.nw\n\
                  @begin code 0\n@defn src/main.rs\n@nl\n@text f(\n@use helper\n@text )\n@nl\n@end code 0\n\
                  @begin code 1\n@defn helper\n@nl\n@text 1\n@nl\n@end code 1\n";
        let doc = model_from(ir);
        let cfg = LangConfig::default();
        assert_eq!(resolve(&doc, "helper", &cfg), Some(Lang::Rust));
    }

    #[test]
    fn resolve_gives_up_on_an_unknown_language() {
        let ir = "@file t.nw\n@begin code 0\n@defn notes.txt\n@nl\n@text x\n@nl\n@end code 0\n";
        let doc = model_from(ir);
        let cfg = LangConfig::default();
        assert_eq!(resolve(&doc, "notes.txt", &cfg), None);
    }

    #[test]
    fn bash_highlights() {
        let lines = highlight("if true; then\n  echo hi\nfi", &[], Lang::Bash).unwrap();
        let all = lines.join("\n");
        assert!(all.contains("tok-"), "bash produced no token spans: {all}");
    }

    #[test]
    fn css_highlights() {
        let lines = highlight(".chunk { color: red; }", &[], Lang::Css).unwrap();
        let all = lines.join("\n");
        assert!(all.contains("tok-"), "css produced no token spans: {all}");
        assert_eq!(strip_tags(&lines[0]), ".chunk { color: red; }");
    }
}
