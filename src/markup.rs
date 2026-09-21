//! The native `.cob` reader (§4.1). Makes the same `Event` stream as noweb's
//! `markup`, so cob reads its own source with no external process and can ship
//! as one binary (§11). A differential test proves the events match real
//! `markup` for every module; `noweb::parse` stays as the oracle's decoder.

use std::fmt;
use std::path::Path;

use crate::noweb::Event;

#[derive(Debug)]
pub struct ReadError {
    pub path: String,
    pub source: std::io::Error,
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error[E034]: could not read {}: {}", self.path, self.source)
    }
}

impl std::error::Error for ReadError {}

enum Seg {
    Text(String),
    Use(String),
    Open,
    Close,
}

enum Line {
    Def(String),
    Control(String),
    Plain(String),
}

peg::parser! {
    grammar nw() for str {
        pub rule classify() -> Line
            = d:def_line() { Line::Def(d) }
            / c:control_line() { c }
            / p:$([_]*) { Line::Plain(p.to_string()) }

        rule def_line() -> String
            = "<<" n:$((!">>=" [_])*) ">>=" [' ' | '\t']* ![_] { n.to_string() }

        rule control_line() -> Line
            = "@" ![_] { Line::Control(String::new()) }
            / "@" [' ' | '\t'] r:$([_]*) { Line::Control(r.to_string()) }

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

        pub rule docs_out() -> (Vec<Seg>, bool)
            = run:docs_run() rest:docs_block()* {
                let mut v = vec![Seg::Text(run)];
                let mut open = false;
                for (segs, ended) in rest {
                    v.extend(segs);
                    open = ended;
                }
                (v, open)
            }

        pub rule docs_in() -> (Vec<Seg>, bool)
            = content:docs_qrun() tail:docs_reopen()? {
                match tail {
                    Some((mut segs, ended)) => {
                        let mut v = vec![Seg::Text(content), Seg::Close];
                        v.append(&mut segs);
                        (v, ended)
                    }
                    None => (vec![Seg::Text(content)], true),
                }
            }

        rule docs_reopen() -> (Vec<Seg>, bool)
            = docs_close() rest:docs_out() { rest }

        rule docs_block() -> (Vec<Seg>, bool)
            = "[[" content:docs_qrun() close:docs_close()? post:docs_run() {
                let mut v = vec![Seg::Open, Seg::Text(content)];
                match close {
                    Some(()) => {
                        v.push(Seg::Close);
                        v.push(Seg::Text(post));
                        (v, false)
                    }
                    None => (v, true),
                }
            }

        rule docs_close() -> () = "]]" !"]" { () }

        rule docs_run() -> String = s:$(docs_ch()*) { resolve_esc(s) }
        rule docs_ch() = escape() / (!"[[" [_] {})

        rule docs_qrun() -> String = s:$(qrun_ch()*) { resolve_esc(s) }
        rule qrun_ch() = escape() / (!docs_close() [_] {})

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

/// Read each `.cob` file and make the `markup` event stream (§4.1).
///
/// Paths should be relative to the project root so `@file` events match what a
/// `markup` run would print.
pub fn read<S: AsRef<Path>>(files: &[S]) -> Result<Vec<Event>, ReadError> {
    let mut reader = Reader::default();
    for file in files {
        let path = file.as_ref();
        let text = std::fs::read_to_string(path).map_err(|source| ReadError {
            path: path.display().to_string(),
            source,
        })?;
        reader.file(&path.display().to_string(), &text);
    }
    Ok(reader.out)
}

#[derive(Default)]
struct Reader {
    out: Vec<Event>,
    counter: u32,
    open: Option<bool>,
    cur: u32,
    defs_pending: bool,
    in_quote: bool,
}

impl Reader {
    fn open_docs(&mut self) {
        let n = self.counter;
        self.counter += 1;
        self.cur = n;
        self.open = Some(false);
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
        self.defs_pending = false;
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
                Seg::Open => self.out.push(Event::Quote),
                Seg::Close => self.out.push(Event::EndQuote),
            }
        }
        self.out.push(Event::Nl);
    }

    fn code_emit(&mut self, l: &str) {
        let segs = nw::code_line(l).expect("a code line tokenizes");
        self.emit_segs(segs);
    }

    fn docs_emit(&mut self, l: &str) {
        let (segs, ended) = if self.in_quote {
            nw::docs_in(l).expect("a docs line tokenizes")
        } else {
            nw::docs_out(l).expect("a docs line tokenizes")
        };
        self.in_quote = ended;
        self.emit_segs(segs);
    }

    fn index(&mut self, ids: &str, defn: bool) {
        if self.open != Some(true) {
            self.close_current();
            self.open_docs();
            self.docs_emit(if defn { "%def" } else { "%use" });
            return;
        }
        for id in ids.split_whitespace() {
            self.out.push(if defn {
                Event::IndexDefn(id.to_string())
            } else {
                Event::IndexUse(id.to_string())
            });
        }
        self.out.push(Event::IndexNl);
        self.defs_pending = true;
    }

    fn line(&mut self, l: &str) {
        match nw::classify(l).expect("every line classifies") {
            Line::Def(name) => {
                self.close_current();
                self.open_code();
                self.out.push(Event::Defn(name));
                self.out.push(Event::Nl);
            }
            Line::Control(content) => {
                if let Some(rest) = directive(&content, "%def") {
                    self.index(rest, true);
                } else if let Some(rest) = directive(&content, "%use") {
                    self.index(rest, false);
                } else {
                    self.close_current();
                    self.open_docs();
                    self.docs_emit(&content);
                }
            }
            Line::Plain(l) => {
                if self.defs_pending {
                    self.close_current();
                }
                if self.open.is_none() {
                    self.open_docs();
                }
                if self.open == Some(true) {
                    self.code_emit(&l);
                } else {
                    self.docs_emit(&l);
                }
            }
        }
    }

    fn file(&mut self, path: &str, text: &str) {
        self.out.push(Event::File(path.to_string()));
        self.open_docs();
        for line in text.lines() {
            self.line(line);
        }
        self.close_current();
    }
}

fn directive<'a>(content: &'a str, key: &str) -> Option<&'a str> {
    if content == key {
        return Some("");
    }
    content.strip_prefix(key).filter(|r| r.starts_with(' '))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::noweb::parse;

    fn same_as_oracle(nw: &str, markup: &str) {
        let ours = read(&[nw]).expect("reader reads the fixture");
        let oracle = parse(markup).expect("oracle markup parses");
        assert_eq!(ours, oracle, "reader diverged from markup for {nw}");
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

    #[test]
    fn matches_markup_for_quote() {
        same_as_oracle("fixtures/quote.cob", include_str!("../fixtures/quote.markup"));
    }
}
