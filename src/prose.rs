//! Steps 1–2 of the prose pipeline (SPEC.md §6.2): reassemble docs spans, then
//! lift math out into placeholders.
//!
//! The ordering is the whole point. Escaping `[[…]]` happens before anything
//! else so `[[<div>]]` is inert, and math is extracted before any HTML parsing
//! so `$a < b$` is never seen as a malformed tag.

use std::fmt;

use crate::model::ProseSpan;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Math {
    pub source: String,
    pub display: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProseError {
    pub delim: String,
    pub context: String,
}

impl fmt::Display for ProseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "unterminated math delimiter `{}` (started at {:?})",
            self.delim, self.context
        )
    }
}

impl std::error::Error for ProseError {}

/// Escape for HTML text context. `&<>"` only — prose is authored HTML and the
/// author is trusted (§6.2); this exists to make quoted code inert, not to
/// sanitize.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

/// Step 1. `@text`/`@nl` concatenated; `[[…]]` becomes escaped `<code>`.
pub fn reassemble(spans: &[ProseSpan]) -> String {
    let mut out = String::new();
    for span in spans {
        match span {
            ProseSpan::Text(t) => out.push_str(t),
            ProseSpan::Nl => out.push('\n'),
            ProseSpan::Quote(q) => {
                out.push_str("<code>");
                out.push_str(&escape(q));
                out.push_str("</code>");
            }
        }
    }
    out
}

/// Regions where math is not scanned and `\$` is not unescaped: the `<code>`
/// step 1 produced, plus any `<pre>`/`<code>` the author wrote.
const SKIP_TAGS: [&str; 2] = ["code", "pre"];

fn skip_region(s: &str, at: usize) -> Option<usize> {
    let rest = &s[at..];
    if !rest.starts_with('<') {
        return None;
    }
    for tag in SKIP_TAGS {
        let open = &rest[1..];
        let matches_name = open.len() > tag.len()
            && open[..tag.len()].eq_ignore_ascii_case(tag)
            && open[tag.len()..]
                .chars()
                .next()
                .is_some_and(|c| c == '>' || c == ' ' || c == '\n' || c == '\t' || c == '/');
        if !matches_name {
            continue;
        }
        let close = format!("</{tag}>");
        // Unclosed author markup is not our error to raise here; treat the
        // remainder as skipped so the math scanner cannot misread it.
        return Some(match find_ci(s, at, &close) {
            Some(i) => i + close.len(),
            None => s.len(),
        });
    }
    None
}

fn find_ci(s: &str, from: usize, needle: &str) -> Option<usize> {
    s[from..]
        .to_ascii_lowercase()
        .find(&needle.to_ascii_lowercase())
        .map(|i| from + i)
}

