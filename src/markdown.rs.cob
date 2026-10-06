# The prose dialect (§6.4)

This module is the specification and the implementation of cob's prose dialect.
The prose is the specification. The chunks after it are the implementation.

## Why cob owns the dialect {#sec:xZ8V}

cob tells a program as a document, so the prose surface must be small and ours.
CommonMark is large and hard to reason about: its emphasis rule is an operational
flanking algorithm, its raw-HTML blocks have seven start conditions, and its link
definitions need two passes. cob owns a small line-oriented block grammar and a
LaTeX-style command family instead. The \code{peg} crate — the same crate that reads
\code{.cob} — builds the inline grammar into a parser at compile time. A post-pass
lowers the tokens to HTML.

## The command family {#sec:TAUn}

Marks are commands, not punctuation, so there is no flanking rule to get wrong:

- \code{\emph{…}} makes \code{<em>} and \code{\strong{…}} makes \code{<strong>}. Both nest.
- \code{\code{…}} makes inline \code{<code>}. The body is verbatim; cob escapes it for
  HTML. Balanced braces inside need no escape (\code{\code{fn f() { x }}}); a lone
  brace uses \code{\{} or \code{\}}.
- \code{$…$} is inline math and \code{$$…$$} is display math. A literal dollar is \code{\$}.
- \code{\ref{ns:name}} makes the same \code{<a data-ref>} the resolver reads (§7).
- \code{\cite{key}} makes one \code{<a data-cite>} marker per key; \code{\cite{k1, k2}} makes two.
  The weaver mints each cited work a node id and draws the \code{[id]} marker (§14).
- \code{\transclude{sec:name}} makes the transclusion island the weaver expands (§10).
  A paragraph that is only a \code{\transclude} makes the bare island, not a \code{<p>}.

Inline code is \code{\code{…}} or a backtick span (\code{`…`}); both are the same
\code{<code>} and both are literal — a \code{\ref}, \code{\cite}, \code{\transclude}, or \code{$…$} inside
either is text, never a command, because the grammar captures the span's body
whole and never reads it. An unmatched backtick is a literal backtick. (Use
\code{\code{}} when the body itself holds a backtick.)

## The block grammar {#sec:k8T0}

A line loop frames the inline grammar, the way the reader's file loop frames its
line grammar. Blank lines split blocks. cob knows:

