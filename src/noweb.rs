//! Parser for noweb's `markup` pipeline format.
//!
//! cob reads `.cob` files with the native reader (`markup::read`, §4.1); this
//! module only parses `markup` IR text into events, which the frozen
//! `fixtures/*.markup` goldens and `cob dump-ir --from-markup` still use as the
//! reader's oracle. Verified against noweb 2.13 (nixpkgs); see §4.2 for the
//! findings this encodes, notably: empty text lines arrive as `@text ` with a
//! trailing space, and an `@fatal` event marks a markup error.

use std::fmt;

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

#[cfg(test)]
mod tests {
    use super::*;

    const HELLO: &str = include_str!("../fixtures/hello.markup");

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
}
