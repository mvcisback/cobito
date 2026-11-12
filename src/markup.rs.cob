# The native reader (§4.1, §4.2)

This module is the specification and the implementation of the native reader. The
prose is the specification. The chunks after it are the implementation.

The reader reads a \code{.cob} file and makes the event stream that the rest of cob
uses (§4.1). noweb's \code{markup} stage first made this event type, and \code{src/noweb.rs}
keeps the type. The reader runs no external tool, so cob can ship as one binary
(§11). The chunk syntax is cob's own. It is not noweb's syntax now (§sec:fence-chunks).

noweb stays the **oracle** for what it can still judge. The fixtures hold a frozen
\code{markup} golden from the time cob read noweb's syntax. A test proves that this reader
agrees with each golden on every code chunk and on every line of prose (§15). The
IR decoder in \code{src/noweb.rs} stays too, now only as the oracle's decoder in tests.

## What the reader must reproduce {#sec:read-rules}

The reader makes the \code{Event} stream of \code{src/noweb.rs}. It follows these rules:

- A file is a list of chunks. Each chunk is documentation or code. A fence open line
  (§sec:fence-chunks) opens a code chunk. A fence close line ends it. Every other
  line continues the open chunk. The reader opens one empty documentation chunk at
  the start of each file.
- The reader gives each chunk a number, counting up from zero across the whole
  run. The number becomes the section id \code{sec-N} downstream (§5.1).
- A fence open line opens a code chunk. It makes \code{@defn name} and one \code{@nl} for
  the line's own newline.
- A fence close line closes the open code chunk and opens a documentation chunk. The
  close line is the first line of the new chunk. It is empty.
- A plain line continues the open chunk. In documentation it is text; in code it
  is text with chunk uses.
