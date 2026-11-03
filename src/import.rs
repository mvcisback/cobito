//! Importing macros from another forest (§13). An `imports` fence declares
//! `\import <name> as <alias>`; this turns the imported macro tables into
//! content-addressed (merkle) KaTeX macros, plus the `alias.name -> id` map the
//! weaver uses to rewrite `\alias.name` in a formula. The author never sees the
//! id; it only has to be clash-free and stable, which a content hash gives.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

#[derive(Debug, Default)]
pub struct Imports {
    /// `\<id>` → the macro's expansion, with its own references already rewritten
    /// to ids. The weaver adds these to the document's KaTeX macro table.
    pub macros: BTreeMap<String, String>,
    /// `alias.name` → `\<id>`. The weaver rewrites `\alias.name` in a formula to
    /// the id before KaTeX.
    pub rewrites: BTreeMap<String, String>,
    /// `\<id>` → (import name, original macro name), so an opaque id is traceable.
    pub provenance: BTreeMap<String, (String, String)>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ImportError {
    /// `\import <name> as …` names a source with no loaded macro table.
    Unknown(String),
    /// A macro expands into itself, directly or through a chain, in the source.
    Cycle(String),
    /// A content id collided with a local macro of different content — the rare
    /// case the hash does not rule out, caught at merge time (§13).
    Collision(String),
}

impl fmt::Display for ImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ImportError::Unknown(name) => write!(
                f,
                "error[E036]: `\\import {name} as …` names an unknown import; add \
                 an `[import.{name}]` to cob.toml"
            ),
            ImportError::Cycle(name) => {
                write!(f, "error[E036]: imported macro `{name}` expands into itself")
            }
            ImportError::Collision(name) => write!(
                f,
                "error[E036]: imported macro id `{name}` collides with a local macro"
            ),
        }
    }
}

impl std::error::Error for ImportError {}

/// Resolve `decls` (import name, local alias) against `sources` (import name →
/// its macro table). See §13.
pub fn resolve(
    sources: &BTreeMap<String, BTreeMap<String, String>>,
    decls: &[(String, String)],
) -> Result<Imports, ImportError> {
    let mut out = Imports::default();
    for (name, alias) in decls {
        let table = sources
            .get(name)
            .ok_or_else(|| ImportError::Unknown(name.clone()))?;
        // Content-id every macro of this source; deps are computed first.
        let mut ids: BTreeMap<String, String> = BTreeMap::new();
        let mut exps: BTreeMap<String, String> = BTreeMap::new();
        for mname in table.keys() {
            compute(mname, table, &mut ids, &mut exps, &mut BTreeSet::new())?;
        }
        for (mname, id) in &ids {
            let key = format!("\\{id}");
            out.macros.insert(key.clone(), exps[mname].clone());
            let bare = mname.strip_prefix('\\').unwrap_or(mname);
            out.rewrites.insert(format!("{alias}.{bare}"), key.clone());
            out.provenance.insert(key, (name.clone(), mname.clone()));
        }
    }
    Ok(out)
}

/// Compute (and memoize) a macro's content id and its dependency-rewritten
/// expansion. Recurses into references first, so the id is a merkle id.
fn compute(
    name: &str,
    table: &BTreeMap<String, String>,
    ids: &mut BTreeMap<String, String>,
    exps: &mut BTreeMap<String, String>,
    stack: &mut BTreeSet<String>,
) -> Result<String, ImportError> {
    if let Some(id) = ids.get(name) {
        return Ok(id.clone());
    }
    if !stack.insert(name.to_string()) {
        return Err(ImportError::Cycle(name.to_string()));
    }
    let expansion = table[name].clone();
    let rewritten = rewrite_refs(&expansion, table, ids, exps, stack)?;
    stack.remove(name);
    let id = content_id(&rewritten);
    ids.insert(name.to_string(), id.clone());
    exps.insert(name.to_string(), rewritten);
    Ok(id)
}

