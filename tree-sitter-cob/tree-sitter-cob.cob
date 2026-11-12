# tree-sitter-cob: a grammar for the editor

This document is the tree-sitter grammar for `.cob` files. An editor (neovim,
Helix, Zed) parses a buffer with a tree-sitter grammar and colors it from a
query. cob is language-agnostic, so this grammar colors the literate *structure*
— the chunk fences, the chunk uses, and the escapes — and hands the
code and the prose to other grammars through **injection** queries (§5.5, Tier 1
of the editor track). It is also a cob grammar like any other, so cob's own web
highlighter can color a `.cob` shown as code.

This grammar tangles to five files: the grammar `grammar.js`, the external scanner
`src/scanner.c`, two query files under `queries/`, and the package manifest
`tree-sitter.json`. Edit this `.cob` and re-tangle (`cob tangle
tree-sitter-cob/tree-sitter-cob.cob --out .`), never the generated files.

## The surface syntax {#sec:5FQr}

A `.cob` file is a list of chunks. A code chunk opens with a fence open line: four
or more backticks, the word `chunk`, and a name. It runs to a fence close line, a
line of backticks at least as long as the open line's run. A documentation chunk
is every other line; its prose is Markdown. Inside code, a `<<name>>` is a chunk
use (a hole), and `@<<` or `@>>` is a literal `<<` or `>>`. Three backticks stay
free for an ordinary fence in prose, so this grammar never confuses the two.

The grammar also reads noweb's old chunk syntax: a `<<name>>=` line at column 0
that opens a chunk, and an `@` line that ends it (`markup.rs.cob` §sec:fence-chunks).
The reader now refuses that syntax (E043). The grammar keeps it so that an editor can
still color a file that `cob migrate` has not converted yet.

Four facts need lookahead, so the grammar keeps them in an external scanner
(`src/scanner.c`): a def and a use both start with `<<`, so the scanner tells them
apart by the trailing `>>=` (def) or `>>` (use); a lone `<<` with no `>>` on the
line (a bash heredoc, `<<'DOC'`) is literal; `@` opens a control line only at
column 0 and only before a space, a tab, or the end of the line, so `@article` in
a string stays code; and a fence open or close needs to count backticks and, for
a close, remember how many the matching open used — the one piece of state this
scanner carries across lines.

The grammar does not model two rules of the reader (`markup.rs.cob` §sec:read-docs).
It does not know that a first-level heading starts a new documentation chunk, and it
does not know a Markdown fenced block. Suppose an author shows a chunk line as an
example inside a longer fence. The reader takes it as plain text, but this grammar
still colors it as a chunk. That is a mistake in color only. The `treesitter` check
parses every `.cob` in the repository, and none of them shows such an example.


## The grammar {#sec:I9DM}

`grammar.js` lists the rules. The external tokens are the five the scanner owns.
The one conflict is after a chunk definition, where an `@` can be an index line
(the chunk continues) or the chunk's end; the `%def` after the `@` tells them
apart, so GLR explores both. The escape rule is the one place the code needs the
`@<<` / `@>>` form in its own text, so it reads `@@<<` / `@@>>` in this source.
`fence_chunk` carries no `index_line`: `%def` is noweb-only bookkeeping, dead in
every real `.cob` file already, so the fence chunk never grew it. The prose lines
after a fence close line belong to the `fence_chunk`, as the prose lines after a
control line belong to a `doc_chunk`.

