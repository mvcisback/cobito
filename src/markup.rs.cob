# The native reader (§4.1, §4.2)

This module is the specification and the implementation of the native reader. The
prose is the specification. The chunks after it are the implementation.

The reader reads a \code{.cob} file and makes the same event stream that noweb's
\code{markup} stage makes (§4.1). It replaces the \code{markup} process. cob no longer runs
an external tool to read its own source, so cob can ship as one binary (§11). cob
also owns the syntax now, so a later milestone can add new chunk-line syntax that
\code{markup} cannot express.

noweb does not go away. It stays the **oracle**: a test proves this reader makes
the same events as real \code{markup} for every module (§15). The old IR decoder in
\code{src/noweb.rs} stays too, now only as the oracle's decoder in tests.

## What the reader must reproduce {#sec:read-rules}

The reader makes the \code{Event} stream of \code{src/noweb.rs}. It follows these rules,
each checked against real \code{markup} (§4.2):

- A file is a list of chunks. Each chunk is documentation or code. A chunk begins
  with a \code{@<<name@>>=} line (code), an \code{@ } control line (documentation), a fence
  line (§sec:fence-chunks, also code), or a plain line that continues the open
  chunk. The reader opens one empty documentation chunk at the start of each file,
  the same as \code{markup}.
- The reader gives each chunk a number, counting up from zero across the whole
  run. The number becomes the section id \code{sec-N} downstream (§5.1).
- A \code{@<<name@>>=} line opens a code chunk. It makes \code{@defn name} and one \code{@nl} for
  the line's own newline.
- An \code{@ } line (or a bare \code{@}) closes the open chunk and opens a documentation
  chunk. The text after \code{@ } (one space is dropped) is the first line of the new
  chunk.
- \code{@ %def a b} after a code chunk does not open a documentation chunk. It adds
  \code{@index defn a}, \code{@index defn b}, and one \code{@index nl} to that code chunk. More
  \code{@ %def} lines add more index entries. The next real line closes the code chunk.
- A plain line continues the open chunk. In documentation it is text; in code it
  is text with chunk uses.
- A documentation line is one \code{@text} run. It has no chunk uses and no quotes:
  inline code is \code{\code{…}} (§6.4), so \code{[[} and \code{]]} are ordinary text. (This is
  the one place the reader departs from noweb, which emits \code{@quote} for \code{[[…]]}.)
- A code line splits on \code{@<<name@>>} chunk uses. Each use is \code{@use name}. A \code{@<<}
  with no later \code{>>} on the line is literal text (for example a shift operator).
- An \code{@} before a doubled bracket is an escape: \code{@<<name@>>} in prose is the
  literal text \code{@<<name@>>}, not a use. The reader drops the \code{@} and keeps the two
  brackets, and they do not start a use. A single \code{@<} or \code{@>} is literal, \code{@} and
  all.
- Every source line makes exactly one newline event: \code{@nl} for a normal line, or
  \code{@index nl} for a \code{%def} line. This keeps the line counter true (§4.2).
- The reader makes a text token for the run before each use only when
  the run is not empty, but it always makes the trailing text token after the last
  one, even when that run is empty. So a use on its own line makes no text before
  it and one empty text token after it, the same as \code{markup}.

## A second, fence-based chunk syntax {#sec:fence-chunks}

\code{<<name>>=} and bare \code{@} are noweb's own spelling for a chunk boundary. They read
oddly next to the rest of a \code{.cob} file, where every other piece of structure — a
heading, a labelled fence — is a plain word a reader already knows. This module
adds a second, cob-only spelling for the same two jobs: opening a code chunk and
closing one. It changes no event, no chunk, and no section; only the bytes that
trigger them.

A code chunk opens with a line of four or more backticks, the word \code{chunk}, one
or more spaces, then the chunk's name (the rest of the line, trailing space
trimmed) — the same name grammar as \code{<<name>>=}, so a path-shaped name is still a
root and a repeated name still continues. It closes on a line that holds only
backticks, run of the same length or longer. noweb's \code{markup} cannot make this
syntax, so there is no \code{markup} oracle for it (§15 covers the replacement test
strategy); the native reader is this syntax's only authority.

