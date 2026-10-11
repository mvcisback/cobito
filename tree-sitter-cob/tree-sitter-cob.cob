@ # tree-sitter-cob: a grammar for the editor

This document is the tree-sitter grammar for `.cob` files. An editor (neovim,
Helix, Zed) parses a buffer with a tree-sitter grammar and colors it from a
query. cob is language-agnostic, so this grammar colors the literate *structure*
— the chunk definitions, the chunk uses, and the control lines — and hands the
code and the prose to other grammars through **injection** queries (§5.5, Tier 1
of the editor track). It is also a cob grammar like any other, so cob's own web
highlighter can color a `.cob` shown as code.

This grammar tangles to five files: the grammar `grammar.js`, the external scanner
`src/scanner.c`, two query files under `queries/`, and the package manifest
`tree-sitter.json`. Edit this `.cob` and re-tangle (`cob tangle
tree-sitter-cob/tree-sitter-cob.cob --out .`), never the generated files.

@ ## The surface syntax

A `.cob` file is a list of chunks. A code chunk opens with a `<<name>>=` line at
column 0 and runs to the next `@` line or the next def. A documentation chunk
opens with an `@ ` line and continues on bare lines; its prose is Markdown. The
file may open with bare prose, because noweb starts an implicit documentation
chunk. Inside code, a `<<name>>` is a chunk use (a hole), and `@<<` or `@>>` is a
literal `<<` or `>>`.

Three facts need lookahead, so the grammar keeps them in an external scanner
(`src/scanner.c`): a def and a use both start with `<<`, so the scanner tells them
apart by the trailing `>>=` (def) or `>>` (use); a lone `<<` with no `>>` on the
line (a bash heredoc, `<<'DOC'`) is literal; and `@` opens a control line only at
column 0 and only before a space, a tab, or the end of the line, so `@article` in
a string stays code.

@ ## The grammar

`grammar.js` lists the rules. The external tokens are the three the scanner owns.
The one conflict is after a chunk definition, where an `@` can be an index line
(the chunk continues) or the chunk's end; the `%def` after the `@` tells them
apart, so GLR explores both. The escape rule is the one place the code needs the
`@<<` / `@>>` form in its own text, so it reads `@@<<` / `@@>>` in this source.

<<tree-sitter-cob/grammar.js>>=
// tree-sitter-cob — the .cob surface syntax (generated from tree-sitter-cob.cob).
module.exports = grammar({
  name: 'cob',

  // The format is line-oriented, so whitespace is significant: no extras.
  extras: $ => [],

  externals: $ => [
    $._at,        // "@" at column 0 before whitespace — a control/index line
    $._def_open,  // the def open, at column 0 when the line ends with ">>="
    $._use_open,  // the use open, when a ">>" follows on the line
  ],

  // After a chunk definition, "@" is an index line or the chunk ending; "%def"
  // disambiguates, so let GLR explore both.
  conflicts: $ => [[$.code_chunk]],

  rules: {
    // noweb opens an implicit documentation chunk, so a file may begin with bare
    // prose before any marker.
    source_file: $ => seq(repeat($.doc_line), repeat($._chunk)),

    _chunk: $ => choice($.code_chunk, $.doc_chunk),

    code_chunk: $ => seq(
      $.chunk_definition,
      optional($.code_body),
      repeat($.index_line),
    ),

    // The body as one node, so an injection can hand it to a language grammar.
    code_body: $ => repeat1($._body_line),

    chunk_definition: $ => seq(
      $._def_open,
      field('name', $.chunk_name),
      '>>=',
      /[^\n]*/,
      '\n',
    ),

    chunk_name: $ => /[^\n>]+/,

    _body_line: $ => seq(
      repeat(choice($.escape, $.chunk_use, $.code_text)),
      '\n',
    ),

    chunk_use: $ => seq($._use_open, field('name', $.use_name), '>>'),
    use_name: $ => /[^\n>]+/,

    // The escapes for a literal double-angle open or close inside code.
    escape: $ => token(choice('@@<<', '@@>>')),

    // Code text: a run with no "<" (begins a use) and no "@" (begins an escape),
    // or a lone "<" or "@" that begins neither.
    code_text: $ => choice(/[^\n<@]+/, '<', '@'),

    index_line: $ => prec.dynamic(1, seq($._at, /[ \t]/, '%def', field('names', /[^\n]*/), '\n')),

    doc_chunk: $ => seq($.control_line, repeat($.doc_line)),

    control_line: $ => seq(
      $._at,
      optional(seq(/[ \t]/, field('text', /[^\n]*/))),
      '\n',
    ),

    doc_line: $ => seq(field('text', /[^\n]*/), '\n'),
  }
});
@ ## The external scanner

The scanner owns the three lookahead decisions. It acts only at column 0 for the
`@` and def markers; the use marker may come anywhere on a line. For `<<` it
consumes the two characters, marks the token end, then scans the rest of the line
for `>>`: with a following `=` at column 0 it is a def, otherwise a use; with no
`>>` it emits nothing and the grammar takes a lone `<`.

<<tree-sitter-cob/src/scanner.c>>=
#include "tree_sitter/parser.h"

enum TokenType { AT_MARKER, DEF_OPEN, USE_OPEN };

void *tree_sitter_cob_external_scanner_create(void) { return 0; }
void tree_sitter_cob_external_scanner_destroy(void *p) { (void)p; }
unsigned tree_sitter_cob_external_scanner_serialize(void *p, char *b) { (void)p; (void)b; return 0; }
void tree_sitter_cob_external_scanner_deserialize(void *p, const char *b, unsigned n) { (void)p; (void)b; (void)n; }

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