````chunk tree-sitter-cob/grammar.js
// tree-sitter-cob — the .cob surface syntax (generated from tree-sitter-cob.cob).
module.exports = grammar({
  name: 'cob',

  // The format is line-oriented, so whitespace is significant: no extras.
  extras: $ => [],

  // Named (no leading underscore), not hidden: an editor highlights these
  // markers directly — a hidden external token leaves no node for a
  // highlight query to bind to.
  externals: $ => [
    $.at,          // "@" at column 0 before whitespace — a control/index line
    $.def_open,    // the def open, at column 0 when the line ends with ">>="
    $.use_open,    // the use open, when a ">>" follows on the line
    $.fence_open,  // four-or-more backticks, "chunk", a space — the fence's open
    $.fence_close, // a long-enough backtick run alone on its line — the fence's close
  ],

  // After a chunk definition, "@" is an index line or the chunk ending; "%def"
  // disambiguates, so let GLR explore both.
  conflicts: $ => [[$.code_chunk]],

  rules: {
    // noweb opens an implicit documentation chunk, so a file may begin with bare
    // prose before any marker.
    source_file: $ => seq(repeat($.doc_line), repeat($._chunk)),

    _chunk: $ => choice($.code_chunk, $.fence_chunk, $.doc_chunk),

    code_chunk: $ => seq(
      $.chunk_definition,
      optional($.code_body),
      repeat($.index_line),
    ),

    // The second spelling of a code chunk (§sec:fence-chunks): same body, same
    // chunk-use holes inside it, a fence instead of @<<name@>>=...@.
    fence_chunk: $ => seq(
      $.fence_open,
      field('name', $.fence_chunk_name),
      '\n',
      optional($.code_body),
      $.fence_close,
      '\n',
      repeat($.doc_line),
    ),

    fence_chunk_name: $ => /[^\n]+/,

    // The body as one node, so an injection can hand it to a language grammar.
    code_body: $ => repeat1($._body_line),

    chunk_definition: $ => seq(
      $.def_open,
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

    chunk_use: $ => seq($.use_open, field('name', $.use_name), '>>'),
    use_name: $ => /[^\n>]+/,

    // The escapes for a literal double-angle open or close inside code.
    escape: $ => token(choice('@@<<', '@@>>')),

    // Code text: a run with no "<" (begins a use) and no "@" (begins an escape),
    // or a lone "<" or "@" that begins neither.
    code_text: $ => choice(/[^\n<@]+/, '<', '@'),

    index_line: $ => prec.dynamic(1, seq($.at, /[ \t]/, '%def', field('names', /[^\n]*/), '\n')),

    doc_chunk: $ => seq($.control_line, repeat($.doc_line)),

    control_line: $ => seq(
      $.at,
      optional(seq(/[ \t]/, field('text', /[^\n]*/))),
      '\n',
    ),

    doc_line: $ => seq(field('text', /[^\n]*/), '\n'),
  }
});
````
## The external scanner {#sec:s6Z1}

The scanner owns the four lookahead decisions. It acts only at column 0 for the
`@`, def, and fence markers; the use marker may come anywhere on a line. For `<<`
it consumes the two characters, marks the token end, then scans the rest of the
line for `>>`: with a following `=` at column 0 it is a def, otherwise a use;
with no `>>` it emits nothing and the grammar takes a lone `<`.

A fence open or close both start the same way, a run of backticks at column 0, so
the scanner counts them once and then branches: four or more, followed by
`chunk` and a space, is an open; three or more, alone on the rest of the line,
is a candidate close. Whether a candidate close really closes anything depends
on the open's own count — state with no token of its own to live in, so the
scanner is the one piece of this grammar that carries state across lines. It
clamps to a `u8` and serializes that one byte; no real `.cob` file opens a fence
with 255 backticks, and a byte is enough even if an adversarial one tried.

````chunk tree-sitter-cob/src/scanner.c
#include "tree_sitter/parser.h"
#include <stdlib.h>

enum TokenType { AT_MARKER, DEF_OPEN, USE_OPEN, FENCE_OPEN, FENCE_CLOSE };

// The one piece of state this scanner needs: the backtick count the open
// fence used, or 0 when no fence is open. Everything else a chunk needs lives
// in the parse tree already.
void *tree_sitter_cob_external_scanner_create(void) {
  uint8_t *state = malloc(sizeof(uint8_t));
  *state = 0;
  return state;
}
void tree_sitter_cob_external_scanner_destroy(void *p) { free(p); }
unsigned tree_sitter_cob_external_scanner_serialize(void *p, char *b) {
  b[0] = *(uint8_t *)p;
  return 1;
}
void tree_sitter_cob_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  *(uint8_t *)p = (n >= 1) ? (uint8_t)b[0] : 0;
}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

bool tree_sitter_cob_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  uint8_t *fence_len = (uint8_t *)payload;
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

  // A fence line (§sec:fence-chunks): a run of backticks at column 0. Four or
  // more, then "chunk" and a space, opens one and remembers its count. Three
  // or more alone on the rest of the line is a candidate close; it only
  // counts when a fence is open and this run reaches that open's count.
  if (col == 0 && (valid_symbols[FENCE_OPEN] || valid_symbols[FENCE_CLOSE]) && lexer->lookahead == '`') {
    uint32_t n = 0;
    while (lexer->lookahead == '`') { advance(lexer); n++; }

    if (n >= 4 && valid_symbols[FENCE_OPEN]) {
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t') advance(lexer);
      static const char want[] = "chunk";
      bool ok = true;
      for (int i = 0; want[i] != 0; i++) {
        if (lexer->lookahead != (uint32_t)want[i]) { ok = false; break; }
        advance(lexer);
      }
      if (ok && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
        advance(lexer);
        lexer->mark_end(lexer);
        *fence_len = (n > 255) ? 255 : (uint8_t)n;
        lexer->result_symbol = FENCE_OPEN;
        return true;
      }
      return false;
    }

    if (n >= 3 && valid_symbols[FENCE_CLOSE] && *fence_len > 0 && n >= *fence_len) {
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t') advance(lexer);
      if (lexer->lookahead == '\n' || lexer->lookahead == '\r' || lexer->lookahead == 0) {
        lexer->mark_end(lexer);
        *fence_len = 0;
        lexer->result_symbol = FENCE_CLOSE;
        return true;
      }
      return false;
    }

    return false;
  }

  return false;
}
````
## The highlights query {#sec:WAeo}

