# The prose layer (§6.1, §6.2)

This module is the specification and the implementation of the shared ends of
the prose pipeline. The prose is the specification. The chunks after it are the
implementation.

noweb does not solve the prose problem. Its \code{tohtml} passes prose through
verbatim, because it assumes the author wrote HTML. Its \code{l2h} translates a fixed
LaTeX subset, does not expand author macros, and shows math as italics. cob does
its own prose layer instead.

## One prose dialect {#sec:iquM}

An author writes a docs chunk in one dialect: command Markdown (§6.4). Prose is
CommonMark plus cob's command markers and fenced-float directives. Paragraphs,
emphasis, lists, links, and headings become HTML. The fenced directives for
math, figures, and tables become labelled, numbered floats, and \code{\ref{…}} is a
cross-reference.

The Markdown render is a post-\code{markup} transform on the reassembled prose
(§6.4). It slots in between reassembly and the HTML rewrite. Everything after
that step — numbering, references, math render, sidenote hoist, and \code{site.json}
— is the same for every document.

## The pipeline (the order is load-bearing) {#sec:O0Sz}

cob processes each docs chunk in this order:

1. Reassemble. Join the \code{@text} and \code{@nl} spans. Turn each \code{@quote}…\code{@endquote}
   into a \code{<code>} element with its contents HTML-escaped. This escape comes
   first, so an inline quote of a tag such as \code{<div>} is safe.
2. Render Markdown. The command-Markdown pass (§6.4) turns the prose into HTML.
   It extracts each math run into an opaque placeholder as it goes, so a formula
   like \code{$a < b$} is never read as a broken tag.
3. Rewrite. Inject section ids, number the figures, tables, and equations,
   resolve each \code{data-ref}, and hoist each sidenote aside into the section's
   margin array.
4. Serialize.
5. Render math. Replace each placeholder with KaTeX output.

Steps 3 to 5 need document-global numbering, so cob runs the whole document
through step 2 before any section reaches step 3. Weave cannot stream.

cob does not sanitize prose. The author is the trusted party. A margin comment
is the annotation layer's problem (\code{ANNOTATIONS.md}), never merged into cob's
output.

## How the code implements this {#sec:bz51}

This module holds the shared ends of the pipeline: the extracted-math type, the
HTML escaper, step 1 (reassembly), and the step-5 substitution that puts
rendered math back. The Markdown render (step 2) is the markdown module; the
rewrite (steps 3–4) is the rewrite module; step 5's KaTeX call is the math
module.
<<src/prose.rs>>=
<<the module banner>>

<<imports>>

<<extracted math>>

<<the html escaper>>

<<step 1: reassemble>>

<<step 5: substitute math>>

<<the tests>>
@
The banner states the two shared ends of the pipeline this module owns.
<<the module banner>>=
//! The shared ends of the prose pipeline (§6.2): reassemble docs spans into
//! prose (step 1), and substitute rendered math back into the serialized HTML
//! (step 5). The Markdown render in between, which extracts math, is the
//! markdown module.
@
The \code{ProseSpan} the model hands us.
<<imports>>=
use crate::model::ProseSpan;
@
One extracted formula: its source and whether it renders in display mode.
<<extracted math>>=
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Math {
    pub source: String,
    pub display: bool,
}
@
Escape for HTML text — four characters only. Prose is authored HTML by a trusted
author (§6.2), so this exists to make quoted code inert, not to sanitize.
<<the html escaper>>=
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
@
Step 1. Concatenate the text and newline spans into one prose string. Inline code
is \code{\code{…}} now (§6.4), lowered later by the Markdown pass, so reassembly is a
plain join.
<<step 1: reassemble>>=
/// Step 1. `@text`/`@nl` spans concatenated into one prose string.
pub fn reassemble(spans: &[ProseSpan]) -> String {
    let mut out = String::new();
    for span in spans {
        match span {
            ProseSpan::Text(t) => out.push_str(t),
            ProseSpan::Nl => out.push('\n'),
        }
    }
    out
}
@
Step 5. Walk the serialized HTML, replacing each numbered placeholder with its
rendered fragment. A placeholder whose number has no rendered entry, or a malformed
one, is left as-is rather than dropped.
<<step 5: substitute math>>=
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
@
The tests walk this module's two behaviors: reassembling spans into prose, and
math substitution back into serialized HTML.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    <<reassembly joins spans>>

    <<substitution round-trips>>
}
@
Reassembly joins the text and newline spans verbatim; inline code is \code{\code{…}}
now, lowered later by the Markdown pass, so reassembly does no escaping.
<<reassembly joins spans>>=
#[test]
fn reassembly_joins_text_and_newlines() {
    let spans = vec![
        ProseSpan::Text("a `b`".to_string()),
        ProseSpan::Nl,
        ProseSpan::Text("c".to_string()),
    ];
    assert_eq!(reassemble(&spans), "a `b`\nc");
}
@
Rendered fragments substitute back into their placeholders by index; a
placeholder with no rendered entry is left as-is.
<<substitution round-trips>>=
#[test]
fn substitution_round_trips() {
    let html = "a <span data-cob-math=\"0\"></span> b <span data-cob-math=\"1\"></span>";
    let out = substitute_math(html, &["<X/>".to_string(), "<Y/>".to_string()]);
    assert_eq!(out, "a <X/> b <Y/>");
}
@