Four backticks, not three, because three is already spoken for: every illustrative
fence this document writes (\code{verbatim}, \code{math}, a worked PEG example) opens with
three, inside ordinary prose, and must never accidentally open a real chunk. A
fence of fewer than four backticks is never a chunk boundary, by construction — it
falls through as plain text, for \code{markdown.rs} to read later as a fenced float
(§6.4) if its kind word says so. Four is reserved; if a chunk's own body ever needs
to show a run of four or more backticks on its own line (nested documentation of
this very rule, say), the surrounding fence opens with five or more, the same
escape-by-escalation CommonMark itself uses for a nested fence.

This is additive for now: both spellings work, side by side, in the same file,
even continuing the same chunk. Removing the noweb spelling is a later, separate
change (tracked in \code{cobito.cob}'s milestones), because every \code{.cob} file written
so far — this one included — still uses it.

## The grammar {#sec:read-grammar}

The rules above are the whole behavior. This section gives the syntactic core as a
formal grammar, and the reader runs the grammar directly: the \code{peg} crate turns it
into the parser at compile time (§sec:read-code). The grammar is also the reference
for later syntax that \code{markup} cannot express (§11). It is a Parsing Expression
Grammar (PEG): the choice operator \code{/} tries the left side first, and repetition is
greedy.

A file is a list of lines. Each line is one of five kinds (§sec:fence-chunks adds
the first two). This is the line level:

```verbatim \lang{peg}
document        <- line*
line            <- chunk_open / fence_close / def_line / control_line / plain_line

chunk_open      <- backtick4 hspace* "chunk" hspace+ fname hspace* eol
fence_close     <- backtick3 "`"* hspace* eol   // a candidate close; length decides (§sec:read-code)

def_line        <- "@<<" name "@>>=" hspace* eol   // opens a code chunk
control_line    <- "@" ( hspace rest )? eol        // "@", "@ text", or "@<tab>text"
plain_line      <- rest eol                        // continues the open chunk

backtick4       <- "`" "`" "`" "`" "`"*   // four or more backticks
backtick3       <- "`" "`" "`"            // three, the floor for any fence line
fname           <- ( !eol . )*
name            <- ( !( "@>>=" / "@>>" ) . )+
rest            <- ( !eol . )*
hspace          <- " " / "\t"
eol             <- "\n" / EOF
```

\code{fence_close} only says a line is a *candidate* close: three or more backticks and
nothing else. Whether it actually closes anything depends on state the grammar
cannot see — the backtick count the matching \code{chunk_open} used — so §sec:read-code
decides it from the open chunk's own recorded length, the same way code decides the
other state-dependent rules below.

Inside a line the text tokenizes two ways. The open chunk sets the mode: a code
chunk uses the code tokens, a documentation chunk uses the documentation tokens.

```verbatim \lang{peg}
// a code-chunk line
code_line    <- code_atom*
code_atom    <- use / escape / char
use          <- "@<<" use_name "@>>"
use_name     <- ( !"@>>" . )+

// a documentation-chunk line: one text run, no uses, no quotes
docs_line    <- ( escape / char )*

// shared
escape       <- "@" ( "@<<" / "@>>" )           // the "@" is dropped, both brackets stay
char         <- .
```

The grammar gives the shape, not the whole event stream. Five things stay outside
it, because a PEG cannot state them:

- Which mode a plain line uses. The mode comes from the open chunk, which is state
  from earlier lines, not shape.
- Where a text token ends. \code{markup} breaks a code run at each use and each literal
  \code{@<<}, and it drops an empty run before a use but keeps an empty run at the end
  (§sec:read-rules).
- The \code{%def} and \code{%use} control lines. They add index entries to the open code
  chunk and hold it open until the next line. That is state, not shape.
- The chunk number and the line number. Both are counters over the whole run.
- Whether a \code{fence_close} actually closes anything. It does only when a chunk is
  open and that chunk's own \code{chunk_open} used a backtick run no longer than this
  one's (§sec:fence-chunks). A shorter run, or no open fence-opened chunk at all,
  makes the line plain text instead — left for \code{markdown.rs} to read as an
  ordinary fenced float.

The prose rules (§sec:read-rules) and the differential test (§15) cover these.

A \code{def_line} today ends right after \code{@>>=}. A later milestone adds an optional
metadata group in that slot, so a chunk can set its own language, for example
\code{@<<lex@>>= {lang=rust}} (§5.5). \code{markup} cannot carry that text, so this grammar
becomes the reference for it. The slot is not parsed yet.

## How the code implements this {#sec:read-code}

The reader runs the grammar of §sec:read-grammar directly. The \code{peg} crate turns
the grammar into a parser at compile time. The grammar tokenizes a code line into a
list of \code{Seg} atoms — text or a chunk use — returns a documentation line as one
text run, and sorts a whole line into its \code{Line} kind. A stateful \code{Reader} then
lowers these to events with the state rules of §sec:read-rules: the chunk counter,
the open chunk, and the \code{%def} wait. So the grammar owns the shape and the \code{Reader}
owns the state.

The grammar is the one parser. For the noweb spelling, noweb stays the oracle at
test time, not a second reader: the differential test (§15) and the flake
\code{reader} check diff this reader against real \code{markup} for every module, so
that half of the grammar can never drift from the behavior it copies. The fence
spelling (§sec:fence-chunks) has no such oracle — \code{markup} cannot read it — so
its tests (§15) check the native reader against itself instead.

The module is the read error, the \code{Seg} and \code{Line} types the grammar makes, the
grammar, the escape helper, the entry point that reads each file, the stateful
\code{Reader}, and the tests.
<<src/markup.rs>>=
<<the reader banner>>

<<reader imports>>

<<the read error>>

<<the line and segment types>>

<<the grammar>>

<<the escape helper>>

<<read the files>>

<<the reader state>>

<<the reader tests>>
@
The banner states the module's job and the one safety rule: noweb stays the
oracle, so this reader must match it byte for byte.
<<the reader banner>>=
//! The native `.cob` reader (§4.1). Makes the same `Event` stream as noweb's
//! `markup`, so cob reads its own source with no external process and can ship
//! as one binary (§11). A differential test proves the events match real
//! `markup` for every module; `noweb::parse` stays as the oracle's decoder.
@
The reader needs paths, formatting, and the shared \code{Event} type. It makes the
same events the old parser made, so downstream code does not change.
<<reader imports>>=
use std::fmt;
use std::path::Path;

use crate::noweb::Event;
@
Reading a source file can fail one way that matters here: the file will not read
(it is absent, or the read itself fails). That is E034.
<<the read error>>=
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
@
The grammar makes two small types. \code{Seg} is one atom of a code line: a text run or
a chunk use. \code{Line} is the kind of a whole line: a fence-opened code definition, a
fence-closed candidate, a noweb-spelled code definition, an \code{@} control line, or a
plain line. The \code{Reader} reads these, never raw characters.
<<the line and segment types>>=
enum Seg {
    Text(String),
    Use(String),
}

enum Line {
    ChunkOpen(usize, String),
    Fence(usize),
    Def(String),
    Control(String),
    Plain(String),
}
@
The grammar is the runnable form of §sec:read-grammar. Each rule returns the atoms
of one line. A \code{pub rule} is one the \code{Reader} calls: \code{classify} sorts a line into
its kind, \code{code_line} tokenizes a code line into text and use atoms, and
\code{docs_line} returns a documentation line as one text run. A documentation line has
no chunk uses and no quotes — inline code is \code{\code{…}} (§6.4), so a \code{[[…]]} bracket
pair is ordinary text.

The run rules (\code{code_run}, \code{docs_line}) capture the whole text run as one slice,
then \code{resolve_esc} strips the \code{@} from each escape in one pass. This is faster than
one string per character, and it makes the same text either way.
<<the grammar>>=
peg::parser! {
    grammar nw() for str {
        pub rule classify() -> Line
            = o:chunk_open_line() { o }
            / f:fence_line() { f }
            / d:def_line() { Line::Def(d) }
            / c:control_line() { c }
            / p:$([_]*) { Line::Plain(p.to_string()) }

        // §sec:fence-chunks: four or more backticks, "chunk", the name.
        rule chunk_open_line() -> Line
            = n:$("`" "`" "`" "`" "`"*) [' ' | '\t']* "chunk" [' ' | '\t']+
              name:$([_]*) ![_] {
                Line::ChunkOpen(n.len(), name.trim_end().to_string())
            }

        // A candidate close: three or more backticks, nothing else. Whether it
        // actually closes depends on the open chunk's own length (§sec:read-code).
        rule fence_line() -> Line
            = n:$("`" "`" "`" "`"*) [' ' | '\t']* ![_] { Line::Fence(n.len()) }

        rule def_line() -> String
            = "@<<" n:$((!"@>>=" [_])*) "@>>=" [' ' | '\t']* ![_] { n.to_string() }

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
            / lone:$("@<<") run:code_run() { vec![Seg::Text(format!("{lone}{run}"))] }

        rule use_tok() -> String
            = "@<<" n:$((!"@>>" [_])*) "@>>" { n.to_string() }

        rule code_run() -> String = s:$(code_ch()*) { resolve_esc(s) }
        rule code_ch() = escape() / (!"@<<" [_] {})

        // A documentation line is one text run. `[[` carries no special meaning
        // (§6.4 uses `\code{…}` for inline code); only the `@@<<`/`@@>>` escapes
        // are resolved.
        pub rule docs_line() -> String = s:$(docs_ch()*) { resolve_esc(s) }
        rule docs_ch() = escape() / [_]

        rule escape() = "@@<<" / "@@>>"
    }
}
@
A text run keeps its escapes as written, so one pass strips them: \code{@@<<} becomes
\code{@<<} and \code{@@>>} becomes \code{@>>}. Most runs hold no \code{@}, so the reader checks for one
before it makes a new string.
<<the escape helper>>=
fn resolve_esc(s: &str) -> String {
    if s.as_bytes().contains(&b'@') {
        s.replace("@@<<", "@<<").replace("@@>>", "@>>")
    } else {
        s.to_string()
    }
}
@
The entry point reads each file and folds it into one event stream. It emits one
\code{@file} per file with the path as given, so \code{@file} events stay portable, the
same as \code{markup}. The chunk counter runs across every file.
<<read the files>>=
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

