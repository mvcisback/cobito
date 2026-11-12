//! The native `.cob` reader (§4.1). Makes the `Event` stream the rest of cob
//! reads, so cob reads its own source with no external process and can ship
//! as one binary (§11). The chunk syntax is cob's own (§4.2).

use std::fmt;
use std::path::Path;

use crate::noweb::Event;

#[derive(Debug)]
pub enum ReadError {
    Io {
        path: String,
        source: std::io::Error,
    },
    Retired {
        path: String,
        line: usize,
    },
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReadError::Io { path, source } => {
                write!(f, "error[E034]: could not read {path}: {source}")
            }
            ReadError::Retired { path, line } => write!(
                f,
                "error[E043]: {path}:{line}: noweb chunk syntax is retired; run `cob migrate {path}`"
            ),
        }
    }
}

impl std::error::Error for ReadError {}

enum Seg {
    Text(String),
    Use(String),
}

enum Line {
    ChunkOpen(usize, String),
    Fence(usize),
    Plain(String),
}

peg::parser! {
    grammar nw() for str {
        pub rule classify() -> Line
            = o:chunk_open_line() { o }
            / f:fence_line() { f }
            / p:$([_]*) { Line::Plain(p.to_string()) }

        // Four or more backticks, "chunk", the name (§sec:fence-chunks).
        rule chunk_open_line() -> Line
            = n:$("`" "`" "`" "`" "`"*) [' ' | '\t']* "chunk" [' ' | '\t']+
              name:$([_]*) ![_] {
                Line::ChunkOpen(n.len(), name.trim_end().to_string())
            }

        // A candidate close: three or more backticks, nothing else. Whether it
        // closes anything depends on the open chunk's own length (§sec:read-code).
        rule fence_line() -> Line
            = n:$("`" "`" "`" "`"*) [' ' | '\t']* ![_] { Line::Fence(n.len()) }

        pub rule code_line() -> Vec<Seg>
            = run:code_run() rest:code_after()* {
                let mut v = vec![Seg::Text(run)];
                for r in rest {
                    v.extend(r);
                }
                v
            }

        rule code_after() -> Vec<Seg>
            = u:use_tok() run:code_run() { vec![Seg::Use(u), Seg::Text(run)] }
            / lone:$("<<") run:code_run() { vec![Seg::Text(format!("{lone}{run}"))] }

        rule use_tok() -> String
            = "<<" n:$((!">>" [_])*) ">>" { n.to_string() }

        rule code_run() -> String = s:$(code_ch()*) { resolve_esc(s) }
        rule code_ch() = escape() / (!"<<" [_] {})

        // A documentation line is one text run. `[[` carries no special meaning
        // (§6.4 uses `\code{…}` for inline code); only the `@<<`/`@>>` escapes
        // are resolved.
        pub rule docs_line() -> String = s:$(docs_ch()*) { resolve_esc(s) }
        rule docs_ch() = escape() / [_]

        rule escape() = "@<<" / "@>>"
    }
}

fn resolve_esc(s: &str) -> String {
    if s.as_bytes().contains(&b'@') {
        s.replace("@<<", "<<").replace("@>>", ">>")
    } else {
        s.to_string()
    }
}

/// Read each `.cob` file and make the event stream (§4.1).
///
/// Paths should be relative to the project root so `@file` events are portable.
pub fn read<S: AsRef<Path>>(files: &[S]) -> Result<Vec<Event>, ReadError> {
    let mut reader = Reader::default();
    for file in files {
        let path = file.as_ref();
        let text = std::fs::read_to_string(path).map_err(|source| ReadError::Io {
            path: path.display().to_string(),
            source,
        })?;
        reader.file(&path.display().to_string(), &text);
    }
    match reader.retired {
        Some((path, line)) => Err(ReadError::Retired { path, line }),
        None => Ok(reader.out),
    }
}

/// Read one in-memory buffer into events, naming it `name` so `@file` events match
/// (§5.5, #2): the path an editor would save to. The LSP path — it has the unsaved
/// buffer text, so it never touches disk — where `read` reads files. It never
/// reports E043: an editor shows an old-syntax buffer as prose until it is migrated.
pub fn read_str(name: &str, text: &str) -> Vec<Event> {
    let mut reader = Reader::default();
    reader.file(name, text);
    reader.out
}

