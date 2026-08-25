//! The Markdown prose dialect (SPEC.md §6.1/§6.4).
//!
//! Markdown is a *post-`markup`* transform: it runs on the reassembled prose of
//! a docs chunk, between step 1 (`prose::reassemble`) and the HTML rewrite, and
//! only in Markdown mode. The rest of the pipeline (numbering, refs, math
//! render, sidenote hoist) is untouched — raw HTML the author drops inline
//! (figures, tables, asides with ids, `<a data-ref>`) passes straight through
//! CommonMark, which is exactly how labeled/numbered "islands" keep working.
//!
//! Ordering is the whole subtlety. Fenced blocks come out first so neither the
//! math scanner nor CommonMark touches their bodies; then inline `$…$` is
//! extracted to placeholders (reusing `prose::extract_math`); then CommonMark
//! renders the prose. A ```` ```math ```` fence is display-mode math sugar for
//! `<div class="equation">…</div>` — inside it you write bare LaTeX (the fence
//! *is* the delimiter, so `$` is redundant and never scanned).

use std::fmt;

use pulldown_cmark::{html, Options, Parser};

use crate::prose::{self, Math, ProseError};

/// Everything that can go wrong turning a docs chunk's Markdown into HTML. Math
/// delimiter faults surface as `Prose` (E022, shared with HTML mode); the fenced
/// float directives (`\label`/`\caption` on a `figure`/`table`/`math` fence) have
/// their own faults under `Fence` (E030).
#[derive(Debug)]
pub enum MarkdownError {
    Prose(ProseError),
    Fence { code: &'static str, message: String },
}

impl fmt::Display for MarkdownError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MarkdownError::Prose(e) => write!(f, "error[E022]: {e}"),
            MarkdownError::Fence { code, message } => write!(f, "error[{code}]: {message}"),
        }
    }
}

impl std::error::Error for MarkdownError {}

impl From<ProseError> for MarkdownError {
    fn from(e: ProseError) -> Self {
        MarkdownError::Prose(e)
    }
}

fn fence_err(message: impl Into<String>) -> MarkdownError {
    MarkdownError::Fence {
        code: "E030",
        message: message.into(),
    }
}

/// Render one docs chunk's reassembled prose as Markdown. Appends any math it
/// finds (fenced display first, then inline) to `math`, mirroring the HTML-mode
/// contract so `substitute_math` resolves both by index later.
pub fn render(input: &str, math: &mut Vec<Math>) -> Result<String, MarkdownError> {
    let (protected, code_blocks) = protect_fences(input, math)?;
    let html = render_prose(&protected, math, Options::empty())?;
    Ok(restore_fences(html, &code_blocks))
}

/// The shared prose→HTML path used for the outer document, figure bodies, table
/// bodies, and captions. Cross-references (`\ref{…}`) lower first (they are inert
/// inline HTML), then inline `$…$` math is extracted, then CommonMark renders.
/// `options` enables GFM tables only where a `table` fence asked for them.
fn render_prose(
    src: &str,
    math: &mut Vec<Math>,
    options: Options,
) -> Result<String, MarkdownError> {
    let with_refs = substitute_refs(src);
    let with_math = prose::extract_math(&with_refs, math)?;
    Ok(to_html(&with_math, options))
}

fn to_html(md: &str, options: Options) -> String {
    let parser = Parser::new_ext(md, options);
    let mut out = String::with_capacity(md.len());
    html::push_html(&mut out, parser);
    out
}

