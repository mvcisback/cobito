//! Fold `markup`'s IR into cob's document model (§19.2).
//!
//! The line counter is the subtle part: it advances on both `Nl` *and*
//! `IndexNl`, because an `@ %def` line is a source line whose newline reaches
//! us as `IndexNl` (§4.2). Getting this wrong silently shifts every
//! provenance attribute after the first `%def` in a file.

use std::collections::BTreeMap;
use std::fmt;

use crate::noweb::Event;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProseSpan {
    Text(String),
    Nl,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodeSpan {
    Text(String),
    Nl,
    Use { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SectionKind {
    Docs {
        spans: Vec<ProseSpan>,
    },
    Code {
        name: String,
        continues: bool,
        spans: Vec<CodeSpan>,
        /// `@index defn` names; unused until the identifier index lands.
        index_defs: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub id: String,
    pub file: String,
    pub line: u32,
    pub kind: SectionKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChunkInfo {
    /// Section ids in source order; `len() > 1` means the chunk is continued.
    pub defs: Vec<String>,
    pub uses: Vec<String>,
    pub root: bool,
}

#[derive(Debug, Default)]
pub struct DocModel {
    pub files: Vec<String>,
    pub sections: Vec<Section>,
    pub chunks: BTreeMap<String, ChunkInfo>,
}

/// A chunk name noweb would tangle to a file: path-shaped, or bare with an
/// extension. Chunk names are free text, so anything containing whitespace is
/// prose-like and never a root.
fn is_root_name(name: &str) -> bool {
    if name.is_empty() || name.chars().any(char::is_whitespace) {
        return false;
    }
    if name.contains('/') {
        return true;
    }
    match name.rsplit_once('.') {
        Some((stem, ext)) => {
            !stem.is_empty() && !ext.is_empty() && ext.chars().all(|c| c.is_ascii_alphanumeric())
        }
        None => false,
    }
}

fn is_blank_docs(spans: &[ProseSpan]) -> bool {
    spans.iter().all(|s| match s {
        ProseSpan::Nl => true,
        ProseSpan::Text(t) => t.trim().is_empty(),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UndefinedChunk {
    pub name: String,
    pub file: String,
    pub line: u32,
}

#[derive(Debug)]
pub enum ModelError {
    /// E010 — one entry per offending use site.
    UndefinedChunks(Vec<UndefinedChunk>),
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let ModelError::UndefinedChunks(uses) = self;
        for (i, u) in uses.iter().enumerate() {
            if i > 0 {
                writeln!(f)?;
            }
            write!(
                f,
                "error[E010]: use of undefined chunk `{}`\n  --> {}:{}",
                u.name, u.file, u.line
            )?;
        }
        Ok(())
    }
}

impl std::error::Error for ModelError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lint {
    pub code: &'static str,
    pub message: String,
    pub file: String,
    pub line: u32,
}

impl fmt::Display for Lint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "warning[{}]: {}\n  --> {}:{}",
            self.code, self.message, self.file, self.line
        )
    }
}

/// Where a `@use` appeared, kept during the walk so E010 can be located.
struct UseSite {
    name: String,
    file: String,
    line: u32,
}

#[derive(Default)]
struct Builder {
    files: Vec<String>,
    sections: Vec<Section>,
    chunks: BTreeMap<String, ChunkInfo>,
    use_sites: Vec<UseSite>,

    file: String,
    line: u32,
    open: Option<Open>,
    /// The `Nl` right after `@defn` terminates the definition line, not the body.
    pending_defn_nl: bool,
}

struct Open {
    id: String,
    file: String,
    line: u32,
    code: bool,
    name: String,
    continues: bool,
    prose: Vec<ProseSpan>,
    code_spans: Vec<CodeSpan>,
    index_defs: Vec<String>,
}

impl Builder {
    fn begin(&mut self, n: u32, code: bool) {
        self.open = Some(Open {
            id: format!("sec-{n}"),
            file: self.file.clone(),
            line: self.line,
            code,
            name: String::new(),
            continues: false,
            prose: Vec::new(),
            code_spans: Vec::new(),
            index_defs: Vec::new(),
        });
    }

    fn finish(&mut self) {
        let Some(open) = self.open.take() else {
            return;
        };
        let kind = if open.code {
            let entry = self.chunks.entry(open.name.clone()).or_default();
            entry.root = is_root_name(&open.name);
            entry.defs.push(open.id.clone());
            SectionKind::Code {
                name: open.name,
                continues: open.continues,
                spans: open.code_spans,
                index_defs: open.index_defs,
            }
        } else {
            // Blank lines between chunks arrive as empty docs chunks; drop them.
            if is_blank_docs(&open.prose) {
                return;
            }
            SectionKind::Docs { spans: open.prose }
        };
        self.sections.push(Section {
            id: open.id,
            file: open.file,
            line: open.line,
            kind,
        });
    }

    fn text(&mut self, t: &str) {
        let Some(open) = self.open.as_mut() else {
            return;
        };
        if open.code {
            open.code_spans.push(CodeSpan::Text(t.to_string()));
        } else {
            open.prose.push(ProseSpan::Text(t.to_string()));
        }
    }

    fn newline(&mut self) {
        self.line += 1;
        if self.pending_defn_nl {
            self.pending_defn_nl = false;
            return;
        }
        let Some(open) = self.open.as_mut() else {
            return;
        };
        if open.code {
            open.code_spans.push(CodeSpan::Nl);
        } else {
            open.prose.push(ProseSpan::Nl);
        }
    }
}

pub fn build(events: &[Event]) -> Result<DocModel, ModelError> {
    let mut b = Builder::default();

    for event in events {
        match event {
            Event::File(f) => {
                b.finish();
                if b.files.last().map(String::as_str) != Some(f.as_str()) {
                    b.files.push(f.clone());
                }
                b.file = f.clone();
                b.line = 1;
            }
            Event::BeginDocs(n) => b.begin(*n, false),
            Event::BeginCode(n) => b.begin(*n, true),
            Event::EndDocs(_) | Event::EndCode(_) => b.finish(),

            Event::Text(t) => b.text(t),
            Event::Nl => b.newline(),

            Event::Defn(name) => {
                b.pending_defn_nl = true;
                // Continuation means *already defined*. A forward `@use` creates
                // the map entry first, so key-existence is not the question.
                let seen = b
                    .chunks
                    .get(name.as_str())
                    .is_some_and(|c| !c.defs.is_empty());
                if let Some(open) = b.open.as_mut() {
                    open.name = name.clone();
                    open.continues = seen;
                }
            }
            Event::Use(name) => {
                let (id, file, line) = match b.open.as_ref() {
                    Some(open) => (open.id.clone(), open.file.clone(), open.line),
                    None => continue,
                };
                if let Some(open) = b.open.as_mut() {
                    open.code_spans.push(CodeSpan::Use { name: name.clone() });
                }
                b.chunks.entry(name.clone()).or_default().uses.push(id);
                b.use_sites.push(UseSite {
                    name: name.clone(),
                    file,
                    line,
                });
            }

            Event::IndexDefn(name) => {
                if let Some(open) = b.open.as_mut() {
                    open.index_defs.push(name.clone());
                }
            }
            Event::IndexNl => b.line += 1,

            // Parsed and preserved, but not part of the model. `@quote`/`@endquote`
            // are noweb IR the native reader never emits (§6.4 uses `\code{…}`); the
            // parser still accepts them, so ignore them here.
            Event::Quote
            | Event::EndQuote
            | Event::IndexUse(_)
            | Event::Line(_)
            | Event::Literal(_)
            | Event::Fatal(_)
            | Event::Other { .. } => {}
        }
    }
    b.finish();

    let undefined: Vec<UndefinedChunk> = b
        .use_sites
        .iter()
        .filter(|u| {
            b.chunks
                .get(&u.name)
                .map(|c| c.defs.is_empty())
                .unwrap_or(true)
        })
        .map(|u| UndefinedChunk {
            name: u.name.clone(),
            file: u.file.clone(),
            line: u.line,
        })
        .collect();
    if !undefined.is_empty() {
        return Err(ModelError::UndefinedChunks(undefined));
    }

    Ok(DocModel {
        files: b.files,
        sections: b.sections,
        chunks: b.chunks,
    })
}

impl DocModel {
    /// W102: a non-root chunk that nothing uses is dead code.
    pub fn lints(&self) -> Vec<Lint> {
        let mut lints = Vec::new();
        for (name, info) in &self.chunks {
            if info.root || !info.uses.is_empty() {
                continue;
            }
            let (file, line) = info
                .defs
                .first()
                .and_then(|id| self.sections.iter().find(|s| &s.id == id))
                .map(|s| (s.file.clone(), s.line))
                .unwrap_or_default();
            lints.push(Lint {
                code: "W102",
                message: format!("chunk `{name}` is defined but never used"),
                file,
                line,
            });
        }
        lints
    }

    pub fn roots(&self) -> Vec<&str> {
        self.chunks
            .iter()
            .filter(|(_, c)| c.root)
            .map(|(n, _)| n.as_str())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::noweb::parse;

    const HELLO: &str = include_str!("../fixtures/hello.markup");

    fn hello() -> DocModel {
        build(&parse(HELLO).expect("fixture parses")).expect("fixture folds")
    }

    #[test]
    fn blank_docs_chunks_are_dropped() {
        let m = hello();
        let docs: Vec<&Section> = m
            .sections
            .iter()
            .filter(|s| matches!(s.kind, SectionKind::Docs { .. }))
            .collect();
        // markup emits 7 docs chunks; only 4 carry prose (incl. a leading empty
        // `docs 0` and the blank lines between chunks).
        assert_eq!(
            docs.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            vec!["sec-1", "sec-4", "sec-7", "sec-10"]
        );
    }

    #[test]
    fn code_sections_and_continuation() {
        let m = hello();
        let code: Vec<(&str, &str, bool)> = m
            .sections
            .iter()
            .filter_map(|s| match &s.kind {
                SectionKind::Code {
                    name, continues, ..
                } => Some((s.id.as_str(), name.as_str(), *continues)),
                _ => None,
            })
            .collect();
        assert_eq!(
            code,
            vec![
                ("sec-2", "lex a token", false),
                ("sec-5", "lex a token", true),
                ("sec-8", "next char", false),
                ("sec-11", "src/main.rs", false),
            ]
        );
        assert_eq!(m.chunks["lex a token"].defs, vec!["sec-2", "sec-5"]);
    }

    #[test]
    fn line_numbers_track_indexnl() {
        let m = hello();
        let at = |id: &str| m.sections.iter().find(|s| s.id == id).unwrap().line;
        // Definition lines in fixtures/hello.cob.
        assert_eq!(at("sec-1"), 1);
        assert_eq!(at("sec-2"), 6);
        // sec-4 lands on 11 only if `@ %def c`'s IndexNl advanced the counter.
        assert_eq!(at("sec-4"), 11);
        assert_eq!(at("sec-5"), 15);
        assert_eq!(at("sec-8"), 22);
        assert_eq!(at("sec-11"), 28);
        assert!(m.sections.iter().all(|s| s.file == "fixtures/hello.cob"));
    }

    #[test]
    fn defn_newline_is_not_body() {
        let m = hello();
        let SectionKind::Code { spans, .. } =
            &m.sections.iter().find(|s| s.id == "sec-8").unwrap().kind
        else {
            unreachable!()
        };
        assert_eq!(
            spans,
            &vec![
                CodeSpan::Text("input.next().unwrap()".to_string()),
                CodeSpan::Nl
            ]
        );
    }

    #[test]
    fn indentation_before_use_is_its_own_span() {
        let m = hello();
        let SectionKind::Code { spans, .. } =
            &m.sections.iter().find(|s| s.id == "sec-11").unwrap().kind
        else {
            unreachable!()
        };
        let i = spans
            .iter()
            .position(|s| matches!(s, CodeSpan::Use { .. }))
            .unwrap();
        // noweb propagates indentation by emitting it as text before the use.
        assert_eq!(spans[i - 1], CodeSpan::Text("    ".to_string()));
        assert_eq!(
            spans[i],
            CodeSpan::Use {
                name: "lex a token".to_string()
            }
        );
    }

    #[test]
    fn uses_and_roots() {
        let m = hello();
        assert_eq!(m.chunks["next char"].uses, vec!["sec-2"]);
        assert_eq!(m.chunks["lex a token"].uses, vec!["sec-11"]);
        assert!(m.chunks["src/main.rs"].uses.is_empty());
        assert_eq!(m.roots(), vec!["src/main.rs"]);
        assert!(m.lints().is_empty(), "fixture should be lint-clean");
    }

    #[test]
    fn undefined_chunk_is_e010() {
        let ir = "@file t.cob\n@begin code 0\n@defn r.rs\n@nl\n@use missing\n@nl\n@end code 0\n";
        let err = build(&parse(ir).unwrap()).unwrap_err();
        let ModelError::UndefinedChunks(u) = &err;
        assert_eq!(u[0].name, "missing");
        assert_eq!((u[0].file.as_str(), u[0].line), ("t.cob", 1));
        assert!(err.to_string().starts_with("error[E010]"));
    }

    #[test]
    fn unused_nonroot_chunk_is_w102() {
        let ir = "@file t.cob\n@begin code 0\n@defn orphan\n@nl\n@text x\n@nl\n@end code 0\n";
        let lints = build(&parse(ir).unwrap()).unwrap().lints();
        assert_eq!(lints.len(), 1);
        assert_eq!(lints[0].code, "W102");
        assert!(lints[0].to_string().starts_with("warning[W102]"));
    }

    #[test]
    fn root_names() {
        assert!(is_root_name("src/main.rs"));
        assert!(is_root_name("Makefile.in"));
        assert!(!is_root_name("lex a token"));
        assert!(!is_root_name("next char"));
        assert!(!is_root_name("Makefile"));
    }
}
