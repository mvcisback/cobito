# cobito

A web-first literate programming system. You write a program as a document. The
prose and the code live in one source. `cob` makes two things from that source:

- **weave** — a static website for the archive. cob makes the math at build time,
  so the content needs no browser JavaScript.
- **tangle** — the plain source files that the compiler reads.

The command is `cob`. The sources are `.cob` files. cob builds itself: its crate,
its build file, and its stylesheet are all literate `.cob` documents.

## Install

```sh
nix build git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git          # the cob binary
nix build git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git#static   # one portable static binary
```

## Syntax highlighting — cob ships with no grammars

cob works with any language. Only syntax highlighting needs to know the language.
So cob makes a grammar a **build input**, not a built-in part. The shipped binary
gives no color until you add a grammar. This keeps cob small. You can color any
language that has a tree-sitter grammar. You do not wait for cobito to add it.

### Add a grammar

In your own flake, add the grammar's tree-sitter repo as an input. Then give it to
`withGrammars`:

```nix
{
  inputs.cobito.url = "git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git";
  inputs.tree-sitter-sql = { url = "github:DerekStride/tree-sitter-sql"; flake = false; };

  outputs = { self, cobito, tree-sitter-sql }:
    let system = "x86_64-linux"; in {
      packages.${system}.default = cobito.packages.${system}.cob.withGrammars [
        { id = "sql"; exts = [ "sql" ]; src = tree-sitter-sql; }
      ];
    };
}
```

Now `nix build` gives you a cob that colors SQL. A grammar is a record:

| field    | meaning                                            | needed |
|----------|----------------------------------------------------|--------|
| `id`     | the language name (`cob language` prints it)       | yes    |
| `exts`   | the file extensions that select it, e.g. `[ "sql" ]` | yes  |
| `src`    | the tree-sitter repo (a `flake = false` input)     | yes    |
| `symbol` | the C entry point; defaults to `tree_sitter_<id>`  | no     |

Both `cob` and `static` have `withGrammars`, so the portable static binary takes
grammars too. The `symbol` field defaults from `id`. For a grammar whose symbol
does not match, give the field: `symbol = "tree_sitter_embedded_template";`.

The grammar's repo must use the standard tree-sitter layout: `src/parser.c` (and an
optional `src/scanner.c` or `src/scanner.cc`), and `queries/highlights.scm`. A query
that uses the standard capture names (`@keyword`, `@string`, …) maps onto cob's
`tok-*` CSS classes.

### Build cobito's own site

cobito's own documents use Rust, Nix, Bash, and CSS. So the repo gives you a
development build with these four grammars:

```sh
nix build git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git#cobDoc
```

## Learn more

cob tells the whole system as a literate program. Read `cobito.cob` first (the
goals, the architecture, the milestones). Then read `src/highlight.rs.cob` §5.5 for
syntax highlighting and the grammar-as-build-input design.