#[derive(Default)]
struct Reader {
    out: Vec<Event>,
    counter: u32,
    open: Option<bool>,
    cur: u32,
    fence_len: Option<usize>,
    md_fence: Option<(char, usize)>,
    docs_has_text: bool,
    path: String,
    lineno: usize,
    retired: Option<(String, usize)>,
}

impl Reader {
    fn open_docs(&mut self) {
        let n = self.counter;
        self.counter += 1;
        self.cur = n;
        self.open = Some(false);
        self.docs_has_text = false;
        self.md_fence = None;
        self.out.push(Event::BeginDocs(n));
    }

    fn open_code(&mut self) {
        let n = self.counter;
        self.counter += 1;
        self.cur = n;
        self.open = Some(true);
        self.out.push(Event::BeginCode(n));
    }

    fn close_current(&mut self) {
        self.fence_len = None;
        if let Some(code) = self.open.take() {
            let n = self.cur;
            self.out.push(if code {
                Event::EndCode(n)
            } else {
                Event::EndDocs(n)
            });
        }
    }

    fn emit_segs(&mut self, segs: Vec<Seg>) {
        let n = segs.len();
        for (i, seg) in segs.into_iter().enumerate() {
            let last = i + 1 == n;
            match seg {
                Seg::Text(s) => {
                    if last || !s.is_empty() {
                        self.out.push(Event::Text(s));
                    }
                }
                Seg::Use(u) => self.out.push(Event::Use(u)),
            }
        }
        self.out.push(Event::Nl);
    }

    fn code_emit(&mut self, l: &str) {
        let segs = nw::code_line(l).expect("a code line tokenizes");
        self.emit_segs(segs);
    }

    fn docs_emit(&mut self, l: &str) {
        // A docs line is one text run (no uses, no quotes). Keep the last run even
        // when empty, so the empty-text rule of §sec:read-rules holds.
        let run = nw::docs_line(l).expect("a docs line tokenizes");
        self.out.push(Event::Text(run));
        self.out.push(Event::Nl);
    }

    fn line(&mut self, l: &str) {
        self.lineno += 1;
        if self.open == Some(false) && self.md_fence.is_some() {
            self.docs_line(l);
            return;
        }
        match nw::classify(l).expect("every line classifies") {
            Line::ChunkOpen(len, name) => {
                self.close_current();
                self.open_code();
                self.fence_len = Some(len);
                self.out.push(Event::Defn(name));
                self.out.push(Event::Nl);
            }
            Line::Fence(len) => {
                if matches!(self.fence_len, Some(req) if len >= req) {
                    self.close_current();
                    self.open_docs();
                    // The close line still counts as one line (§sec:read-rules).
                    self.docs_emit("");
                } else {
                    self.plain(l);
                }
            }
            Line::Plain(l) => self.plain(&l),
        }
    }

    fn plain(&mut self, l: &str) {
        if self.open == Some(true) {
            self.code_emit(l);
        } else {
            self.docs_line(l);
        }
    }

    fn docs_line(&mut self, l: &str) {
        match self.md_fence {
            Some(fence) => {
                if closes_md_fence(l, fence) {
                    self.md_fence = None;
                }
            }
            None => {
                if is_retired(l) && self.retired.is_none() {
                    self.retired = Some((self.path.clone(), self.lineno));
                }
                if is_h1(l) && self.docs_has_text {
                    self.close_current();
                    self.open_docs();
                }
                self.md_fence = opens_md_fence(l);
            }
        }
        self.docs_emit(l);
        if !l.trim().is_empty() {
            self.docs_has_text = true;
        }
    }

    fn file(&mut self, path: &str, text: &str) {
        self.path = path.to_string();
        self.lineno = 0;
        self.out.push(Event::File(path.to_string()));
        self.open_docs();
        for line in text.lines() {
            self.line(line);
        }
        self.close_current();
    }
}

