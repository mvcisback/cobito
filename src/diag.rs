//! Long-form error explanations for `lit --explain <CODE>` (SPEC.md §12). The
//! one-line form is emitted at the error site; this is the paragraph a reader
//! asks for when that line is not enough. Codes are stable (§12 registry).

/// The long form for a stable error code, or `None` if the code is unknown.
/// Matching is case-insensitive on the letter so `e014` works too.
pub fn explain(code: &str) -> Option<&'static str> {
    let code = code.to_ascii_uppercase();
    let text = match code.as_str() {
        "E001" => "The `markup` IR contained a line lit could not parse. This means \
                   the noweb version on PATH emits an IR shape lit was not built \
                   against — check that the pinned noweb from the flake is in use.",
        "E002" => "`markup` itself failed, emitted an `@fatal`, or could not be \
                   found. It ships with noweb; run inside `nix develop` or the \
                   wrapped package so noweb's pipeline tools are on PATH.",
        "E010" => "A code chunk used `<<name>>` for a chunk that is never defined. \
                   Define the chunk, or fix the reference — notangle would fail on \
                   the same input, so lit reports it before shelling out.",
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
        "E023" => "LIT_KATEX_ASSETS is unset or wrong. It points at the pinned KaTeX \
                   dist (CSS + woff2 fonts) that the site embeds; without it every \
                   equation renders twice. The devShell and wrapped package set it.",
        "E024" => "Writing the woven site to the output directory failed — usually \
                   permissions or a full disk. The underlying OS error is included.",
        "E025" => "The page template failed to render. This is an internal error in \
                   lit's own template, not your input; please report it.",
        "E026" => "Rewriting a prose section's HTML failed inside lol_html. This is \
                   almost always malformed HTML in authored prose; the message \
                   names the offending construct.",
        "E027" => "`notangle` could not be run or exited nonzero. It ships with \
                   noweb — run inside the dev shell or wrapped package. A nonzero \
                   exit carries noweb's own `file:line: message`.",
        "E028" => "Writing a tangled root to disk failed — permissions, a full disk, \
                   or an unwritable parent directory. The path and OS error are \
                   included.",
        "E029" => "`lit.toml` was present but could not be read or parsed. The \
                   message carries the TOML parser's reason and location; fix the \
                   manifest, or remove it to fall back to CLI-derived defaults.",
        "E030" => "A `figure`/`table`/`math` fence had a malformed directive: an \
                   unterminated or mis-namespaced `\\label{…}`, an unterminated \
                   `\\caption{…}`, or unexpected text after the directive. The label \
                   namespace must match the fence (`fig:`/`tbl:`/`eq:`) so the \
                   cross-reference machinery can find it.",
        "E031" => "A label carried by a float was not found in `lit.lock` while \
                   weaving under `--locked`. Locked weaves (CI and the read-only Nix \
                   sandbox) never mint ids; they require every label to already own \
                   a frozen id (§7.1). Run `lit lock` to mint the missing ids and \
                   commit the updated `lit.lock`, or drop `--locked`.",
        "E032" => "`lit.lock` could not be read, parsed, or written. The message \
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
        assert!(explain("E029").unwrap().contains("lit.toml"));
        assert!(explain("E030").unwrap().contains("namespace"));
        assert!(explain("E031").unwrap().contains("lit.lock"));
        assert!(explain("E032").unwrap().contains("lit.lock"));
    }

    #[test]
    fn unknown_code_is_none() {
        assert!(explain("E999").is_none());
        assert!(explain("nonsense").is_none());
    }
}
