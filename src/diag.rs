//! Long-form error explanations for `cob --explain <CODE>` (§12). The
//! one-line form is emitted at the error site; this is the paragraph a reader
//! asks for when that line is not enough. Codes are stable (§12 registry).

/// The long form for a stable error code, or `None` if the code is unknown.
/// Matching is case-insensitive on the letter so `e014` works too.
pub fn explain(code: &str) -> Option<&'static str> {
    let code = code.to_ascii_uppercase();
    let text = match code.as_str() {
        "E001" => "cob could not parse a line of markup IR. cob parses IR only to read \
                   a frozen `.markup` golden (§4.1); a parse error means the golden, or \
                   the noweb that made it, has an IR shape cob was not built against.",
        "E002" => "Retired. cob read source through a noweb `markup` process in v1; it \
                   now reads `.cob` natively (§4.1), so this code is no longer emitted.",
        "E010" => "A code chunk used `<<name>>` for a chunk that is never defined. \
                   Define the chunk, or fix the reference. cob's tangler needs every use \
                   to resolve, so it reports this before it tangles.",
        "E014" => "Two labels share one name (e.g. two `id=\"fig:x\"`). Labels must \
                   be unique across the whole document because cross-references and \
                   `site.json` key on them. Rename one.",
        "E015" => "A `data-ref` points at a label that does not exist anywhere in \
                   the document. Check the spelling, or add the missing label.",
        "E020" => "KaTeX rejected a math fragment. The message carries KaTeX's own \
                   reason; fix the TeX. Math is rendered at weave time so the site \
                   ships no script — a broken formula cannot be deferred to the \
                   browser.",
        "E022" => "A `$` or `$$` math delimiter was opened but never closed on the \
                   same section. Balance the delimiters; to write a literal dollar \
                   sign, escape it as `\\$`.",
        "E023" => "COB_KATEX_ASSETS is unset or wrong. It points at the pinned KaTeX \
                   dist (CSS + woff2 fonts) that the site embeds; without it every \
                   equation renders twice. The devShell and wrapped package set it.",
        "E024" => "Writing the woven site to the output directory failed — usually \
                   permissions or a full disk. The underlying OS error is included.",
        "E025" => "The page template failed to render. This is an internal error in \
                   cob's own template, not your input; please report it.",
        "E026" => "Rewriting a prose section's HTML failed inside lol_html. This is \
                   almost always malformed HTML in authored prose; the message \
                   names the offending construct.",
        "E027" => "Retired. cob v1 tangled by running noweb's `notangle`; it now \
                   tangles natively (§11), so this code is no longer emitted.",
        "E028" => "Writing a tangled root to disk failed — permissions, a full disk, \
                   or an unwritable parent directory. The path and OS error are \
                   included.",
        "E035" => "A chunk expands into itself, directly or through a chain of uses. \
                   The native tangler reports the cycle (with the chain of names) \
                   instead of looping forever; break the recursion.",
        "E029" => "`cob.toml` was present but could not be read or parsed. The \
                   message carries the TOML parser's reason and location; fix the \
                   manifest, or remove it to fall back to CLI-derived defaults.",
        "E030" => "A fence had a malformed modifier: an unterminated or mis-namespaced \
                   `\\label{…}`, an unterminated `\\caption{…}`, a `\\lang{…}` on a fence \
                   that is not `verbatim`, or a `\\label` on a `verbatim` fence. A float \
                   label's namespace must match the fence (`fig:`/`tbl:`/`eq:`) so the \
                   cross-reference machinery can find it.",
        "E034" => "A fenced block had no kind (a bare ```` ``` ````) or an unknown kind. \
                   The kinds are closed: `math`, `figure`, `table`, `macros`, \
                   `html-escape`, or `verbatim`. Use `verbatim` (with an optional \
                   `\\lang{…}`) for plain preformatted text; a missing or misspelt kind \
                   is an error, not a silent fallback.",
        "E031" => "A label carried by a float was not found in `cob.lock` while \
                   weaving under `--locked`. Locked weaves (CI and the read-only Nix \
                   sandbox) never mint ids; they require every label to already own \
                   a frozen id (§7.1). Run `cob lock` to mint the missing ids and \
                   commit the updated `cob.lock`, or drop `--locked`.",
        "E032" => "`cob.lock` could not be read, parsed, or written. The message \
                   carries the underlying I/O or TOML error. The lock is generated \
                   TOML (§7.1); edit it only to retire a label, and never by hand in \
                   a way that corrupts its structure.",
        _ => return None,
    };
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_codes_explain_and_are_case_insensitive() {
        assert!(explain("E014").unwrap().contains("unique"));
        assert_eq!(explain("e014"), explain("E014"));
        assert!(explain("E029").unwrap().contains("cob.toml"));
        assert!(explain("E030").unwrap().contains("namespace"));
        assert!(explain("E034").unwrap().contains("verbatim"));
        assert!(explain("E031").unwrap().contains("cob.lock"));
        assert!(explain("E032").unwrap().contains("cob.lock"));
    }

    #[test]
    fn unknown_code_is_none() {
        assert!(explain("E999").is_none());
        assert!(explain("nonsense").is_none());
    }
}
