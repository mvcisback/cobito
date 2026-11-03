@ # Untangle: a patch from tangled edits back to source (§11, #2/D)

cob tangles a `.cob` document to the plain source files a compiler reads. This
module runs the other way: given edits made to a tangled file, it emits a patch on
the `.cob` source that reproduces them. So a quick fix or a formatter run on
`src/main.rs` becomes a `git apply`-able diff on `src/main.rs.cob`, and a
re-tangle then matches the edit.

It builds on the located tangle (§11, #3): tangling a root yields its text and a
line map — which `.cob` file and line wrote each output line. An edit to a tangled
line therefore maps back to one source line. The tangle adds splice indentation to
a chunk used on its own line, so the module strips that indentation from the edit
to recover the source line.

This first slice maps **in-place line edits** — the common "tweak a line" case. An
edit that adds or removes lines, that lands on a line holding an expanded chunk-use
hole, or that changes the splice indentation, is reported as a **conflict** and
left out of the patch, never guessed. The reverse map that would resolve those
exactly (source byte spans per span) is a later change.

@ ## The module {#sec:a908}

The module is the conflict type, the per-line rewrite (the one piece of logic, so
it is unit-tested on its own), the unified-diff writer, and the entry point that
walks every root.
<<src/untangle.rs>>=
<<imports>>

<<the conflict>>

<<rewrite one line>>

<<the unified diff>>

<<the patch entry point>>

<<the tests>>
@ The module pulls in the model, the located tangle, and a sorted map for the
per-file edits.
<<imports>>=
use crate::model::DocModel;
use crate::tangle::{self, TangleError};
use std::collections::BTreeMap;
use std::path::Path;
@ ## The conflict {#sec:byjB}

A conflict is a tangled-file edit the module will not map back: it names the root,
the 1-based tangled line (0 for a whole-file structural change), and why.
<<the conflict>>=
/// A tangled-file edit that could not be mapped back to source.
pub struct Conflict {
    pub root: String,
    pub line: usize,
    pub reason: &'static str,
}
@ ## Rewriting one line {#sec:nj26}

The one piece of logic, kept pure so a test drives it directly. A tangled line of a
chunk used on its own line is `indent + source_line`, where `indent` is the splice
whitespace and `source_line` is the chunk's own text. So the edit maps back by
stripping that same `indent` from the edited line. If the tangled line does not end
with its source text, the line holds an expanded hole or an escape, and the edit
cannot map back cleanly.
<<rewrite one line>>=
/// Map an edited tangled line back to its source line, or say why it cannot.
/// `orig` is the original tangled line, `edited` the new one, `src` the source
/// line the map points at.
fn rewrite_line(orig: &str, edited: &str, src: &str) -> Result<String, &'static str> {
    let Some(prefix_len) = orig.len().checked_sub(src.len()) else {
        return Err("tangled line shorter than its source line (a hole or escape)");
    };
    if &orig[prefix_len..] != src {
        return Err("tangled line does not end with its source text (a hole or escape)");
    }
    let indent = &orig[..prefix_len];
    if !indent.bytes().all(|b| b == b' ' || b == b'\t') {
        return Err("the inserted prefix is not whitespace");
    }
    if !edited.starts_with(indent) {
        return Err("the edit changed the chunk indentation");
    }
    Ok(edited[indent.len()..].to_string())
}
@ ## The unified diff {#sec:cU8i}

A minimal unified diff for a file whose only changes are line replacements (same
line count). Changed line indices group into hunks with three lines of context,
and each hunk lists context, removed, and added lines, so `git apply` and `patch`
both take it.
<<the unified diff>>=
/// A unified diff for `path` from `old` with `changed` (0-based line → new text),
/// three lines of context. Empty when nothing changed.
fn unified_diff(path: &str, old: &[&str], changed: &BTreeMap<usize, String>) -> String {
    if changed.is_empty() {
        return String::new();
    }
    const CTX: usize = 3;
    let idxs: Vec<usize> = changed.keys().copied().collect();
    // Group changed lines into hunks, merging when their context would touch.
    let mut hunks: Vec<(usize, usize)> = Vec::new();
    let (mut s, mut e) = (idxs[0], idxs[0]);
    for &i in &idxs[1..] {
        if i <= e + 2 * CTX + 1 {
            e = i;
        } else {
            hunks.push((s, e));
            (s, e) = (i, i);
        }
    }
    hunks.push((s, e));

    let mut out = format!("--- a/{path}\n+++ b/{path}\n");
    for (hs, he) in hunks {
        let start = hs.saturating_sub(CTX);
        let end = (he + CTX).min(old.len().saturating_sub(1));
        let count = end - start + 1;
        out += &format!("@@ -{},{count} +{},{count} @@\n", start + 1, start + 1);
        for (i, line) in old.iter().enumerate().take(end + 1).skip(start) {
            match changed.get(&i) {
                Some(new) => {
                    out += &format!("-{line}\n+{new}\n");
                }
                None => out += &format!(" {line}\n"),
            }
        }
    }
    out
}
@ ## The entry point {#sec:m2DE}

