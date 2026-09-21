@ # Markdown fixture

A tiny document authored in the \emph{Markdown} dialect. It exercises the
post-\code{markup} prose transform: paragraphs and \strong{emphasis} become HTML, and the
fenced float directives produce numbered, labelled equations, figures, and
tables. The mass–energy relation is \ref{eq:mass}, sketched in
\ref{fig:diagram} and tabulated in \ref{tbl:units}.

```math \label{eq:mass}
E = mc^2
```

```figure \label{fig:diagram}
\caption{A \emph{schematic} of $E = mc^2$.}
<img src="diagram.svg" alt="mass to energy">
```

```table \label{tbl:units}
\caption{Symbols and their units.}
| Symbol | Unit |
|--------|------|
| \code{E} | J  |
| \code{m} | kg |
```

The inline tail $O(1)$ still renders. The code lives in
\ref{chunk:src/answer.rs}.

<<src/answer.rs>>=
pub fn answer() -> u32 {
    42
}
@