/// Read one in-memory buffer into events, naming it `name` so `@file` events match
/// (§5.5, #2): the path an editor would save to. The LSP path — it has the unsaved
/// buffer text, so it never touches disk — where `read` reads files.
pub fn read_str(name: &str, text: &str) -> Vec<Event> {
    let mut reader = Reader::default();
    reader.file(name, text);
    reader.out
}
@
The reader holds the growing event stream, the chunk counter, and the open chunk.
\code{open} is \code{Some(true)} for code, \code{Some(false)} for documentation, and \code{None}
between chunks. \code{cur} is the open chunk's number, needed for its \code{@end}.
\code{defs_pending} remembers that a code chunk saw \code{@ %def} and waits for the next
real line to close it. \code{fence_len} remembers the backtick count a fence-opened
code chunk used, so a later \code{fence_line} candidate can tell whether it is long
enough to close it (§sec:fence-chunks); it is \code{None} for a chunk opened the noweb
way, or whenever no chunk is open.
<<the reader state>>=
#[derive(Default)]
struct Reader {
    out: Vec<Event>,
    counter: u32,
    open: Option<bool>,
    cur: u32,
    defs_pending: bool,
    fence_len: Option<usize>,
}

impl Reader {
    <<open and close a chunk>>

    <<lower a line to events>>

