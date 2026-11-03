# The algorithm fence {#sec:pseudocode}

The `algorithm` fence (§6.4) renders pseudocode as a numbered, referenceable
float. Its body uses the grammar of LaTeX's `algorithmic` family — the same
control words [pseudocode.js](https://github.com/SaswatPadhi/pseudocode.js) reads
— but cob renders it to static HTML at weave time. There is no JavaScript: the
listing is in the archival page, like every other float, so copy, paste, and the
annotation layer's quote selectors survive. KaTeX renders the inline `$…$` math
through the same path the rest of the document uses.

Why a native reader, not pseudocode.js? pseudocode.js is a client-side renderer;
its output appears only when a script runs, which breaks cob's no-JS content rule.
The one server-side option runs pseudocode.js through Node at build time — a
process and a dependency cob removed with noweb. So cob reads the grammar itself,
the same choice it made for the markup reader and the tangler (§11).

The module is a tokenizer, a recursive-descent parser over the tokens, and a
renderer that walks the parse into a nested ordered list. The caller passes an
`inline` closure — the Markdown inline renderer — so a line's text, a condition,
or a comment is rendered in the document's own dialect, math and all.

<<src/pseudocode.rs>>=
//! §6.5 The `algorithm` fence: a native pseudocode renderer.
//!
//! The body uses the LaTeX `algorithmic` control words (the pseudocode.js
//! grammar): `\State`, `\If`/`\ElsIf`/`\Else`/`\EndIf`, `\For`/`\ForAll`/
//! `\While`/`\Repeat`..`\Until`, `\Function`/`\Procedure`, `\Return`/`\Print`,
//! `\Require`/`\Ensure`/`\Input`/`\Output`, `\Comment`, `\Call`, and the inline
//! words `\And`/`\Or`/`\Not`/`\To`/`\True`/`\False`/… Command names are matched
//! case-insensitively, so `\STATE` and `\State` are the same.
//!
//! cob renders the structure to a nested `<ol>` at weave time — no JavaScript —
//! and hands each run of text to an `inline` closure (the Markdown inline
//! renderer), so `$…$` math and `\emph`/`\ref` work as everywhere else.

<<a pseudocode token>>

<<tokenize a body>>

<<a parsed node>>

<<parse a block>>

<<render a block>>

<<the keyword tables>>

<<pseudocode tests>>
@

A token is a control word, a brace-balanced group, or a run of literal text. A
`$…$` math span is kept whole inside a text token, so its braces and backslashes
never look like groups or commands. An escaped character (`\{`, `\$`) is literal
text.
<<a pseudocode token>>=
enum Tok {
    /// A `\Word` control word, without the backslash, in its original case.
    Cmd(String),
    /// A `{…}` group, brace-balanced, its inner text.
    Group(String),
    /// A run of literal text, with any `$…$` math span kept whole.
    Text(String),
}
@

The tokenizer is one pass over the characters. It is UTF-8 safe: it builds each
token by pushing characters, never by slicing on a byte offset.
<<tokenize a body>>=
fn tokenize(s: &str) -> Vec<Tok> {
    let mut toks = Vec::new();
    let mut text = String::new();
    let mut chars = s.chars().peekable();
    let flush = |text: &mut String, toks: &mut Vec<Tok>| {
        if !text.is_empty() {
            toks.push(Tok::Text(std::mem::take(text)));
        }
    };
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.peek() {
                Some(&d) if d.is_ascii_alphabetic() => {
                    flush(&mut text, &mut toks);
                    let mut name = String::new();
                    while let Some(&d) = chars.peek() {
                        if d.is_ascii_alphabetic() {
                            name.push(d);
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    toks.push(Tok::Cmd(name));
                }
                // An escaped character is literal: `\{`, `\}`, `\$`, `\\`.
                Some(&d) => {
                    text.push(d);
                    chars.next();
                }
                None => text.push('\\'),
            },
            '{' => {
                flush(&mut text, &mut toks);
                let mut depth = 1usize;
                let mut inner = String::new();
                while let Some(d) = chars.next() {
                    match d {
                        '\\' => {
                            inner.push('\\');
                            if let Some(e) = chars.next() {
                                inner.push(e);
                            }
                        }
                        '{' => {
                            depth += 1;
                            inner.push('{');
                        }
                        '}' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                            inner.push('}');
                        }
                        _ => inner.push(d),
                    }
                }
                toks.push(Tok::Group(inner));
            }
            // A `$…$` math span is kept whole in the text token.
            '$' => {
                text.push('$');
                while let Some(d) = chars.next() {
                    text.push(d);
                    if d == '\\' {
                        if let Some(e) = chars.next() {
                            text.push(e);
                        }
                        continue;
                    }
                    if d == '$' {
                        break;
                    }
                }
            }
            _ => text.push(c),
        }
    }
    flush(&mut text, &mut toks);
    toks
}
@