- A heading of the first level, \code{# Title}, starts a new documentation chunk. It does
  not do so when the open chunk has no text yet, or when a fenced block holds the
  line (§sec:read-docs).
- A documentation line is one \code{@text} run. It has no chunk uses and no quotes:
  inline code is \code{\code{…}} (§6.4), so \code{[[} and \code{]]} are ordinary text.
- A code line splits on \code{<<name>>} chunk uses. Each use is \code{@use name}. A \code{<<}
  with no later \code{>>} on the line is literal text (for example a shift operator).
- An \code{@} before a doubled bracket is an escape. In code, \code{@@<<} is the literal text
  \code{<<}, and \code{@@>>} is the literal text \code{>>}. The reader drops the \code{@}, and
  the two brackets do not start a use. A single \code{@<} or \code{@>} is literal, \code{@} and all.
- Every source line makes exactly one newline event, \code{@nl}. This keeps the line
  counter true (§4.2).
- The reader makes a text token for the run before each use only when
  the run is not empty, but it always makes the trailing text token after the last
  one, even when that run is empty. So a use on its own line makes no text before
  it and one empty text token after it.

## The chunk syntax {#sec:fence-chunks}

A code chunk opens with a fence open line. The line holds four or more backticks, the
word \code{chunk}, one or more spaces, and the name of the chunk. The name is the rest
of the line, with the trailing space cut. A name that looks like a path is a root,
and a name that repeats continues the earlier chunk.

The chunk closes at a fence close line. This is a line that holds only backticks, and
at least as many backticks as the open line had. Every line between the two lines is
the body of the chunk. The body can hold chunk uses and escapes (§sec:read-rules).

The open line needs four backticks, not three. Three backticks are for the fences of
Markdown. Every illustrative fence that a document writes (\code{verbatim}, \code{math}, a worked
example) opens with three, in ordinary prose, and must not open a chunk by mistake. A
fence of fewer than four backticks never starts a chunk. It stays plain text, and
\code{markdown.rs} reads it later as a fenced float if its kind word says so (§6.4).

A body can need a line that starts with four or more backticks. Then the fence of
that chunk opens with more backticks than any such line has, the same way
CommonMark opens a longer fence around a fenced block. \code{cob migrate} picks that
length by itself.

noweb's syntax is retired (M17). It used a line that starts with \code{<<name>>=} to
open a chunk, and a line that starts with \code{@} to close one. A reader that finds such
a line in documentation reports E043 and reads the file no further than the end. The
fix is \code{cob migrate FILE}, which rewrites the file in the new syntax (§4.3).

## Documentation chunks and headings {#sec:read-docs}

A documentation chunk ends at the next fence open line. It ends in one more case: a
heading of the first level. An h1 is a page (§5.2), and a page starts at the start of
a section. So the reader starts a new chunk at each \code{# Title} line. This is how one
file holds several pages.

Two things stop the split. The first is an open chunk with no text yet: the heading
is already at the start of its section, and a split would only make an empty chunk.
The second is a fenced block. A \code{# comment} line in a code block is not a heading.

The reader follows the CommonMark rules for a fenced block. A line of three or more
backticks, or of three or more tildes, opens a block. The line can have up to three
spaces before it. A line of backticks cannot have a backtick in its info text. The
block closes at a line of the same character, at least as long, with only spaces
after it. Every line in the block is text. A line that looks like a fence open line
of a chunk is text too, so a longer fence can show a chunk as an example.

A heading of a deeper level does not split a chunk. A heading starts its own node
in any case (§10).

## The grammar {#sec:read-grammar}

The rules above are the whole behavior. This section gives the syntactic core as a
formal grammar, and the reader runs the grammar directly: the \code{peg} crate turns it
into the parser at compile time (§sec:read-code). It is a Parsing Expression
Grammar (PEG): the choice operator \code{/} tries the left side first, and repetition is
greedy.

A file is a list of lines. Each line is one of three kinds. This is the line level:

```verbatim \lang{peg}
document        <- line*
line            <- chunk_open / fence_close / plain_line

chunk_open      <- backtick4 hspace* "chunk" hspace+ fname hspace* eol
fence_close     <- backtick3 "`"* hspace* eol   // a candidate close; length decides (§sec:read-code)
plain_line      <- rest eol                     // continues the open chunk

backtick4       <- "`" "`" "`" "`" "`"*   // four or more backticks
backtick3       <- "`" "`" "`"            // three, the floor for any fence line
fname           <- ( !eol . )*
rest            <- ( !eol . )*
hspace          <- " " / "\t"
eol             <- "\n" / EOF
```

\code{fence_close} only says a line is a *candidate* close: three or more backticks and
nothing else. Whether it closes anything depends on state the grammar cannot see: the
backtick count that the matching \code{chunk_open} used. So §sec:read-code decides it
from the open chunk's own recorded length.

Inside a line the text tokenizes two ways. The open chunk sets the mode: a code
chunk uses the code tokens, a documentation chunk uses the documentation tokens.

```verbatim \lang{peg}
// a code-chunk line
code_line    <- code_atom*
code_atom    <- use / escape / char
use          <- "<<" use_name ">>"
use_name     <- ( !">>" . )+

// a documentation-chunk line: one text run, no uses, no quotes
docs_line    <- ( escape / char )*

// shared
escape       <- "@" ( "<<" / ">>" )             // the "@" is dropped, both brackets stay
char         <- .
```

The grammar gives the shape, not the whole event stream. Four things stay outside
it, because a PEG cannot state them:

- Which mode a plain line uses. The mode comes from the open chunk, which is state
  from earlier lines, not shape.
- Where a text token ends. The reader breaks a code run at each use and each literal
  \code{<<}, and it drops an empty run before a use but keeps an empty run at the end
  (§sec:read-rules).
- The chunk number and the line number. Both are counters over the whole run.
- Whether a \code{fence_close} closes anything, and whether a heading splits a chunk. The
  first needs the open chunk's backtick count. The second needs to know if a
  Markdown fenced block is open and if the chunk has text (§sec:read-docs). Both are
  state, not shape.

The prose rules (§sec:read-rules) and the tests (§15) cover these.

## How the code implements this {#sec:read-code}

The reader runs the grammar of §sec:read-grammar directly. The \code{peg} crate turns
the grammar into a parser at compile time. The grammar tokenizes a code line into a
list of \code{Seg} atoms — text or a chunk use — returns a documentation line as one
text run, and sorts a whole line into its \code{Line} kind. A stateful \code{Reader} then
lowers these to events with the state rules of §sec:read-rules: the chunk counter,
the open chunk, the length of the open fence, and the state of a Markdown fenced
block. So the grammar owns the shape and the \code{Reader} owns the state.

The grammar is the one parser. noweb stays the oracle at test time, not a second
reader. The differential test (§15) and the flake \code{reader} check compare this reader
with real \code{markup} output on every fixture. They compare the code chunks and the
prose, which is what the oracle can still judge.

The module is the read error, the \code{Seg} and \code{Line} types the grammar makes, the
grammar, the escape helper, the entry point that reads each file, the stateful
\code{Reader}, the helpers for documentation lines, and the tests.
````chunk src/markup.rs
<<the reader banner>>

<<reader imports>>

<<the read error>>

<<the line and segment types>>

<<the grammar>>

<<the escape helper>>

<<read the files>>

<<the reader state>>

<<the documentation helpers>>

<<the reader tests>>
````
The banner states the module's job.
````chunk the reader banner
//! The native `.cob` reader (§4.1). Makes the `Event` stream the rest of cob
//! reads, so cob reads its own source with no external process and can ship
//! as one binary (§11). The chunk syntax is cob's own (§4.2).
````
The reader needs paths, formatting, and the shared \code{Event} type.
````chunk reader imports
use std::fmt;
use std::path::Path;

use crate::noweb::Event;
````
Reading a source file can fail in two ways. The file may not read: it is absent, or
the read itself fails. Or the file may use noweb's retired chunk syntax (E043). The
second error names the first line that does, and the fix.
````chunk the read error
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
````
The grammar makes two small types. \code{Seg} is one atom of a code line: a text run or
a chunk use. \code{Line} is the kind of a whole line: a fence open line with the length of
its backtick run and the chunk name, a candidate fence close line with the length of
its run, or a plain line. The \code{Reader} reads these, never raw characters.
````chunk the line and segment types
enum Seg {
    Text(String),
    Use(String),
}

enum Line {
    ChunkOpen(usize, String),
    Fence(usize),
    Plain(String),
}
````
The grammar is the runnable form of §sec:read-grammar. Each rule returns the atoms
of one line. A \code{pub rule} is one the \code{Reader} calls: \code{classify} sorts a line into
its kind, \code{code_line} tokenizes a code line into text and use atoms, and
\code{docs_line} returns a documentation line as one text run. A documentation line has
no chunk uses and no quotes — inline code is \code{\code{…}} (§6.4), so a \code{[[…]]} bracket
pair is ordinary text.

The run rules (\code{code_run}, \code{docs_line}) capture the whole text run as one slice,
then \code{resolve_esc} strips the \code{@} from each escape in one pass. This is faster than
one string per character, and it makes the same text either way.
````chunk the grammar
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
````
A text run keeps its escapes as written, so one pass strips them: \code{@@<<} becomes
\code{@<<} and \code{@@>>} becomes \code{@>>}. Most runs hold no \code{@}, so the reader checks for one
before it makes a new string.
````chunk the escape helper
fn resolve_esc(s: &str) -> String {
    if s.as_bytes().contains(&b'@') {
        s.replace("@@<<", "@<<").replace("@@>>", "@>>")
    } else {
        s.to_string()
    }
}
````
The entry point reads each file and folds it into one event stream. It emits one
\code{@file} per file with the path as given, so \code{@file} events stay portable. The chunk
counter runs across every file. When the reader met noweb's retired syntax in any
file, the entry point gives back E043 for the first such line, and no events.
````chunk read the files
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
````
The reader holds the growing event stream, the chunk counter, and the open chunk.
\code{open} is \code{Some(true)} for code and \code{Some(false)} for documentation. \code{cur} is the open
chunk's number, needed for its \code{@end}. \code{fence_len} is the backtick count that the open
code chunk used, so a later \code{fence_line} candidate can tell if it is long enough to
close the chunk (§sec:fence-chunks). \code{md_fence} is the open Markdown fenced block of
the documentation chunk, if any: its character and its length (§sec:read-docs).
\code{docs_has_text} is true once the open documentation chunk holds a line that is not
blank. The last three fields are for E043: the file being read, the line in it, and
the first retired line the reader met.
````chunk the reader state
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
    <<open and close a chunk>>

    <<lower a line to events>>

    <<dispatch one line>>

    <<read a documentation line>>

    <<walk one file>>
}
````
\code{open_docs}/\code{open_code} take the next number and emit the \code{@begin}. A new
documentation chunk has no text and no open fenced block. \code{close_current} emits the
\code{@end} for the open chunk and clears the fence length.
````chunk open and close a chunk
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
````
\code{emit_segs} turns one code line's atoms into events. It drops an empty text run
before a use but keeps the last run of the line, even when it is empty, so the
empty-text rule of §sec:read-rules holds. One \code{@nl} ends the line. \code{code_emit}
tokenizes a code line and emits its atoms; \code{docs_emit} emits a documentation line
as one \code{@text} run and one \code{@nl}.
````chunk lower a line to events
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
````
The dispatch decides what one line is. A line inside a Markdown fenced block of a
documentation chunk is text, whatever it looks like, so it goes straight to
\code{docs_line}. For any other line, \code{classify} sorts it. A \code{ChunkOpen} opens a code
chunk and remembers its length. A \code{Fence} is only a candidate: it closes the open
chunk when its own length is at least that chunk's \code{fence_len}, and otherwise it is
plain text. The close line is the first line of the new documentation chunk, and it
is empty. \code{plain} sends a plain line to the code or the documentation path.
````chunk dispatch one line
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
````
A documentation line has three jobs, in this order. Inside a Markdown fenced block, it
may close the block. Outside one, it is checked for the retired syntax, then it may
start a new chunk if it is an h1 and the chunk has text, then it may open a block.
Last, it becomes a text event, and it marks the chunk as having text if it is not
blank.
````chunk read a documentation line
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
````
One file: emit \code{@file}, open the leading empty documentation chunk, walk every
line, then close whatever chunk stays open at the end.
````chunk walk one file
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
````
Four small functions answer questions about one documentation line. \code{is_h1} says if
the line is a heading of the first level: a \code{#} at the start of the line, then a
space, a tab, or the end of the line. \code{opens_md_fence} gives the character and the
length of the Markdown fenced block that the line opens, or nothing.
\code{closes_md_fence} says if the line closes the block. \code{is_retired} says if the line
is noweb's retired syntax: an \code{@} alone, an \code{@} and a space, or a def line that has a
name between two angle pairs and then an equals sign.
````chunk the documentation helpers
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
    let def_end = "@>>=";
    match l.strip_prefix("@<<") {
        Some(rest) => rest.find(def_end).is_some_and(|end| {
            rest[end + def_end.len()..]
                .chars()
                .all(|c| c == ' ' || c == '\t')
        }),
        None => false,
    }
}
````
The tests have two parts. The first part is a differential: this reader must agree with
real \code{markup} on what the oracle can still judge. The pinned \code{fixtures/*.markup} files
are the oracle output, so the test is hermetic — it decodes them with \code{noweb::parse}
and compares.

The fixtures use the fence syntax now, and \code{markup} cannot read that. The goldens
came from the same fixtures in noweb's syntax. So the two event streams differ in
where a documentation chunk starts, and in the index events. They agree on two
things, and those are what the test compares. The first is every code chunk: its
name, its text runs, its uses, and its newlines. The second is every non-blank
line of prose. \code{signature} keeps just those.

The second part checks the events of small texts: the fence rules, the heading rule,
the Markdown fenced block rule, and E043.
````chunk the reader tests
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

    <<the syntax tests>>
}
````
These tests read small texts. \code{texts} keeps the text events, \code{count} counts the events
of one kind, and \code{read_text} reads a temporary file, so a test can ask for E043.
````chunk the syntax tests
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
    let got = read_str("f", "````chunk a\nlet x = @<<b@>>; @@<<y\n````\n");
    assert!(got.contains(&Event::Use("b".into())));
    assert!(got.contains(&Event::Text("; @<<y".into())));
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
    let e = read_text("def", "prose\n@<<a@>>=\nx\n@\n").unwrap_err();
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
````
