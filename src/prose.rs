//! The shared ends of the prose pipeline (§6.2): reassemble docs spans into
//! prose (step 1), and substitute rendered math back into the serialized HTML
//! (step 5). The Markdown render in between, which extracts math, is the
//! markdown module.

use crate::model::ProseSpan;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Math {
    pub source: String,
    pub display: bool,
}

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

/// Step 5. Substitute rendered math back into the serialized HTML.
pub fn substitute_math(html: &str, rendered: &[String]) -> String {
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while let Some(found) = html[i..].find("<span data-cob-math=\"") {
        let start = i + found;
        out.push_str(&html[i..start]);
        let num_start = start + "<span data-cob-math=\"".len();
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
    fn substitution_round_trips() {
        let html = "a <span data-cob-math=\"0\"></span> b <span data-cob-math=\"1\"></span>";
        let out = substitute_math(html, &["<X/>".to_string(), "<Y/>".to_string()]);
        assert_eq!(out, "a <X/> b <Y/>");
    }
}
