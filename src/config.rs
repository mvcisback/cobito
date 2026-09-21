//! `cob.toml`, the project manifest (§5.2). M4 reads a deliberately
//! small slice: `[[document]]` metadata (which feeds `site.json`'s `meta`) and
//! `[[tangle.root]]` line-pragma formats. The `[weave]` / `[weave.annotate]`
//! keys of §5.3/§10 are parsed leniently (unknown keys ignored) but not yet
//! acted on — they arrive with the milestones that need them.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug)]
pub enum ConfigError {
    /// `cob.toml` was present but did not parse.
    Parse { path: String, message: String },
    /// Reading `cob.toml` failed for a reason other than absence.
    Read { path: String, source: std::io::Error },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Parse { path, message } => {
                write!(f, "error[E029]: {path}: {message}")
            }
            ConfigError::Read { path, source } => {
                write!(f, "error[E029]: reading {path}: {source}")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

/// The whole manifest. Every section is optional so a bare or absent `cob.toml`
/// is valid — the CLI simply falls back to its argument-derived defaults.
#[derive(Deserialize, Default)]
pub struct Config {
    #[serde(rename = "document", default)]
    pub documents: Vec<Document>,
    #[serde(default)]
    pub tangle: Tangle,
    #[serde(default)]
    pub weave: Weave,
}

/// The `[weave]` table (§5.5). Only the document-wide highlighting default lives
/// here for now; the `[weave.annotate]` keys of §5.3/§10 arrive with their
/// milestones and are parsed leniently (unknown keys ignored) until then.
#[derive(Deserialize, Default)]
pub struct Weave {
    /// The document-wide language for syntax highlighting (tier 2, §5.5): the
    /// value `cob language`/the weaver resolves against, e.g. `"rust"` or
    /// `"nix"`. Absent means fall back to the tangle-root file extension.
    #[serde(default)]
    pub lang: Option<String>,
    /// The `[weave.chunk-lang]` map (tier 1, §5.5): chunk name → language id, the
    /// per-chunk override that wins over `lang` and the extension fallback. It is
    /// out-of-band config, so it survives `markup` where an inline `{lang=…}`
    /// would not. `BTreeMap` keeps the deserialized order deterministic.
    #[serde(rename = "chunk-lang", default)]
    pub chunk_lang: BTreeMap<String, String>,
}

/// One document's identity and file set (§5.2). A project may declare several;
/// M4's single-document CLI uses the first.
#[derive(Deserialize, Default, Clone)]
pub struct Document {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub files: Vec<String>,
}

#[derive(Deserialize, Default)]
pub struct Tangle {
    #[serde(default)]
    pub outdir: Option<String>,
    #[serde(rename = "root", default)]
    pub roots: Vec<Root>,
}

/// A per-root override. Only `line-pragma` matters in M4; `chunk` names the root
/// it applies to.
#[derive(Deserialize, Default, Clone)]
pub struct Root {
    pub chunk: String,
    #[serde(rename = "line-pragma", default)]
    pub line_pragma: LinePragma,
}

/// `notangle -L` format for a root, or `false` for none. The correct format is
/// language-specific, so a plain boolean can only *disable* pragmas — enabling
/// them requires the format string itself (§5.2).
#[derive(Deserialize, Clone)]
#[serde(untagged)]
pub enum LinePragma {
    // The bool is parse-only: it lets `line-pragma = false` deserialize, but
    // carries no information beyond "off", which `format()` returns as `None`.
    Off(#[allow(dead_code)] bool),
    Format(String),
}

impl Default for LinePragma {
    fn default() -> Self {
        LinePragma::Off(false)
    }
}

impl LinePragma {
    /// The `-L` format to pass notangle, or `None` when pragmas are off.
    pub fn format(&self) -> Option<&str> {
        match self {
            LinePragma::Format(s) if !s.is_empty() => Some(s),
            _ => None,
        }
    }
}

impl Config {
    /// Load `dir/cob.toml`. Absence is not an error — returns `Ok(None)` so the
    /// caller keeps its argument-derived defaults.
    pub fn load(dir: &Path) -> Result<Option<Config>, ConfigError> {
        let path = dir.join("cob.toml");
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(ConfigError::Read {
                    path: path.display().to_string(),
                    source,
                })
            }
        };
        toml::from_str(&text)
            .map(Some)
            .map_err(|e| ConfigError::Parse {
                path: path.display().to_string(),
                message: e.message().to_string(),
            })
    }

    /// The first declared document, if any — M4's single-document convention.
    pub fn document(&self) -> Option<&Document> {
        self.documents.first()
    }

    /// Root name → `-L` format, for the roots that configure one.
    pub fn tangle_pragmas(&self) -> BTreeMap<String, String> {
        self.tangle
            .roots
            .iter()
            .filter_map(|r| r.line_pragma.format().map(|f| (r.chunk.clone(), f.to_string())))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Config {
        toml::from_str(text).unwrap()
    }

    #[test]
    fn absent_file_is_not_an_error() {
        let dir = std::env::temp_dir().join("cob-config-absent");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(Config::load(&dir).unwrap().is_none());
    }

    #[test]
    fn document_meta_is_read() {
        let c = parse(
            r#"
            [[document]]
            id = "cob"
            title = "cob: a system"
            authors = ["A", "B"]
            files = ["a.cob", "b.cob"]
            "#,
        );
        let d = c.document().unwrap();
        assert_eq!(d.id, "cob");
        assert_eq!(d.title, "cob: a system");
        assert_eq!(d.authors, vec!["A", "B"]);
        assert_eq!(d.files, vec!["a.cob", "b.cob"]);
    }

    #[test]
    fn line_pragma_off_by_default_and_when_false() {
        let c = parse(
            r#"
            [[tangle.root]]
            chunk = "src/lexer.rs"
            line-pragma = false

            [[tangle.root]]
            chunk = "no-key.rs"

            [[tangle.root]]
            chunk = "server/app.py"
            line-pragma = '# %L "%F"%N'
            "#,
        );
        let pragmas = c.tangle_pragmas();
        // Only the root with a format string appears; `false` and the missing
        // key contribute nothing.
        assert_eq!(pragmas.len(), 1);
        assert_eq!(
            pragmas.get("server/app.py").map(String::as_str),
            Some("# %L \"%F\"%N")
        );
    }

    #[test]
    fn weave_lang_and_chunk_lang_map_are_read() {
        let c = parse(
            r#"
            [weave]
            lang = "nix"

            [weave.chunk-lang]
            "the drift check" = "bash"
            "the lock check" = "bash"
            "#,
        );
        assert_eq!(c.weave.lang.as_deref(), Some("nix"));
        assert_eq!(c.weave.chunk_lang.get("the drift check").map(String::as_str), Some("bash"));
        assert_eq!(c.weave.chunk_lang.get("the lock check").map(String::as_str), Some("bash"));
    }

    #[test]
    fn empty_config_yields_no_document_or_pragmas() {
        let c = parse("");
        assert!(c.document().is_none());
        assert!(c.tangle_pragmas().is_empty());
    }
}