A parsed node is one rendered line or a block. A statement carries a keyword lead
(empty for `\State`), its inline source, and an optional trailing comment. A
conditional is a list of `(condition, body)` branches and an optional `else`. A
loop is a header word, its inline header, a tail word (`do`), and a body. A
repeat-until and a function/procedure round out the set.
<<a parsed node>>=
enum Node {
    Stmt {
        lead: &'static str,
        inline: String,
        comment: Option<String>,
    },
    If {
        branches: Vec<(String, Vec<Node>)>,
        els: Option<Vec<Node>>,
    },
    Loop {
        word: &'static str,
        header: String,
        tail: &'static str,
        body: Vec<Node>,
    },
    Repeat {
        body: Vec<Node>,
        until: String,
    },
    Func {
        word: &'static str,
        name: String,
        params: String,
        body: Vec<Node>,
    },
}
@

The parser is recursive descent over the token slice. `parse_block` reads nodes
until it meets a closing word in `stop` (which it leaves for the caller to
consume) or the end. The leading command of each node decides its shape. An
unknown leading command is an error, so a typo fails rather than renders wrong.
<<parse a block>>=
/// Parse a block of nodes from `toks[*pos..]`, stopping at (without consuming) a
/// command whose lower-case name is in `stop`, or at the end.
fn parse_block(toks: &[Tok], pos: &mut usize, stop: &[&str]) -> Result<Vec<Node>, String> {
    let mut nodes = Vec::new();
    while *pos < toks.len() {
        let name = match &toks[*pos] {
            Tok::Cmd(n) => n.to_ascii_lowercase(),
            // Stray text or a group between statements is skipped: whitespace and
            // separators the author left between commands.
            _ => {
                *pos += 1;
                continue;
            }
        };
        if stop.contains(&name.as_str()) {
            break;
        }
        *pos += 1;
        match name.as_str() {
            "state" => nodes.push(stmt("", toks, pos)),
            "return" => nodes.push(stmt("return", toks, pos)),
            "print" => nodes.push(stmt("print", toks, pos)),
            "require" => nodes.push(stmt("Require:", toks, pos)),
            "ensure" => nodes.push(stmt("Ensure:", toks, pos)),
            "input" => nodes.push(stmt("Input:", toks, pos)),
            "output" => nodes.push(stmt("Output:", toks, pos)),
            "if" => nodes.push(parse_if(toks, pos)?),
            "while" => nodes.push(parse_loop("while", "do", "endwhile", toks, pos)?),
            "for" => nodes.push(parse_loop("for", "do", "endfor", toks, pos)?),
            "forall" => nodes.push(parse_loop("for all", "do", "endforall", toks, pos)?),
            "repeat" => nodes.push(parse_repeat(toks, pos)?),
            "function" => nodes.push(parse_func("function", "endfunction", toks, pos)?),
            "procedure" => nodes.push(parse_func("procedure", "endprocedure", toks, pos)?),
            other => return Err(format!("unknown algorithm command `\\{other}`")),
        }
    }
    Ok(nodes)
}

