# Editor semantic tokens (§5.5, #2 Tier 2)

This module gives an editor whole-file-correct syntax color for a `.cob` buffer.
Tier 1 (`tree-sitter-cob`) colors each code chunk as an isolated fragment; this
tier instead tokenizes the **whole tangled file**, in context, and maps the tokens
back onto the `.cob` source — the same tokens the web weave draws (§5.5, #1), now
offered to any editor through the Language Server Protocol.

The module has two halves. `tokens` is the computation: it reads the document
model and returns one `Token` per colored span, in `.cob` buffer coordinates. The
server half speaks LSP over stdin and stdout and answers a `semanticTokens`
request with the same tokens. `cob tokens` prints them for a test; `cob lsp` runs
the server.

@ ## The token {#sec:AmEH}

A token is a line, a start column, a length, and a kind — the shape the LSP
semantic-tokens encoding needs. Lines and columns are zero-based bytes, which an
editor reads as UTF-16 for an ASCII buffer (cob's code is ASCII in the common
case).
<<src/lsp.rs>>=
<<imports>>

<<the token>>

<<compute the tokens>>

<<reconstruct buffer positions>>

<<map a tok class to an lsp kind>>

<<the language server>>

<<the tests>>
@ The module reads the model, borrows the weave's per-section token runs, and uses
the highlighter's tok-class accessor. The server half speaks JSON-RPC over stdio.
<<imports>>=
use crate::highlight::{self, LangConfig};
use crate::model::{self, CodeSpan, DocModel, SectionKind};
use crate::{markup, weave};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::process::ExitCode;
@ The token type.
<<the token>>=
/// One colored span in a `.cob` buffer: a zero-based line and start column, a byte
/// length, and an LSP semantic-token kind (one of `LEGEND`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub line: u32,
    pub col: u32,
    pub len: u32,
    pub kind: &'static str,
}
@ ## Computing the tokens {#sec:tkaN}