- an ATX heading (\code{#}…\code{######} then a space), with an optional trailing
  \code{{#sec:name}} id;
- a bullet list (\code{- }) or an ordered list (\code{1. }), one level deep;
- a fenced block (opened and closed by \code{```}), whose info line is a kind and
  optional modifiers (\code{\label{ns:name}}, \code{\lang{name}});
- a paragraph — every other run of non-blank lines.

## The fenced blocks {#sec:UWqg}

The kind word picks the block. The set is closed:

- \code{math} is display math. The body is bare LaTeX (the fence is the delimiter, so
  a \code{$} is redundant). It makes an equation div.
- \code{figure} takes an optional leading \code{\caption{…}}, then a raw-HTML body (an
  image or an SVG), and makes a \code{<figure>} with an optional \code{<figcaption>}.
- \code{table} takes an optional \code{\caption{…}}, then a pipe table, and makes a
  \code{<table>} with a \code{<caption>}.
- \code{html-escape} is the one door for raw HTML. Its body passes through verbatim. It
  subsumes the old \code{html} dialect and every raw-HTML island (a sidenote aside is
  now an \code{html-escape} fence).
- \code{verbatim} is preformatted plain text: \code{<pre><code>} with an escaped body. An
  optional \code{\lang{name}} modifier adds a \code{language-name} class for an editor or a
  reader to key on.
- \code{macros} defines math macros and shows them as a node (see below). It needs a
  \code{\label{def:name}}, because it is a node.

There is no silent fallback. A bare fence (no kind) or an unknown kind is E034, so
a typo is an error, not a wrong render.

## Modifiers and namespaces {#sec:k8T1}

The info line is a kind, then modifiers, each a command. The grammar parses them,
so a malformed modifier is an error, not a silent drop. \code{\label{ns:name}} names a
float: its namespace must match the kind (\code{eq:} for \code{math}, \code{fig:} for \code{figure},
\code{tbl:} for \code{table}), and a mismatch is E030. \code{\lang{name}} is for \code{verbatim} only.
A \code{\caption{…}} leads the body of a \code{figure} or a \code{table}. A float with no \code{\label}
gets no id and is not referenceable (§7.1).

## Math order {#sec:k8T2}

cob walks the blocks in document order and pushes each formula onto the shared
\code{math} list as it meets it. The index is internal: \code{substitute_math} (§6.2 step 6)
maps each placeholder back by its own index, so the order the list is built in
does not change the output.

## Macro expositions {#sec:JT0X}

A document with much math needs shared macros. The \code{macros} fence gives them.
Its body is normal prose, so the author writes the exposition. Between the prose,
a \code{\def} or a \code{\let} line defines one macro:

- \code{\def\RR} with a body in braces defines a macro.
- \code{\def\abs} with named parameters in brackets, then a body that uses them, takes
  arguments: \code{\def\abs[x]{\lvert \x \rvert}}, used as \code{\abs{y}}.
- \code{\let\R} then \code{=} then a name makes one name an alias of another.

The fence follows forester: it uses \code{\def} and \code{\let}, not \code{\newcommand}, and
its parameters are named brackets, not \code{#1}. cob owns these two directives and does
two things with each. First, it records the definition in a document-wide macro
table (name to expansion). The math renderer passes this table to KaTeX's \code{macros}
option — it does **not** prepend it to any formula (§6.3) — so a macro works in every
formula, and a formula's copy-paste annotation stays just the formula, with no
definition leaking into it. cob maps each forester parameter to a KaTeX \code{#n} in
order, so KaTeX does the argument substitution. Second, cob shows the definition
verbatim, as a code block, so the reader sees the source.

cob does not typeset a definition — it does not render \code{\RR} as its expansion.
The writer explains the macros in the prose, where they are in scope, and so
chooses how to show them. A \code{\def}/\code{\let} line is a definition only in a
\code{macros} fence; in ordinary prose the same line is literal text.

The fence is a node (§10). It carries a \code{def:} label and earns a frozen id, so it
gets its own page under \code{n/}. The node is homeless: it does not render where the
author writes it. The reader sees the exposition on the node page, or where the
author puts \code{\transclude{def:name}}. A \code{\ref{def:name}} links to the node page.
So the macros stay modular. There is no document-wide list.

## How the code implements this {#sec:lisV}

The module is the error type, the public render, the block loop, the block
renderers, the inline grammar and its lowering, the fence helpers, and the tests.
<<src/markdown.rs>>=
<<the module banner>>

<<imports>>

<<the markdown error>>

<<render a docs chunk>>

<<the raw block>>

<<split into blocks>>

<<recognise a fence line>>

<<recognise a heading line>>

<<recognise a list item>>

<<render a heading>>

<<render a list>>

<<render a paragraph>>

<<render a fence>>

<<render a math fence>>

<<render a macro definition>>

<<render a figure fence>>

<<render a table fence>>

<<peel a caption>>

<<parse the fence info>>

<<an id attribute>>

<<the inline grammar>>

<<the inline node>>

<<lower inline nodes>>

<<render one inline run>>

<<the escape helpers>>

<<the tests>>
@
The banner states where the dialect sits and what it owns.
<<the module banner>>=
//! cob's prose dialect (§6.4). A line loop splits a docs chunk into blocks; a
//! `peg` inline grammar tokenises each run into commands, math, and text; a
//! lowering pass makes HTML. cob owns the whole surface — there is no CommonMark
//! engine. Marks are commands (`\emph`, `\strong`, `\code`), so there is no
//! emphasis flanking rule. Raw HTML has one door: the ```` ```html-escape ````
//! fence.
@
Formatting, the shared prose helpers, and the \code{peg} runtime.
<<imports>>=
use std::collections::BTreeMap;
use std::fmt;

use crate::prose::{self, Math};
@
Two failure classes. A prose or math syntax fault is \code{Syntax} (E022). A fence
fault is \code{Fence}, which carries its code: a bad \code{\label}/\code{\caption}/\code{\lang}
modifier is E030 (\code{fence_err}); a bare or unknown fence kind is E034
(\code{kind_err}).
<<the markdown error>>=
/// A prose dialect fault. `Syntax` is a parse or math fault (E022); `Fence` is a
/// fence fault carrying its own code — a bad modifier (E030) or a bare/unknown
/// kind (E034).
#[derive(Debug)]
pub enum MarkdownError {
    Syntax(String),
    Fence { code: &'static str, message: String },
}

impl fmt::Display for MarkdownError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MarkdownError::Syntax(m) => write!(f, "error[E022]: {m}"),
            MarkdownError::Fence { code, message } => write!(f, "error[{code}]: {message}"),
        }
    }
}

impl std::error::Error for MarkdownError {}

fn fence_err(message: impl Into<String>) -> MarkdownError {
    MarkdownError::Fence {
        code: "E030",
        message: message.into(),
    }
}

fn kind_err(message: impl Into<String>) -> MarkdownError {
    MarkdownError::Fence {
        code: "E034",
        message: message.into(),
    }
}
@
The top level splits the reassembled prose into blocks, renders each in document
order, and joins them. It appends any math it meets to \code{math}, so
\code{substitute_math} resolves each placeholder by index later (§6.2).
<<render a docs chunk>>=
/// Render one docs chunk's reassembled prose. Appends every formula it meets to
/// `math` in document order; `substitute_math` resolves each placeholder by its
/// own index later (§6.2), so the build order does not change the output.
pub fn render(
    input: &str,
    math: &mut Vec<Math>,
    defs: &mut BTreeMap<String, String>,
) -> Result<String, MarkdownError> {
    render_ctx(input, math, defs, false)
}

/// The block loop. `macros` is true only while rendering a `macros` fence body,
/// where a `\def`/`\let` line is a macro definition (§6.4), not prose. A `macros`
/// body records its definitions in `defs` (name → expansion); every other block
/// ignores it.
fn render_ctx(
    input: &str,
    math: &mut Vec<Math>,
    defs: &mut BTreeMap<String, String>,
    macros: bool,
) -> Result<String, MarkdownError> {
    let mut out: Vec<String> = Vec::new();
    for block in split_blocks(input, macros) {
        let html = match block {
            RawBlock::Fence { info, body } => render_fence(&info, &body, math, defs)?,
            RawBlock::Heading { level, text } => render_heading(level, &text, math)?,
            RawBlock::List { ordered, items } => render_list(ordered, &items, math)?,
            RawBlock::Paragraph(text) => render_paragraph(&text, math)?,
            RawBlock::MacroDef(src) => render_macro_def(&src, defs)?,
        };
        if !html.is_empty() {
            out.push(html);
        }
    }
    Ok(out.join("\n"))
}
@
A raw block is the line loop's output before inline rendering: a fence with its
info and body, a heading with its level and text, a one-level list, or a paragraph.
<<the raw block>>=
enum RawBlock {
    Fence { info: String, body: String },
    Heading { level: usize, text: String },
    List { ordered: bool, items: Vec<String> },
    Paragraph(String),
    /// A `\def`/`\let` line inside a `macros` fence body (§6.4).
    MacroDef(String),
}
@
The line loop. A blank line is a separator. A fence runs to its closing fence,
blank lines included. A heading is one line. A list is a run of item lines. Every
other run of non-blank lines is a paragraph, cut at the next fence, heading, or
list.
<<split into blocks>>=
fn split_blocks(input: &str, macros: bool) -> Vec<RawBlock> {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        if lines[i].trim().is_empty() {
            i += 1;
            continue;
        }
        // In a `macros` body, a run of `\def`/`\let` lines is one definition block,
        // shown verbatim as one code block.
        if macros && is_macro_def_line(lines[i]) {
            let mut defs = Vec::new();
            while i < lines.len() && is_macro_def_line(lines[i]) {
                defs.push(lines[i].trim());
                i += 1;
            }
            blocks.push(RawBlock::MacroDef(defs.join("\n")));
            continue;
        }
        if let Some(ticks) = fence_open(lines[i]) {
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
            blocks.push(RawBlock::Fence { info, body });
            i = if j < lines.len() { j + 1 } else { j };
            continue;
        }
        if let Some((level, text)) = heading_line(lines[i]) {
            blocks.push(RawBlock::Heading { level, text });
            i += 1;
            continue;
        }
        if list_item(lines[i]).is_some() {
            let ordered = ordered_item(lines[i]).is_some();
            let mut items = Vec::new();
            while i < lines.len() {
                let want = if ordered {
                    ordered_item(lines[i])
                } else {
                    bullet_item(lines[i])
                };
                match want {
                    Some(content) => {
                        items.push(content);
                        i += 1;
                    }
                    None => break,
                }
            }
            blocks.push(RawBlock::List { ordered, items });
            continue;
        }
        let mut para = String::new();
        while i < lines.len() {
            let l = lines[i];
            if l.trim().is_empty()
                || fence_open(l).is_some()
                || heading_line(l).is_some()
                || list_item(l).is_some()
                || (macros && is_macro_def_line(l))
            {
                break;
            }
            if !para.is_empty() {
                para.push('\n');
            }
            para.push_str(l);
            i += 1;
        }
        blocks.push(RawBlock::Paragraph(para));
    }
    blocks
}

/// A `macros` body line that begins a `\def` or `\let` definition. The keyword
/// must be a whole control word, so a longer word like `\define` is not caught.
fn is_macro_def_line(line: &str) -> bool {
    let t = line.trim_start();
    ["\\def", "\\let"].iter().any(|kw| {
        t.strip_prefix(kw)
            .is_some_and(|rest| !rest.chars().next().is_some_and(|c| c.is_ascii_alphabetic()))
    })
}
@
Three predicates recognise a fence line: the opening backtick count (three or more,
no backtick in the info), the info string, and whether a line closes a fence.
<<recognise a fence line>>=
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
@
A heading line is one to six leading \code{#} and a space, then the text (which may end
with a \code{{#sec:name}} id).
<<recognise a heading line>>=
fn heading_line(line: &str) -> Option<(usize, String)> {
    let hashes = line.chars().take_while(|&c| c == '#').count();
    if (1..=6).contains(&hashes) && line[hashes..].starts_with(' ') {
        Some((hashes, line[hashes + 1..].trim_end().to_string()))
    } else {
        None
    }
}
@
A list item is a bullet (\code{- }) or an ordered marker (\code{1. }). \code{list_item} is either;
the split loop uses \code{ordered_item}/\code{bullet_item} to keep one list one kind.
<<recognise a list item>>=
fn bullet_item(line: &str) -> Option<String> {
    line.strip_prefix("- ").map(|s| s.to_string())
}

fn ordered_item(line: &str) -> Option<String> {
    let digits = line.chars().take_while(|c| c.is_ascii_digit()).count();
    if digits > 0 && line[digits..].starts_with(". ") {
        Some(line[digits + 2..].to_string())
    } else {
        None
    }
}

fn list_item(line: &str) -> Option<String> {
    bullet_item(line).or_else(|| ordered_item(line))
}
@
A heading renders its text as one inline run, with the optional id split off the
tail. The id is source-anchored (§7.1), so \code{cob lock} writes \code{{#sec:<id>}} here.
<<render a heading>>=
fn render_heading(
    level: usize,
    text: &str,
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (inline_src, id) = split_heading_attr(text.trim());
    let inner = render_inline(inline_src.trim(), math)?;
    let attr = match id {
        Some(id) => format!(" id=\"{}\"", prose::escape(id)),
        None => String::new(),
    };
    Ok(format!("<h{level}{attr}>{inner}</h{level}>"))
}

fn split_heading_attr(text: &str) -> (&str, Option<&str>) {
    let t = text.trim_end();
    if t.ends_with('}') {
        if let Some(p) = t.rfind("{#") {
            return (t[..p].trim_end(), Some(&t[p + 2..t.len() - 1]));
        }
    }
    (t, None)
}
@
A list renders each item as one inline run inside an \code{<li>}, wrapped in \code{<ul>} or
\code{<ol>}.
<<render a list>>=
fn render_list(
    ordered: bool,
    items: &[String],
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (open, close) = if ordered { ("<ol>", "</ol>") } else { ("<ul>", "</ul>") };
    let mut out = String::from(open);
    for item in items {
        let inner = render_inline(item.trim(), math)?;
        out.push_str(&format!("<li>{inner}</li>"));
    }
    out.push_str(close);
    Ok(out)
}
@
A paragraph renders as one inline run inside a \code{<p>}. A paragraph that is only a
\code{\transclude} makes the bare island instead, so the weaver's transclusion pass
sees a block-level marker (§10).
<<render a paragraph>>=
fn render_paragraph(text: &str, math: &mut Vec<Math>) -> Result<String, MarkdownError> {
    let nodes = parse_inline(text)?;
    if let [Inline::Transclude(id)] = nodes.as_slice() {
        return Ok(format!(
            "<div class=\"transclusion\" data-transclude=\"{}\"></div>",
            prose::escape(id.trim())
        ));
    }
    let mut out = String::new();
    lower(&nodes, math, &mut out);
    Ok(format!("<p>{out}</p>"))
}
@
A fence dispatches on its kind. \code{math} makes the equation div in place;
\code{figure}/\code{table} make their float; \code{html-escape} passes its body through;
\code{verbatim} makes an escaped code sample, with a \code{language-*} class when it carries
a \code{\lang}.
<<render a fence>>=
fn render_fence(
    info: &str,
    body: &str,
    math: &mut Vec<Math>,
    defs: &mut BTreeMap<String, String>,
) -> Result<String, MarkdownError> {
    match parse_fence_info(info)? {
        Fence::Math(label) => Ok(render_math(label.as_deref(), body, math)),
        Fence::Figure(label) => render_figure(label.as_deref(), body, math),
        Fence::Table(label) => render_table(label.as_deref(), body, math),
        Fence::HtmlEscape => Ok(body.to_string()),
        Fence::Verbatim(lang) => {
            let class = match lang {
                Some(l) => format!(" class=\"language-{}\"", prose::escape(&l)),
                None => String::new(),
            };
            Ok(format!("<pre><code{class}>{}</code></pre>", prose::escape(body)))
        }
        Fence::Imports => {
            // An import is a declaration, not content (§13): it renders nothing in
            // the reading flow. The weaver scans the `\import … as …` lines to
            // resolve the macros and to list the document's imports in the page
            // chrome (like references), and records the edge in `site.json`.
            Ok(String::new())
        }
        Fence::Macros(label) => {
            // The body is normal prose with `\def`/`\let` lines; render it macro-
            // aware. Each definition is recorded in `defs` (name → expansion) and
            // passed to KaTeX's `macros` option, so it expands everywhere without
            // leaking into any formula's source (§6.4).
            let inner = render_ctx(body, math, defs, true)?;
            Ok(format!(
                "<div class=\"macros\" id=\"{}\">{inner}</div>",
                prose::escape(&label)
            ))
        }
    }
}
@
A math fence makes the equation div, its bare-LaTeX body pushed as display math. A
labelled fence gets its \code{id} and joins the numbering; an unlabelled one opts out
with \code{data-nonumber}, because only a labelled float earns a stable id (§7.1).
<<render a math fence>>=
fn render_math(label: Option<&str>, body: &str, math: &mut Vec<Math>) -> String {
    let idx = math.len();
    math.push(Math {
        source: body.to_string(),
        display: true,
    });
    let attr = match label {
        Some(_) => id_attr(label),
        None => " data-nonumber".to_string(),
    };
    format!(
        "<div class=\"equation\"{attr}><span data-cob-math=\"{idx}\"></span></div>"
    )
}
@
A run of \code{\def}/\code{\let} lines in a \code{macros} body does two things (§6.4). It
records each definition in \code{defs} — name to expansion — which the math renderer
feeds to KaTeX's \code{macros} option, so a macro expands in every formula and never
leaks into a formula's source. It also shows the definitions verbatim, as one code
block, so the reader sees the source. cob does not typeset them — the prose around
them is the exposition, where the macros are in scope. A \code{\def} may take forester
named parameters (\code{\def\abs[x]{…\x…}}); cob maps each name to a KaTeX \code{#n} in
order, replacing a whole control word only (so \code{\x} does not touch \code{\xi}). A
malformed line is E022.
<<render a macro definition>>=
fn render_macro_def(
    src: &str,
    defs: &mut BTreeMap<String, String>,
) -> Result<String, MarkdownError> {
    for line in src.lines() {
        match dialect::macrodef(line).map_err(|e| MarkdownError::Syntax(e.to_string()))? {
            MacroDef::Def {
                name,
                params,
                body,
            } => {
                // Map each forester parameter to a KaTeX `#n` in the expansion;
                // KaTeX infers the arity from the highest `#n`, so no arity marker
                // is needed on the name.
                let mut body = body;
                for (i, p) in params.iter().enumerate() {
                    body = replace_control_word(&body, p, &format!("#{}", i + 1));
                }
                defs.insert(name, body);
            }
            MacroDef::Let { name, target } => {
                // `\let\R=\RR` is an alias; KaTeX resolves the target macro in turn.
                defs.insert(name, target);
            }
        }
    }
    // Show the definitions verbatim; the prose around them is the exposition, and
    // the author chooses how to typeset it there (§6.4).
    Ok(format!(
        "<pre class=\"macro-src\"><code>{}</code></pre>",
        prose::escape(src)
    ))
}

/// Replace the control word `\name` in `body` with `to`, but only where `\name`
/// is a whole control word — the next char is not a letter — so a parameter `\x`
/// does not corrupt `\xi`. cob uses this to map forester params to KaTeX `#n`.
fn replace_control_word(body: &str, name: &str, to: &str) -> String {
    let needle = format!("\\{name}");
    let mut out = String::new();
    let mut rest = body;
    while let Some(pos) = rest.find(&needle) {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + needle.len()..];
        if after.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
            out.push_str(&needle);
        } else {
            out.push_str(to);
        }
        rest = after;
    }
    out.push_str(rest);
    out
}
@
A figure fence takes an optional leading caption, then a raw-HTML body (an image or
an SVG), and makes a real \code{<figure>}/\code{<figcaption>} so the numbering and ref
machinery downstream is reused unchanged.
<<render a figure fence>>=
fn render_figure(
    label: Option<&str>,
    body: &str,
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (caption, rest) = take_caption(body)?;
    let body_html = rest.trim();
    let cap_html = match caption {
        Some(c) => format!("\n<figcaption>{}</figcaption>", render_inline(&c, math)?),
        None => String::new(),
    };
    Ok(format!(
        "<figure{}>\n{body_html}{cap_html}\n</figure>",
        id_attr(label)
    ))
}
@
A table fence takes an optional caption, then a pipe table. The first row is the
head, the second is the delimiter, the rest are body rows; each cell is one inline
run. The id and caption splice into the \code{<table>}.
<<render a table fence>>=
fn render_table(
    label: Option<&str>,
    body: &str,
    math: &mut Vec<Math>,
) -> Result<String, MarkdownError> {
    let (caption, rest) = take_caption(body)?;
    let cap_html = match caption {
        Some(c) => format!("<caption>{}</caption>", render_inline(&c, math)?),
        None => String::new(),
    };
    let rows: Vec<&str> = rest.lines().filter(|l| !l.trim().is_empty()).collect();
    let mut inner = String::new();
    if let Some(head) = rows.first() {
        inner.push_str("<thead><tr>");
        for cell in split_row(head) {
            inner.push_str(&format!("<th>{}</th>", render_inline(&cell, math)?));
        }
        inner.push_str("</tr></thead>");
    }
    inner.push_str("<tbody>");
    for row in rows.iter().skip(2) {
        inner.push_str("<tr>");
        for cell in split_row(row) {
            inner.push_str(&format!("<td>{}</td>", render_inline(&cell, math)?));
        }
        inner.push_str("</tr>");
    }
    inner.push_str("</tbody>");
    Ok(format!("<table{}>{cap_html}{inner}</table>", id_attr(label)))
}

fn split_row(line: &str) -> Vec<String> {
    line.trim()
        .trim_start_matches('|')
        .trim_end_matches('|')
        .split('|')
        .map(|c| c.trim().to_string())
        .collect()
}
@
A leading \code{\caption{…}} (brace-balanced, possibly multi-line) is peeled off a fence
body by the grammar, which returns its raw source and the byte offset where the rest
of the body starts. The remainder goes to the float renderer.
<<peel a caption>>=
fn take_caption(body: &str) -> Result<(Option<String>, String), MarkdownError> {
    if !body.trim_start().starts_with("\\caption") {
        return Ok((None, body.to_string()));
    }
    let (cap, pos) = dialect::caption(body).map_err(|_| fence_err("malformed `\\caption{…}`"))?;
    Ok((Some(cap), body[pos..].to_string()))
}
@
A parsed fence is a float directive (each with its optional namespace-checked
label), the \code{html-escape} door, or a \code{verbatim} block with an optional language.
<<parse the fence info>>=
enum Fence {
    Math(Option<String>),
    Figure(Option<String>),
    Table(Option<String>),
    HtmlEscape,
    Verbatim(Option<String>),
    /// A `def:`-labelled exposition of macros (§6.4). Its body is normal prose
    /// with `\def`/`\let` definition lines; the label is required, because the
    /// fence is a node.
    Macros(String),
    /// A declaration of imports (§13): `\import <name> as <alias>` lines. The
    /// weaver scans the body to resolve `@alias` addresses; here it just renders
    /// the lines verbatim so the reader sees what the document imports.
    Imports,
}

/// One header modifier: a float `\label` or a `verbatim` `\lang`.
enum Modifier {
    Label(String),
    Lang(String),
}
@
The kind is the leading word (letters, digits, \code{-}). The grammar parses the
modifiers that follow, so a malformed one is an error, not a silent drop. A bare
fence (empty kind) and an unknown kind are E034; a bad modifier is E030.
<<parse the fence info>>=
const KINDS: &str = "math, figure, table, macros, imports, html-escape, or verbatim";

fn parse_fence_info(info: &str) -> Result<Fence, MarkdownError> {
    let info = info.trim();
    let end = info
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
        .unwrap_or(info.len());
    let kind = &info[..end];
    let rest = info[end..].trim();
    let mods = dialect::modifiers(rest)
        .map_err(|_| fence_err(format!("malformed modifier after `{kind}` fence; use {KINDS}")))?;
    match kind {
        "math" => Ok(Fence::Math(label_of(&mods, kind, "eq:")?)),
        "figure" => Ok(Fence::Figure(label_of(&mods, kind, "fig:")?)),
        "table" => Ok(Fence::Table(label_of(&mods, kind, "tbl:")?)),
        "macros" => match label_of(&mods, kind, "def:")? {
            Some(l) => Ok(Fence::Macros(l)),
            None => Err(fence_err("a `macros` fence needs a `\\label{def:…}`")),
        },
        "imports" => {
            reject_modifiers(&mods, kind)?;
            Ok(Fence::Imports)
        }
        "html-escape" => {
            reject_modifiers(&mods, kind)?;
            Ok(Fence::HtmlEscape)
        }
        "verbatim" => Ok(Fence::Verbatim(lang_of(&mods)?)),
        "" => Err(kind_err(format!("a fence needs a kind: {KINDS}"))),
        other => Err(kind_err(format!("unknown fence kind `{other}`; use {KINDS}"))),
    }
}
@
The modifier validators enforce, per kind, which modifiers are legal and check a
label's namespace against its float kind (E030).
<<parse the fence info>>=
fn label_of(mods: &[Modifier], kind: &str, prefix: &str) -> Result<Option<String>, MarkdownError> {
    let mut label = None;
    for m in mods {
        match m {
            Modifier::Label(name) => {
                let name = name.trim();
                if !name.starts_with(prefix) {
                    return Err(fence_err(format!(
                        "label `{name}` on a `{kind}` fence must use the `{prefix}` namespace"
                    )));
                }
                label = Some(name.to_string());
            }
            Modifier::Lang(_) => {
                return Err(fence_err(format!("`\\lang` is not allowed on a `{kind}` fence")))
            }
        }
    }
    Ok(label)
}

fn lang_of(mods: &[Modifier]) -> Result<Option<String>, MarkdownError> {
    let mut lang = None;
    for m in mods {
        match m {
            Modifier::Lang(name) => lang = Some(name.trim().to_string()),
            Modifier::Label(_) => {
                return Err(fence_err("`\\label` is not allowed on a `verbatim` fence"))
            }
        }
    }
    Ok(lang)
}

fn reject_modifiers(mods: &[Modifier], kind: &str) -> Result<(), MarkdownError> {
    if mods.is_empty() {
        Ok(())
    } else {
        Err(fence_err(format!("a `{kind}` fence takes no modifiers")))
    }
}
@
The \code{id="…"} attribute for an optional label, escaped, or empty.
<<an id attribute>>=
fn id_attr(label: Option<&str>) -> String {
    label
        .map(|l| format!(" id=\"{}\"", prose::escape(l)))
        .unwrap_or_default()
}
@
The grammar. \code{peg} builds it into a parser at compile time. \code{nodes} tokenises one
prose run into commands, math, and literal text. A command body recurses through
the same grammar, so \code{\strong{\emph{x}}} nests. A \code{\code{}} body is a slice with
balanced braces, captured whole, so any command inside it stays literal. Two more
public rules serve the fence header: \code{modifiers} reads the whole info-line tail
after the kind, and \code{caption} peels a leading \code{\caption{…}} off a float body and
reports where the rest begins.
<<the inline grammar>>=
peg::parser! {
    grammar dialect() for str {
        pub rule nodes() -> Vec<Inline> = node()*

        rule node() -> Inline
            = strong() / emph() / code() / codespan() / refc() / citec() / transclude() / dmath() / imath() / text() / lonetick()

        rule strong() -> Inline = "\\strong{" ns:nodes() "}" { Inline::Strong(ns) }
        rule emph() -> Inline = "\\emph{" ns:nodes() "}" { Inline::Emph(ns) }

        rule code() -> Inline = "\\code{" v:$(cb_atom()*) "}" { Inline::Code(unescape_braces(v)) }
        rule cb_atom() = "\\{" {} / "\\}" {} / braces() / (!['{' | '}'] [_] {})
        rule braces() = "{" cb_atom()* "}"

        // A backtick code span is literal, like `\code{}`: its body is captured whole
        // and never read for commands, so `` `\cite{x}` `` is text, not a citation.
        // An unmatched backtick is a literal character (`lonetick`), so a stray
        // backtick never fails the parse.
        rule codespan() -> Inline = "`" v:$((!"`" [_])*) "`" { Inline::Code(v.to_string()) }
        rule lonetick() -> Inline = "`" { Inline::Text("`".to_string()) }

        rule refc() -> Inline = "\\ref{" s:$((!"}" [_])*) "}" { Inline::Ref(s.to_string()) }
        rule citec() -> Inline = "\\cite{" s:$((!"}" [_])*) "}" { Inline::Cite(s.to_string()) }
        rule transclude() -> Inline
            = "\\transclude{" s:$((!"}" [_])*) "}" { Inline::Transclude(s.to_string()) }

        rule dmath() -> Inline
            = "$$" s:$((!"$$" [_])*) "$$" { Inline::Math { src: s.to_string(), display: true } }
        rule imath() -> Inline
            = "$" s:$(m_atom()*) "$" { Inline::Math { src: s.to_string(), display: false } }
        rule m_atom() = "\\$" {} / (!"$" [_] {})

        rule text() -> Inline = s:$(t_atom()+) { Inline::Text(unescape_text(s)) }
        rule t_atom() = "\\$" {} / "\\{" {} / "\\}" {} / "\\\\" {} / (!marker() [_] {})
        rule marker() = "\\strong{" / "\\emph{" / "\\code{" / "\\ref{" / "\\cite{" / "\\transclude{" / "$" / "{" / "}" / "`"

        rule ws() = [' ' | '\t' | '\n' | '\r']*
        pub rule modifiers() -> Vec<Modifier> = ws() m:(x:modifier() ws() { x })* { m }
        rule modifier() -> Modifier
            = "\\label{" v:$(cb_atom()*) "}" { Modifier::Label(unescape_braces(v)) }
            / "\\lang{" v:$(cb_atom()*) "}" { Modifier::Lang(unescape_braces(v)) }
        pub rule caption() -> (String, usize)
            = ws() "\\caption{" v:$(cb_atom()*) "}" p:position!() [_]* { (v.to_string(), p) }

        pub rule macrodef() -> MacroDef
            = ws() "\\def" name:cs() params:param()* "{" body:$(cb_atom()*) "}" ws()
                { MacroDef::Def {
                    name: name.to_string(),
                    params: params.iter().map(|p| p.to_string()).collect(),
                    body: body.to_string(),
                } }
            / ws() "\\let" name:cs() ws() "=" ws() target:cs() ws()
                { MacroDef::Let { name: name.to_string(), target: target.to_string() } }
        rule cs() -> &'input str = $("\\" ['a'..='z' | 'A'..='Z']+)
        rule param() -> &'input str = "[" p:$(['a'..='z' | 'A'..='Z']+) "]" { p }
    }
}
@
The inline node the grammar makes.
<<the inline node>>=
#[derive(Debug, Clone, PartialEq, Eq)]
enum Inline {
    Text(String),
    Emph(Vec<Inline>),
    Strong(Vec<Inline>),
    Code(String),
    Math { src: String, display: bool },
    Ref(String),
    Cite(String),
    Transclude(String),
}

/// A parsed `\def`/`\let` line from a `macros` body (§6.4). `name` and `target`
/// keep their leading backslash, so they round-trip straight into the preamble.
/// `params` are forester's named brackets (`\def\abs[x]{…}`); cob maps each to a
/// KaTeX `#n`.
enum MacroDef {
    Def {
        name: String,
        params: Vec<String>,
        body: String,
    },
    Let {
        name: String,
        target: String,
    },
}
@
Lowering walks the nodes and makes HTML. Text is escaped; a command wraps its
lowered children; \code{\code} escapes its verbatim body; math pushes onto the shared
list and leaves a placeholder the render pass fills (§6.2).
<<lower inline nodes>>=
fn lower(nodes: &[Inline], math: &mut Vec<Math>, out: &mut String) {
    for node in nodes {
        match node {
            Inline::Text(t) => out.push_str(&prose::escape(t)),
            Inline::Emph(ns) => {
                out.push_str("<em>");
                lower(ns, math, out);
                out.push_str("</em>");
            }
            Inline::Strong(ns) => {
                out.push_str("<strong>");
                lower(ns, math, out);
                out.push_str("</strong>");
            }
            Inline::Code(v) => {
                out.push_str("<code>");
                out.push_str(&prose::escape(v));
                out.push_str("</code>");
            }
            Inline::Ref(id) => {
                out.push_str(&format!("<a data-ref=\"{}\"></a>", prose::escape(id.trim())))
            }
            Inline::Cite(keys) => {
                // `\cite{k1, k2}` lowers to one inert marker per key; the weaver
                // mints each a node id and draws the `[id]` marker (§14).
                for key in keys.split(',') {
                    let key = key.trim();
                    if !key.is_empty() {
                        out.push_str(&format!("<a data-cite=\"{}\"></a>", prose::escape(key)));
                    }
                }
            }
            Inline::Transclude(id) => out.push_str(&format!(
                "<div class=\"transclusion\" data-transclude=\"{}\"></div>",
                prose::escape(id.trim())
            )),
            Inline::Math { src, display } => {
                let idx = math.len();
                math.push(Math {
                    source: src.clone(),
                    display: *display,
                });
                out.push_str(&format!("<span data-cob-math=\"{idx}\"></span>"));
            }
        }
    }
}
@
The two inline helpers: parse a run to nodes (a parse fault is E022), and render a
run straight to HTML.
<<render one inline run>>=
fn parse_inline(src: &str) -> Result<Vec<Inline>, MarkdownError> {
    dialect::nodes(src).map_err(|e| MarkdownError::Syntax(e.to_string()))
}

fn render_inline(src: &str, math: &mut Vec<Math>) -> Result<String, MarkdownError> {
    let nodes = parse_inline(src)?;
    let mut out = String::new();
    lower(&nodes, math, &mut out);
    Ok(out)
}
@
The escape helpers turn the grammar's escapes back into literals. A \code{\code} body
only unescapes braces — \code{\{} and \code{\}} — and leaves everything else verbatim;
text also unescapes the dollar escape \code{\$} and a doubled backslash.
<<the escape helpers>>=
fn unescape_braces(s: &str) -> String {
    if s.contains('\\') {
        s.replace("\\{", "{").replace("\\}", "}")
    } else {
        s.to_string()
    }
}

fn unescape_text(s: &str) -> String {
    if s.contains('\\') {
        s.replace("\\$", "$")
            .replace("\\{", "{")
            .replace("\\}", "}")
            .replace("\\\\", "\\")
    } else {
        s.to_string()
    }
}
@
The tests walk each §6.4 behavior: the command family, headings and lists, the
\code{html-escape} door, verbatim code, each float directive, the ref and transclude
lowering and their no-op inside code, the E030 namespace check, and a round trip
through math substitution.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &str) -> (String, Vec<Math>) {
        let mut math = Vec::new();
        let html = render(input, &mut math, &mut BTreeMap::new()).expect("renders");
        (html, math)
    }

    <<command marks render>>

    <<a heading and a list>>

    <<html escape passes through>>

    <<code is verbatim>>

    <<a fenced math is a numbered display>>

    <<inline math is extracted>>

    <<a dollar in a code fence is not math>>

    <<a labelled math fence carries its id>>

    <<a figure fence emits a figure>>

    <<a table fence splices id and caption>>

    <<a bare pipe row stays literal>>

    <<a multiline caption balances braces>>

    <<a ref lowers to a data-ref>>

    <<a cite lowers to data-cite markers>>

    <<a backtick span is literal inline code>>

    <<a transclude lowers to a placeholder>>

    <<a ref inside code is literal>>

    <<a mismatched namespace is e030>>

    <<a code fence with a language>>

    <<round trip through math substitution>>

    <<a macros fence defines and typesets>>

    <<a def line is inert in prose>>
}
@
A \code{macros} fence records its \code{\def}/\code{\let} in the macro table (name →
expansion), shows them verbatim as a code block, and renders the prose between
them. A definition is not typeset; forester named params map to KaTeX \code{#n}, and
the translated \code{#n} form never appears in the rendered HTML — only in the table.
The label is required (§6.4).
<<a macros fence defines and typesets>>=
#[test]
fn macros_fence_registers_and_shows_source() {
    let mut math = Vec::new();
    let mut defs = BTreeMap::new();
    let html = render(
        "```macros \\label{def:basics}\n\\def\\RR{\\mathbb{R}}\nThe reals.\n\
         \\def\\abs[x]{\\lvert \\x \\rvert}\n\\let\\R=\\RR\n```",
        &mut math,
        &mut defs,
    )
    .expect("a macros fence renders");
    // Each definition is recorded in the macro table (name → expansion) for KaTeX;
    // a param macro is translated to `#1`, replacing the whole control word only.
    assert_eq!(defs.get("\\RR").map(String::as_str), Some("\\mathbb{R}"));
    assert_eq!(defs.get("\\abs").map(String::as_str), Some("\\lvert #1 \\rvert"));
    assert_eq!(defs.get("\\R").map(String::as_str), Some("\\RR"));
    // The exposition is a node div with the label id; the prose renders.
    assert!(html.contains("<div class=\"macros\" id=\"def:basics\">"));
    assert!(html.contains("<p>The reals.</p>"));
    // The definitions show verbatim (the author's forester source, not KaTeX #1),
    // as a code block, but are not typeset. A run of them is one block.
    assert!(html.contains("<pre class=\"macro-src\"><code>\\def\\RR{\\mathbb{R}}</code></pre>"));
    assert!(html.contains("\\def\\abs[x]{\\lvert \\x \\rvert}\n\\let\\R=\\RR"));
    // The translated `#1` form is table-only — it must never leak into the HTML.
    assert!(!html.contains("#1"));
    assert!(math.is_empty());

    // The label is required.
    let err = render("```macros\n\\def\\RR{x}\n```", &mut Vec::new(), &mut BTreeMap::new())
        .unwrap_err();
    assert!(matches!(err, MarkdownError::Fence { .. }));
}
@
Outside a \code{macros} fence a \code{\def}/\code{\let} line is ordinary prose, so it adds
nothing to the macro table.
<<a def line is inert in prose>>=
#[test]
fn def_line_is_inert_in_prose() {
    let mut math = Vec::new();
    let mut defs = BTreeMap::new();
    let html = render("\\let\\R=\\RR here", &mut math, &mut defs).expect("prose renders");
    assert!(defs.is_empty());
    assert!(html.contains("\\let\\R=\\RR here"));
}
@
The command family renders to the matching tags, and nests.
<<command marks render>>=
#[test]
fn command_marks_render() {
    let (html, _) = run("plain with \\emph{em} and \\strong{strong} and \\code{span}.");
    assert!(html.contains(
        "<p>plain with <em>em</em> and <strong>strong</strong> and <code>span</code>.</p>"
    ));
    let (nested, _) = run("\\strong{bold \\emph{and italic}}");
    assert!(nested.contains("<strong>bold <em>and italic</em></strong>"));
}
@
A heading with an id, and a list.
<<a heading and a list>>=
#[test]
fn heading_and_list() {
    let (html, _) = run("# Title {#sec:top}\n\n- one\n- two\n");
    assert!(html.contains("<h1 id=\"sec:top\">Title</h1>"));
    assert!(html.contains("<ul><li>one</li><li>two</li></ul>"));
}
@
An \code{html-escape} fence passes its body through verbatim — the one raw-HTML door.
<<html escape passes through>>=
#[test]
fn html_escape_passes_through_verbatim() {
    let aside = "<aside id=\"sn:a\">A sidenote.</aside>";
    let (html, _) = run(&format!("text\n\n```html-escape\n{aside}\n```\n\nmore"));
    assert!(html.contains(aside));
}
@
Inline \code{\code} is verbatim and escaped, and balanced braces need no escape.
<<code is verbatim>>=
#[test]
fn code_is_verbatim_and_escapes() {
    let (html, _) = run("see \\code{v[0] & <T>} and \\code{fn f() { x }}");
    assert!(html.contains("<code>v[0] &amp; &lt;T&gt;</code>"));
    assert!(html.contains("<code>fn f() { x }</code>"));
}
@
A labelled math fence becomes a display equation with its id (so it joins the
numbering downstream); an unlabelled one opts out of numbering (§7.1).
<<a fenced math is a numbered display>>=
#[test]
fn fenced_math_is_a_display_equation() {
    let (html, math) =
        run("intro\n\n```math \\label{eq:slot}\nslot(i) = (head + i) \\bmod n\n```\n\nafter");
    assert_eq!(math.len(), 1);
    assert!(math[0].display);
    assert_eq!(math[0].source, "slot(i) = (head + i) \\bmod n");
    assert!(html
        .contains("<div class=\"equation\" id=\"eq:slot\"><span data-cob-math=\"0\"></span></div>"));
    // An unlabelled fence has no id, so it opts out of numbering.
    let (html, _) = run("```math\nx\n```");
    assert!(html.contains("<div class=\"equation\" data-nonumber><span data-cob-math=\"0\"></span></div>"));
}
@
Inline math is extracted to a placeholder.
<<inline math is extracted>>=
#[test]
fn inline_math_is_extracted() {
    let (html, math) = run("the tail is $\\operatorname{slot}(n)$ here");
    assert_eq!(math.len(), 1);
    assert!(!math[0].display);
    assert_eq!(math[0].source, "\\operatorname{slot}(n)");
    assert!(html.contains("<span data-cob-math=\"0\"></span>"));
}
@
A dollar inside a verbatim fence is not math.
<<a dollar in a code fence is not math>>=
#[test]
fn dollar_inside_a_verbatim_fence_is_not_math() {
    let (html, math) = run("```verbatim\necho $HOME > $OUT\n```");
    assert!(math.is_empty());
    assert!(html.contains("<pre><code>echo $HOME &gt; $OUT</code></pre>"));
}
@
A labelled math fence carries its id onto the equation div.
<<a labelled math fence carries its id>>=
#[test]
fn labeled_math_fence_carries_its_id() {
    let (html, math) = run("```math \\label{eq:wrap}\nx = y\n```");
    assert_eq!(math.len(), 1);
    assert!(html.contains(
        "<div class=\"equation\" id=\"eq:wrap\"><span data-cob-math=\"0\"></span></div>"
    ));
}
@
A figure fence emits a figure with its caption.
<<a figure fence emits a figure>>=
#[test]
fn figure_fence_emits_figure_with_caption() {
    let (html, _) = run(
        "```figure \\label{fig:p}\n\\caption{The \\emph{pipeline} stages.}\n<img src=\"p.svg\">\n```",
    );
    assert!(html.contains("<figure id=\"fig:p\">"));
    assert!(html.contains("<img src=\"p.svg\">"));
    assert!(html.contains("<figcaption>The <em>pipeline</em> stages.</figcaption>"));
}
@
A table fence parses a pipe table and splices in the id and caption.
<<a table fence splices id and caption>>=
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
@
A bare pipe row in prose stays literal, since a table lives only in a fence.
<<a bare pipe row stays literal>>=
#[test]
fn bare_pipe_row_in_prose_stays_literal() {
    let (html, _) = run("a | b | c\n");
    assert!(!html.contains("<table"));
    assert!(html.contains("<p>a | b | c</p>"));
}
@
A multi-line caption with nested braces and math balances.
<<a multiline caption balances braces>>=
#[test]
fn multiline_caption_with_braces_is_balanced() {
    let (html, _) = run(
        "```figure\n\\caption{first line\nand $a_{i}$ second}\n<img src=\"p.svg\">\n```",
    );
    assert!(html.contains(
        "<figcaption>first line\nand <span data-cob-math=\"0\"></span> second</figcaption>"
    ));
}
@
A ref command lowers to a data-ref anchor.
<<a ref lowers to a data-ref>>=
#[test]
fn ref_lowers_to_a_data_ref() {
    let (html, _) = run("see \\ref{fig:p} and \\ref{eq:wrap}.");
    assert!(html.contains("<a data-ref=\"fig:p\"></a>"));
    assert!(html.contains("<a data-ref=\"eq:wrap\"></a>"));
}
@
A backtick span is literal inline code — commands inside it never lower — and an
unmatched backtick is a literal character.
<<a backtick span is literal inline code>>=
#[test]
fn a_backtick_span_is_literal_inline_code() {
    // Commands inside a backtick span are text, like inside `\code{}`.
    let (html, _) = run("use `\\cite{x}` and `\\ref{fig:p}` and `$x$` literally");
    assert!(html.contains("<code>\\cite{x}</code>"));
    assert!(html.contains("<code>\\ref{fig:p}</code>"));
    assert!(html.contains("<code>$x$</code>"));
    assert!(!html.contains("data-cite"));
    assert!(!html.contains("data-ref"));
    // A real command outside the span still lowers.
    let (live, _) = run("code `\\ref{fig:p}` but real \\ref{fig:q}");
    assert!(live.contains("<code>\\ref{fig:p}</code>"));
    assert!(live.contains("<a data-ref=\"fig:q\"></a>"));
    // An unmatched backtick is a literal backtick, not a parse error.
    let (lone, _) = run("a lone ` backtick");
    assert!(lone.contains("lone ` backtick") || lone.contains("lone `"));
}
@
A cite command lowers to one \code{data-cite} marker per key.
<<a cite lowers to data-cite markers>>=
#[test]
fn cite_lowers_to_one_data_cite_per_key() {
    // One key makes one marker; a comma list makes one per key (§14).
    let (one, _) = run("as \\cite{smith2020} shows");
    assert!(one.contains("<a data-cite=\"smith2020\"></a>"));
    let (many, _) = run("see \\cite{smith2020, knuth1984}");
    assert!(many.contains("<a data-cite=\"smith2020\"></a>"));
    assert!(many.contains("<a data-cite=\"knuth1984\"></a>"));
    // A `\cite` inside `\code` is literal.
    let (code, _) = run("write \\code{\\cite{x}} here");
    assert!(code.contains("<code>\\cite{x}</code>"));
    assert!(!code.contains("data-cite=\"x\""));
}
@
A lone-transclude paragraph lowers to the bare island the weaver expands.
<<a transclude lowers to a placeholder>>=
#[test]
fn transclude_lowers_to_a_placeholder() {
    let (html, _) = run("before\n\n\\transclude{sec:lexing}\n\nafter");
    assert!(html.contains("<div class=\"transclusion\" data-transclude=\"sec:lexing\"></div>"));
    // A `\transclude` inside `\code` is literal.
    let (cob, _) = run("write \\code{\\transclude{sec:x}} here");
    assert!(cob.contains("<code>\\transclude{sec:x}</code>"));
    assert!(!cob.contains("data-transclude=\"sec:x\""));
}
@
A ref inside \code{\code} is literal, never lowered.
<<a ref inside code is literal>>=
#[test]
fn ref_inside_code_is_literal() {
    let (html, _) = run("write \\code{\\ref{fig:p}} then \\ref{fig:p} resolves");
    assert!(html.contains("<code>\\ref{fig:p}</code>"));
    assert!(html.contains("<a data-ref=\"fig:p\"></a>"));
}
@
A label whose namespace does not match its fence kind is E030.
<<a mismatched namespace is e030>>=
#[test]
fn mismatched_label_namespace_is_e030() {
    let mut math = Vec::new();
    let err =
        render("```figure \\label{tbl:x}\n\\caption{c}\n<img>\n```", &mut math, &mut BTreeMap::new()).unwrap_err();
    assert!(matches!(err, MarkdownError::Fence { code: "E030", .. }));
    assert!(err.to_string().contains("fig:"));
}
@
A verbatim fence with a \code{\lang{}} modifier keeps a language class. A bare
fence and an unknown kind are both E034, so a typo fails fast.
<<a code fence with a language>>=
#[test]
fn verbatim_lang_modifier_adds_a_language_class() {
    let (html, _) = run("```verbatim \\lang{rust}\nlet x = 1;\n```");
    assert!(html.contains("<pre><code class=\"language-rust\">let x = 1;</code></pre>"));
}

#[test]
fn a_bare_or_unknown_fence_is_e034() {
    let mut math = Vec::new();
    let bare = render("```\nx\n```", &mut math, &mut BTreeMap::new()).unwrap_err();
    assert!(matches!(bare, MarkdownError::Fence { code: "E034", .. }));
    let unknown = render("```rust\nx\n```", &mut math, &mut BTreeMap::new()).unwrap_err();
    assert!(matches!(unknown, MarkdownError::Fence { code: "E034", .. }));
    // A `\lang{}` on any kind but verbatim is a bad modifier (E030).
    let misplaced = render("```math \\lang{rust}\nx\n```", &mut math, &mut BTreeMap::new()).unwrap_err();
    assert!(matches!(misplaced, MarkdownError::Fence { code: "E030", .. }));
}
@
Both math placeholders resolve by index through the substitution pass.
<<round trip through math substitution>>=
#[test]
fn round_trips_through_math_substitution() {
    let mut math = Vec::new();
    let html = render("$x$\n\n```math \\label{eq:y}\ny\n```", &mut math, &mut BTreeMap::new()).unwrap();
    // Document order: inline `$x$` is index 0, the fenced display is index 1.
    assert_eq!((math[0].source.as_str(), math[0].display), ("x", false));
    assert_eq!((math[1].source.as_str(), math[1].display), ("y", true));
    let out = prose::substitute_math(
        &html,
        &["<INLINE/>".to_string(), "<DISPLAY/>".to_string()],
    );
    assert!(out.contains("<INLINE/>"));
    assert!(out.contains("<div class=\"equation\" id=\"eq:y\"><DISPLAY/></div>"));
}
@
