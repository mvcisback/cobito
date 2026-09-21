@ # Quote and escape fixture

This document exercises the documentation-quote and bracket-escape edge cases the
native reader must match (§4.1). It is not a real program; it only feeds the
differential test.

A quote can run over more than one line: the open [[begins here
and the close]] lands on the next line. An empty quote a[[]]b makes no inner
text. A nested quote [[v[[0]]]] keeps its inner brackets, greedy to the last
close.

An escaped @<<name@>> in prose is literal, not a use. A single @< or @> stays
literal, the @ and all.

<<root>>=
let shift = a @<< b;
let use = <<real>> here;
let single = @< keep @> me;
let esc = @<<name@>> literal;
@ %def shift
<<real>>=
0
@ The document ends here.
