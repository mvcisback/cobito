# The markup IR parser (§4.1, §4.2)

This module is the specification and the implementation of the IR parser. The
prose is the specification. The chunks after it are the implementation.

## What the parser reads {#sec:0AwF}

cob does not drive \code{noweave}. It reads the IR that noweb's \code{markup} stage emits,
and it shells out to \code{notangle} for tangle. \code{markup} writes one tagged line per
token. A short example:

```
@file lexer.cob
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

cob consumes these tags: \code{@file}, \code{@line}, \code{@begin}/\code{@end docs|code}, \code{@text},
\code{@nl}, \code{@defn}, \code{@use}, \code{@quote}/\code{@endquote} (from an inline prose quote),
\code{@literal}, \code{@index defn}, and \code{@fatal}.

Chunk structure is reliable with no extra filter. \code{markup} must emit \code{@defn} and
\code{@use} for each definition and reference, because \code{notangle} is itself
\code{markup | nt}, and \code{nt} reads exactly those tags. cob v1 skips \code{finduses} and
\code{noidx}, which serve the identifier index, not chunk structure. So cob ships no
identifier index in v1; it can come back later.

## Verified against noweb 2.13 {#sec:Kt8c}

R1 is retired. cob probed the real toolchain with \code{fixtures/hello.cob} and the
parser encodes these facts (§4.2):

- The pipeline tools are not on \code{bin}. \code{markup}, \code{nt}, \code{tohtml}, and the rest
  live in \code{lib/noweb}. Only the \code{notangle}/\code{noweave}/\code{noroots} drivers are on
  \code{bin}. The Nix wrapper must add \code{lib/noweb} to the PATH.
- \code{markup} emits no \code{@line} markers by default. cob counts each \code{@nl} since the
  last \code{@file} to get a line number, the same way \code{nt} does for \code{-L}. The parser
  tracks this count for diagnostics (§12).
- \code{@ %def c} becomes \code{@index defn c} and makes no docs chunk.
- A continued chunk arrives as separate \code{@begin code} blocks that share one
  \code{@defn} name, in source order.
- An inline prose quote matches greedily to its last closing bracket pair, so a
  nested quote keeps its inner brackets.
- A blank line between chunks becomes an empty docs chunk, and the stream also
  opens with a leading empty docs chunk. The section builder merges or drops
  these.
- Inside a code chunk, the indentation before a chunk use arrives as its own
  \code{@text} token. This is how noweb propagates indentation.
- On error, \code{markup} emits an \code{@fatal} event in the stream. The parser preserves
  it as \code{Event::Fatal}, so a frozen golden records the failure too.
- An unescaped chunk-use bracket in a docs chunk is a fatal error. The at-escape
  (an \code{@} before each bracket) arrives as literal text.
- A backslash-dollar in prose passes through untouched. That escape is cob's own
  convention (§6.2), not a noweb feature.

## How the code implements this {#sec:nsvK}

The module is the event type and a line parser that folds \code{markup} IR text into
events.
<<src/noweb.rs>>=
<<the module banner>>

<<imports>>

<<the event type>>

<<the parse error>>

<<parse the whole ir>>

<<parse one line>>

<<the tests>>
@
The banner records the noweb version and the three empirical quirks the parser must
respect.
<<the module banner>>=
//! Parser for noweb's `markup` pipeline format.
//!
//! cob reads `.cob` files with the native reader (`markup::read`, §4.1); this
//! module only parses `markup` IR text into events, which the frozen
//! `fixtures/*.markup` goldens and `cob dump-ir --from-markup` still use as the
//! reader's oracle. Verified against noweb 2.13 (nixpkgs); see §4.2 for the
//! findings this encodes, notably: empty text lines arrive as `@text ` with a
//! trailing space, and an `@fatal` event marks a markup error.
@
Only formatting — this module parses \code{markup} IR text into events. It runs no
process; the native reader (\code{markup::read}, §4.1) reads \code{.cob} files at run time.
<<imports>>=
use std::fmt;
@
Every line of markup IR maps to one \code{Event}. An unknown tag is not an error: it
becomes \code{Other}, so a future noweb version surfaces as a failing test rather than a
panic.
<<the event type>>=
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    File(String),
    BeginDocs(u32),
    EndDocs(u32),
    BeginCode(u32),
    EndCode(u32),
    Text(String),
    Nl,
    Defn(String),
    Use(String),
    Quote,
    EndQuote,
    IndexDefn(String),
    IndexUse(String),
    IndexNl,
    Line(u32),
    Literal(String),
    Fatal(String),
    /// Unknown tag, preserved so version drift surfaces in tests, not panics.
    Other {
        tag: String,
        arg: String,
    },
}
@
A line the parser cannot read is E001. It carries the line number and the offending
text, because the usual cause is a noweb version whose IR shape cob was not built
against.
<<the parse error>>=
#[derive(Debug)]
pub struct ParseError {
    pub line_no: usize,
    pub line: String,
    pub reason: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "error[E001]: bad IR line {}: {} ({:?})",
            self.line_no, self.reason, self.line
        )
    }
}

impl std::error::Error for ParseError {}
@
Parse the whole IR line by line, numbering from one so an error points at a real
line.
<<parse the whole ir>>=
pub fn parse(input: &str) -> Result<Vec<Event>, ParseError> {
    input
        .lines()
        .enumerate()
        .map(|(i, line)| {
            parse_line(line).map_err(|reason| ParseError {
                line_no: i + 1,
                line: line.to_string(),
                reason,
            })
        })
        .collect()
}
@
One line to one event. Strip the leading \code{@}, split off the tag, then dispatch.
\code{begin} and \code{end} carry a \code{docs|code N} argument; \code{index} has its own sub-grammar;
everything unrecognized falls through to \code{Other} rather than failing, so version
drift is visible but never fatal.
<<parse one line>>=
fn parse_line(line: &str) -> Result<Event, String> {
    let rest = line
        .strip_prefix('@')
        .ok_or_else(|| "line does not start with '@'".to_string())?;
    let (tag, arg) = match rest.split_once(' ') {
        Some((tag, arg)) => (tag, arg),
        None => (rest, ""),
    };
    let event = match tag {
        "file" => Event::File(arg.to_string()),
        "begin" | "end" => {
            let (kind, n) = arg
                .split_once(' ')
                .ok_or_else(|| format!("@{tag} expects `docs|code N`"))?;
            let n: u32 = n.parse().map_err(|_| format!("bad chunk number {n:?}"))?;
            match (tag, kind) {
                ("begin", "docs") => Event::BeginDocs(n),
                ("begin", "code") => Event::BeginCode(n),
                ("end", "docs") => Event::EndDocs(n),
                ("end", "code") => Event::EndCode(n),
                _ => return Err(format!("unknown chunk kind {kind:?}")),
            }
        }
        "text" => Event::Text(arg.to_string()),
        "nl" => Event::Nl,
        "defn" => Event::Defn(arg.to_string()),
        "use" => Event::Use(arg.to_string()),
        "quote" => Event::Quote,
        "endquote" => Event::EndQuote,
        "index" => match arg.split_once(' ') {
            Some(("defn", name)) => Event::IndexDefn(name.to_string()),
            Some(("use", name)) => Event::IndexUse(name.to_string()),
            None if arg == "nl" => Event::IndexNl,
            _ => Event::Other {
                tag: format!("index {}", arg.split(' ').next().unwrap_or("")),
                arg: arg.to_string(),
            },
        },
        "line" => Event::Line(
            arg.parse()
                .map_err(|_| format!("bad line number {arg:?}"))?,
        ),
        "literal" => Event::Literal(arg.to_string()),
        "fatal" => Event::Fatal(arg.to_string()),
        _ => Event::Other {
            tag: tag.to_string(),
            arg: arg.to_string(),
        },
    };
    Ok(event)
}
@
The tests are the executable half of §4.2: they pin real \code{markup} output and the
parser's handling of each event shape.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    const HELLO: &str = include_str!("../fixtures/hello.markup");

    <<parsing the pinned fixture>>

    <<text forms>>

    <<structural lines>>

    <<unknown tags survive>>
}
@
The pinned \code{hello.markup} fixture parses, its code-chunk numbers and defn/use names
come out as expected, and nothing degrades to \code{Other}.
<<parsing the pinned fixture>>=
#[test]
fn parses_pinned_markup_output() {
    let events = parse(HELLO).expect("pinned fixture must parse");
    assert_eq!(events[0], Event::File("fixtures/hello.cob".to_string()));

    let code_numbers: Vec<u32> = events
        .iter()
        .filter_map(|e| match e {
            Event::BeginCode(n) => Some(*n),
            _ => None,
        })
        .collect();
    assert_eq!(code_numbers, vec![2, 5, 8, 11]);

    let defns: Vec<&str> = events
        .iter()
        .filter_map(|e| match e {
            Event::Defn(name) => Some(name.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        defns,
        vec!["lex a token", "lex a token", "next char", "src/main.rs"]
    );

    let uses: Vec<&str> = events
        .iter()
        .filter_map(|e| match e {
            Event::Use(name) => Some(name.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(uses, vec!["next char", "lex a token"]);

    assert!(events.contains(&Event::IndexDefn("c".to_string())));
    assert!(!events.iter().any(|e| matches!(e, Event::Other { .. })));
}
@
Empty text is \code{@text } with a trailing space, but the parser is liberal and also
accepts a bare \code{@text}. Spaces inside content are significant.
<<text forms>>=
#[test]
fn text_forms() {
    // Empty text arrives as `@text ` (trailing space); be liberal about `@text`.
    assert_eq!(parse_line("@text ").unwrap(), Event::Text(String::new()));
    assert_eq!(parse_line("@text").unwrap(), Event::Text(String::new()));
    // Trailing spaces inside content are significant.
    assert_eq!(
        parse_line("@text We call ").unwrap(),
        Event::Text("We call ".to_string())
    );
    assert_eq!(parse_line("@nl").unwrap(), Event::Nl);
}
@
The structural tags — begin/end, index, defn — parse to their typed events.
<<structural lines>>=
#[test]
fn structural_lines() {
    assert_eq!(parse_line("@begin docs 0").unwrap(), Event::BeginDocs(0));
    assert_eq!(parse_line("@end code 11").unwrap(), Event::EndCode(11));
    assert_eq!(
        parse_line("@index defn c").unwrap(),
        Event::IndexDefn("c".to_string())
    );
    assert_eq!(parse_line("@index nl").unwrap(), Event::IndexNl);
    assert_eq!(
        parse_line("@defn lex a token").unwrap(),
        Event::Defn("lex a token".to_string())
    );
}
@
An unknown tag becomes \code{Other} rather than an error, and a line without a leading
\code{@} is rejected.
<<unknown tags survive>>=
#[test]
fn unknown_tags_are_preserved_not_fatal() {
    assert_eq!(
        parse_line("@xref label NW1").unwrap(),
        Event::Other {
            tag: "xref".to_string(),
            arg: "label NW1".to_string()
        }
    );
    assert!(parse_line("no at sign").is_err());
}
@
