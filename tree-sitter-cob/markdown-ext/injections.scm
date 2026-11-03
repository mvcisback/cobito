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
