//! Citations and the bibliography (§14). A cited work is a node (§10): it earns a
//! frozen opaque id and a node page, and `\cite{key}` is a reference to it. This
//! module only reads a BibTeX file into plain `Reference`s and formats one; the
//! node model gives it identity, a page, and "Cited by" backlinks.

use std::collections::BTreeMap;
use std::path::Path;

use biblatex::{Bibliography, ChunksExt, DateValue, PermissiveType};

use crate::prose;

/// One bibliography entry as cob keeps it (§14): the parser's types are extracted
/// into this plain record, so nothing else in cob depends on `biblatex`.
#[derive(Debug, Clone, Default)]
pub struct Reference {
    pub key: String,
    /// The BibTeX entry type word (`article`, `book`, …), lowercased.
    pub kind: String,
    /// Display author names, given-then-family (`Jane Smith`).
    pub authors: Vec<String>,
    pub title: String,
    /// The journal, booktitle, or publisher — whichever the entry carries.
    pub container: String,
    pub year: Option<i32>,
}

/// A loaded bibliography (§14): `key → Reference`. Read once per weave; a cited
/// key that is absent is the caller's E040, not this module's concern.
#[derive(Debug, Default)]
pub struct Bib {
    entries: BTreeMap<String, Reference>,
}

impl Bib {
    /// The reference for a cite key, if the bibliography has it.
    pub fn get(&self, key: &str) -> Option<&Reference> {
        self.entries.get(key)
    }
}

/// E039 — the bibliography file could not be read or parsed (§14).
#[derive(Debug)]
pub enum CiteError {
    Read { path: String, message: String },
    Parse { path: String, message: String },
}

impl std::fmt::Display for CiteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CiteError::Read { path, message } => {
                write!(f, "error[E039]: reading {path}: {message}")
            }
            CiteError::Parse { path, message } => {
                write!(f, "error[E039]: {path}: {message}")
            }
        }
    }
}

impl std::error::Error for CiteError {}

/// Read and parse a BibTeX file into a `Bib` (§14). A read or parse failure is
/// E039; a missing field within an entry is tolerated (left empty).
pub fn load(path: &Path) -> Result<Bib, CiteError> {
    let text = std::fs::read_to_string(path).map_err(|e| CiteError::Read {
        path: path.display().to_string(),
        message: e.to_string(),
    })?;
    let parsed = Bibliography::parse(&text).map_err(|e| CiteError::Parse {
        path: path.display().to_string(),
        message: e.to_string(),
    })?;
    let mut entries = BTreeMap::new();
    for entry in parsed.iter() {
        let r = extract(entry);
        entries.insert(r.key.clone(), r);
    }
    Ok(Bib { entries })
}

/// One `biblatex` entry → cob's plain `Reference`. Every field is best-effort: a
/// missing or unparsable field is left empty rather than failing the load.
fn extract(entry: &biblatex::Entry) -> Reference {
    let authors = entry
        .author()
        .map(|ps| ps.iter().map(person_name).collect())
        .unwrap_or_default();
    let title = entry
        .title()
        .map(|t| t.format_verbatim())
        .unwrap_or_default();
    // The container is the journal, booktitle, or publisher — whichever exists.
    let container = ["journal", "booktitle", "publisher"]
        .iter()
        .find_map(|f| entry.get(f).map(|c| c.format_verbatim()))
        .unwrap_or_default();
    Reference {
        key: entry.key.clone(),
        kind: format!("{:?}", entry.entry_type).to_lowercase(),
        authors,
        title,
        container,
        year: year_of(entry),
    }
}

/// A person's display name, given-then-family (`Jane Smith`); family only when
/// there is no given name.
fn person_name(p: &biblatex::Person) -> String {
    if p.given_name.is_empty() {
        p.name.clone()
    } else {
        format!("{} {}", p.given_name, p.name)
    }
}