bool tree_sitter_cob_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;
  uint32_t col = lexer->get_column(lexer);

  // "@" opens a control or index line at column 0, only before whitespace or the
  // end of the line. "@article" (no space) is ordinary content.
  if (col == 0 && valid_symbols[AT_MARKER] && lexer->lookahead == '@') {
    advance(lexer);
    int32_t c = lexer->lookahead;
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0) {
      lexer->mark_end(lexer);
      lexer->result_symbol = AT_MARKER;
      return true;
    }
    return false;
  }

  // A def open (column 0, line ends ">>=") or a use open (a ">>" follows). A lone
  // open with no ">>" — a bash heredoc — is literal, so the grammar lexes a "<".
  if ((valid_symbols[DEF_OPEN] || valid_symbols[USE_OPEN]) && lexer->lookahead == '<') {
    advance(lexer);
    if (lexer->lookahead != '<') return false;
    advance(lexer);
    lexer->mark_end(lexer);

    bool found = false, eq_after = false;
    while (lexer->lookahead != 0 && lexer->lookahead != '\n') {
      if (lexer->lookahead == '>') {
        advance(lexer);
        if (lexer->lookahead == '>') {
          advance(lexer);
          found = true;
          eq_after = (lexer->lookahead == '=');
          break;
        }
      } else {
        advance(lexer);
      }
    }
    if (!found) return false;

    if (col == 0 && eq_after && valid_symbols[DEF_OPEN]) {
      lexer->result_symbol = DEF_OPEN;
      return true;
    }
    if (valid_symbols[USE_OPEN]) {
      lexer->result_symbol = USE_OPEN;
      return true;
    }
    return false;
  }

  return false;
}
@ ## The highlights query

This query colors the literate scaffolding. The chunk name is a `@function`
(definition or reference), the `>>` and `>>=` closers are `@punctuation.special`,
an escape is `@string.escape`, and `%def` is a `@keyword`. The `<<` and `@`
openers are hidden scanner tokens, so the name and the closers carry the color.
Code and prose get their color from the injected grammars.

<<tree-sitter-cob/queries/highlights.scm>>=
; tree-sitter-cob highlights (generated from tree-sitter-cob.cob).

(chunk_definition
  name: (chunk_name) @function)
(chunk_definition ">>=" @punctuation.special)

(chunk_use
  name: (use_name) @function)
(chunk_use ">>" @punctuation.special)

(escape) @string.escape

(index_line "%def" @keyword)
@ ## The injections query

This query hands the prose to Markdown and each code body to a language grammar.
The language comes from the def-name extension (§5.5, tier 3): a name ending in
`.rs` is Rust, `.nix` is Nix, and so on. An abstract chunk — a name with no
extension, like `<<lex a token>>=` — gets no injection and stays plain; the LSP
tier (Tier 2) runs cob's full resolver for those. Add a language by copying one
pattern with a new extension.

<<tree-sitter-cob/queries/injections.scm>>=
; tree-sitter-cob injections (generated from tree-sitter-cob.cob).

; Documentation prose is Markdown, combined so multi-line constructs hold together.
((doc_line) @injection.content
  (#set! injection.language "markdown")
  (#set! injection.combined))
((control_line) @injection.content
  (#set! injection.language "markdown")
  (#set! injection.combined))

; Code bodies, by the def-name extension.
((code_chunk (chunk_definition name: (chunk_name) @_n) (code_body) @injection.content)
  (#match? @_n "\\.rs$") (#set! injection.language "rust"))
((code_chunk (chunk_definition name: (chunk_name) @_n) (code_body) @injection.content)
  (#match? @_n "\\.nix$") (#set! injection.language "nix"))
((code_chunk (chunk_definition name: (chunk_name) @_n) (code_body) @injection.content)
  (#match? @_n "\\.(sh|bash)$") (#set! injection.language "bash"))
((code_chunk (chunk_definition name: (chunk_name) @_n) (code_body) @injection.content)
  (#match? @_n "\\.css$") (#set! injection.language "css"))
@ ## The package manifest

`tree-sitter.json` is the package metadata the tree-sitter CLI reads. The scope and
the file type let an editor match `.cob` to this grammar.

<<tree-sitter-cob/tree-sitter.json>>=
{
  "grammars": [
    {
      "name": "cob",
      "scope": "source.cob",
      "path": ".",
      "file-types": ["cob"],
      "injection-regex": "^cob$"
    }
  ],
  "metadata": {
    "version": "0.0.1",
    "license": "MIT",
    "description": "tree-sitter grammar for cobito .cob literate sources",
    "authors": [{ "name": "cobito" }]
  },
  "bindings": {
    "c": true,
    "rust": false,
    "node": false,
    "go": false,
    "python": false,
    "swift": false,
    "kotlin": false
  }
}
@ ## Using it in neovim

neovim (0.9 and later) reads a tree-sitter grammar and its queries from the
runtime path. First build the parser: tangle this document, run `tree-sitter
generate`, then `tree-sitter build -o cob.so` in `tree-sitter-cob/`. Then tell
neovim about the `.cob` file type, the parser, and the queries.

```verbatim \lang{lua}
vim.filetype.add({ extension = { cob = "cob" } })
vim.treesitter.language.add("cob", { path = "/path/to/cob.so" })
-- put highlights.scm and injections.scm under ~/.config/nvim/queries/cob/
vim.api.nvim_create_autocmd("FileType", {
  pattern = "cob",
  callback = function() vim.treesitter.start() end,
})
```

The injections hand the code and the prose to other grammars, so install the Rust,
Nix, Bash, CSS, and Markdown parsers too (for example with nvim-treesitter). A
grammar cob does not ship still colors here when the editor has it.
@