/// A statement: gather inline tokens up to the next structural command.
fn stmt(lead: &'static str, toks: &[Tok], pos: &mut usize) -> Node {
    let (inline, comment) = gather_inline(toks, pos);
    Node::Stmt { lead, inline, comment }
}

/// `\If{c}` … `\ElsIf{c}` … `\Else` … `\EndIf`.
fn parse_if(toks: &[Tok], pos: &mut usize) -> Result<Node, String> {
    let mut branches = Vec::new();
    let cond = take_group(toks, pos, "if")?;
    let body = parse_block(toks, pos, &["elif", "elsif", "else", "endif"])?;
    branches.push((cond, body));
    let mut els = None;
    while *pos < toks.len() {
        let name = cmd_name(&toks[*pos]);
        match name.as_deref() {
            Some("elif") | Some("elsif") => {
                *pos += 1;
                let cond = take_group(toks, pos, "elsif")?;
                let body = parse_block(toks, pos, &["elif", "elsif", "else", "endif"])?;
                branches.push((cond, body));
            }
            Some("else") => {
                *pos += 1;
                els = Some(parse_block(toks, pos, &["endif"])?);
            }
            Some("endif") => {
                *pos += 1;
                break;
            }
            _ => break,
        }
    }
    Ok(Node::If { branches, els })
}

/// `\While{c}`/`\For{s}`/`\ForAll{s}` … matching end word.
fn parse_loop(
    word: &'static str,
    tail: &'static str,
    end: &'static str,
    toks: &[Tok],
    pos: &mut usize,
) -> Result<Node, String> {
    let header = take_group(toks, pos, word)?;
    let body = parse_block(toks, pos, &[end, "endfor"])?;
    consume(toks, pos, &[end, "endfor"]);
    Ok(Node::Loop { word, header, tail, body })
}

/// `\Repeat` … `\Until{c}`.
fn parse_repeat(toks: &[Tok], pos: &mut usize) -> Result<Node, String> {
    let body = parse_block(toks, pos, &["until"])?;
    consume(toks, pos, &["until"]);
    let until = take_group(toks, pos, "until")?;
    Ok(Node::Repeat { body, until })
}

/// `\Function{name}{params}`/`\Procedure{…}{…}` … matching end word.
fn parse_func(
    word: &'static str,
    end: &'static str,
    toks: &[Tok],
    pos: &mut usize,
) -> Result<Node, String> {
    let name = take_group(toks, pos, word)?;
    let params = take_group(toks, pos, word)?;
    let body = parse_block(toks, pos, &[end])?;
    consume(toks, pos, &[end]);
    Ok(Node::Func { word, name, params, body })
}

/// The lower-case name of a command token, if the token is a command.
fn cmd_name(t: &Tok) -> Option<String> {
    match t {
        Tok::Cmd(n) => Some(n.to_ascii_lowercase()),
        _ => None,
    }
}

/// Take the next token as a group argument, else error naming `ctx`.
fn take_group(toks: &[Tok], pos: &mut usize, ctx: &str) -> Result<String, String> {
    match toks.get(*pos) {
        Some(Tok::Group(g)) => {
            *pos += 1;
            Ok(g.clone())
        }
        _ => Err(format!("`\\{ctx}` needs a `{{…}}` argument")),
    }
}

/// Consume a command token if its name is in `names`.
fn consume(toks: &[Tok], pos: &mut usize, names: &[&str]) {
    if let Some(n) = toks.get(*pos).and_then(cmd_name) {
        if names.contains(&n.as_str()) {
            *pos += 1;
        }
    }
}