This query colors the literate scaffolding. The chunk name is a `@function`
(definition or reference), the `<<`/`>>`/`>>=` openers and closers are
`@punctuation.special`, an escape is `@string.escape`, and `%def` and `@` are
`@keyword` — the noweb markers that make a line a chunk boundary or a
control line, not prose or code. The fence spelling's name gets the same
`@function`, and its open/close fences the same `@punctuation.special` as the
noweb markers they stand in for — one meaning, two spellings, one color. Code
and prose get their color from the injected grammars.

````chunk tree-sitter-cob/queries/highlights.scm
; tree-sitter-cob highlights (generated from tree-sitter-cob.cob).

(chunk_definition
  name: (chunk_name) @function)
(def_open) @punctuation.special
(chunk_definition ">>=" @punctuation.special)

(chunk_use
  name: (use_name) @function)
(use_open) @punctuation.special
(chunk_use ">>" @punctuation.special)

(fence_chunk
  name: (fence_chunk_name) @function)
(fence_open) @punctuation.special
(fence_close) @punctuation.special

(escape) @string.escape

(at) @keyword
(index_line "%def" @keyword)
````
## The injections query {#sec:hLDV}

This query hands the prose to Markdown and each code body to a language grammar.
The language comes from the def-name extension (§5.5, tier 3): a name ending in
`.rs` is Rust, `.nix` is Nix, and so on. An abstract chunk — a name with no
extension, like `<<lex a token>>=` — gets no injection and stays plain; the LSP
tier (Tier 2) runs cob's full resolver for those. Add a language by copying one
pattern with a new extension.

````chunk tree-sitter-cob/queries/injections.scm
; tree-sitter-cob injections (generated from tree-sitter-cob.cob).

