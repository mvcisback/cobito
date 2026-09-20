@ # A tiny literate program
This fixture exercises the noweb constructs we care about.
We call \code{lex()} in a loop, which runs in $O(n \log n)$ time.
Note a tricky case: math with an angle bracket, $a < b$.

<<lex a token>>=
let c = <<next char>>;
tokens.push(c);
@ %def c

@ Chunk continuation: we append to the same chunk later.
Also an inline code example: \code{tokens[0]} and a literal
dollar in prose: cost is \$5.

<<lex a token>>=
count += 1;
@

@ ## The next char helper
A second-level heading, for the nav tree.

<<next char>>=
input.next().unwrap()
@

@ Finally the root chunk, path-shaped.

<<src/main.rs>>=
fn main() {
    let mut tokens = vec![];
    let mut count = 0;
    <<lex a token>>
    println!("{count}");
}
@