/// Gather the inline source of a statement: text, groups, and inline commands up
/// to the next structural command. A `\Comment{…}` is pulled out as the trailing
/// comment. Returns (inline source, comment source).
fn gather_inline(toks: &[Tok], pos: &mut usize) -> (String, Option<String>) {
    let mut out = String::new();
    let mut comment = None;
    while *pos < toks.len() {
        match &toks[*pos] {
            Tok::Text(t) => {
                out.push_str(t);
                *pos += 1;
            }
            Tok::Group(g) => {
                out.push_str(g);
                *pos += 1;
            }
            Tok::Cmd(name) => {
                let low = name.to_ascii_lowercase();
                if STRUCTURAL.contains(&low.as_str()) {
                    break;
                }
                *pos += 1;
                match low.as_str() {
                    "comment" => {
                        if let Some(Tok::Group(g)) = toks.get(*pos) {
                            comment = Some(g.clone());
                            *pos += 1;
                        }
                    }
                    "call" => {
                        let f = toks.get(*pos).and_then(group_inner).unwrap_or_default();
                        if matches!(toks.get(*pos), Some(Tok::Group(_))) {
                            *pos += 1;
                        }
                        let a = toks.get(*pos).and_then(group_inner).unwrap_or_default();
                        if matches!(toks.get(*pos), Some(Tok::Group(_))) {
                            *pos += 1;
                        }
                        out.push_str(&format!("{f}({a})"));
                    }
                    // `\hfill` and other spacing is dropped.
                    "hfill" | "quad" | "qquad" => {}
                    _ => {
                        if let Some(word) = INLINE_WORDS
                            .iter()
                            .find(|(k, _)| *k == low)
                            .map(|(_, w)| *w)
                        {
                            out.push_str(word);
                        }
                        // An unknown inline command is dropped silently: a
                        // formatting command the body can do without.
                    }
                }
            }
        }
    }
    (out.trim().to_string(), comment.map(|c| c.trim().to_string()))
}

fn group_inner(t: &Tok) -> Option<String> {
    match t {
        Tok::Group(g) => Some(g.clone()),
        _ => None,
    }
}
@

The renderer walks the parse into a nested ordered list. Each node is one `<li>`;
a block nests an `<ol>` inside its opening line, so the CSS line counter runs
unbroken down the listing and indentation shows the block. A keyword is a
`<span class="kw">`, never part of the author's text, so it is not searchable or
selectable as content. The inline closure renders each run of text.
<<render a block>>=
type Inline<'a> = dyn FnMut(&str) -> Result<String, String> + 'a;

/// Render a pseudocode body to a `<ol class="pseudocode">`. `inline` renders a
/// run of text in the document's dialect (math, emphasis, refs).
pub fn render(body: &str, inline: &mut Inline) -> Result<String, String> {
    let toks = tokenize(body);
    let mut pos = 0;
    let nodes = parse_block(&toks, &mut pos, &[])?;
    let mut out = String::from("<ol class=\"pseudocode\">");
    render_nodes(&nodes, inline, &mut out)?;
    out.push_str("</ol>");
    Ok(out)
}

fn render_nodes(nodes: &[Node], inline: &mut Inline, out: &mut String) -> Result<(), String> {
    for node in nodes {
        render_node(node, inline, out)?;
    }
    Ok(())
}

fn block(nodes: &[Node], inline: &mut Inline, out: &mut String) -> Result<(), String> {
    out.push_str("<ol>");
    render_nodes(nodes, inline, out)?;
    out.push_str("</ol>");
    Ok(())
}

fn kw(word: &str) -> String {
    format!("<span class=\"kw\">{word}</span>")
}