; Documentation prose is Markdown, combined so multi-line constructs hold together.
((doc_line) @injection.content
  (#set! injection.language "markdown")
  (#set! injection.combined))
; A control line opens with `@` and one space before any text, and the `text`
; field is a bare regex token with no node of its own, so a query cannot match
; it directly (`text: (_)` is an impossible pattern — `(_)` matches only named
; nodes, and an inline regex token in the grammar is never one). Capture the
; whole node instead and use `#offset!` to drop that two-byte `@ ` prefix
; before Markdown ever sees it — left in, it would feed the `@` to the parser
; as the first byte of the first line, so `@ # Title` parses as a paragraph,
; not a heading. The `#match?` guard requires the space (or tab) after `@`,
; which only a control line carrying text has, so a bare `@` line (no text,
; nothing to highlight) is skipped rather than offset into an empty range.
; `#match?` runs on nvim's Vim-regex engine, which defaults unprefixed
; patterns to "very magic" — there `@` is a multi-assertion operator, not a
; literal, so an un-escaped `@` here is "Unknown operator". `\m` (plain
; "magic", Vim's own default mode) switches that off and makes `@` literal
; again.
((control_line) @injection.content
  (#match? @injection.content "\\m^@[ \t]")
  (#offset! @injection.content 0 2 0 0)
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

; The same, for the fence spelling's code body.
((fence_chunk name: (fence_chunk_name) @_n (code_body) @injection.content)
  (#match? @_n "\\.rs$") (#set! injection.language "rust"))
((fence_chunk name: (fence_chunk_name) @_n (code_body) @injection.content)
  (#match? @_n "\\.nix$") (#set! injection.language "nix"))
((fence_chunk name: (fence_chunk_name) @_n (code_body) @injection.content)
  (#match? @_n "\\.(sh|bash)$") (#set! injection.language "bash"))
((fence_chunk name: (fence_chunk_name) @_n (code_body) @injection.content)
  (#match? @_n "\\.css$") (#set! injection.language "css"))
````
## The verbatim `\lang{}` override {#sec:gL53}

A `verbatim \lang{name}` fence (§6.1, the `markdown.rs.cob` fenced-float rules)
keeps a language class at weave time, but an editor's own markdown grammar does
not know that convention: it reads a fence's info line as one bare language
name, so `verbatim \lang{rust}` makes it look for a language called
"verbatim" and gives up — the body goes uncolored. The fix is a query, not a
grammar change, but it is a query on **markdown**, not on cob, so it cannot
live next to `highlights.scm`/`injections.scm` above: those are the `cob`
language's own queries, and `pkgs.neovimUtils.grammarToPlugin` (the tool that
turns a raw grammar into something an editor's plugin manager loads) always
installs a grammar's queries under its own language's name. It has no path for
one grammar to carry a second language's override. So this one query ships as
its own small package (`cobMarkdownInjections` in the flake, §6.3), added to an
editor's runtime path beside the cob grammar, not wrapped inside it.

A markdown query file that starts with the magic comment `;; extends` is read
alongside the editor's own base markdown queries, not instead of them — so
this rule adds the one case it knows about and leaves every other fence to
the editor's stock behavior.

The peg grammar's own `modifiers()` rule (`markdown.rs.cob` §6.1) allows any
run of whitespace, and any order, between a fence's modifiers — so `\lang{}`
may sit after another modifier, or after two spaces, or not appear at all (a
bare `verbatim` fence is valid and common). A tree-sitter query cannot see
that far: `#offset!`'s four numbers are byte counts fixed when the query is
written, never counted at match time from what a capture actually holds, so
there is no way to skip a *variable*-length prefix. The query below only
recognizes the single canonical shape — `verbatim`, one space, `\lang{name}`,
nothing after — and checks it with one `#match?` over the whole info line
before trusting the fixed-width skip. Anything else (no `\lang{}`, extra
whitespace, a second modifier, `\lang{}` not last) fails that check and falls
through to no injection: an uncolored body, same as today, never a wrong one.

````chunk tree-sitter-cob/markdown-ext/injections.scm
;; extends

; The one shape this rule knows: `verbatim \lang{name}`, one space, nothing
; else on the line. `#offset!`'s 15 is `len("verbatim \lang{")`, fixed only
; because the `#match?` above it pins the exact bytes before "name" — any
; other spacing, order, or missing `\lang{}` fails the match and falls
; through to no injection, not a wrong one.
((fenced_code_block
  (info_string) @injection.language
  (code_fence_content) @injection.content)
  (#match? @injection.language "\\m^verbatim \\\\lang{[^}]\\+}$")
  (#offset! @injection.language 0 15 0 -1))
````
## The package manifest {#sec:5vYN}

`tree-sitter.json` is the package metadata the tree-sitter CLI reads. The scope and
the file type let an editor match `.cob` to this grammar.

````chunk tree-sitter-cob/tree-sitter.json
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
````
## Using it in neovim {#sec:B7g1}

neovim (0.9 and later) reads a tree-sitter grammar and its queries from the
runtime path. The flake ships the compiled parser as a package, built from a
clone of this repo:

```verbatim \lang{sh}
nix build .#treeSitterCobLib
# writes result/parser (the compiled grammar), result/queries/*.scm,
# result/tree-sitter.json — the same shape pkgs.tree-sitter.buildGrammar
# produces, so it plugs into the standard nvim-treesitter tooling, not just
# a bespoke path.
```

Without nix: tangle this document, then from `tree-sitter-cob/` run
`tree-sitter generate` followed by `tree-sitter build -o parser` (the
`tree-sitter` CLI needs a C compiler on `PATH` either way).

**Declaratively, through nvim-treesitter** (home-manager's neovim module,
nvf, nixvim, or any other setup built on `nixpkgs#vimPlugins.nvim-treesitter`):
wrap the package with `pkgs.neovimUtils.grammarToPlugin`, which expects
exactly the `$out/parser` + `$out/queries` shape above, and add the result to
wherever that setup collects extra grammars (nvf: `vim.treesitter.grammars`;
home-manager's `programs.neovim`: `extraPackages`/`plugins`, a parser from
`grammarToPlugin` behaves like any other treesitter plugin). The queries
still need registering explicitly — the wrapped plugin does not read
`tree-sitter-cob/queries/*.scm` on its own — so pass their contents too
(nvf: `vim.treesitter.queries`, one entry per query type).

**Directly, with no plugin manager**, for a quick trial: point neovim at
`result/parser` and `result/queries/*.scm` by hand.

```verbatim \lang{lua}
vim.filetype.add({ extension = { cob = "cob" } })
vim.treesitter.language.add("cob", { path = "/path/to/result/parser" })
-- copy tree-sitter-cob/queries/*.scm (or result/queries/*.scm) to
-- ~/.config/nvim/queries/cob/
vim.api.nvim_create_autocmd("FileType", {
  pattern = "cob",
  callback = function() vim.treesitter.start() end,
})
```

A `/nix/store/...` path does not move after a rebuild, so pasting `result`'s
resolved target once is fine for a quick trial; symlink to `result/parser` in
your dotfiles for something that survives `nix build` running again.

The injections hand the code and the prose to other grammars, so install the Rust,
Nix, Bash, CSS, and Markdown parsers too (for example with nvim-treesitter). A
grammar cob does not ship still colors here when the editor has it.

To check the setup without opening neovim at all: `nix flake check` runs this
grammar against every `.cob` file in the repo (`checks.treesitter`, §5.5) and
fails on the first `ERROR`/`MISSING` node — the same pass/fail signal neovim's
highlighter would hit, just without a UI.
