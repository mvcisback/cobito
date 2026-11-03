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