fn render_node(node: &Node, inline: &mut Inline, out: &mut String) -> Result<(), String> {
    match node {
        Node::Stmt { lead, inline: src, comment } => {
            out.push_str("<li>");
            if !lead.is_empty() {
                out.push_str(&kw(lead));
                out.push(' ');
            }
            out.push_str(&inline(src)?);
            if let Some(c) = comment {
                out.push_str(&format!(" <span class=\"comment\">\u{25B7} {}</span>", inline(c)?));
            }
            out.push_str("</li>");
        }
        Node::If { branches, els } => {
            for (k, (cond, body)) in branches.iter().enumerate() {
                let head = if k == 0 { "if" } else { "else if" };
                out.push_str("<li>");
                out.push_str(&format!("{} {} {}", kw(head), inline(cond)?, kw("then")));
                block(body, inline, out)?;
                out.push_str("</li>");
            }
            if let Some(body) = els {
                out.push_str("<li>");
                out.push_str(&kw("else"));
                block(body, inline, out)?;
                out.push_str("</li>");
            }
        }
        Node::Loop { word, header, tail, body } => {
            out.push_str("<li>");
            out.push_str(&format!("{} {} {}", kw(word), inline(header)?, kw(tail)));
            block(body, inline, out)?;
            out.push_str("</li>");
        }
        Node::Repeat { body, until } => {
            out.push_str("<li>");
            out.push_str(&kw("repeat"));
            block(body, inline, out)?;
            out.push_str("</li>");
            out.push_str("<li>");
            out.push_str(&format!("{} {}", kw("until"), inline(until)?));
            out.push_str("</li>");
        }
        Node::Func { word, name, params, body } => {
            out.push_str("<li>");
            out.push_str(&format!("{} {}({})", kw(word), inline(name)?, inline(params)?));
            block(body, inline, out)?;
            out.push_str("</li>");
        }
    }
    Ok(())
}
@

The structural commands end a statement's inline run; the inline words map a
control word to a rendered keyword.
<<the keyword tables>>=
const STRUCTURAL: &[&str] = &[
    "state", "return", "print", "require", "ensure", "input", "output", "if",
    "elif", "elsif", "else", "endif", "while", "endwhile", "for", "forall",
    "endfor", "endforall", "repeat", "until", "function", "procedure",
    "endfunction", "endprocedure",
];

const INLINE_WORDS: &[(&str, &str)] = &[
    ("and", " and "),
    ("or", " or "),
    ("not", "not "),
    ("xor", " xor "),
    ("to", " to "),
    ("downto", " downto "),
    ("true", "true"),
    ("false", "false"),
    ("break", "break"),
    ("continue", "continue"),
];
@

The tests cover a straight-line body, a conditional with an else, a loop, and a
trailing comment. The inline closure here is the identity, so the assertions see
the structure and keywords without a math round-trip.
<<pseudocode tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    fn id(s: &str) -> Result<String, String> {
        Ok(s.to_string())
    }

    <<a straight-line body numbers each statement>>

    <<a conditional nests its branches>>

    <<a loop nests its body and a comment trails>>

    <<an unknown command is an error>>
}
@

<<a straight-line body numbers each statement>>=
#[test]
fn straight_line_body() {
    let out = render("\\Require input $x$\n\\State $y \\gets x$\n\\Return $y$", &mut id).unwrap();
    assert!(out.starts_with("<ol class=\"pseudocode\">"));
    assert!(out.contains("<span class=\"kw\">Require:</span> input $x$"));
    assert!(out.contains("<li>$y \\gets x$</li>"));
    assert!(out.contains("<span class=\"kw\">return</span> $y$"));
}
@

<<a conditional nests its branches>>=
#[test]
fn conditional_nests_branches() {
    let out = render("\\If{$a$} \\State one \\Else \\State two \\EndIf", &mut id).unwrap();
    assert!(out.contains("<span class=\"kw\">if</span> $a$ <span class=\"kw\">then</span><ol><li>one</li></ol>"));
    assert!(out.contains("<span class=\"kw\">else</span><ol><li>two</li></ol>"));
}
@

<<a loop nests its body and a comment trails>>=
#[test]
fn loop_and_comment() {
    let out = render("\\For{$i$} \\State step \\Comment{note} \\EndFor", &mut id).unwrap();
    assert!(out.contains("<span class=\"kw\">for</span> $i$ <span class=\"kw\">do</span><ol>"));
    assert!(out.contains("step <span class=\"comment\">\u{25B7} note</span>"));
}
@

<<an unknown command is an error>>=
#[test]
fn unknown_command_errors() {
    let err = render("\\Frobnicate x", &mut id).unwrap_err();
    assert!(err.contains("unknown algorithm command"));
}
@