fn is_h1(l: &str) -> bool {
    l == "#" || l.starts_with("# ") || l.starts_with("#\t")
}

fn opens_md_fence(l: &str) -> Option<(char, usize)> {
    let body = l.trim_start_matches(' ');
    if l.len() - body.len() > 3 {
        return None;
    }
    let c = body.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let n = body.chars().take_while(|x| *x == c).count();
    if n < 3 || (c == '`' && body[n..].contains('`')) {
        return None;
    }
    Some((c, n))
}

fn closes_md_fence(l: &str, (c, n): (char, usize)) -> bool {
    let body = l.trim_start_matches(' ');
    if l.len() - body.len() > 3 {
        return false;
    }
    let run = body.chars().take_while(|x| *x == c).count();
    run >= n && body[run..].trim().is_empty()
}

fn is_retired(l: &str) -> bool {
    if l == "@" || l.starts_with("@ ") || l.starts_with("@\t") {
        return true;
    }
    let def_end = ">>=";
    match l.strip_prefix("<<") {
        Some(rest) => rest.find(def_end).is_some_and(|end| {
            rest[end + def_end.len()..]
                .chars()
                .all(|c| c == ' ' || c == '\t')
        }),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::noweb::parse;

    fn signature(events: &[Event]) -> (Vec<Event>, Vec<String>) {
        let mut code = Vec::new();
        let mut prose = Vec::new();
        let mut in_code = false;
        let mut in_docs = false;
        for e in events {
            match e {
                Event::BeginCode(_) => {
                    in_code = true;
                    code.push(Event::BeginCode(0));
                }
                Event::EndCode(_) => {
                    in_code = false;
                    code.push(Event::EndCode(0));
                }
                Event::BeginDocs(_) => in_docs = true,
                Event::EndDocs(_) => in_docs = false,
                Event::File(_) => code.push(e.clone()),
                Event::Text(t) if in_docs => {
                    if !t.is_empty() {
                        prose.push(t.clone());
                    }
                }
                Event::IndexDefn(_) | Event::IndexUse(_) | Event::IndexNl => {}
                other if in_code => code.push(other.clone()),
                _ => {}
            }
        }
        (code, prose)
    }

    fn same_as_oracle(nw: &str, markup: &str) {
        let ours = signature(&read(&[nw]).expect("reader reads the fixture"));
        let oracle = signature(&parse(markup).expect("oracle markup parses"));
        assert_eq!(ours.0, oracle.0, "code chunks diverged from markup for {nw}");
        assert_eq!(ours.1, oracle.1, "prose diverged from markup for {nw}");
    }

    #[test]
    fn matches_markup_for_hello() {
        same_as_oracle(
            "fixtures/hello.cob",
            include_str!("../fixtures/hello.markup"),
        );
    }

    #[test]
    fn matches_markup_for_book() {
        same_as_oracle("fixtures/book.cob", include_str!("../fixtures/book.markup"));
    }

    #[test]
    fn matches_markup_for_md() {
        same_as_oracle("fixtures/md.cob", include_str!("../fixtures/md.markup"));
    }

    #[test]
    fn matches_markup_for_hl() {
        same_as_oracle("fixtures/hl.cob", include_str!("../fixtures/hl.markup"));
    }

    #[test]
    fn matches_markup_for_sections() {
        same_as_oracle(
            "fixtures/sections.cob",
            include_str!("../fixtures/sections.markup"),
        );
    }

    #[test]
    fn matches_markup_for_tx() {
        same_as_oracle("fixtures/tx.cob", include_str!("../fixtures/tx.markup"));
    }

    #[test]
    fn matches_markup_for_txf() {
        same_as_oracle("fixtures/txf.cob", include_str!("../fixtures/txf.markup"));
    }

    fn texts(events: &[Event]) -> Vec<&str> {
        events
            .iter()
            .filter_map(|e| match e {
                Event::Text(t) => Some(t.as_str()),
                _ => None,
            })
            .collect()
    }

    fn count(events: &[Event], want: fn(&Event) -> bool) -> usize {
        events.iter().filter(|e| want(e)).count()
    }

    fn read_text(tag: &str, text: &str) -> Result<Vec<Event>, ReadError> {
        let dir = std::env::temp_dir().join(format!("cob-read-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.cob");
        std::fs::write(&path, text).unwrap();
        let got = read(&[&path]);
        std::fs::remove_dir_all(&dir).ok();
        got
    }

    #[test]
    fn a_fence_chunk_makes_the_chunk_events() {
        let got = read_str("f", "````chunk a\nx\n````\nmore\n");
        let t = |s: &str| Event::Text(s.to_string());
        assert_eq!(
            got,
            vec![
                Event::File("f".into()),
                Event::BeginDocs(0),
                Event::EndDocs(0),
                Event::BeginCode(1),
                Event::Defn("a".into()),
                Event::Nl,
                t("x"),
                Event::Nl,
                Event::EndCode(1),
                Event::BeginDocs(2),
                t(""),
                Event::Nl,
                t("more"),
                Event::Nl,
                Event::EndDocs(2),
            ]
        );
    }

    #[test]
    fn a_close_must_reach_the_opening_length() {
        // Opened with five backticks: a run of four stays in the body.
        let got = read_str("f", "`````chunk a\nx\n````\ny\n`````\n");
        assert_eq!(count(&got, |e| matches!(e, Event::EndCode(_))), 1);
        assert_eq!(texts(&got), vec!["x", "````", "y", ""]);
    }

    #[test]
    fn a_three_backtick_fence_never_opens_a_chunk() {
        let got = read_str("f", "prose\n```\nmore\n```\nend\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginCode(_))), 0);
    }

    #[test]
    fn a_use_and_an_escape_in_a_body() {
        let got = read_str("f", "````chunk a\nlet x = <<b>>; @<<y\n````\n");
        assert!(got.contains(&Event::Use("b".into())));
        assert!(got.contains(&Event::Text("; <<y".into())));
    }

    #[test]
    fn an_h1_starts_a_new_documentation_chunk() {
        let got = read_str("f", "intro\n# A\nmore\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 2);
        assert_eq!(texts(&got), vec!["intro", "# A", "more"]);
    }

    #[test]
    fn an_h1_at_the_start_of_a_chunk_does_not_split() {
        let got = read_str("f", "# T\ntext\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 1);
        let got = read_str("f", "````chunk a\nx\n````\n# T\ntext\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 2);
    }

    #[test]
    fn an_h2_does_not_split() {
        let got = read_str("f", "intro\n## A\nmore\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 1);
    }

    #[test]
    fn a_hash_line_in_a_fenced_block_is_not_a_heading() {
        let got = read_str("f", "intro\n```bash\n# comment\n```\n# B\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 2);
        assert_eq!(texts(&got), vec!["intro", "```bash", "# comment", "```", "# B"]);
    }

    #[test]
    fn a_tilde_fence_and_a_longer_fence_hold_their_lines() {
        let got = read_str("f", "a\n~~~\n# x\n~~~\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 1);
        // A four-backtick line cannot close a five-backtick block, so the chunk
        // open line inside it is text.
        let got = read_str("f", "`````verbatim\n````chunk x\n# y\n`````\n");
        assert_eq!(count(&got, |e| matches!(e, Event::BeginCode(_))), 0);
        assert_eq!(count(&got, |e| matches!(e, Event::BeginDocs(_))), 1);
    }

    #[test]
    fn noweb_syntax_is_error_e043() {
        let e = read_text("def", "prose\n<<a>>=\nx\n@\n").unwrap_err();
        assert!(matches!(e, ReadError::Retired { line: 2, .. }));
        assert!(e.to_string().contains("E043"));
        let e = read_text("at", "@ # Title\n").unwrap_err();
        assert!(matches!(e, ReadError::Retired { line: 1, .. }));
    }

    #[test]
    fn an_at_line_in_a_fence_chunk_or_a_fenced_block_is_not_retired() {
        assert!(read_text("body", "````chunk a\n@ x\n````\n").is_ok());
        assert!(read_text("block", "```\n@ x\n```\n").is_ok());
    }
}