`tokens` reuses the weave's `tangle_section_runs`: it tokenizes each root's whole
tangled text once and maps the runs back onto each code section's holes-removed
source (§5.5, #1). For each section this module then reconstructs where those
source bytes sit in the `.cob` buffer — holes and the `@<<` escape widen the line —
and emits one `Token` per run, split at line boundaries because an LSP token never
crosses a line. The result is sorted, the order the encoding needs.
<<compute the tokens>>=
/// Every semantic token for the document, in `.cob` buffer coordinates, sorted by
/// line then column (§5.5, #2). Whole-file context comes from the weave's tangle
/// runs; this maps them back onto each section's buffer bytes.
pub fn tokens(doc: &DocModel, lang_cfg: &LangConfig, source: &str) -> Vec<Token> {
    let section_runs = weave::tangle_section_runs(doc, lang_cfg);
    let source_lines: Vec<&str> = source.split('\n').collect();
    let mut out = Vec::new();
    for (sec_idx, runs) in &section_runs {
        let sec = &doc.sections[*sec_idx];
        let SectionKind::Code { spans, .. } = &sec.kind else {
            continue;
        };
        let (hr, pos) = reconstruct(spans, sec.line + 1, &source_lines);
        for &(s, e, tok) in runs {
            let kind = lsp_kind(highlight::tok_class(tok));
            emit(&hr, &pos, s.min(hr.len()), e.min(hr.len()), kind, &mut out);
        }
    }
    out.sort_by_key(|t| (t.line, t.col));
    out
}

/// Split one run `[s, e)` (holes-removed offsets) into buffer tokens, one per line.
fn emit(hr: &str, pos: &[(u32, u32)], s: usize, e: usize, kind: &'static str, out: &mut Vec<Token>) {
    let bytes = hr.as_bytes();
    let mut k = s;
    while k < e {
        let mut m = k;
        while m < e && bytes[m] != b'\n' {
            m += 1;
        }
        if m > k {
            let (line, col) = pos[k];
            let (_, col_end) = pos[m];
            if col_end > col {
                out.push(Token { line, col, len: col_end - col, kind });
            }
        }
        k = if m < e { m + 1 } else { m };
    }
}
@ ## Reconstructing buffer positions {#sec:Ex5F}

The tangle runs are offsets into a section's **holes-removed** source — the bytes
the tokenizer saw. The editor buffer has more: each chunk-use hole is the literal
`@<<name@>>` text, and a literal `<<` in code is the escape `@<<`, one byte wider.
`reconstruct` walks the holes-removed bytes and tracks the matching buffer column,
widening it at each hole and each `<<`. It returns the holes-removed text and, for
each byte offset, the buffer line and column.

To make the column exact — not off by one on a bare `<<` operator or heredoc —
`reconstruct` consults the raw buffer line. The only buffer bytes the tokenizer
never saw are a chunk-use hole (`<<name>>`, a known width) and the `@` of an
escape (`@<<` / `@>>`), which the raw line shows directly. Every other byte is one
to one, so the map is exact.
<<reconstruct buffer positions>>=
/// For a code section's spans and the buffer's `source_lines`, rebuild the
/// holes-removed source and a map from each byte offset to the buffer
/// `(line, column)` — 1-based line from `first_line`, zero-based column. The raw
/// line resolves the one ambiguity the model drops: whether a `<<` is an escape
/// (`@<<`, one byte wider) or a bare operator.
fn reconstruct(spans: &[CodeSpan], first_line: u32, source_lines: &[&str]) -> (String, Vec<(u32, u32)>) {
    let mut hr = String::new();
    let mut holes: Vec<(usize, u32)> = Vec::new();
    for span in spans {
        match span {
            CodeSpan::Nl => hr.push('\n'),
            CodeSpan::Text(t) => hr.push_str(t),
            // In the buffer a use is the bracketed name, so its width is name + 4.
            CodeSpan::Use { name } => holes.push((hr.len(), name.len() as u32 + 4)),
        }
    }
    let bytes = hr.as_bytes();
    let mut pos = vec![(first_line, 0u32); bytes.len() + 1];
    let mut line = first_line;
    let mut col = 0u32;
    let raw = |n: u32| source_lines.get(n as usize - 1).copied().unwrap_or("").as_bytes();
    let mut raw_line = raw(line);
    let mut hi = 0;
    let mut i = 0;
    while i <= bytes.len() {
        // A hole here is literal buffer text (a bracketed use) the tokenizer missed.
        while hi < holes.len() && holes[hi].0 == i {
            col += holes[hi].1;
            hi += 1;
        }
        // An escaped double-open or double-close has a leading `@` in the buffer
        // (no hr byte); the raw line shows it.
        let two = bytes.get(i).zip(bytes.get(i + 1));
        if matches!(two, Some((b'<', b'<')) | Some((b'>', b'>')))
            && raw_line.get(col as usize) == Some(&b'@')
        {
            col += 1;
        }
        pos[i] = (line, col);
        if i == bytes.len() {
            break;
        }
        if bytes[i] == b'\n' {
            line += 1;
            col = 0;
            raw_line = raw(line);
        } else {
            col += 1;
        }
        i += 1;
    }
    (hr, pos)
}
@ ## The token kinds {#sec:hfBF}

cob's grammars color with a closed set of `tok-*` classes (§5.5). The LSP needs its
own fixed legend, declared once in `initialize`; a token's type is an index into
it. `lsp_kind` maps each `tok-*` class to the nearest standard LSP type, and
`LEGEND` lists every type those map to, in index order.
<<map a tok class to an lsp kind>>=
/// The LSP semantic-token legend: a token's `kind` is one of these, and the server
/// encodes it as this array's index. Keep `lsp_kind`'s outputs a subset of this.
pub const LEGEND: &[&str] = &[
    "keyword", "string", "number", "comment", "function", "type", "property",
    "operator", "namespace", "decorator", "variable",
];

/// Map one of cob's `tok-*` classes to its LSP legend type.
fn lsp_kind(class: &str) -> &'static str {
    match class {
        "tok-keyword" => "keyword",
        "tok-string" | "tok-escape" => "string",
        "tok-number" => "number",
        "tok-comment" => "comment",
        "tok-function" | "tok-constructor" => "function",
        "tok-type" | "tok-tag" => "type",
        "tok-property" => "property",
        "tok-operator" | "tok-punctuation" => "operator",
        "tok-module" => "namespace",
        "tok-attribute" => "decorator",
        // tok-variable, tok-constant, tok-label have no closer standard type.
        _ => "variable",
    }
}
@ ## The language server {#sec:euE9}

`cob lsp` speaks the Language Server Protocol over stdin and stdout: a loop that
reads one JSON-RPC message, dispatches it, and writes any response. The protocol
frames each message with a `Content-Length` header. The server keeps every open
buffer by uri (full-text sync, the simplest correct mode) and the resolved
language config, which `main` builds and hands in. `handle` is pure — it maps a
request to its response value — so a test drives it without the stdio framing.

