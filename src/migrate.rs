//! `cob migrate` (§4.3): rewrite a `.cob` file from noweb's chunk syntax to the
//! fence syntax. Every code byte, chunk use, and escape stays as it was.

use std::fmt;

/// The converted text, and how many code chunks it holds.
#[derive(Debug, PartialEq)]
pub struct Migrated {
    pub text: String,
    pub chunks: usize,
}

/// A file the tool refuses to convert (E044).
#[derive(Debug, PartialEq)]
pub struct MigrateError {
    pub line: usize,
    pub reason: &'static str,
}

impl fmt::Display for MigrateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.line, self.reason)
    }
}

/// A code chunk that is open: its name and the body lines read so far.
struct Pending {
    name: String,
    body: Vec<String>,
}

enum Kind<'a> {
    Def(&'a str),
    At(&'a str),
    Plain,
}

/// The characters that end a def line, with the escape written out.
const DEF_END: &str = ">>=";

fn classify(line: &str) -> Kind<'_> {
    if let Some(rest) = line.strip_prefix("<<") {
        if let Some(end) = rest.find(DEF_END) {
            let tail = &rest[end + DEF_END.len()..];
            if tail.chars().all(|c| c == ' ' || c == '\t') {
                return Kind::Def(&rest[..end]);
            }
        }
        return Kind::Plain;
    }
    if line == "@" {
        return Kind::At("");
    }
    if let Some(rest) = line.strip_prefix("@ ").or_else(|| line.strip_prefix("@\t")) {
        return Kind::At(rest);
    }
    Kind::Plain
}

/// True for the text of an index line: `%def` or `%use`, alone or with names.
fn is_index(text: &str) -> bool {
    ["%def", "%use"]
        .iter()
        .any(|k| text == *k || text.strip_prefix(*k).is_some_and(|r| r.starts_with(' ')))
}

/// True when the new reader would read this documentation line as a fence open.
fn would_open_a_fence_chunk(line: &str) -> bool {
    let ticks = line.chars().take_while(|c| *c == '`').count();
    if ticks < 4 {
        return false;
    }
    let rest = line[ticks..].trim_start_matches([' ', '\t']);
    rest.strip_prefix("chunk")
        .is_some_and(|r| r.starts_with([' ', '\t']))
}

fn flush(open: &mut Option<Pending>, out: &mut Vec<String>) {
    if let Some(p) = open.take() {
        let widest = p
            .body
            .iter()
            .map(|l| l.chars().take_while(|c| *c == '`').count())
            .max()
            .unwrap_or(0);
        let ticks = "`".repeat(widest.max(3) + 1);
        out.push(format!("{ticks}chunk {}", p.name));
        out.extend(p.body);
        out.push(ticks);
    }
}

/// Convert noweb chunk syntax to fence syntax. Gives back the new text, or the
/// first line the tool refuses.
pub fn convert(text: &str) -> Result<Migrated, MigrateError> {
    let mut out: Vec<String> = Vec::new();
    let mut open: Option<Pending> = None;
    let mut after_index = false;
    let mut chunks = 0;
    for (i, line) in text.lines().enumerate() {
        let no = i + 1;
        let kind = classify(line);
        if let (Some(p), Kind::Plain) = (open.as_mut(), &kind) {
            p.body.push(line.to_string());
            continue;
        }
        match kind {
            Kind::Def(name) => {
                if name.is_empty() || name != name.trim() {
                    return Err(MigrateError {
                        line: no,
                        reason: "a chunk name must not start or end with a space",
                    });
                }
                flush(&mut open, &mut out);
                open = Some(Pending {
                    name: name.to_string(),
                    body: Vec::new(),
                });
                chunks += 1;
                after_index = false;
            }
            Kind::At(t) if is_index(t) => {
                if open.is_none() && !after_index {
                    return Err(MigrateError {
                        line: no,
                        reason: "a %def or %use line is outside a code chunk",
                    });
                }
                flush(&mut open, &mut out);
                after_index = true;
            }
            Kind::At(t) => {
                flush(&mut open, &mut out);
                after_index = false;
                if !t.is_empty() {
                    check_docs(t, no)?;
                    out.push(t.to_string());
                }
            }
            Kind::Plain => {
                after_index = false;
                check_docs(line, no)?;
                out.push(line.to_string());
            }
        }
    }
    flush(&mut open, &mut out);
    let mut text = out.join("\n");
    if !out.is_empty() {
        text.push('\n');
    }
    Ok(Migrated { text, chunks })
}

fn check_docs(line: &str, no: usize) -> Result<(), MigrateError> {
    if would_open_a_fence_chunk(line) {
        return Err(MigrateError {
            line: no,
            reason: "a line of documentation would open a fence chunk",
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conv(s: &str) -> String {
        convert(s).expect("the text converts").text
    }

    #[test]
    fn a_chunk_gets_a_fence_and_the_text_after_its_end_marker_follows() {
        assert_eq!(
            conv("<<a>>=\nx\n@ prose\n"),
            "````chunk a\nx\n````\nprose\n"
        );
    }

    #[test]
    fn a_bare_end_marker_leaves_only_the_fence_close() {
        assert_eq!(conv("<<a>>=\nx\n@\n"), "````chunk a\nx\n````\n");
    }

    #[test]
    fn a_marker_between_two_documentation_chunks_is_dropped() {
        assert_eq!(conv("intro\n@ ## H\nmore\n"), "intro\n## H\nmore\n");
        assert_eq!(conv("a\n@\nb\n"), "a\nb\n");
    }

    #[test]
    fn a_def_after_a_chunk_ends_that_chunk() {
        assert_eq!(
            conv("<<a>>=\nx\n<<b>>=\ny\n@\n"),
            "````chunk a\nx\n````\n````chunk b\ny\n````\n"
        );
    }

    #[test]
    fn an_index_line_ends_the_chunk_and_is_dropped() {
        assert_eq!(
            conv("<<a>>=\nx\n@ %def x\n\nprose\n"),
            "````chunk a\nx\n````\n\nprose\n"
        );
    }

    #[test]
    fn a_body_line_of_backticks_widens_the_fence() {
        assert_eq!(
            conv("<<a>>=\n````\n@\n"),
            "`````chunk a\n````\n`````\n"
        );
    }

    #[test]
    fn the_end_of_the_file_ends_the_chunk() {
        assert_eq!(conv("<<a>>=\nx\n"), "````chunk a\nx\n````\n");
    }

    #[test]
    fn chunk_uses_and_escapes_pass_through() {
        assert_eq!(
            conv("<<a>>=\n    <<b>>\nx @<<y\n@\n"),
            "````chunk a\n    <<b>>\nx @<<y\n````\n"
        );
    }

    #[test]
    fn a_chunk_count_is_reported() {
        let m = convert("<<a>>=\nx\n@\n<<b>>=\ny\n@\n").expect("converts");
        assert_eq!(m.chunks, 2);
    }

    #[test]
    fn a_name_with_a_space_is_refused() {
        let e = convert("prose\n<< a>>=\n").unwrap_err();
        assert_eq!(e.line, 2);
    }

    #[test]
    fn an_index_line_outside_a_chunk_is_refused() {
        let e = convert("prose\n@ %def x\n").unwrap_err();
        assert_eq!(e.line, 2);
    }

    #[test]
    fn a_documentation_line_that_would_open_a_fence_chunk_is_refused() {
        let e = convert("a\n````chunk x\n").unwrap_err();
        assert_eq!(e.line, 2);
        assert!(convert("a\n```verbatim\n").is_ok());
    }
}
