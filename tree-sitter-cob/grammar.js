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
    // chunk-use holes inside it, a fence instead of <<name>>=...@.
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
    escape: $ => token(choice('@<<', '@>>')),

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