On a `semanticTokens/full` request the server reads the buffer into the model and
runs `tokens`, so the color reflects the editor's unsaved text, not the file on
disk. A buffer the model rejects (a mid-edit error) yields no tokens rather than a
crash. The tokens are encoded as the LSP's packed deltas: five integers per token
— line delta, start delta, length, type index into `LEGEND`, and no modifiers —
with the line made zero-based.
<<the language server>>=
/// The server state: open buffers by uri, and the resolved language config.
struct Server {
    docs: HashMap<String, String>,
    lang_cfg: LangConfig,
}

/// Run the LSP server over stdin/stdout until the client sends `exit` (§5.5, #2).
pub fn serve(lang_cfg: LangConfig) -> ExitCode {
    let mut server = Server { docs: HashMap::new(), lang_cfg };
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    while let Some(msg) = read_message(&mut reader) {
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        if let Some(response) = server.handle(&msg) {
            send(&mut out, &response);
        }
        if method == "exit" {
            break;
        }
    }
    ExitCode::SUCCESS
}

impl Server {
    /// Map one message to its response, or `None` for a notification. Pure, so a
    /// test can drive the protocol without the stdio framing.
    fn handle(&mut self, msg: &Value) -> Option<Value> {
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let id = msg.get("id").cloned();
        match method {
            "initialize" => Some(result(id, initialize_result())),
            "shutdown" => Some(result(id, Value::Null)),
            "textDocument/didOpen" => {
                let td = &msg["params"]["textDocument"];
                if let (Some(uri), Some(text)) = (td["uri"].as_str(), td["text"].as_str()) {
                    self.docs.insert(uri.to_string(), text.to_string());
                }
                None
            }
            "textDocument/didChange" => {
                let uri = msg["params"]["textDocument"]["uri"].as_str();
                // Full-text sync: the last change holds the whole new buffer.
                let text = msg["params"]["contentChanges"]
                    .as_array()
                    .and_then(|c| c.last())
                    .and_then(|c| c["text"].as_str());
                if let (Some(uri), Some(text)) = (uri, text) {
                    self.docs.insert(uri.to_string(), text.to_string());
                }
                None
            }
            "textDocument/semanticTokens/full" => {
                let uri = msg["params"]["textDocument"]["uri"].as_str().unwrap_or("");
                Some(result(id, json!({ "data": self.semantic_tokens(uri) })))
            }
            // Any other request still needs a reply so the client is not stuck; a
            // notification (no id) is dropped.
            _ => id.clone().map(|_| result(id, Value::Null)),
        }
    }

    /// The packed semantic tokens for the buffer at `uri`, or empty if it is not
    /// open or the model rejects it.
    fn semantic_tokens(&self, uri: &str) -> Vec<u32> {
        let Some(text) = self.docs.get(uri) else {
            return Vec::new();
        };
        let name = uri.strip_prefix("file://").unwrap_or(uri);
        let events = markup::read_str(name, text);
        let Ok(doc) = model::build(&events) else {
            return Vec::new();
        };
        encode(&tokens(&doc, &self.lang_cfg, text))
    }
}

/// The `initialize` result: full-text sync and a semantic-tokens provider whose
/// legend is `LEGEND`.
fn initialize_result() -> Value {
    json!({
        "capabilities": {
            "textDocumentSync": 1,
            "semanticTokensProvider": {
                "legend": { "tokenTypes": LEGEND, "tokenModifiers": [] },
                "full": true
            }
        },
        "serverInfo": { "name": "cob", "version": env!("CARGO_PKG_VERSION") }
    })
}

/// Pack tokens into the LSP delta encoding: five integers per token, relative to
/// the one before, with a zero-based line.
fn encode(tokens: &[Token]) -> Vec<u32> {
    let mut data = Vec::new();
    let (mut prev_line, mut prev_col) = (0u32, 0u32);
    for t in tokens {
        let line = t.line.saturating_sub(1);
        let dl = line - prev_line;
        let dc = if dl == 0 { t.col - prev_col } else { t.col };
        let ty = LEGEND.iter().position(|&k| k == t.kind).unwrap_or(LEGEND.len() - 1) as u32;
        data.extend_from_slice(&[dl, dc, t.len, ty, 0]);
        prev_line = line;
        prev_col = t.col;
    }
    data
}