    <<dispatch one line>>

    <<walk one file>>
}

<<the directive helper>>
@
\code{open_docs}/\code{open_code} take the next number and emit the \code{@begin}.
\code{close_current} emits the \code{@end} for the open chunk and clears the \code{%def} wait and
the fence length — whichever one, or neither, the closing chunk had.
<<open and close a chunk>>=
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
@
\code{emit_segs} turns one code line's atoms into events. It drops an empty text run
before a use but keeps the last run of the line, even when it is empty, so the
empty-text rule of §sec:read-rules holds. One \code{@nl} ends the line. \code{code_emit}
tokenizes a code line and emits its atoms; \code{docs_emit} emits a documentation line
as one \code{@text} run and one \code{@nl}. \code{index} adds \code{%def}/\code{%use} entries to the open
code chunk and waits to close it.
<<lower a line to events>>=
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
@
The dispatch decides what one line is. \code{classify} sorts it. A \code{ChunkOpen} opens a
code chunk the fence way and remembers its length; a \code{Def} opens one the noweb way.
A \code{Fence} is only a candidate: it closes the open chunk when one is open and its
own length is at least that chunk's \code{fence_len}, and otherwise it is plain text, so
it falls to the same \code{plain} path a \code{Plain} line takes. A \code{Control} is \code{%def}/\code{%use}
(index entries) or an \code{@ } line that opens a documentation chunk. \code{plain} continues
the open chunk — opening a fresh documentation chunk first if a \code{%def} just closed
the code chunk.
<<dispatch one line>>=
fn line(&mut self, l: &str) {
    match nw::classify(l).expect("every line classifies") {
        Line::ChunkOpen(len, name) => {
            self.close_current();
            self.open_code();
            self.fence_len = Some(len);
            self.out.push(Event::Defn(name));
            self.out.push(Event::Nl);
        }
        Line::Fence(len) => {
            let closes = matches!(self.fence_len, Some(req) if len >= req);
            if closes {
                self.close_current();
                self.open_docs();
                // The closing fence line itself still counts as one line, the
                // same as a bare `@` does via its own `docs_emit("")` (§sec:read-rules).
                self.docs_emit("");
            } else {
                self.plain(l);
            }
        }
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
        Line::Plain(l) => self.plain(&l),
    }
}

