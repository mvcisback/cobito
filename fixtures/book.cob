@ # Front matter

Everything before the first boundary is the index page, so this chunk
lands on \code{index.html}. It refers forward to \ref{fig:pipeline} and to
the cost bound in \ref{eq:cost}, both of which live on a later page.

@ # Parsing

This chunk opens with an \code{h1}, so it starts a new page.

```html-escape
<aside class="sidenote">Sidenotes stay where the author put them; CSS
floats them into the margin.</aside>
```

The lexer is \ref{chunk:lex a token}.

## Lexing {#sec:lexing}

A second-level heading, which the nav tree picks up, and which the author
labelled so it can be linked with a stable id.

```figure \label{fig:pipeline}
\caption{The weave pipeline.}
<img src="pipeline.svg" alt="the weave pipeline">
```

<<lex a token>>=
tokens.push(next());
@ ### Cost

A third-level heading. The bound is $O(n \log n)$.

```math \label{eq:cost}
T(n) = 2T(n/2) + O(n)
```

```math
\text{this one opts out of numbering}
```

@ # Codegen

A third page, so pagination has a middle with both neighbours.
See also \ref{fig:pipeline}, referenced twice, and
\ref{sec:lexing} back on the second page.

```table \label{tbl:opcodes}
\caption{Opcodes.}
| Opcode |
|--------|
| nop |
```

<<src/main.rs>>=
fn main() {
    <<lex a token>>
}
@
