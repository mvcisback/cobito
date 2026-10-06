# Diagnostics (§12)

This module is the text behind \code{cob --explain <CODE>}. The prose is the
specification. The chunks after it are the implementation.

## One format for every error {#sec:9zhc}

cob reports one diagnostic format from every stage. The format leads with a stable
code and a one-line message, then points at the source, then adds any notes:

```verbatim
error[E014]: duplicate label `fig:pipeline`
  --> parser.cob:118:6
   |
   = note: first defined at intro.cob:42:6
```

Four rules hold this together. Every error carries a stable code, so a test or a
suppression can name one error and no other. Every source location comes from the
IR's \code{@file} and \code{@line} tags — which is \emph{why} cob consumes those tags even though
tangle handles the pragmas itself. A lint (a missing caption label, a chunk
defined but never used, an empty docs chunk, a code chunk that resolves to no
known language — W104, §5.5) is a warning, and \code{--deny-warnings} promotes every
warning to an error for CI. And \code{cob --explain <CODE>} prints the long form, which
is the text this module holds.

## How the code implements this {#sec:ZCuq}

The module is one function and its tests. \code{explain} is a single \code{match} over the
code. The arms must stay in the order of the §12 registry, so this page groups
them by theme without moving any arm out of registry order. Each group has prose
that says what the codes in it share.
<<src/diag.rs>>=
//! Long-form error explanations for `cob --explain <CODE>` (§12). The
//! one-line form is emitted at the error site; this is the paragraph a reader
//! asks for when that line is not enough. Codes are stable (§12 registry).

<<the explain function>>

<<the explain tests>>
@
The function upper-cases the code first, so \code{e014} and \code{E014} reach the same arm.
An unknown code returns \code{None}, which the caller turns into a "no such code"
message. Every arm returns a \code{&'static str}, so the table costs nothing at run
time.
<<the explain function>>=
/// The long form for a stable error code, or `None` if the code is unknown.
/// Matching is case-insensitive on the letter so `e014` works too.
pub fn explain(code: &str) -> Option<&'static str> {
    let code = code.to_ascii_uppercase();
    let text = match code.as_str() {
        <<markup and missing-chunk diagnostics>>
        <<label and reference diagnostics>>
        <<math diagnostics>>
        <<output and template diagnostics>>
        <<tangle diagnostics>>
        <<manifest diagnostics>>
        <<float-directive diagnostics>>
        <<lock diagnostics>>
        <<import diagnostics>>
        _ => return None,
    };
    Some(text)
}
@
These codes are about the markup IR. E001 is a line of IR that cob cannot parse.
E002 is retired: cob read source through a noweb process in v1, but it reads
\code{.cob} natively now (§4.1). E010 is a chunk use whose name has no matching
definition — cob catches it before it tangles.
<<markup and missing-chunk diagnostics>>=
"E001" => "cob could not parse a line of markup IR. cob parses IR only to read \
           a frozen `.markup` golden (§4.1); a parse error means the golden, or \
           the noweb that made it, has an IR shape cob was not built against.",
"E002" => "Retired. cob read source through a noweb `markup` process in v1; it \
           now reads `.cob` natively (§4.1), so this code is no longer emitted.",
"E010" => "A code chunk used `@<<name@>>` for a chunk that is never defined. \
           Define the chunk, or fix the reference. cob's tangler needs every use \
           to resolve, so it reports this before it tangles.",
@
These two codes guard the cross-reference system. Labels must be unique because
references and \code{site.json} key on them (E014). A reference must point at a label
that exists (E015).
<<label and reference diagnostics>>=
"E014" => "Two labels share one name (e.g. two `id=\"fig:x\"`). Labels must \
           be unique across the whole document because cross-references and \
           `site.json` key on them. Rename one.",
"E015" => "A `data-ref` points at a label that does not exist anywhere in \
           the document. Check the spelling, or add the missing label.",
@
These three codes come from the math pass. E020 is a formula KaTeX rejected.
E022 is an unbalanced math delimiter. E023 is a missing asset bundle. Math
renders at weave time, so a broken formula cannot wait for the browser.
<<math diagnostics>>=
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
@
These three codes are the write-out failures of a weave. E024 is a disk or
permission problem. E025 and E026 are template and HTML-rewrite failures; E025
is an internal bug in cob's own template, while E026 is almost always malformed
authored HTML.
<<output and template diagnostics>>=
"E024" => "Writing the woven site to the output directory failed — usually \
           permissions or a full disk. The underlying OS error is included.",
"E025" => "The page template failed to render. This is an internal error in \
           cob's own template, not your input; please report it.",
"E026" => "Rewriting a prose section's HTML failed inside lol_html. This is \
           almost always malformed HTML in authored prose; the message \
           names the offending construct.",