/// Replace every `\other` in `exp` that names a macro of this source with that
/// macro's `\<id>`. A control word not in the table (a KaTeX builtin) is left
/// alone; a control symbol (`\{`, `\\`, `#1` has no backslash) passes through.
fn rewrite_refs(
    exp: &str,
    table: &BTreeMap<String, String>,
    ids: &mut BTreeMap<String, String>,
    exps: &mut BTreeMap<String, String>,
    stack: &mut BTreeSet<String>,
) -> Result<String, ImportError> {
    let mut out = String::new();
    let mut rest = exp;
    while let Some(p) = rest.find('\\') {
        out.push_str(&rest[..p]);
        let after = &rest[p + 1..];
        let n = after.chars().take_while(|c| c.is_ascii_alphabetic()).count();
        if n == 0 {
            // A control symbol or escaped backslash: copy `\` and its one char.
            out.push('\\');
            if let Some(c) = after.chars().next() {
                out.push(c);
                rest = &after[c.len_utf8()..];
            } else {
                rest = after;
            }
            continue;
        }
        let cs = format!("\\{}", &after[..n]);
        if table.contains_key(&cs) {
            let id = compute(&cs, table, ids, exps, stack)?;
            out.push('\\');
            out.push_str(&id);
        } else {
            out.push_str(&cs);
        }
        rest = &after[n..];
    }
    out.push_str(rest);
    Ok(out)
}

fn content_id(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    let mut out = String::with_capacity(12);
    for _ in 0..12 {
        out.push((b'a' + (h % 26) as u8) as char);
        h /= 26;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn sources(name: &str, t: BTreeMap<String, String>) -> BTreeMap<String, BTreeMap<String, String>> {
        let mut s = BTreeMap::new();
        s.insert(name.to_string(), t);
        s
    }

    #[test]
    fn a_flat_macro_resolves() {
        let s = sources("algebra", table(&[("\\RR", "\\mathbb{R}")]));
        let im = resolve(&s, &[("algebra".to_string(), "alg".to_string())]).unwrap();
        let id = im.rewrites.get("alg.RR").expect("alias.name maps to an id");
        assert!(id.starts_with('\\') && id[1..].chars().all(|c| c.is_ascii_lowercase()));
        assert_eq!(im.macros.get(id).map(String::as_str), Some("\\mathbb{R}"));
        assert_eq!(im.provenance.get(id), Some(&("algebra".to_string(), "\\RR".to_string())));
    }

    #[test]
    fn a_dependency_is_carried_as_an_id() {
        let s = sources("algebra", table(&[("\\RR", "\\mathbb{R}"), ("\\R", "\\RR")]));
        let im = resolve(&s, &[("algebra".to_string(), "alg".to_string())]).unwrap();
        let rr = im.rewrites["alg.RR"].clone();
        let r = im.rewrites["alg.R"].clone();
        // `\R`'s expansion is `\RR` rewritten to `\RR`'s id, not the name `\RR`.
        assert_eq!(im.macros[&r], rr);
        assert_ne!(r, rr);
    }

    #[test]
    fn the_same_macro_gets_the_same_id() {
        let a = resolve(
            &sources("x", table(&[("\\RR", "\\mathbb{R}")])),
            &[("x".to_string(), "p".to_string())],
        )
        .unwrap();
        let b = resolve(
            &sources("y", table(&[("\\RR", "\\mathbb{R}")])),
            &[("y".to_string(), "q".to_string())],
        )
        .unwrap();
        assert_eq!(a.rewrites["p.RR"], b.rewrites["q.RR"]);
    }

    #[test]
    fn unknown_and_cycle_are_e036() {
        let empty = BTreeMap::new();
        let err = resolve(&empty, &[("ghost".to_string(), "g".to_string())]).unwrap_err();
        assert_eq!(err, ImportError::Unknown("ghost".to_string()));
        assert!(err.to_string().starts_with("error[E036]"));

        let s = sources("loop", table(&[("\\a", "\\b"), ("\\b", "\\a")]));
        let err = resolve(&s, &[("loop".to_string(), "l".to_string())]).unwrap_err();
        assert!(matches!(err, ImportError::Cycle(_)));
    }

    #[test]
    fn a_parameter_survives() {
        let s = sources("algebra", table(&[("\\abs", "\\lvert #1 \\rvert")]));
        let im = resolve(&s, &[("algebra".to_string(), "alg".to_string())]).unwrap();
        assert_eq!(im.macros[&im.rewrites["alg.abs"]], "\\lvert #1 \\rvert");
    }
}
