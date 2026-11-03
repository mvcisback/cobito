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
