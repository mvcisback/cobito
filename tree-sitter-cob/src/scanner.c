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