`patch` walks every root in a deterministic order. For each it tangles with the
line map, reads the edited file under `outdir`, and — when the line counts match —
maps each changed line back to a source line through `rewrite_line`. It collects
the per-`.cob`-file line replacements, then writes one unified diff per file. A
file is read once and cached.
<<the patch entry point>>=
/// Compute a patch on the `.cob` source(s) reproducing edits made to the tangled
/// files under `outdir`. Returns the patch text (empty if nothing maps) and the
/// edits that could not be mapped.
pub fn patch(doc: &DocModel, outdir: &Path) -> Result<(String, Vec<Conflict>), TangleError> {
    let mut conflicts = Vec::new();
    let mut sources: BTreeMap<String, String> = BTreeMap::new();
    let mut file_edits: BTreeMap<String, BTreeMap<usize, String>> = BTreeMap::new();

    let mut roots: Vec<&str> = doc
        .chunks
        .iter()
        .filter(|(_, info)| info.root)
        .map(|(name, _)| name.as_str())
        .collect();
    roots.sort_unstable();

    for root in roots {
        let (tangled, map) = tangle::tangle_root_located(doc, root)?;
        let Ok(disk) = std::fs::read_to_string(outdir.join(root)) else {
            continue;
        };
        if disk == tangled {
            continue;
        }
        let orig: Vec<&str> = tangled.split('\n').collect();
        let edited: Vec<&str> = disk.split('\n').collect();
        if orig.len() != edited.len() {
            conflicts.push(Conflict {
                root: root.to_string(),
                line: 0,
                reason: "lines added or removed; only in-place edits map back",
            });
            continue;
        }
        for (i, (o, n)) in orig.iter().zip(&edited).enumerate() {
            if o == n {
                continue;
            }
            let Some(loc) = map.get(i) else {
                conflicts.push(Conflict { root: root.to_string(), line: i + 1, reason: "no source mapping for this line" });
                continue;
            };
            sources
                .entry(loc.file.clone())
                .or_insert_with(|| std::fs::read_to_string(&loc.file).unwrap_or_default());
            let src_line = sources[&loc.file].split('\n').nth(loc.line as usize - 1);
            match src_line.map(|s| rewrite_line(o, n, s)) {
                Some(Ok(new_src)) => {
                    file_edits
                        .entry(loc.file.clone())
                        .or_default()
                        .insert(loc.line as usize - 1, new_src);
                }
                Some(Err(reason)) => conflicts.push(Conflict { root: root.to_string(), line: i + 1, reason }),
                None => conflicts.push(Conflict { root: root.to_string(), line: i + 1, reason: "source line is out of range" }),
            }
        }
    }

    let mut out = String::new();
    for (file, edits) in &file_edits {
        let content = sources.get(file).cloned().unwrap_or_default();
        let old: Vec<&str> = content.split('\n').collect();
        out += &unified_diff(file, &old, edits);
    }
    Ok((out, conflicts))
}
@ ## Tests {#sec:EWzC}

The rewrite covers the three cases: an indented chunk-expansion line maps back by
stripping the indent, a line holding a hole is a conflict, and an edit that touches
the indentation is a conflict. The diff writer gets one small replacement.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrite_strips_splice_indentation() {
        // An indented line from a chunk used on its own line maps back un-indented.
        let got = rewrite_line("    tokens.push(c);", "    tokens.push(c); // note", "tokens.push(c);");
        assert_eq!(got, Ok("tokens.push(c); // note".to_string()));
    }

    #[test]
    fn rewrite_refuses_a_hole_line() {
        // The source line holds a chunk use (@<< / @>> tangle to the brackets), so
        // the tangled line does not end with it — a conflict, not a guess.
        let got = rewrite_line("let c = input.next();", "let c = input.peek();", "let c = @<<next char@>>;");
        assert!(got.is_err());
    }

    #[test]
    fn rewrite_refuses_an_indentation_edit() {
        let got = rewrite_line("    a();", "a();", "a();");
        assert!(got.is_err());
    }

    #[test]
    fn unified_diff_replaces_one_line() {
        let old = ["one", "two", "three"];
        let mut changed = BTreeMap::new();
        changed.insert(1usize, "TWO".to_string());
        let d = unified_diff("f.cob", &old, &changed);
        assert!(d.contains("--- a/f.cob\n+++ b/f.cob\n"));
        assert!(d.contains("-two\n+TWO\n"));
        assert!(d.contains("@@ -1,3 +1,3 @@"));
    }
}
@