/// A JSON-RPC success response.
fn result(id: Option<Value>, value: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": value })
}

/// Read one `Content-Length`-framed JSON-RPC message, or `None` at end of input.
fn read_message<R: BufRead>(r: &mut R) -> Option<Value> {
    let mut len = 0usize;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(v) = line.strip_prefix("Content-Length:") {
            len = v.trim().parse().ok()?;
        }
    }
    let mut buf = vec![0u8; len];
    std::io::Read::read_exact(r, &mut buf).ok()?;
    serde_json::from_slice(&buf).ok()
}

/// Write one `Content-Length`-framed JSON-RPC message.
fn send<W: Write>(w: &mut W, v: &Value) {
    let body = v.to_string();
    let _ = write!(w, "Content-Length: {}\r\n\r\n{}", body.len(), body);
    let _ = w.flush();
}
@ The test builds a model with a hole mid-line and a use on its own line, and
checks that the reconstructed columns account for the hole width.
<<the tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconstruct_accounts_for_a_hole_width() {
        use CodeSpan::*;
        // Buffer first body line 6 is `let c = HOLE;` (HOLE is the use); the
        // holes-removed text the tokenizer sees is `let c = ;`.
        let spans = vec![
            Text("let c = ".into()),
            Use { name: "next char".into() },
            Text(";".into()),
            Nl,
        ];
        // The raw buffer: the chunk body sits on line 6 (index 5). (@<< / @>>
        // tangle to the real brackets so this line is not read as a chunk use.)
        let src = ["", "", "", "", "", "let c = @<<next char@>>;"];
        let (hr, pos) = reconstruct(&spans, 6, &src);
        assert_eq!(hr, "let c = ;\n");
        // `let` starts at column 0 of line 6.
        assert_eq!(pos[0], (6, 0));
        // The `;` is holes-removed offset 8, but the buffer put it after the
        // 13-byte use text, so column 8 + 13 = 21.
        assert_eq!(pos[8], (6, 21));
    }

    #[test]
    fn reconstruct_does_not_shift_a_bare_double_open() {
        use CodeSpan::*;
        // A shift operator, not an escape: the raw line has no leading `@`, so the
        // column must not drift. `b` is offset 5 and buffer column 5, not 6.
        let spans = vec![Text("a << b".into()), Nl];
        let src = ["a << b"];
        let (hr, pos) = reconstruct(&spans, 1, &src);
        assert_eq!(hr, "a << b\n");
        assert_eq!(pos[5], (1, 5));
    }

    #[test]
    fn server_initializes_and_tokenizes_a_buffer() {
        let mut s = Server { docs: HashMap::new(), lang_cfg: LangConfig::default() };
        // `initialize` advertises a semantic-tokens provider.
        let init = s
            .handle(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}))
            .unwrap();
        assert!(init["result"]["capabilities"]["semanticTokensProvider"].is_object());

        // Open a buffer with a Rust root (@<< / @>> tangle to the real brackets),
        // then ask for its tokens.
        s.handle(&json!({"method":"textDocument/didOpen","params":{"textDocument":{
            "uri":"file:///x/demo.cob",
            "text":"@ # t\n\n@<<src/main.rs@>>=\nfn main() {}\n@\n"
        }}}));
        let resp = s
            .handle(&json!({"jsonrpc":"2.0","id":2,
                "method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":"file:///x/demo.cob"}}}))
            .unwrap();
        let data = resp["result"]["data"].as_array().unwrap();
        // `fn` colors, so there is at least one token; the packing is five ints each.
        assert!(!data.is_empty());
        assert_eq!(data.len() % 5, 0);
    }
}
@ ## Using it in an editor {#sec:AXnG}

An editor runs `cob lsp` as the language server for `.cob` files and turns on
semantic highlighting. In neovim (0.9 and later):

```verbatim \lang{lua}
vim.filetype.add({ extension = { cob = "cob" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "cob",
  callback = function(a)
    vim.lsp.start({
      name = "cob",
      cmd = { "cob", "lsp" },
      root_dir = vim.fs.dirname(a.file),
    })
  end,
})
```

The server gives whole-file color with cob's own grammars, so it needs no editor
grammar. It pairs with `tree-sitter-cob` (Tier 1): the grammar gives structure,
folding, and navigation; the server gives the in-context color.
@