fn plain(&mut self, l: &str) {
    if self.defs_pending {
        self.close_current();
    }
    if self.open.is_none() {
        self.open_docs();
    }
    if self.open == Some(true) {
        self.code_emit(l);
    } else {
        self.docs_emit(l);
    }
}
@
One file: emit \code{@file}, open the leading empty documentation chunk, walk every
line, then close whatever chunk stays open at the end.
<<walk one file>>=
fn file(&mut self, path: &str, text: &str) {
    self.out.push(Event::File(path.to_string()));
    self.open_docs();
    for line in text.lines() {
        self.line(line);
    }
    self.close_current();
}
@
\code{directive} reads the text after an \code{@ } control keyword, or \code{None}. \code{%def} and
\code{%def x} both match; the returned rest is empty or the ids.
<<the directive helper>>=
fn directive<'a>(content: &'a str, key: &str) -> Option<&'a str> {
    if content == key {
        return Some("");
    }
    content.strip_prefix(key).filter(|r| r.starts_with(' '))
}
@
The tests are the differential: this reader must make the same events as real
\code{markup}. The pinned \code{fixtures/*.markup} files are the oracle output, so the test
is hermetic — it decodes them with \code{noweb::parse} and compares.
<<the reader tests>>=
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

    <<the fence syntax tests>>
}
@
noweb's \code{markup} cannot read the fence syntax of §sec:fence-chunks, so it has no
oracle output to diff against. These tests instead prove the fence spelling makes
the same events as the equivalent noweb spelling — the native reader checking
itself, which is all that is possible for syntax \code{markup} does not know.
<<the fence syntax tests>>=
#[test]
fn fence_chunk_matches_noweb_spelling() {
    let old = read_str("f", "@<<a@>>=\nx\n@\nmore\n");
    let new = read_str("f", "````chunk a\nx\n````\nmore\n");
    assert_eq!(old, new, "a fence chunk should make the same events as @<<a@>>=…@");
}

#[test]
fn fence_close_must_reach_the_opening_length() {
    // Opened with five backticks: a run of only four does not close it, and
    // stays in the chunk as a line of code; a run of five does.
    let got = read_str("f", "`````chunk a\nx\n````\ny\n`````\n");
    let want = read_str("f", "@<<a@>>=\nx\n````\ny\n@\n");
    assert_eq!(
        got, want,
        "a short closing run should stay in the chunk, not end it"
    );
}

#[test]
fn three_backtick_fence_in_docs_is_plain_text() {
    // No chunk is open, so a plain illustrative ``` fence is just docs text —
    // the same events with or without it, give or take the text itself.
    let got = read_str("f", "prose\n```\nmore\n```\nend\n");
    let want = read_str("f", "prose\n```\nmore\n```\nend\n");
    assert_eq!(got, want);
    // In particular, it never opens or closes a code chunk.
    assert!(!got.iter().any(|e| matches!(e, Event::BeginCode(_))));
}

#[test]
fn fence_and_noweb_opens_continue_the_same_chunk_name() {
    let evs = read_str("f", "@<<a@>>=\nx\n@\n`````chunk a\ny\n`````\n");
    let defs: Vec<&str> = evs
        .iter()
        .filter_map(|e| match e {
            Event::Defn(n) => Some(n.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(defs, vec!["a", "a"], "both opens name the same chunk");
}
@