/// Find `close` at or after `from`, ignoring backslash-escaped occurrences.
fn find_close(s: &str, from: usize, close: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut i = from;
    while i + close.len() <= s.len() {
        if s.is_char_boundary(i) && s[i..].starts_with(close) {
            let escaped = i > 0 && bytes[i - 1] == b'\\';
            if !escaped {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

fn context_at(s: &str, at: usize) -> String {
    let end = s[at..]
        .char_indices()
        .nth(24)
        .map(|(i, _)| at + i)
        .unwrap_or(s.len());
    s[at..end].to_string()
}

/// Step 2. Replace every math run with an opaque placeholder element and push
/// its source onto `out`. The placeholder is well-formed HTML so it survives
/// the parse/serialize round trip that M2 will add between steps 3 and 5.
pub fn extract_math(input: &str, out: &mut Vec<Math>) -> Result<String, ProseError> {
    // Longest delimiters first: `$$` must win over `$`.
    const DELIMS: [(&str, &str, bool); 4] = [
        ("$$", "$$", true),
        ("\\[", "\\]", true),
        ("\\(", "\\)", false),
        ("$", "$", false),
    ];

    let mut html = String::with_capacity(input.len());
    let mut i = 0;
    'outer: while i < input.len() {
        if let Some(end) = skip_region(input, i) {
            html.push_str(&input[i..end]);
            i = end;
            continue;
        }
        // Our convention, not noweb's: `markup` passes `\$` through untouched.
        if input[i..].starts_with("\\$") {
            html.push('$');
            i += 2;
            continue;
        }
        for (open, close, display) in DELIMS {
            if !input[i..].starts_with(open) {
                continue;
            }
            let body = i + open.len();
            let Some(end) = find_close(input, body, close) else {
                return Err(ProseError {
                    delim: open.to_string(),
                    context: context_at(input, i),
                });
            };
            html.push_str(&format!("<span data-lit-math=\"{}\"></span>", out.len()));
            out.push(Math {
                source: input[body..end].to_string(),
                display,
            });
            i = end + close.len();
            continue 'outer;
        }
        let ch = input[i..].chars().next().unwrap_or('\0');
        html.push(ch);
        i += ch.len_utf8();
    }
    Ok(html)
}

/// Step 6. Substitute rendered math back into the serialized HTML.
pub fn substitute_math(html: &str, rendered: &[String]) -> String {
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while let Some(found) = html[i..].find("<span data-lit-math=\"") {
        let start = i + found;
        out.push_str(&html[i..start]);
        let num_start = start + "<span data-lit-math=\"".len();
        let Some(quote) = html[num_start..].find('"') else {
            break;
        };
        let end_tag = "\"></span>";
        if !html[num_start + quote..].starts_with(end_tag) {
            out.push_str(&html[start..num_start]);
            i = num_start;
            continue;
        }
        let idx: usize = html[num_start..num_start + quote]
            .parse()
            .unwrap_or(usize::MAX);
        match rendered.get(idx) {
            Some(r) => out.push_str(r),
            None => out.push_str(&html[start..num_start + quote + end_tag.len()]),
        }
        i = num_start + quote + end_tag.len();
    }
    out.push_str(&html[i..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extract(s: &str) -> (String, Vec<Math>) {
        let mut math = Vec::new();
        let html = extract_math(s, &mut math).expect("extracts");
        (html, math)
    }

    #[test]
    fn quoted_code_is_escaped_at_reassembly() {
        let spans = vec![
            ProseSpan::Text("see ".to_string()),
            ProseSpan::Quote("<div> & \"x\"".to_string()),
            ProseSpan::Nl,
        ];
        assert_eq!(
            reassemble(&spans),
            "see <code>&lt;div&gt; &amp; &quot;x&quot;</code>\n"
        );
    }

    #[test]
    fn angle_bracket_math_is_not_a_tag() {
        // The reason extraction precedes HTML parsing (§6.2 step 2).
        let (html, math) = extract("bracket, $a < b$.");
        assert_eq!(html, "bracket, <span data-lit-math=\"0\"></span>.");
        assert_eq!(math[0].source, "a < b");
        assert!(!math[0].display);
    }

    #[test]
    fn display_and_inline_delimiters() {
        let (_, math) = extract(r"$x$ and $$y$$ and \(z\) and \[w\]");
        assert_eq!(
            math,
            vec![
                Math {
                    source: "x".into(),
                    display: false
                },
                Math {
                    source: "y".into(),
                    display: true
                },
                Math {
                    source: "z".into(),
                    display: false
                },
                Math {
                    source: "w".into(),
                    display: true
                },
            ]
        );
    }

    #[test]
    fn escaped_dollar_is_literal_and_not_math() {
        let (html, math) = extract(r"cost is \$5 and \$6.");
        assert_eq!(html, "cost is $5 and $6.");
        assert!(math.is_empty());
    }

    #[test]
    fn math_is_not_scanned_inside_code_or_pre() {
        let (html, math) = extract("<code>$not math$</code> but $yes$");
        assert_eq!(
            html,
            "<code>$not math$</code> but <span data-lit-math=\"0\"></span>"
        );
        assert_eq!(math.len(), 1);
        assert_eq!(math[0].source, "yes");

        let (html, math) = extract("<pre class=\"chunk\">a $b$ c</pre>");
        assert_eq!(html, "<pre class=\"chunk\">a $b$ c</pre>");
        assert!(math.is_empty());
    }

    #[test]
    fn backslash_dollar_inside_code_stays_verbatim() {
        let (html, _) = extract(r"<code>\$5</code>");
        assert_eq!(html, r"<code>\$5</code>");
    }

    #[test]
    fn unterminated_math_is_an_error() {
        let mut math = Vec::new();
        let err = extract_math("open $a + b", &mut math).unwrap_err();
        assert_eq!(err.delim, "$");
        assert!(err.to_string().contains("unterminated"));
    }

    #[test]
    fn placeholders_are_numbered_document_globally() {
        let mut math = Vec::new();
        let a = extract_math("$p$", &mut math).unwrap();
        let b = extract_math("$q$", &mut math).unwrap();
        assert_eq!(a, "<span data-lit-math=\"0\"></span>");
        assert_eq!(b, "<span data-lit-math=\"1\"></span>");
        assert_eq!(math.len(), 2);
    }

    #[test]
    fn substitution_round_trips() {
        let mut math = Vec::new();
        let html = extract_math("a $x$ b $$y$$", &mut math).unwrap();
        let out = substitute_math(&html, &["<X/>".to_string(), "<Y/>".to_string()]);
        assert_eq!(out, "a <X/> b <Y/>");
    }

    #[test]
    fn fixture_prose_survives_the_pipeline() {
        let ir = include_str!("../fixtures/hello.markup");
        let doc = crate::model::build(&crate::noweb::parse(ir).unwrap()).unwrap();
        let mut math = Vec::new();
        for section in &doc.sections {
            if let crate::model::SectionKind::Docs { spans } = &section.kind {
                extract_math(&reassemble(spans), &mut math).expect("fixture prose extracts");
            }
        }
        let sources: Vec<&str> = math.iter().map(|m| m.source.as_str()).collect();
        assert_eq!(sources, vec![r"O(n \log n)", "a < b"]);
    }
}