/// Lower `\ref{ns:name}` to the same `<a data-ref>` site the HTML dialect uses,
/// so the resolve pass (§7) treats fence-authored and hand-authored references
/// identically. Runs on raw prose, skipping `<code>`/`<pre>` regions and Markdown
/// backtick spans; a `\ref` inside a backtick span is a documented no-op
/// (SPEC.md §6.4) — it is passed through verbatim, never lowered then escaped.
fn substitute_refs(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        if let Some(end) = skip_code(input, i) {
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }
        if let Some(end) = skip_backticks(input, i) {
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }
        if input[i..].starts_with("\\ref") {
            let rest = &input[i + "\\ref".len()..];
            let ws = rest.len() - rest.trim_start().len();
            let brace_at = i + "\\ref".len() + ws;
            if input[brace_at..].starts_with('{') {
                if let Some((name, end)) = brace_content(input, brace_at) {
                    out.push_str(&format!(
                        "<a data-ref=\"{}\"></a>",
                        prose::escape(name.trim())
                    ));
                    i = end;
                    continue;
                }
            }
        }
        let ch = input[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// If `s[at]` opens a Markdown code span (a run of ``` ` ```), return the index
/// just past the matching closing run of the same length, so the whole span
/// (including any `\ref` inside it) is passed through untouched. `None` if `s[at]`
/// is not a backtick or the run never closes — then the backticks are literal
/// text (CommonMark) and scanning proceeds so a following `\ref` still lowers.
fn skip_backticks(s: &str, at: usize) -> Option<usize> {
    let bytes = s.as_bytes();
    if bytes.get(at) != Some(&b'`') {
        return None;
    }
    let open = s[at..].bytes().take_while(|&b| b == b'`').count();
    let mut j = at + open;
    while j < s.len() {
        if bytes[j] == b'`' {
            let run = s[j..].bytes().take_while(|&b| b == b'`').count();
            if run == open {
                return Some(j + run);
            }
            j += run;
        } else {
            j += 1;
        }
    }
    None
}

/// If `s[at..]` opens a `<code>`/`<pre>` element, return the index just past its
/// close so callers can pass the region through verbatim. An unclosed tag
/// swallows the remainder (author markup faults are not ours to raise here).
fn skip_code(s: &str, at: usize) -> Option<usize> {
    for tag in ["code", "pre"] {
        if s[at..].starts_with(&format!("<{tag}"))
            && s[at + 1 + tag.len()..]
                .chars()
                .next()
                .is_some_and(|c| c == '>' || c == ' ' || c == '\n' || c == '\t' || c == '/')
        {
            let close = format!("</{tag}>");
            return Some(match s[at..].find(&close) {
                Some(p) => at + p + close.len(),
                None => s.len(),
            });
        }
    }
    None
}

/// Given `s[start] == '{'`, return the brace-balanced content and the index just
/// past its matching `}`. `None` if the brace is never closed. Nested `{}` (and
/// thus `${…}$` inside a caption) are depth-matched, not terminated early.
fn brace_content(s: &str, start: usize) -> Option<(String, usize)> {
    let bytes = s.as_bytes();
    if bytes.get(start) != Some(&b'{') {
        return None;
    }
    let mut depth = 0usize;
    let mut i = start;
    while i < s.len() {
        match bytes[i] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((s[start + 1..i].to_string(), i + 1));
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Pull every fenced block out before math extraction and Markdown rendering so
/// their bodies are never rescanned. A `math` fence becomes an inert equation
/// placeholder emitted in place; any other fence is rendered to `<pre><code>`
/// and stashed behind a `<pre data-lit-fence="K">` placeholder (a `<pre>`, so
/// the math scanner skips it and CommonMark passes it through as an HTML block).
fn protect_fences(
    input: &str,
    math: &mut Vec<Math>,
) -> Result<(String, Vec<String>), MarkdownError> {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut out_lines: Vec<String> = Vec::new();
    let mut code_blocks: Vec<String> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let Some(ticks) = fence_open(lines[i]) else {
            out_lines.push(lines[i].to_string());
            i += 1;
            continue;
        };
        let info = fence_info(lines[i]);
        let mut body = String::new();
        let mut j = i + 1;
        while j < lines.len() && !fence_close(lines[j], ticks) {
            if !body.is_empty() {
                body.push('\n');
            }
            body.push_str(lines[j]);
            j += 1;
        }
        let placeholder = make_placeholder(&info, &body, math, &mut code_blocks)?;
        // Blank lines around the placeholder so CommonMark starts a fresh HTML
        // block rather than folding it into a surrounding paragraph.
        out_lines.push(String::new());
        out_lines.push(placeholder);
        out_lines.push(String::new());
        // Skip the closing fence line when there was one.
        i = if j < lines.len() { j + 1 } else { j };
    }
    Ok((out_lines.join("\n"), code_blocks))
}

/// The backtick count of an opening fence (≥3), or `None`. An info string that
/// itself contains a backtick is not a valid fence per CommonMark.
fn fence_open(line: &str) -> Option<usize> {
    let t = line.trim_start();
    let ticks = t.chars().take_while(|&c| c == '`').count();
    if ticks < 3 || t[ticks..].contains('`') {
        return None;
    }
    Some(ticks)
}

fn fence_info(line: &str) -> String {
    let t = line.trim_start();
    let ticks = t.chars().take_while(|&c| c == '`').count();
    t[ticks..].trim().to_string()
}

fn fence_close(line: &str, open_ticks: usize) -> bool {
    let t = line.trim();
    let ticks = t.chars().take_while(|&c| c == '`').count();
    !t.is_empty() && ticks == t.len() && ticks >= open_ticks
}

/// A recognised fence directive (or a plain code fence). The `Option<String>` is
/// the `\label{ns:name}` when the author gave one — already namespace-checked
/// against the kind, so a `tbl:` id can never land on a `<figure>`.
enum Fence {
    Math(Option<String>),
    Figure(Option<String>),
    Table(Option<String>),
    Code(String),
}

/// The `id="…"` attribute for an optional label, escaped, or empty.
fn id_attr(label: Option<&str>) -> String {
    label
        .map(|l| format!(" id=\"{}\"", prose::escape(l)))
        .unwrap_or_default()
}

/// Stash a fully rendered HTML block behind an inert `<pre data-lit-fence>`
/// placeholder that the outer CommonMark pass copies through untouched.
fn stash(html: String, code_blocks: &mut Vec<String>) -> String {
    let k = code_blocks.len();
    code_blocks.push(html);
    format!("<pre data-lit-fence=\"{k}\"></pre>")
}

fn make_placeholder(
    info: &str,
    body: &str,
    math: &mut Vec<Math>,
    code_blocks: &mut Vec<String>,
) -> Result<String, MarkdownError> {
    match parse_fence_info(info)? {
        Fence::Math(label) => Ok(render_math(label.as_deref(), body, math)),
        Fence::Figure(label) => {
            let html = render_figure(label.as_deref(), body, math)?;
            Ok(stash(html, code_blocks))
        }
        Fence::Table(label) => {
            let html = render_table(label.as_deref(), body, math)?;
            Ok(stash(html, code_blocks))
        }
        Fence::Code(lang) => {
            let class = if lang.is_empty() {
                String::new()
            } else {
                format!(" class=\"language-{}\"", prose::escape(&lang))
            };
            let html = format!("<pre><code{class}>{}</code></pre>", prose::escape(body));
            Ok(stash(html, code_blocks))
        }
    }
}

/// Split a fence info string into its directive and validated label. A leading
/// word of `math`/`figure`/`table` is a float directive whose remainder must be
/// empty or a single `\label{…}`; anything else is a plain code fence whose info
/// stays the language class.
fn parse_fence_info(info: &str) -> Result<Fence, MarkdownError> {
    let info = info.trim();
    let (kind, rest) = match info.find(char::is_whitespace) {
        Some(p) => (&info[..p], info[p..].trim()),
        None => (info, ""),
    };
    let prefix = match kind {
        "math" => "eq:",
        "figure" => "fig:",
        "table" => "tbl:",
        _ => return Ok(Fence::Code(info.to_string())),
    };
    let label = parse_label(rest, kind, prefix)?;
    Ok(match kind {
        "math" => Fence::Math(label),
        "figure" => Fence::Figure(label),
        _ => Fence::Table(label),
    })
}

/// Parse the optional `\label{ns:name}` after a directive word. The namespace
/// must match the kind (`fig:`/`tbl:`/`eq:`) so a mismatch is caught here rather
/// than silently dropped by the rewrite pass, which keys labels off the id.
fn parse_label(
    rest: &str,
    kind: &str,
    prefix: &str,
) -> Result<Option<String>, MarkdownError> {
    if rest.is_empty() {
        return Ok(None);
    }
    let Some(after) = rest.strip_prefix("\\label") else {
        return Err(fence_err(format!(
            "unexpected `{rest}` after `{kind}` fence; only `\\label{{…}}` is allowed"
        )));
    };
    let after = after.trim_start();
    if !after.starts_with('{') {
        return Err(fence_err("`\\label` must be followed by `{…}`"));
    }
    let (name, end) = brace_content(after, 0).ok_or_else(|| fence_err("unterminated `\\label{`"))?;
    if !after[end..].trim().is_empty() {
        return Err(fence_err(format!("trailing text after `\\label{{{name}}}`")));
    }
    let name = name.trim();
    if !name.starts_with(prefix) {
        return Err(fence_err(format!(
            "label `{name}` on a `{kind}` fence must use the `{prefix}` namespace"
        )));
    }
    Ok(Some(name.to_string()))
}

/// A `math` fence is display-mode math sugar for the equation div (§6.4). The
/// body is bare LaTeX (the fence *is* the delimiter, so `$` is not scanned).
fn render_math(label: Option<&str>, body: &str, math: &mut Vec<Math>) -> String {
    let idx = math.len();
    math.push(Math {
        source: body.to_string(),
        display: true,
    });
    format!(
        "<div class=\"equation\"{}><span data-lit-math=\"{idx}\"></span></div>",
        id_attr(label)
    )
}

/// A `figure` fence: an optional leading `\caption{…}`, then block Markdown for
/// the figure body. Emits a real `<figure id><figcaption>` so all of the
/// numbering/labelling/ref machinery downstream is reused unchanged.
fn render_figure(
    label: Option<&str>,
    body: &str,
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (caption, rest) = take_caption(body)?;
    let body_html = render_prose(rest.trim(), math, Options::empty())?;
    let cap_html = match caption {
        Some(c) => format!("\n<figcaption>{}</figcaption>", render_caption(&c, math)?),
        None => String::new(),
    };
    Ok(format!(
        "<figure{}>\n{body_html}{cap_html}\n</figure>",
        id_attr(label)
    ))
}

/// A `table` fence: an optional leading `\caption{…}`, then a GFM pipe table
/// (tables are enabled *only* here, so bare pipes in prose stay literal). The id
/// and `<caption>` are spliced into the bare `<table>` pulldown-cmark emits.
fn render_table(
    label: Option<&str>,
    body: &str,
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (caption, rest) = take_caption(body)?;
    let body_html = render_prose(rest.trim(), math, Options::ENABLE_TABLES)?;
    let cap_html = match caption {
        Some(c) => format!("<caption>{}</caption>", render_caption(&c, math)?),
        None => String::new(),
    };
    let open = format!("<table{}>", id_attr(label));
    Ok(match body_html.strip_prefix("<table>") {
        Some(inner) => format!("{open}{cap_html}{inner}"),
        None => format!("{open}{cap_html}{body_html}</table>"),
    })
}

/// Peel a leading `\caption{…}` (brace-balanced, possibly multi-line) off a
/// fence body, returning its source and the remaining body.
fn take_caption(body: &str) -> Result<(Option<String>, String), MarkdownError> {
    let trimmed = body.trim_start();
    let Some(after) = trimmed.strip_prefix("\\caption") else {
        return Ok((None, body.to_string()));
    };
    let after = after.trim_start();
    if !after.starts_with('{') {
        return Err(fence_err("`\\caption` must be followed by `{…}`"));
    }
    let (cap, end) =
        brace_content(after, 0).ok_or_else(|| fence_err("unterminated `\\caption{`"))?;
    Ok((Some(cap), after[end..].to_string()))
}

/// Render caption source as inline Markdown+math, unwrapping the single
/// paragraph pulldown-cmark wraps it in so it sits directly in the caption tag.
fn render_caption(src: &str, math: &mut Vec<Math>) -> Result<String, MarkdownError> {
    let html = render_prose(src.trim(), math, Options::empty())?;
    let html = html.trim();
    Ok(html
        .strip_prefix("<p>")
        .and_then(|h| h.strip_suffix("</p>"))
        .unwrap_or(html)
        .to_string())
}

fn restore_fences(mut html: String, blocks: &[String]) -> String {
    for (k, block) in blocks.iter().enumerate() {
        let ph = format!("<pre data-lit-fence=\"{k}\"></pre>");
        html = html.replace(&ph, block);
    }
    html
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &str) -> (String, Vec<Math>) {
        let mut math = Vec::new();
        let html = render(input, &mut math).expect("renders");
        (html, math)
    }

    #[test]
    fn paragraphs_and_inline_marks() {
        let (html, _) = run("plain prose with *em* and **strong** and a `span`.");
        assert!(html.contains("<p>plain prose with <em>em</em> and <strong>strong</strong> and a <code>span</code>.</p>"));
    }

    #[test]
    fn heading_and_list() {
        let (html, _) = run("# Title\n\n- one\n- two\n");
        assert!(html.contains("<h1>Title</h1>"));
        assert!(html.contains("<li>one</li>"));
        assert!(html.contains("<li>two</li>"));
    }

    #[test]
    fn raw_html_island_passes_through_verbatim() {
        let island = "<figure id=\"fig:a\"><img src=\"p.svg\"><figcaption>Cap.</figcaption></figure>";
        let (html, _) = run(&format!("text\n\n{island}\n\nmore"));
        assert!(html.contains(island));
    }

    #[test]
    fn reassembled_inline_code_survives() {
        // `[[…]]` is lowered to <code> before Markdown; it must pass through.
        let (html, _) = run("see <code>lex()</code> there");
        assert!(html.contains("<code>lex()</code>"));
    }

    #[test]
    fn fenced_math_is_a_numbered_display_equation() {
        let (html, math) = run("intro\n\n```math\nslot(i) = (head + i) \\bmod n\n```\n\nafter");
        assert_eq!(math.len(), 1);
        assert!(math[0].display);
        assert_eq!(math[0].source, "slot(i) = (head + i) \\bmod n");
        assert!(html.contains("<div class=\"equation\"><span data-lit-math=\"0\"></span></div>"));
    }

    #[test]
    fn inline_math_is_still_extracted() {
        let (html, math) = run("the tail is $\\operatorname{slot}(n)$ here");
        assert_eq!(math.len(), 1);
        assert!(!math[0].display);
        assert_eq!(math[0].source, "\\operatorname{slot}(n)");
        assert!(html.contains("<span data-lit-math=\"0\"></span>"));
    }

    #[test]
    fn dollar_inside_a_code_fence_is_not_math() {
        let (html, math) = run("```\necho $HOME > $OUT\n```");
        assert!(math.is_empty());
        assert!(html.contains("<pre><code>echo $HOME &gt; $OUT</code></pre>"));
    }

    #[test]
    fn fenced_math_indexes_before_inline() {
        let (_, math) = run("```math\na\n```\n\ntext $b$ more");
        assert_eq!(math.len(), 2);
        assert_eq!((math[0].source.as_str(), math[0].display), ("a", true));
        assert_eq!((math[1].source.as_str(), math[1].display), ("b", false));
    }

    #[test]
    fn labeled_math_fence_carries_its_id() {
        let (html, math) = run("```math \\label{eq:wrap}\nx = y\n```");
        assert_eq!(math.len(), 1);
        assert!(html.contains(
            "<div class=\"equation\" id=\"eq:wrap\"><span data-lit-math=\"0\"></span></div>"
        ));
    }

    #[test]
    fn figure_fence_emits_figure_with_caption() {
        let (html, _) = run(
            "```figure \\label{fig:p}\n\\caption{The *pipeline* stages.}\n<img src=\"p.svg\">\n```",
        );
        assert!(html.contains("<figure id=\"fig:p\">"));
        assert!(html.contains("<img src=\"p.svg\">"));
        assert!(html.contains("<figcaption>The <em>pipeline</em> stages.</figcaption>"));
    }

    #[test]
    fn table_fence_parses_pipe_table_and_splices_id_and_caption() {
        let (html, _) = run(
            "```table \\label{tbl:api}\n\\caption{The API.}\n| A | B |\n|---|---|\n| 1 | 2 |\n```",
        );
        assert!(html.contains("<table id=\"tbl:api\">"));
        assert!(html.contains("<caption>The API.</caption>"));
        assert!(html.contains("<th>A</th>"));
        assert!(html.contains("<td>1</td>"));
    }

    #[test]
    fn bare_pipe_table_in_prose_stays_literal() {
        // Tables are enabled only inside a `table` fence, never in prose.
        let (html, _) = run("| A | B |\n|---|---|\n| 1 | 2 |\n");
        assert!(!html.contains("<table"));
    }

    #[test]
    fn multiline_caption_with_braces_is_balanced() {
        let (html, _) = run(
            "```figure\n\\caption{first line\nand $a_{i}$ second}\n<img src=\"p.svg\">\n```",
        );
        assert!(html.contains("<figcaption>first line\nand <span data-lit-math=\"0\"></span> second</figcaption>"));
    }

    #[test]
    fn ref_lowers_to_a_data_ref() {
        let (html, _) = run("see \\ref{fig:p} and \\ref{eq:wrap}.");
        assert!(html.contains("<a data-ref=\"fig:p\"></a>"));
        assert!(html.contains("<a data-ref=\"eq:wrap\"></a>"));
    }

    #[test]
    fn ref_inside_inline_html_code_is_skipped() {
        let (html, _) = run("call <code>\\ref{x}</code> literally");
        assert!(html.contains("<code>\\ref{x}</code>"));
        assert!(!html.contains("data-ref"));
    }

    #[test]
    fn ref_inside_backtick_span_is_literal() {
        // A `\ref` in a Markdown code span is a documented no-op (§6.4): it must
        // survive as literal text in a <code>, never be lowered then escaped.
        let (html, _) = run("write `\\ref{fig:p}` then \\ref{fig:p} resolves");
        assert!(html.contains("<code>\\ref{fig:p}</code>"));
        assert!(!html.contains("&lt;a data-ref"));
        // The real `\ref` outside the span still lowers.
        assert!(html.contains("<a data-ref=\"fig:p\"></a>"));
    }

    #[test]
    fn unclosed_backtick_run_does_not_swallow_a_later_ref() {
        // A lone backtick with no closing run is literal text; the following
        // `\ref` must still lower.
        let (html, _) = run("a ` stray tick then \\ref{eq:x} here");
        assert!(html.contains("<a data-ref=\"eq:x\"></a>"));
    }

    #[test]
    fn mismatched_label_namespace_is_e030() {
        let mut math = Vec::new();
        let err = render("```figure \\label{tbl:x}\n\\caption{c}\n<img>\n```", &mut math)
            .unwrap_err();
        assert!(matches!(err, MarkdownError::Fence { code: "E030", .. }));
        assert!(err.to_string().contains("fig:"));
    }

    #[test]
    fn code_fence_with_language_is_unchanged() {
        let (html, _) = run("```rust\nlet x = 1;\n```");
        assert!(html.contains("<pre><code class=\"language-rust\">let x = 1;</code></pre>"));
    }

    #[test]
    fn round_trips_through_math_substitution() {
        // Both placeholders render() emits must resolve by index. Fenced display
        // math is pulled first (index 0), inline `$…$` after (index 1).
        let mut math = Vec::new();
        let html = render("$x$\n\n```math\ny\n```", &mut math).unwrap();
        assert_eq!((math[0].source.as_str(), math[0].display), ("y", true));
        assert_eq!((math[1].source.as_str(), math[1].display), ("x", false));
        let out = prose::substitute_math(
            &html,
            &["<DISPLAY/>".to_string(), "<INLINE/>".to_string()],
        );
        assert!(out.contains("<div class=\"equation\"><DISPLAY/></div>"));
        assert!(out.contains("<INLINE/>"));
    }
}