/// The entry's year, from its `date`/`year` field, or `None` when absent or a
/// range/open date cob does not reduce to one year.
fn year_of(entry: &biblatex::Entry) -> Option<i32> {
    match entry.date().ok()? {
        PermissiveType::Typed(d) => match d.value {
            DateValue::At(ts) | DateValue::After(ts) | DateValue::Before(ts) => Some(ts.year),
            DateValue::Between(a, _) => Some(a.year),
        },
        PermissiveType::Chunks(_) => None,
    }
}

/// One reference as an HTML line (§14): `Authors. Title. <em>Container</em>, Year.`
/// Empty parts are skipped and every text part is escaped.
pub fn format_html(r: &Reference) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !r.authors.is_empty() {
        parts.push(prose::escape(&r.authors.join(", ")));
    }
    if !r.title.is_empty() {
        parts.push(prose::escape(&r.title));
    }
    let mut tail = String::new();
    if !r.container.is_empty() {
        tail.push_str(&format!("<em>{}</em>", prose::escape(&r.container)));
    }
    if let Some(y) = r.year {
        if !tail.is_empty() {
            tail.push_str(", ");
        }
        tail.push_str(&y.to_string());
    }
    if !tail.is_empty() {
        parts.push(tail);
    }
    let mut out = parts.join(". ");
    if !out.is_empty() {
        out.push('.');
    }
    out
}

/// A short label for a reference's node page and breadcrumb (§14): the first
/// author's family name and the year (`Smith 2020`), falling back to the author,
/// the year, or the key when a part is missing.
pub fn short_title(r: &Reference) -> String {
    let family = r
        .authors
        .first()
        .map(|a| a.rsplit(' ').next().unwrap_or(a).to_string());
    match (family, r.year) {
        (Some(w), Some(y)) => format!("{w} {y}"),
        (Some(w), None) => w,
        (None, Some(y)) => y.to_string(),
        (None, None) => r.key.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = r#"
@article{smith2020,
  author  = {Jane Smith and John Doe},
  title   = {On the Nature of Things},
  journal = {Journal of Things},
  year    = {2020}
}
@book{knuth1984,
  author    = {Donald E. Knuth},
  title     = {The {\TeX}book},
  publisher = {Addison-Wesley},
  year      = {1984}
}
@misc{sparse,
  title = {A Note}
}
"#;

    fn bib() -> Bib {
        // A unique path per call: tests run in parallel, so a shared file could be
        // read mid-write by another test and parse short.
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join("cob-cite-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("refs-{}-{}.bib", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        std::fs::write(&path, SRC).unwrap();
        load(&path).unwrap()
    }

    #[test]
    fn an_article_extracts_authors_title_container_year() {
        let b = bib();
        let r = b.get("smith2020").unwrap();
        assert_eq!(r.kind, "article");
        assert_eq!(r.authors, vec!["Jane Smith", "John Doe"]);
        assert_eq!(r.title, "On the Nature of Things");
        assert_eq!(r.container, "Journal of Things");
        assert_eq!(r.year, Some(2020));
    }

    #[test]
    fn a_book_reads_its_publisher_and_strips_tex() {
        let b = bib();
        let r = b.get("knuth1984").unwrap();
        assert_eq!(r.kind, "book");
        assert_eq!(r.container, "Addison-Wesley");
        // `biblatex` renders the TeX, so `{\TeX}book` is plain text.
        assert_eq!(r.title, "The TeXbook");
    }

    #[test]
    fn format_skips_empty_parts_and_escapes() {
        let b = bib();
        let full = format_html(b.get("smith2020").unwrap());
        assert_eq!(
            full,
            "Jane Smith, John Doe. On the Nature of Things. <em>Journal of Things</em>, 2020."
        );
        // A sparse entry (title only) still reads cleanly.
        let sparse = format_html(b.get("sparse").unwrap());
        assert_eq!(sparse, "A Note.");
    }

    #[test]
    fn an_unknown_key_is_none() {
        assert!(bib().get("ghost").is_none());
    }
}
