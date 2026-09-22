//! Source-side section anchors (§7.1). `cob lock` gives every unlabelled `h2`/`h3`
//! heading a frozen opaque id by writing a `sec:` anchor into the `.cob` source, so
//! the id lives on the heading line and survives a reword of the heading text. This
//! module finds a heading's source line, writes the Markdown anchor, and renames
//! it when the author gives the id a human name. It edits only the heading line;
//! every other byte of the source is left as it is.

use std::io;
use std::path::Path;

use crate::model::{DocModel, ProseSpan, SectionKind};

/// A heading found in a docs chunk, with the `.cob` line that carries it. `anchored`
/// is true when the heading already has an id (an author `sec:` label or a past
/// anchor), so `cob lock` skips it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadingSite {
    pub file: String,
    pub line: u32,
    pub level: u8,
    pub anchored: bool,
}

/// Every heading (levels 1..=3) in document order, each with its `.cob` source line.
/// Walks the model's docs sections; a Markdown code fence hides the lines inside it.
pub fn headings(doc: &DocModel) -> Vec<HeadingSite> {
    let mut out = Vec::new();
    // A ``` fence can span a code chunk, so its state is per file, not per section.
    let mut fenced = false;
    let mut cur_file: Option<&str> = None;
    for sec in &doc.sections {
        if cur_file != Some(sec.file.as_str()) {
            cur_file = Some(sec.file.as_str());
            fenced = false;
        }
        let spans = match &sec.kind {
            SectionKind::Docs { spans } => spans,
            SectionKind::Code { .. } => continue,
        };
        let mut line = sec.line;
        let mut buf = String::new();
        for span in spans {
            match span {
                ProseSpan::Text(s) => buf.push_str(s),
                ProseSpan::Nl => {
                    scan_line(&sec.file, line, &buf, &mut fenced, &mut out);
                    line += 1;
                    buf.clear();
                }
            }
        }
        if !buf.is_empty() {
            scan_line(&sec.file, line, &buf, &mut fenced, &mut out);
        }
    }
    out
}

fn scan_line(file: &str, line: u32, text: &str, fenced: &mut bool, out: &mut Vec<HeadingSite>) {
    if text.trim_start().starts_with("```") {
        *fenced = !*fenced;
        return;
    }
    if *fenced {
        return;
    }
    if let Some((level, anchored)) = md_heading(text) {
        out.push(HeadingSite {
            file: file.to_string(),
            line,
            level,
            anchored,
        });
    }
}

/// A Markdown ATX heading (`#`..`###` then a space) → its level and whether it
/// already carries a `{#…}` id.
fn md_heading(text: &str) -> Option<(u8, bool)> {
    // CommonMark allows up to three leading spaces before the hashes.
    let t = text.trim_start_matches(' ');
    let hashes = t.bytes().take_while(|&b| b == b'#').count();
    if hashes == 0 || hashes > 3 {
        return None;
    }
    let rest = &t[hashes..];
    if !rest.starts_with(' ') {
        return None;
    }
    let trimmed = rest.trim_end();
    let anchored = trimmed.ends_with('}') && trimmed.contains("{#");
    Some((hashes as u8, anchored))
}

/// Write a `sec:<id>` anchor into the heading on each `(line, id)` of `path`. Edits
/// only those lines; every other byte is preserved. An empty edit list writes
/// nothing.
pub fn apply_anchors(path: &Path, edits: &[(u32, String)]) -> io::Result<()> {
    if edits.is_empty() {
        return Ok(());
    }
    let content = std::fs::read_to_string(path)?;
    let mut lines: Vec<String> = content.split_inclusive('\n').map(str::to_string).collect();
    for (line, id) in edits {
        let idx = (*line as usize) - 1;
        let (body, nl) = split_nl(&lines[idx]);
        lines[idx] = format!("{} {{#sec:{id}}}{nl}", body.trim_end());
    }
    std::fs::write(path, lines.concat())
}

/// Split a stored line into its body and its trailing newline (empty at EOF).
fn split_nl(line: &str) -> (&str, &str) {
    match line.strip_suffix('\n') {
        Some(body) => (body, "\n"),
        None => (line, ""),
    }
}

/// Rewrite a heading anchor in `path` from `sec:<old>` to `sec:<new>`. `old`/`new`
/// are the bare names after `sec:`. Returns whether it changed a byte, so the caller
/// can report a missing anchor.
pub fn rename_anchor(path: &Path, old: &str, new: &str) -> io::Result<bool> {
    let content = std::fs::read_to_string(path)?;
    let (from, to) = (format!("{{#sec:{old}}}"), format!("{{#sec:{new}}}"));
    if !content.contains(&from) {
        return Ok(false);
    }
    std::fs::write(path, content.replace(&from, &to))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{DocModel, ProseSpan, Section, SectionKind};

    fn docs(file: &str, line: u32, body: &str) -> Section {
        let mut spans = Vec::new();
        let mut first = true;
        for l in body.split('\n') {
            if !first {
                spans.push(ProseSpan::Nl);
            }
            first = false;
            spans.push(ProseSpan::Text(l.to_string()));
        }
        Section {
            id: String::new(),
            file: file.to_string(),
            line,
            kind: SectionKind::Docs { spans },
        }
    }

    fn model(sections: Vec<Section>) -> DocModel {
        DocModel {
            sections,
            ..Default::default()
        }
    }

    #[test]
    fn finds_markdown_headings_with_source_lines() {
        let doc = model(vec![docs(
            "a.cob",
            1,
            "# Title\n\n## Lexing\n\nprose\n\n### Cost {#sec:cost}",
        )]);
        let hs = headings(&doc);
        assert_eq!(
            hs,
            vec![
                HeadingSite { file: "a.cob".into(), line: 1, level: 1, anchored: false },
                HeadingSite { file: "a.cob".into(), line: 3, level: 2, anchored: false },
                HeadingSite { file: "a.cob".into(), line: 7, level: 3, anchored: true },
            ]
        );
    }

    #[test]
    fn a_hash_inside_a_fence_is_not_a_heading() {
        let doc = model(vec![docs(
            "a.cob",
            1,
            "## Real\n\n```\n## not a heading\n```\n\n## Also real",
        )]);
        let hs = headings(&doc);
        let lines: Vec<u32> = hs.iter().map(|h| h.line).collect();
        assert_eq!(lines, vec![1, 7], "the fenced `##` is skipped");
    }

    #[test]
    fn writes_a_markdown_anchor_on_the_named_line() {
        let dir = std::env::temp_dir().join(format!("cob-sec-md-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.cob");
        std::fs::write(&path, "@ # Title\n\n## Lexing\nprose\n").unwrap();
        apply_anchors(&path, &[(3, "k3f9".into())]).unwrap();
        let got = std::fs::read_to_string(&path).unwrap();
        assert_eq!(got, "@ # Title\n\n## Lexing {#sec:k3f9}\nprose\n");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn renames_a_named_anchor_and_reports_a_miss() {
        let dir = std::env::temp_dir().join(format!("cob-sec-rn-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.cob");
        std::fs::write(&path, "## Lexing {#sec:k3f9}\n").unwrap();
        assert!(rename_anchor(&path, "k3f9", "lexing").unwrap());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "## Lexing {#sec:lexing}\n"
        );
        // A name that is not present changes nothing and reports the miss.
        assert!(!rename_anchor(&path, "absent", "x").unwrap());
        std::fs::remove_dir_all(&dir).ok();
    }
}