@
These codes come from the tangle path. E028 is a disk failure while writing a
tangled root. E035 is a chunk that uses itself, directly or through others — the
native tangler reports the cycle instead of looping forever. E027 is retired: cob
tangled through \code{notangle} in v1, and the code stays reserved so an old
diagnostic still explains.
<<tangle diagnostics>>=
"E027" => "Retired. cob v1 tangled by running noweb's `notangle`; it now \
           tangles natively (§11), so this code is no longer emitted.",
"E028" => "Writing a tangled root to disk failed — permissions, a full disk, \
           or an unwritable parent directory. The path and OS error are \
           included.",
"E035" => "A chunk expands into itself, directly or through a chain of uses. \
           The native tangler reports the cycle (with the chain of names) \
           instead of looping forever; break the recursion.",
@
This code is the manifest failure. \code{cob.toml} was present but could not be read
or parsed. Removing it falls back to CLI-derived defaults.
<<manifest diagnostics>>=
"E029" => "`cob.toml` was present but could not be read or parsed. The \
           message carries the TOML parser's reason and location; fix the \
           manifest, or remove it to fall back to CLI-derived defaults.",
@
These two codes guard the fenced blocks (§6.4). E030 is a malformed modifier on a
known fence: a bad \code{\label{…}}, a bad \code{\caption{…}}, a label namespace that
does not match its fence, or a \code{\lang}/\code{\label} on a fence that does not take
it. The namespace must match so the cross-reference machinery can find the label.
E034 is a fence whose kind is missing or unknown; the kind set is closed, so a typo
is an error, not a wrong render.
<<float-directive diagnostics>>=
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
@
These two codes come from the frozen-id lock (§7.1). E031 is a label with no
frozen id during a \code{--locked} weave, which never mints. E032 is a lock file that
could not be read, parsed, or written.
<<lock diagnostics>>=
"E031" => "A label carried by a float was not found in `cob.lock` while \
           weaving under `--locked`. Locked weaves (CI and the read-only Nix \
           sandbox) never mint ids; they require every label to already own \
           a frozen id (§7.1). Run `cob lock` to mint the missing ids and \
           commit the updated `cob.lock`, or drop `--locked`.",
"E032" => "`cob.lock` could not be read, parsed, or written. The message \
           carries the underlying I/O or TOML error. The lock is generated \
           TOML (§7.1); edit it only to retire a label, and never by hand in \
           a way that corrupts its structure.",
@
These codes come from the forest (§13). E036 is an \code{\import} fault: an import
with no \code{[import.…]} in \code{cob.toml}, a macro that expands into itself, or the rare
content-id clash with a local macro. E037 is a fetch fault: a failed git clone, an
unsatisfiable \code{version} requirement, a moved release tag, a ref with no published
\code{cob-exports.json}, or a \code{git} import a weave met before \code{cob fetch} pinned it.
E038 is a format file (a \code{cob.lock} or an imported \code{cob-exports.json}) with a newer
major schema than this cob understands. E039 and E040 are citations (§14): a
bibliography that does not read or parse, and a \code{\cite} to a key no bibliography
has. E041 is a \code{cob backlinks} write failure (§16).
<<import diagnostics>>=
"E036" => "An `\\import … as …` failed. Either it names an import with no \
           `[import.<name>]` in cob.toml, or an imported macro expands into \
           itself, or an imported macro's content id collided with a local \
           macro. Imports are content-addressed (§13); a collision is \
           improbable, so it usually means a missing or misnamed import.",
"E037" => "`cob fetch`/`cob update` could not pin a remote import, or a weave met \
           a `git` import that was never fetched. Causes: a git clone/fetch \
           failed, no released tag satisfies the `version` requirement, a `git` \
           import gave neither or both of `version`/`rev`, a released version's \
           tag moved (it must be immutable), the ref has no cob-exports.json at \
           its root, the cache could not be written, or you need to run \
           `cob fetch` before weaving (§13).",
"E038" => "A format file has a newer major schema than this cob understands — a \
           `cob.lock` or an imported forest's `cob-exports.json` written by a \
           newer cob. Schemas are semver: the same major is compatible (a newer \
           minor only adds fields cob ignores), a newer major is not. Upgrade cob \
           (§7.1, §13).",
"E039" => "The bibliography file named in `[cite] bib` could not be read or \
           parsed. The message carries the path and the BibTeX parser's reason; \
           fix the file, or correct the path in cob.toml (§14).",
"E040" => "A `\\cite{key}` names a key that is in no configured bibliography. \
           Check the key's spelling, add the entry to the `.bib`, or set \
           `[cite] bib` in cob.toml if no bibliography is configured yet (§14).",
"E041" => "`cob backlinks` could not write a reverse-backlink fragment — usually \
           a permissions or disk problem writing into a site's `n/` directory. \
           The path and OS error are included (§16).",
@
The tests pin two properties: a few known codes explain and are case-insensitive,
and an unknown code is \code{None}.
<<the explain tests>>=
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
@
