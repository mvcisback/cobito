# The cob flake, as a literate program

This page is the build file for cob. It is a literate program. cob tangles this
page to make two flakes: \code{flake.nix}, the \code{main}-branch build, and
\code{flake.dist.nix}, which the release step writes as the \code{flake.nix} of the
\code{tangled} snapshot. The committed \code{flake.nix} on \code{main} must match the tangled
\code{flake.nix} root byte for byte; a CI check (\code{dogfood}) tangles the page again on
each run and compares. This makes sure the two stay the same.

This page is the first step in the self-host path of cob (§13). The Nix
part of the toolchain is now a cob document. cob has a Nix grammar for syntax
highlighting (§5.5). The grammar gives color to this page.

The checks below are long shell scripts. This page tells each one as its own set
of chunks. The prose explains why each step exists. A shell script is not Nix, so
a \code{[weave.chunk-lang]} map in \code{cob.toml} marks each script chunk as \code{bash} (§5.5,
tier 1). cob then gives the script chunks Bash color, and the Nix wrapper around
them keeps Nix color. This is the reason the Bash grammar exists.

This document tangles to **two** flakes, one per branch, from shared chunks. The
\code{main} flake (\code{flake.nix}) is the working flake: it seeds the build from the
\code{tangled} release branch and runs the full check set. The \code{dist} flake
(\code{flake.dist.nix}) is what the release step writes into the \code{tangled} snapshot:
it builds the committed \code{.rs} straight, with no seed and no self-reference. Both
share the system list, the KaTeX pin, and the builder, so there is one source of
truth for the parts that do not differ.

## The main flake {#sec:TaAs}

The \code{main} flake is one attribute set. It has a \code{description} and two inputs.
\code{nixpkgs} is pinned. \code{seed} is the \code{tangled} release branch, pinned by tag: it
holds the committed \code{.rs}/\code{.css} that a build on \code{main} compiles first, before
\code{cob} tangles the \code{.cob} again (§13). \code{seed} is \code{flake = false} — cob reads its
tree, not its outputs. The \code{outputs} function starts with a \code{let} block of shared
helpers, then gives the \code{packages}, \code{devShells}, and \code{checks}.
<<flake.nix>>=
{
  description = "cobito — a web-first literate programming system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # The `tangled` release branch on the forge, pinned by tag: the committed
  # .rs/.css seed a build on `main` (§13). A release pushes a new tag and bumps
  # this ref. An absolute forge URL (not `git+file:.`) so the lock is portable.
  inputs.seed = {
    url = "git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git?ref=refs/tags/v0.1.2";
    flake = false;
  };

  # Highlighting grammars are a build input, not a Cargo dependency (§5.5): each
  # is a pinned tree-sitter repo the build compiles in. These four are the
  # default set — cob needs them to weave itself.
  inputs.tree-sitter-rust = { url = "github:tree-sitter/tree-sitter-rust"; flake = false; };
  inputs.tree-sitter-nix = { url = "github:nix-community/tree-sitter-nix"; flake = false; };
  inputs.tree-sitter-bash = { url = "github:tree-sitter/tree-sitter-bash"; flake = false; };
  inputs.tree-sitter-css = { url = "github:tree-sitter/tree-sitter-css"; flake = false; };

  outputs = { self, nixpkgs, seed, tree-sitter-rust, tree-sitter-nix, tree-sitter-bash, tree-sitter-css }:
    let
      <<system iteration>>

      <<pinned katex assets>>

      <<grammar inputs and manifest>>

      <<the cob builder>>
    in
    {
      packages = eachSystem (system: pkgs: rec {
        <<the cob package>>
        <<the tangled flake output>>
        default = cob;
      });

      devShells = eachSystem (system: pkgs: {
        <<the dev shell>>
      });

      checks = eachSystem (system: pkgs: {
        <<the checks>>
      });
    };
}
@
## The dist flake {#sec:e9uc}

The \code{dist} flake is what the \code{tangled} branch carries as its \code{flake.nix}. On
\code{tangled} the \code{.rs}/\code{.css} are tracked, so this flake has no \code{seed} input and no
tangle step: it just builds the committed tree with \code{mkCob self}. That keeps
\code{tangled} cleanly buildable on its own, with a \code{flake.lock} that pins only
\code{nixpkgs} — no self-reference. It reuses the same shared helpers as the \code{main}
flake. The build check compiles the crate and runs the hermetic tests, which is
the whole point of a release snapshot: proof that these committed bytes build.
<<flake.dist.nix>>=
{
  description = "cobito — buildable release snapshot (the tangled branch)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Grammars are a build input, not a Cargo dep (§5.5); the snapshot pins the
  # same default set as `main` so the committed tree builds on its own.
  inputs.tree-sitter-rust = { url = "github:tree-sitter/tree-sitter-rust"; flake = false; };
  inputs.tree-sitter-nix = { url = "github:nix-community/tree-sitter-nix"; flake = false; };
  inputs.tree-sitter-bash = { url = "github:tree-sitter/tree-sitter-bash"; flake = false; };
  inputs.tree-sitter-css = { url = "github:tree-sitter/tree-sitter-css"; flake = false; };

  outputs = { self, nixpkgs, tree-sitter-rust, tree-sitter-nix, tree-sitter-bash, tree-sitter-css }:
    let
      <<system iteration>>

      <<pinned katex assets>>

      <<grammar inputs and manifest>>

      <<the cob builder>>
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # The tree is already tangled: compile the committed .rs directly. The
        # shipped cob ships with no grammars (§5.5), the same as `main`; a user
        # opts in with `cob.withGrammars`.
        cob = mkCob pkgs self ./Cargo.lock [ ] false // {
          withGrammars = extra: mkCob pkgs self ./Cargo.lock extra false;
        };
        # tree-sitter-cob, tangled then `tree-sitter generate`d (§5.5).
        treeSitterCob = pkgs.runCommand "tree-sitter-cob"
          { nativeBuildInputs = [ pkgs.tree-sitter pkgs.nodejs ]; } ''
          cp -r ${self}/tree-sitter-cob $out
          chmod -R +w $out
          export HOME=$TMPDIR
          cd $out && tree-sitter generate
        '';
        # The grammar-ful development build, which also runs the cargo tests —
        # the release snapshot's proof that these committed bytes build and pass.
        cobDoc = mkCob pkgs self ./Cargo.lock
          (cobGrammars ++ [{ id = "cob"; exts = [ "cob" ]; src = treeSitterCob; symbol = "tree_sitter_cob"; }])
          true;
        default = cob;
      });

      devShells = eachSystem (system: pkgs: {
        <<the dist dev shell>>
      });

      checks = eachSystem (system: pkgs: {
        # The shipped cob builds with an empty grammar registry (§5.5) …
        build = self.packages.${system}.cob;
        # … and the grammar-ful build runs the hermetic cargo tests.
        tests = self.packages.${system}.cobDoc;
      });
    };
}
@
## System iteration {#sec:kHIL}

cob builds each output for the four systems in the list. \code{eachSystem} is the
helper for this. It maps a function of \code{system} and \code{pkgs} across the list with
\code{genAttrs}. You write \code{packages}, \code{devShells}, and \code{checks} one time. cob then
makes one instance for each system.
<<system iteration>>=
systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
eachSystem = f: nixpkgs.lib.genAttrs systems (system:
  f system nixpkgs.legacyPackages.${system});
@
## The KaTeX pin {#sec:hwLv}

cob renders math at weave time. The HTML from KaTeX is coupled to its own CSS
and font metrics. The assets must match the version of KaTeX that the \code{katex}
crate contains. The \code{katex} package in nixpkgs is a different version. A wrong
version makes each equation show two times. The flake pins the version and the
asset bundle together, by hash (§6.3).
<<pinned katex assets>>=
# KaTeX renders to HTML that is version-coupled to its own CSS and font
# metrics, so these assets must match the version the `katex` crate
# embeds (0.16.4) — nixpkgs' katex is a different release. See §6.3.
# Bump both together or math silently mislays.
katexVersion = "0.16.4";
katexAssets = pkgs: pkgs.fetchzip {
  url = "https://github.com/KaTeX/KaTeX/releases/download/v${katexVersion}/katex.tar.gz";
  sha256 = "0pgajj8vqfvgws3wnn5bfy4h3w75n4dz8jvjsxcw8s80jnp0md8c";
};
@
## The grammar manifest {#sec:grammars}

Highlighting is the one language-bound part of cob (§5.5). cob keeps it a **build
input**, not a Cargo dependency: each grammar is a pinned tree-sitter repo (a flake
input above), and the build script (`build.rs`) compiles each one named in the
`COB_GRAMMARS` manifest into the registry. So a user adds a grammar by naming its
repo to the build (`cob.withGrammars`), with no edit to cob's source — cob is a
meta-language for highlighting.

The shipped \code{cob} ships with **no grammars** — cob is language-agnostic, and a
grammar is a build input a user opts into (the README shows how). \code{cobGrammars}
is a different thing: the set cobito needs to weave **its own** documents — Rust,
Nix, Bash, and CSS (the crate, the flake, shell scripts in the flake, and the
stylesheet). The \code{cobDoc} output and the flake's checks use it; the shipped \code{cob}
and \code{static} do not.

A grammar is \code{\{ id; exts; src; symbol? \}}: \code{src} is a pinned tree-sitter repo,
\code{exts} the file extensions that imply it, and \code{symbol} the \code{tree_sitter_<name>}
C entry point — which defaults from \code{id}, so a regular grammar needs only three
fields. \code{grammarManifest} writes the file \code{build.rs} reads: one grammar per line,
tab-separated. The builder sets \code{COB_GRAMMARS} to this file, so the grammar sources
enter the build closure through it.

A user adds a grammar with no edit to cob: both \code{cob} and \code{static} carry a
\code{withGrammars} function, so \code{cob.withGrammars [ \{ id = "sql"; exts = [ "sql" ];
src = tree-sitter-sql; \} ]} is cob with that one grammar compiled in. This is the
meta-language point of §5.5 — cob is language-agnostic, and a grammar is a build
input, not a fork.
<<grammar inputs and manifest>>=
# The grammars cobito needs to weave its OWN documents (§5.5): the crate, the
# flake, shell scripts, the stylesheet. The shipped cob ships none of these — a
# user opts in with `cob.withGrammars`. A grammar is `{ id; exts; src; symbol? }`:
# `src` a pinned tree-sitter repo input, `exts` the file extensions that imply it,
# `symbol` the tree_sitter_<name> C entry point (defaults from `id`).
cobGrammars = [
  { id = "rust"; exts = [ "rs" ];        src = tree-sitter-rust; }
  { id = "nix";  exts = [ "nix" ];       src = tree-sitter-nix; }
  { id = "bash"; exts = [ "sh" "bash" ]; src = tree-sitter-bash; }
  { id = "css";  exts = [ "css" ];       src = tree-sitter-css; }
];
# The COB_GRAMMARS file build.rs reads: one grammar per line, tab-separated —
# id, comma-joined extensions, source tree, C symbol. The grammar store paths
# appear in the content, so setting COB_GRAMMARS to it pulls the sources into
# the build closure. `symbol` defaults to tree_sitter_<id> (with `-` → `_`).
grammarManifest = pkgs: grammars:
  let line = g:
        let symbol = g.symbol or
              ("tree_sitter_" + builtins.replaceStrings [ "-" ] [ "_" ] g.id);
        in "${g.id}\t${nixpkgs.lib.concatStringsSep "," g.exts}\t${g.src}\t${symbol}\n";
  in pkgs.writeText "cob-grammars" (nixpkgs.lib.concatMapStrings line grammars);
@
## The builder {#sec:Mh65}

Two builders, for the two deployment shapes (§6.3). \code{mkCob} is the Nix build:
a \code{buildRustPackage} whose \code{postFixup} wraps the binary to set
\code{COB_KATEX_ASSETS} at the pinned store path, so the small binary reads the dist
from the store at run time. The \code{cob} binary reads and tangles \code{.cob} files
natively (§4.1, §11), so it needs no noweb — only the KaTeX assets for weave. It
takes the source tree, so the flake builds the same crate from the committed seed
and from the tangled \code{.cob}. The last argument, \code{runTests}, says whether to run
the hermetic cargo tests. cob ships with an **empty** grammar registry (§5.5), and
the highlighting unit tests need a grammar, so only the grammar-ful \code{cobDoc} output
runs the tests; the shipped empty \code{cob} only has to compile.
<<the cob builder>>=
# One buildRustPackage, applied to two source trees (the committed seed and
# the freshly tangled .cob). cob reads and tangles .cob natively, so the binary
# needs no noweb — only the KaTeX assets for weave, read from the store at run
# time via the wrapper.
mkCob = pkgs: src: lock: grammars: runTests: pkgs.rustPlatform.buildRustPackage {
  pname = "cob";
  version = "0.1.0";
  inherit src;
  # Each source tree carries its own lock, so a dependency change on `main` does
  # not force a seed refresh — stage 0 builds the seed with the seed's lock.
  cargoLock.lockFile = lock;
  # build.rs compiles each grammar named here into the registry (§5.5). The
  # shipped cob ships none; the grammar-ful cobDoc output carries the four cob
  # needs for its own documents. The stdenv C compiler builds the grammar C.
  COB_GRAMMARS = grammarManifest pkgs grammars;
  # The highlighting tests need a grammar, so only a grammar-ful build runs them.
  doCheck = runTests;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postFixup = ''
    wrapProgram $out/bin/cob \
      --set COB_KATEX_ASSETS ${katexAssets pkgs}
  '';
};
@
\code{mkCobStatic} is the standalone build: a fully static musl binary
(\code{pkgsStatic}) with the KaTeX dist baked in (feature \code{embed-assets}, from
\code{COB_KATEX_ASSETS} at build time). It carries no wrapper and no store references,
so the one file runs on any Linux box — this is the distribution artifact for
non-Nix users. It skips the cargo tests; the Nix \code{build} check already runs them.
<<the cob builder>>=
# The standalone single binary: static musl (pkgsStatic) with the pinned KaTeX
# dist baked in (feature `embed-assets`, embedded from COB_KATEX_ASSETS at build
# time). No wrapper, no store paths — one file that runs anywhere.
mkCobStatic = pkgs: src: lock: grammars: pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "cob";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = lock;
  buildFeatures = [ "embed-assets" ];
  # include_bytes! reads this at build time; the pin lives in the flake (§6.3).
  COB_KATEX_ASSETS = katexAssets pkgs;
  # The grammars compile into the static binary too (§5.5), with the musl C
  # compiler from pkgsStatic's stdenv.
  COB_GRAMMARS = grammarManifest pkgs grammars;
  # Tests are covered by the Nix `build` check; keep the static build lean.
  doCheck = false;
};
@
## The package: two stages {#sec:UIDl}

cob builds in two stages, so the literate \code{.cob} sources stay the one authority
on \code{main} (§13). On \code{main} no \code{.rs} or \code{.css} is committed; each comes from a
\code{.cob}. But a tangler must exist before anything can be tangled, and cob's tangler
is now native (§11) — there is no noweb to seed with. The \code{seed} input closes
that gap: it is the \code{tangled} release branch, which does commit the \code{.rs}/\code{.css}.

Stage 0 is \code{cobBootstrap}, built straight from the \code{seed} — the committed \code{.rs}
of the pinned \code{tangled} snapshot. Stage 1 is \code{cob}, the default package:
\code{cobBootstrap} tangles every \code{.cob} with cob itself into \code{cobSource}, and \code{cob}
builds from that. The \code{selfhost} check proves \code{cob tangle} reproduces \code{cobSource}
byte for byte, so cob is a fixed point of its own tangler and the loop is sound.
<<the cob package>>=
# Stage 0: build cob from the seed — the committed .rs of the pinned tangled
# snapshot. The bootstrap only tangles cobSource, which needs no grammars, so it
# builds with an empty set and skips the tests.
cobBootstrap = mkCob pkgs seed (seed + "/Cargo.lock") [ ] false;
<<the tangled source tree>>
# Stage 1, the shipped packages. cob ships with NO grammars (§5.5): it is
# language-agnostic, and a grammar is a build input a user opts into with
# `cob.withGrammars [ … ]`. The empty build only has to compile, so it skips the
# tests (the highlighting tests need a grammar — cobDoc runs them).
cob = mkCob pkgs cobSource ./Cargo.lock [ ] false // {
  withGrammars = extra: mkCob pkgs cobSource ./Cargo.lock extra false;
};
# The standalone single static binary (embedded KaTeX), also shipped empty; it
# carries the same `withGrammars` so a static build can add grammars too.
static = mkCobStatic pkgs cobSource ./Cargo.lock [ ] // {
  withGrammars = extra: mkCobStatic pkgs cobSource ./Cargo.lock extra;
};
# tree-sitter-cob, tangled then run through `tree-sitter generate` so it has its
# src/parser.c. It is a cob grammar like any other, so cob can color a .cob shown
# as code (§5.5), and the treesitter check parses the whole corpus with it.
treeSitterCob = pkgs.runCommand "tree-sitter-cob"
  { nativeBuildInputs = [ pkgs.tree-sitter pkgs.nodejs ]; } ''
  cp -r ${cobSource}/tree-sitter-cob $out
  chmod -R +w $out
          export HOME=$TMPDIR
  cd $out && tree-sitter generate
'';
# The development output: cob with the grammars cobito needs to weave its own
# documents — Rust, Nix, Bash, CSS, and cob itself (§5.5). The flake's checks
# weave and highlight cob's own sources, so they use this build; it also runs the
# hermetic cargo tests, which need a grammar present. `nix build .#cobDoc`
# rebuilds cobito's own site with highlighting.
cobDoc = mkCob pkgs cobSource ./Cargo.lock
  (cobGrammars ++ [{ id = "cob"; exts = [ "cob" ]; src = treeSitterCob; symbol = "tree_sitter_cob"; }])
  true;
@
Stage 1 tangles each literate source again with \code{cob} itself. Each root chunk
names its target file (\code{src/main.rs}, \code{templates/cob.css}), so \code{--out .} writes
each tangled file into place. \code{cob tangle} enumerates every root of a file, so
\code{templates/cob.css.cob} yields both the sheet and its palette from one call. This
runs no noweb — cob's tangler is native (§11).
<<the tangled source tree>>=
# Stage 1 tangles every .cob with cob (natively, no noweb), so the shipped
# binary compiles from a tree cob itself made (§13). templates/cob.css is
# include_str!'d into the weaver, so it and its palette are tangled here too.
# build.rs is the grammar build script (§5.5); it tangles to the repo root.
cobSource = pkgs.runCommand "cob-src" { } ''
  cp -r ${self} $out
  chmod -R +w $out
  cd $out
  for nw in src/*.rs.cob templates/cob.css.cob build.rs.cob tree-sitter-cob/tree-sitter-cob.cob; do
    ${cobBootstrap}/bin/cob tangle "$nw" --out .
  done
'';
@
## The tangled flake, as an output {#sec:3OSt}

This output makes the dogfood loop a file that you can build. \code{nix build .#flake}
tangles \code{flake.nix.cob} with the new \code{cob} binary. It makes the same \code{flake.nix}
that built this output. The loop is not circular. The build needs \code{cob}, and
\code{cob} needs the committed \code{flake.nix} as its permanent bootstrap (§13).
\code{checks.dogfood} compares the committed file with this output.

<<the tangled flake output>>=
# `nix build .#flake` re-tangles flake.nix.cob and emits the flake.nix this
# very output was built from — the dogfood loop as a buildable artifact
# (§13). checks.dogfood diffs the committed file against this.
flake = pkgs.runCommand "flake.nix" { } ''
  cd ${self}
  ${cob}/bin/cob tangle flake.nix.cob --out $TMPDIR
  cp $TMPDIR/flake.nix $out
'';
@
## The dev shell {#sec:zQ5K}

The dev shell has the Rust toolchain, and no noweb — cob needs none. It sets
\code{COB_KATEX_ASSETS} the same as the package wrapper, so \code{cargo run} in \code{nix
develop} behaves like the installed binary.

On \code{main} no \code{.rs} or \code{.css} is committed, so a fresh checkout has nothing for
\code{cargo} to build. The shell hook seeds the generated tree from the pinned
\code{tangled} snapshot (\code{seed}) once, if \code{src/main.rs} is absent. That is enough to
build \code{cob}; after that, edit the \code{.cob} and re-tangle with \code{cob tangle} to refresh
from the current sources.
<<the dev shell>>=
default = pkgs.mkShell {
  packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer ];
  shellHook = ''
    export COB_KATEX_ASSETS="${katexAssets pkgs}"
    # build.rs reads this to compile the grammars into cob (§5.5); without it a
    # cargo build highlights nothing.
    export COB_GRAMMARS="${grammarManifest pkgs cobGrammars}"
    # On `main` the .rs/.css are generated and gitignored (§13). Seed them from
    # the pinned tangled snapshot so cargo has something to build; then
    # `cob tangle` refreshes from the current .cob.
    if [ ! -f src/main.rs ]; then
      echo "cob: seeding generated .rs/.css from the tangled snapshot; run 'cob tangle' to refresh"
      cp ${seed}/src/*.rs src/
      cp ${seed}/templates/cob.css ${seed}/templates/cob-syntax.css templates/
    fi
  '';
};
@
The \code{dist} dev shell is simpler: on the \code{tangled} branch the \code{.rs}/\code{.css} are
tracked, so there is nothing to seed. It gives the same toolchain and KaTeX assets,
for anyone who wants to build or hack the snapshot directly.
<<the dist dev shell>>=
default = pkgs.mkShell {
  packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer ];
  shellHook = ''
    export COB_KATEX_ASSETS="${katexAssets pkgs}"
    export COB_GRAMMARS="${grammarManifest pkgs cobGrammars}"
  '';
};
@
## The checks {#sec:P3N3}

\code{nix flake check} runs the full test set of cob. Each check is an independent
derivation. Together the checks guard the build, byte-determinism, the frozen
label lock, the tangle goldens, and the native reader against its frozen
\code{markup} goldens. No check runs noweb — the goldens are the oracle now.
<<the checks>>=
<<the build check>>

<<the determinism check>>

<<the lock check>>

<<the section-anchor check>>

<<the tangle check>>

<<the untangle check>>

<<the reader check>>

<<the dogfood check>>

<<the selfhost check>>

<<the modules check>>

<<the macros check>>

<<the imports check>>

<<the fetch check>>

<<the cite check>>

<<the backlinks check>>

<<the treesitter check>>
@
### build {#sec:9hJs}

These are the cheapest checks, each one Nix expression, not a shell script.
\code{build} compiles the **shipped** cob, which has an empty grammar registry (§5.5) —
so it proves the language-agnostic binary builds with no grammar at all. \code{tests}
compiles \code{cobDoc}, the grammar-ful development build, which runs the hermetic cargo
tests; the highlighting tests need a grammar, so they run here, not on the empty
build.
<<the build check>>=
# The shipped cob builds with an empty grammar registry (§5.5).
build = self.packages.${system}.cob;
# The grammar-ful development build runs the hermetic cargo tests.
tests = self.packages.${system}.cobDoc;
@
### determinism {#sec:dNbo}

This is the most important check. It weaves several documents two times each and
compares the bytes. The JSON contract of §8 and the archival goal both need this
property. The read-only Nix sandbox makes each weave use \code{--locked}. This also
shows that the frozen float ids stay the same across runs.

The Nix wrapper is short. It names the derivation and hands the whole test to one
Bash chunk. The Bash chunk sets up the shell and then calls one chunk for each
group of assertions. Each group has its own prose below.
<<the determinism check>>=
# Weave twice, compare bytes. Determinism is the property §8's JSON
# contract and the archival goal both rest on. The book fixture also
# exercises M2: page splitting, cross-page refs, and numbering.
determinism = pkgs.runCommand "cob-determinism" { } ''
  <<determinism script>>
'';
@
The script sets the \code{cob} path once and then runs each assertion group in order.
A \code{touch} of the output at the end tells Nix that the check passed.
<<determinism script>>=
cd ${self}
cob=${self.packages.${system}.cobDoc}/bin/cob
<<weave the book fixture, twice>>
<<assert the opaque-id scheme>>
<<assert the archival contract>>
<<assert the markdown dialect>>
<<assert syntax highlighting>>
<<assert transclusion>>
<<assert float nodes>>
touch $out
@
This group is the core determinism act. It weaves the book fixture two times with
\code{--archive} and diffs the two trees. \code{--archive} brings \code{site.json} and the
per-page JSON into the diff. The group also confirms that the KaTeX assets are
present.
<<weave the book fixture, twice>>=
# The Nix sandbox is read-only, so every weave runs `--locked`: it reads
# the committed cob.lock and never mints (§7.1). This also proves the
# frozen ids are stable across runs — the whole point of the lock.
# --archive brings site.json + per-page JSON under the byte-diff too,
# which is the whole point of §8's determinism requirement.
$cob weave --locked --archive fixtures/book.cob --out $TMPDIR/a
$cob weave --locked --archive fixtures/book.cob --out $TMPDIR/b
diff -r $TMPDIR/a $TMPDIR/b
test -s $TMPDIR/a/katex/katex.min.css
grep -q 'katex-mathml' $TMPDIR/a/parsing.html
@
This group checks the opaque-id scheme of §7.1. The book splits into three pages
at its h1 headings. A cross-page reference points at the target page and anchor.
A float and a labelled section each carry a four-character base62 id, never a
sequential number.
<<assert the opaque-id scheme>>=
# §5.3 split at h1: three source headings ⇒ three pages.
test -f $TMPDIR/a/index.html
test -f $TMPDIR/a/parsing.html
test -f $TMPDIR/a/codegen.html
# §7 cross-page reference resolves to the target page and anchor.
grep -q 'href="parsing.html#fig-pipeline"' $TMPDIR/a/index.html
# §7.1 the float carries its frozen opaque id (four base62 chars), never
# a sequential number, and the cross-page ref text is "Figure <id>".
grep -qE '<figure id="fig-pipeline" data-id="[0-9A-Za-z]{4}">' $TMPDIR/a/parsing.html
grep -qE 'href="parsing.html#fig-pipeline">Figure [0-9A-Za-z]{4}</a>' $TMPDIR/a/index.html
# §7.1 a labelled *section* joins the opaque-id scheme: its heading
# leads with a clickable permalink whose four-char id lives in data-id
# (drawn by CSS, never text), and a cross-page \ref renders "Section
# <id>" pointing at the section anchor.
grep -qE '<h2 id="sec-lexing"><a class="sec-uid" href="#sec-lexing" data-id="[0-9A-Za-z]{4}"></a>' $TMPDIR/a/parsing.html
grep -qE 'href="parsing.html#sec-lexing">Section [0-9A-Za-z]{4}</a>' $TMPDIR/a/codegen.html
if grep -q 'data-number' $TMPDIR/a/parsing.html; then
  echo "float still carries a sequential data-number; §7.1 wants an opaque id" >&2
  exit 1
fi
@
This group checks the archival contract. The \emph{content} must need no JavaScript
(§6.3): a page may carry only the inline \code{nav-spy} navigation aid, no other script
and no external \code{src}. Every content page carries that one aid. The \code{site.json}
must use the frozen schema, give one file per page, and hoist sidenotes out of the
prose into the margin (§8). The weaver must also emit one standalone \code{sitemap.html}
that lists the whole nav tree, and every page footer must link to it.
<<assert the archival contract>>=
# §6.3 the content needs no JavaScript: the only script a page may carry is
# the inline nav-spy aid — no math script, no external src.
for p in $TMPDIR/a/*.html; do
  if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
    echo "$p carries a script other than the nav-spy aid; math must render at weave time" >&2
    exit 1
  fi
  if grep -qE '<script[^>]*src=' "$p"; then
    echo "$p links an external script; the archive must stay self-contained" >&2
    exit 1
  fi
done
# The nav-spy aid is present on a content page (progressive enhancement).
grep -q '<script id="nav-spy">' $TMPDIR/a/index.html
# §8 site.json: frozen schema, one file per page, sidenotes hoisted
# out of prose into margin[] (no <aside> survives in the JSON bodies).
grep -q '"schema": 2' $TMPDIR/a/site.json
test -f $TMPDIR/a/index.json
test -f $TMPDIR/a/parsing.json
test -f $TMPDIR/a/codegen.json
grep -q '"kind": "sidenote"' $TMPDIR/a/site.json
if grep -q '<aside' $TMPDIR/a/site.json; then
  echo "site.json prose still contains <aside>; sidenotes not hoisted" >&2
  exit 1
fi
# The weaver emits one standalone sitemap page that lists the whole nav
# tree through the same hrefs, and every page footer links to it. The
# script loop above already proved no page carries a stray script.
test -f $TMPDIR/a/sitemap.html
grep -q 'href="parsing.html#sec-lexing">Lexing</a>' $TMPDIR/a/sitemap.html
grep -q 'href="sitemap.html"' $TMPDIR/a/index.html
# The syntax palette is imported by cob.css; both files must be in the output.
test -f $TMPDIR/a/cob-syntax.css
@
This group checks the Markdown dialect (§6.4). It weaves two Markdown documents
two times each and diffs them. It confirms that prose became HTML and that the
fenced float directives made a table, an equation, and a figure, each with its
own opaque id.
<<assert the markdown dialect>>=
# §6.4 Markdown dialect: ring.cob is authored in CommonMark (the default
# dialect, so no cob.toml needed). Weave twice, byte-diff, and confirm
# prose actually became HTML rather than passing through literally.
$cob weave --locked examples/ring.cob --out $TMPDIR/md-a
$cob weave --locked examples/ring.cob --out $TMPDIR/md-b
diff -r $TMPDIR/md-a $TMPDIR/md-b
grep -q '<p>' $TMPDIR/md-a/index.html
grep -q 'class="equation"' $TMPDIR/md-a/index.html
# Fenced floats: a ```table``` fence became a <table> carrying its opaque
# id, the ```math``` fence a labelled equation, and every \ref{…}
# resolved to the float's anchor (§6.4/§7.1).
grep -qE '<table id="tbl-api" data-id="[0-9A-Za-z]{4}">' $TMPDIR/md-a/index.html
grep -qE '<caption data-id="[0-9A-Za-z]{4}">' $TMPDIR/md-a/index.html
grep -qE 'id="eq-wrap" data-id="[0-9A-Za-z]{4}"' $TMPDIR/md-a/index.html
grep -q 'href="#eq-wrap"' $TMPDIR/md-a/index.html
grep -q 'href="#tbl-api"' $TMPDIR/md-a/index.html
if grep '<script' $TMPDIR/md-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "Markdown weave emitted a script other than the nav-spy aid; math must render at weave time" >&2
  exit 1
fi
# The md.cob fixture additionally exercises the ```figure``` fence: a real
# <figure> carrying its opaque id and its raw-HTML body passed through,
# deterministically.
$cob weave --locked fixtures/md.cob --out $TMPDIR/mdfx-a
$cob weave --locked fixtures/md.cob --out $TMPDIR/mdfx-b
diff -r $TMPDIR/mdfx-a $TMPDIR/mdfx-b
grep -qE '<figure id="fig-diagram" data-id="[0-9A-Za-z]{4}">' $TMPDIR/mdfx-a/index.html
grep -qE '<figcaption data-id="[0-9A-Za-z]{4}">' $TMPDIR/mdfx-a/index.html
# §10 taxa: a `\taxon{name}` directive stamps the next heading with data-taxon, the
# API the stylesheet and other tools read. The directive emits no text of its own.
tx=$TMPDIR/taxon
mkdir -p $tx
printf '# T\n\n> a quote\n\n\\taxon{theorem}\n## Pumping Lemma\n\nA fact.\\sidenote{a margin note}\n' > $tx/t.cob
( cd $tx && $cob lock t.cob >/dev/null && $cob weave --locked t.cob --out _site )
grep -qE '<h2 id="sec-[0-9A-Za-z]{4}" data-taxon="theorem">' $tx/_site/index.html
if grep -q 'taxon{' $tx/_site/index.html; then
  echo "the \\taxon directive leaked into the output as text" >&2
  exit 1
fi
# §6.4 a `>` line is a blockquote. A `\sidenote{…}` (§10) is a footnote: an
# inline marker where it is written, and the note at the foot of the page. The
# marker number is a CSS counter, so no digit enters the text.
grep -q '<blockquote>' $tx/_site/index.html
grep -qE '<sup class="fn-ref" id="fnref-[0-9]+"><a href="#sn-[0-9]+"></a></sup>' $tx/_site/index.html
grep -q '<section class="footnotes"' $tx/_site/index.html
grep -qE '<li id="sn-[0-9]+">a margin note' $tx/_site/index.html
if grep -q 'sidenote{' $tx/_site/index.html; then
  echo "the \\sidenote directive leaked into the output as text" >&2
  exit 1
fi
# §6.4 assets: a figure's referenced local image is copied into the site so the
# archive is self-contained; a weave copies only the assets it references.
as=$TMPDIR/assets
mkdir -p $as/pics
printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>' > $as/pics/d.svg
printf '# A\n\n```figure\n\\caption{A picture.}\n<img src="pics/d.svg">\n```\n' > $as/a.cob
( cd $as && $cob lock a.cob >/dev/null && $cob weave --locked a.cob --out _site )
test -f $as/_site/pics/d.svg
# An unreferenced sibling is not copied — only what a page uses.
printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>' > $as/pics/unused.svg
( cd $as && $cob weave --locked a.cob --out _site2 )
test ! -e $as/_site2/pics/unused.svg
# §6.6 custom fence: a `cob.toml`-registered CLI renders the body. A tiny shell
# handler (no heavy tool) echoes a figure, so the pipeline is exercised with only
# `sh` in the sandbox: the placeholder becomes a numbered float, `\ref` resolves,
# no `<cob-custom>` leaks, and two weaves are byte-identical.
cu=$TMPDIR/custom
mkdir -p $cu
cat > $cu/h.sh <<'HANDLER'
#!/bin/sh
cat >/dev/null
echo '{"html": "<figure id=\"fig:cu\">custom ok</figure>"}'
HANDLER
chmod +x $cu/h.sh
printf '[fence.demo]\ncmd = ["sh", "h.sh"]\n' > $cu/cob.toml
printf '# C\n\nSee \\ref{fig:cu}.\n\n```custom[demo] \\label{fig:cu}\n\\caption{A demo.}\nbody\n```\n' > $cu/c.cob
( cd $cu && $cob lock c.cob >/dev/null && $cob weave --locked c.cob --out _site && $cob weave --locked c.cob --out _site2 )
diff -r $cu/_site $cu/_site2
grep -q 'custom ok' $cu/_site/index.html
grep -qE '<figure id="fig-cu" data-id="[0-9A-Za-z]{4}">' $cu/_site/index.html
grep -qE 'href="#fig-cu">Figure [0-9A-Za-z]{4}</a>' $cu/_site/index.html
if grep -q 'cob-custom' $cu/_site/index.html; then
  echo "a custom fence placeholder leaked into the output" >&2
  exit 1
fi
# §5.2/§7 a book: the `[[document]] files` in cob.toml name the sources, so
# `cob lock` and `cob weave` need no file arguments. A `ch:`/`part:` label on a
# page heading makes the chapter a `\ref` target ("Chapter <id>", "Part <id>"),
# and `\ref{label}{text}` keeps the author's text. A page is not a node: no
# permalink prefix on the h1 and no `n/` directory.
bk=$TMPDIR/book
mkdir -p $bk
cat > $bk/cob.toml <<'MANIFEST'
[[document]]
id = "bk"
title = "Bk"
files = ["a.cob", "b.cob"]
MANIFEST
cat > $bk/a.cob <<'PAGE'
# Alpha {#part:a}

See \ref{ch:b} and \ref{ch:b}{the second chapter}.
PAGE
cat > $bk/b.cob <<'PAGE'
# Beta {#ch:b}

Back to \ref{part:a}.
PAGE
( cd $bk && $cob lock >/dev/null && $cob weave --locked --out _site )
grep -qE 'href="beta.html#beta">Chapter [0-9A-Za-z]{4}</a>' $bk/_site/index.html
grep -q 'href="beta.html#beta">the second chapter</a>' $bk/_site/index.html
grep -qE 'href="index.html#index">Part [0-9A-Za-z]{4}</a>' $bk/_site/beta.html
grep -q '<h1 id="beta">Beta' $bk/_site/beta.html
test ! -e $bk/_site/n
# §10 a `node[taxon]` fence is a node with an explicit extent: exactly the fence.
# It is a labelled section with a title paragraph (never a heading), it earns an
# opaque id, a typed ref ("Definition <id>"), and a node page, and the prose after
# the fence is in none of them.
nf=$TMPDIR/nodefence
mkdir -p $nf
cat > $nf/n.cob <<'PAGE'
# N

## Basics

```node[definition] \label{def:x}
\title{A thing}
A thing is an $x$.
```

After the definition.

See \ref{def:x}.
PAGE
( cd $nf && $cob lock n.cob >/dev/null && $cob weave --locked n.cob --out _site )
grep -qE '<section class="taxon-node" id="def-x" data-taxon="definition" data-id="[0-9A-Za-z]{4}">' $nf/_site/index.html
grep -qE '<p class="node-title" data-taxon="definition"><a class="sec-uid"' $nf/_site/index.html
grep -qE 'href="#def-x">Definition [0-9A-Za-z]{4}</a>' $nf/_site/index.html
# The node fence's own page is named by its opaque id. (The `## Basics` heading
# node has a page too, and it rightly holds the prose under the heading.)
nid=$(grep -oE 'id="def-x" data-taxon="definition" data-id="[0-9A-Za-z]{4}"' $nf/_site/index.html | grep -oE '[0-9A-Za-z]{4}"$' | tr -d '"')
test -f $nf/_site/n/$nid.html
grep -q 'A thing' $nf/_site/n/$nid.html
if grep -q 'After the definition' $nf/_site/n/$nid.html; then
  echo "a node fence's page holds the prose after the fence" >&2
  exit 1
fi
@
This group checks syntax highlighting (§5.5). The \code{hl.cob} fixture has a Rust root
and a Nix root. Each root pulls an abstract chunk in through a hole. The group
confirms that both grammars ran, that the chunk-use hole stays outside any color
span, and that the page carries no script but the nav-spy aid.
<<assert syntax highlighting>>=
# §5.5 syntax highlighting: hl.cob has a Rust root and a Nix root, each
# pulling an abstract chunk in through a hole. Weave twice, byte-diff,
# and confirm the coloring is deterministic and structurally sound.
$cob weave --locked fixtures/hl.cob --out $TMPDIR/hl-a
$cob weave --locked fixtures/hl.cob --out $TMPDIR/hl-b
diff -r $TMPDIR/hl-a $TMPDIR/hl-b
# Both grammars ran, on the whole tangled file in context (§5.5, #1): `fn`/`let`
# are Rust keywords, and the Nix flake's own string colors on the Nix side. The
# tokens are the *valid-source* classification — e.g. a Nix attrpath is a variable,
# where per-chunk highlighting of the hole-punched fragment used to mis-recover it.
grep -q 'class="tok-keyword">' $TMPDIR/hl-a/index.html
grep -q 'class="tok-string">&quot;a tiny flake&quot;' $TMPDIR/hl-a/index.html
grep -q 'class="tok-string">' $TMPDIR/hl-a/index.html
# The chunk-use hole is spliced back verbatim, still inside its `.line`,
# and is *never* wrapped in a color span (§5.4/§5.5).
grep -q '<a href="#sec-1">&lt;<i>greeting</i>&gt;</a>' $TMPDIR/hl-a/index.html
if grep -qE 'tok-[a-z]+">&lt;<i>' $TMPDIR/hl-a/index.html; then
  echo "a chunk-use hole was wrapped in a highlight span; §5.5 wants it opaque" >&2
  exit 1
fi
# Highlighting is pure CSS classes — the only script is the nav-spy aid.
if grep '<script' $TMPDIR/hl-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "highlighted weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
  exit 1
fi

# §5.5 #1 the proof that highlighting uses the tangled file, not the fragment: a
# Rust string opens in one chunk and its contents are a *used* chunk. Only
# whole-file tokenization knows that content is inside the literal; a per-chunk
# tokenizer reads it as bare identifiers. The doc is generated here rather than
# kept as a fixture because a chunk marker in this script would be read as a chunk
# of flake.nix.cob itself — so the angle-bracket pairs are built from octal escapes
# (\074 is a less-than, \076 a greater-than), which also dodge Nix string escaping.
span=$TMPDIR/span
mkdir -p $span
op=$(printf '\074\074')
cl=$(printf '\076\076')
printf '@ # span\n\n%sout.rs%s=\nlet s = "%sinner%s";\n@\n\n%sinner%s=\ninside the string\n@\n' \
  "$op" "$cl" "$op" "$cl" "$op" "$cl" > $span/t.cob
( cd $span && $cob lock t.cob >/dev/null && $cob weave --locked t.cob --out _site )
grep -q 'class="tok-string">inside the string' $span/_site/index.html
@
This group checks transclusion and the node model (§10). The \code{tx.cob} fixture puts
a title, an intro, and the source heading in one \code{@} chunk, then transcludes the
source into a later section. The group confirms that the copy is cut at the
markdown heading — so the shallower \code{h1} stays out and the page keeps one \code{h1} —
that the copy scopes its ids and links back to the canonical node, that the node
runs across the following code chunk, and that nothing but the nav-spy aid is a
script.
<<assert transclusion>>=
# §10 transclusion: tx.cob puts a title, an intro, and the source heading
# in one @ chunk, then transcludes the source into a later section. Weave
# twice, byte-diff, and confirm the node model and scoping are sound.
$cob weave --locked fixtures/tx.cob --out $TMPDIR/tx-a
$cob weave --locked fixtures/tx.cob --out $TMPDIR/tx-b
diff -r $TMPDIR/tx-a $TMPDIR/tx-b
# The directive lowers to a lazy <cob-transclude> pointing at the source's own
# n/ page, with a link fallback naming the heading — reachable with no JS (§10).
grep -q '<cob-transclude src="n/' $TMPDIR/tx-a/index.html
grep -q 'data-transclude="sec:source">' $TMPDIR/tx-a/index.html
grep -q 'The source &rarr;</a></cob-transclude>' $TMPDIR/tx-a/index.html
# No server-side copy: no spliced section, no scoped ids, no duplicated body.
if grep -q '<section class="transclusion" data-transclude=' $TMPDIR/tx-a/index.html; then
  echo "transclusion was spliced server-side; §10 wants a lazy element" >&2; exit 1
fi
if grep -q 'tx1-' $TMPDIR/tx-a/index.html; then
  echo "a scoped id leaked; shadow DOM isolates the copy (§10)" >&2; exit 1
fi
# Node extent is the markdown heading, not the @ chunk: the h1 that shares
# the source's chunk is NOT pulled in, so the page has one h1.
test "$(grep -oE '<h1[ >]' $TMPDIR/tx-a/index.html | wc -l)" -eq 1
# The body is not duplicated: one canonical id, one chunk body.
test "$(grep -oE 'id="sec-source"' $TMPDIR/tx-a/index.html | wc -l)" -eq 1
test "$(grep -oE 'class="chunk-body"' $TMPDIR/tx-a/index.html | wc -l)" -eq 1
# Transclusion duplicates finished HTML, so it adds no script: the only
# script a page may carry is the nav-spy aid (§6.3).
if grep '<script' $TMPDIR/tx-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "transcluded weave emitted a script other than the nav-spy aid" >&2
  exit 1
fi
# §10 node pages: every uid-bearing node earns a standalone page under n/.
# The two h2 nodes get a page; the h1 (no uid) does not.
test "$(ls $TMPDIR/tx-a/n/*.html | wc -l)" -eq 2
# The heading in context leads with a node-page link, drawn by CSS (no text).
grep -q 'class="node-link" href="n/' $TMPDIR/tx-a/index.html
# A node page carries the node body, a breadcrumb up to the document h1, and a
# "read in context" link to the canonical anchor — both one directory up. The
# source node is the one whose own context link points at sec-source.
src=$(grep -l 'href="../index.html#sec-source">Read in context' $TMPDIR/tx-a/n/*.html)
grep -q '<a href="../index.html">Transclusion fixture</a>' "$src"
grep -q 'Transcluded by' "$src"
# A node page is archival too: the only scripts are the nav-spy and cob-transclude
# aids, so a transclusion inside a node page lazy-loads and everything else holds.
for p in $TMPDIR/tx-a/n/*.html; do
  if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
    echo "a node page emitted a script other than the enhancement aids" >&2
    exit 1
  fi
done
@
A float is a node too (§10). The \code{txf.cob} fixture labels an equation and a figure,
then transcludes each into a later section. This group confirms that a labelled
float is cut from its section body by balancing its tag, gets its own page under
\code{n/}, links to that page in context, and can be transcluded on its own.
<<assert float nodes>>=
# §10 floats are nodes: txf.cob labels an equation and a figure, then
# transcludes each into a later section. Weave twice, byte-diff, and
# confirm a float is cut, paged, linked, and transcludable.
$cob weave --locked fixtures/txf.cob --out $TMPDIR/txf-a
$cob weave --locked fixtures/txf.cob --out $TMPDIR/txf-b
diff -r $TMPDIR/txf-a $TMPDIR/txf-b
# Two heading nodes and two float nodes each earn a standalone page under n/.
test "$(ls $TMPDIR/txf-a/n/*.html | wc -l)" -eq 4
# Each float is transcluded on its own as a lazy <cob-transclude> at its node
# page; no server-side splice, no scoped ids (§10).
grep -q 'data-transclude="fig:demo">' $TMPDIR/txf-a/index.html
grep -q 'data-transclude="eq:demo">' $TMPDIR/txf-a/index.html
grep -q '<cob-transclude src="n/' $TMPDIR/txf-a/index.html
if grep -q '<section class="transclusion" data-transclude=' $TMPDIR/txf-a/index.html; then
  echo "float transclusion was spliced; §10 wants a lazy element" >&2; exit 1
fi
if grep -q 'tx1-' $TMPDIR/txf-a/index.html; then
  echo "a scoped id leaked (§10)" >&2; exit 1
fi
# The canonical figure keeps its bare id; only one canonical figure exists.
test "$(grep -oE 'id="fig-demo"' $TMPDIR/txf-a/index.html | wc -l)" -eq 1
# In context, a float leads with a node-page link, drawn by CSS (no text). The
# figcaption carries one; so does the equation.
grep -qE '<figcaption[^>]*>.*<a class="node-link" href="n/' $TMPDIR/txf-a/index.html
grep -qE 'class="equation"[^>]*><a class="node-link" href="n/' $TMPDIR/txf-a/index.html
# The figure's node page carries the figure, a breadcrumb up to the document
# h1, a "read in context" link to the canonical anchor, and a "Transcluded by"
# backlink. Find it by the context link that points at fig-demo.
fig=$(grep -l 'href="../index.html#fig-demo">Read in context' $TMPDIR/txf-a/n/*.html)
grep -q '<a href="../index.html">Float transclusion fixture</a>' "$fig"
grep -q '<figure id="fig-demo"' "$fig"
grep -q 'Transcluded by' "$fig"
# A float node page is archival too: only the nav-spy and cob-transclude aids.
for p in $TMPDIR/txf-a/n/*.html; do
  if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
    echo "a float node page emitted a script other than the enhancement aids" >&2
    exit 1
  fi
done
@
### lock {#sec:Vv1B}

The committed \code{cob.lock} is the source of truth for the frozen id of each label.
This check tests the read-only CLI on top of the lock. The Nix wrapper hands the
work to one Bash chunk, which runs two assertion groups.
<<the lock check>>=
# §7.1 the committed cob.lock is the source of truth. If a float were
# added without running `cob lock` and committing the grown lock, a
# `--locked` weave would trip E031 — so a green `determinism` check above
# already proves the lock is complete. Here we exercise the read-only CLI
# surface: `cob id` returns a four-char base62 id, `cob labels` lists them.
lock = pkgs.runCommand "cob-lock" { } ''
  <<lock check script>>
'';
@
The script sets the \code{cob} path and runs the two groups.
<<lock check script>>=
cd ${self}
cob=${self.packages.${system}.cobDoc}/bin/cob
<<assert the frozen label lock>>
<<assert the language resolver>>
<<assert semantic tokens>>
touch $out
@
The semantic-token mapping (§5.5, #2) tokenizes the whole tangled file and maps the
tokens back onto the `.cob` buffer, through holes. On `hello.cob`, `let` on line 7
is a keyword at column 0, and the `;` after a chunk-use hole lands at the buffer
column past the hole, not the holes-removed column — the proof the reconstruction
accounts for the hole width.
<<assert semantic tokens>>=
# `cob tokens` prints whole-file semantic tokens in .cob buffer coordinates (#2).
# `let` opens line 7 as a keyword at column 0.
$cob tokens fixtures/hello.cob | grep -qx '7:0 3 keyword'
# The `;` after the chunk-use hole on line 7 is at buffer column 21 — holes
# removed it is at 8, so this proves the hole width is mapped back.
$cob tokens fixtures/hello.cob | grep -qx '7:21 1 operator'
@
This group tests the label side of the lock. \code{cob id} returns a four-character
id. \code{cob labels} lists each label with its kind. A \code{sec:}-labelled heading is a
first-class label. An unknown label gives a nonzero exit.
<<assert the frozen label lock>>=
$cob id fixtures/book.cob fig:pipeline | grep -qE '^[0-9A-Za-z]{4}$'
$cob labels examples/ring.cob | grep -qE '^eq:wrap\s+[0-9A-Za-z]{4}\s+Equation$'
# §7.1 a `sec:`-labelled heading is a first-class label: it has an id
# and lists with kind Section, exactly like a float.
$cob id fixtures/book.cob sec:lexing | grep -qE '^[0-9A-Za-z]{4}$'
$cob labels fixtures/book.cob | grep -qE '^sec:lexing\s+[0-9A-Za-z]{4}\s+Section$'
# An unknown label is a nonzero exit, not a silent empty line.
if $cob id fixtures/book.cob fig:nope; then
  echo "cob id returned success for a label not in the lock" >&2
  exit 1
fi
@
This group tests the highlighting resolver. \code{cob language} is the shared resolver
that the weaver and any editor plugin agree on (§5.5). A root resolves from its
own extension. An abstract chunk resolves from the root that reaches it. An
unknown chunk gives a nonzero exit, so a build can gate on it.
<<assert the language resolver>>=
# §5.5 `cob language` is the shared resolver: a root resolves from its
# own extension, an abstract chunk from the root that reaches it, and an
# unknown chunk is a nonzero exit (so a build can gate on it).
test "$($cob language fixtures/hl.cob src/demo.rs)" = rust
test "$($cob language fixtures/hl.cob flake.nix)" = nix
test "$($cob language fixtures/hl.cob greeting)" = rust
test "$($cob language fixtures/hl.cob packages)" = nix
if $cob language fixtures/hl.cob nope; then
  echo "cob language returned success for a chunk with no known language" >&2
  exit 1
fi
@
### section anchors {#sec:FT5y}

Every section earns an opaque id (§7.1). \code{cob lock} auto-anchors an unlabelled
\code{h2}/\code{h3}: it mints an id and writes a \code{{#sec:<id>}} anchor into the \code{.cob} source,
in place, so the id survives a later reword. \code{cob lock} writes to the source, so
this check first copies the fixture to a writable place — the Nix store is
read-only. It then proves the round trip: the source gets the anchor, the lock
gets a \code{Section} entry, the weave draws a permalink prefix, \code{cob rename-label}
gives the id a human name without changing the id, and a second \code{cob lock} mints
nothing.
<<the section-anchor check>>=
section-anchors = pkgs.runCommand "cob-section-anchors" { } ''
  <<section-anchor check script>>
'';
@
The script works on a writable copy of \code{sections.cob}, a Markdown-dialect fixture
with three unlabelled headings (two \code{h2}, one \code{h3}).
<<section-anchor check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
# `cob lock` edits the source in place, so work on a writable copy; the
# store path is read-only.
work=$TMPDIR/sec
mkdir -p $work
cp ${self}/fixtures/sections.cob $work/sections.cob
chmod u+w $work/sections.cob
cd $work

# The three headings start unlabelled. `cob lock` mints an id for each.
grep -qE '^## Lexing$' sections.cob
$cob lock sections.cob | grep -q '3 newly minted'

# §7.1 cob lock writes a {#sec:<id>} anchor into the source, in place …
grep -qE '^## Lexing \{#sec:[0-9A-Za-z]{4}\}$' sections.cob
grep -qE '^### Cost \{#sec:[0-9A-Za-z]{4}\}$' sections.cob
grep -qE '^## Parsing \{#sec:[0-9A-Za-z]{4}\}$' sections.cob
# … and a matching Section entry into the lock.
$cob labels sections.cob | grep -qE '^sec:[0-9A-Za-z]{4}\s+[0-9A-Za-z]{4}\s+Section$'

# The weave draws a clickable permalink prefix and a stable heading id.
$cob weave --locked sections.cob --out out
grep -qE '<h2 id="sec-[0-9A-Za-z]{4}"><a class="sec-uid" href="#sec-[0-9A-Za-z]{4}" data-id="[0-9A-Za-z]{4}">' out/index.html
# The only script the archival page carries is the nav-spy aid (§6.3).
if grep '<script' out/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "section weave emitted a script other than the nav-spy aid" >&2
  exit 1
fi

# §7.1 cob rename-label gives an auto id a human name; the id never changes.
label=$(grep -oE 'sec:[0-9A-Za-z]{4}' sections.cob | head -1)
id=$(printf '%s' "$label" | cut -c5-)
$cob rename-label $id lexing
grep -qE '^## Lexing \{#sec:lexing\}$' sections.cob
test "$($cob id sections.cob sec:lexing)" = "$id"
# The old auto label is gone: a rename moves the name, not the id.
if $cob id sections.cob $label; then
  echo "the old auto label survived a rename" >&2
  exit 1
fi

# A second lock is idempotent: an already-anchored heading is left alone.
$cob lock sections.cob | grep -q '0 newly minted'
touch $out
@
### tangle goldens {#sec:ATUX}

\code{cob tangle} must make the same bytes as the frozen \code{notangle} goldens in
\code{fixtures/tangled/} (§11). \code{--check} must be clean just after a tangle, and must
report drift after an edit. The goldens were made once by \code{notangle} and record
its behavior with no live noweb — the hermetic half of the two-tangler agreement
that seeded cob's own tangler. The Nix wrapper hands the work to one Bash chunk.
<<the tangle check>>=
# Tangle goldens (§11): `cob tangle` must byte-match the frozen notangle
# goldens in fixtures/tangled/, and `--check` must be clean after a tangle
# and flag drift after an edit. The goldens are the oracle now — no live
# noweb runs.
tangle = pkgs.runCommand "cob-tangle" { } ''
  <<tangle check script>>
'';
@
The script tangles every fixture that has goldens, diffs the output tree against
the committed goldens, and then edits an output to confirm that \code{--check}
reports the drift.
<<tangle check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
cd ${self}
# `cob tangle --out DIR` writes each root under DIR; fixtures/tangled/<stem>
# holds the frozen notangle output for the same roots. Diff the trees.
for stem in hello book hl md sections tx; do
  $cob tangle "fixtures/$stem.cob" --out "$TMPDIR/$stem"
  diff -r "$TMPDIR/$stem" "fixtures/tangled/$stem"
done
# Clean immediately after a tangle.
$cob tangle --check fixtures/hello.cob --out $TMPDIR/hello
# An edited root must be reported as drift (nonzero exit).
echo '// drift' >> $TMPDIR/hello/src/main.rs
if $cob tangle --check fixtures/hello.cob --out $TMPDIR/hello; then
  echo "--check passed despite an edited root" >&2
  exit 1
fi
<<assert the source map>>
touch $out
@
The source map (§11, #3) turns a line in a tangled file back into its `.cob`
source. `fn main() {` is the root's first body line; the lines inside the
`@<<lex a token@>>` expansion map to that chunk, at its own source lines, not to
the use site. A line past the end is a nonzero exit, so a build can rely on it.
<<assert the source map>>=
# `cob where` maps a tangled line back to the .cob line that wrote it (#3). The
# root's own first body line, then lines from an expanded chunk map to that chunk.
test "$($cob where fixtures/hello.cob src/main.rs 1)" = 'fixtures/hello.cob:29 (chunk src/main.rs)'
test "$($cob where fixtures/hello.cob src/main.rs 4)" = 'fixtures/hello.cob:7 (chunk lex a token)'
test "$($cob where fixtures/hello.cob src/main.rs 5)" = 'fixtures/hello.cob:8 (chunk lex a token)'
# A line past the end of the tangled file is a nonzero exit.
if $cob where fixtures/hello.cob src/main.rs 999; then
  echo "cob where accepted a line past the end" >&2
  exit 1
fi
@
### untangle {#sec:untangle}

The untangle check (§11, #2/D) proves the round trip: an edit to a tangled file
becomes a `.cob` patch that, applied, re-tangles to the same edit. It also proves a
structural edit (a new line) is a reported conflict, not a silent, wrong patch. It
needs `git` to apply the patch.
<<the untangle check>>=
untangle = pkgs.runCommand "cob-untangle" { nativeBuildInputs = [ pkgs.git ]; } ''
  <<untangle check script>>
'';
@
The script works on a writable copy: tangle `hello.cob`, edit one non-hole line of
the tangled output, untangle to a patch, apply it, and re-tangle to confirm the
edit round-trips. Then it appends a line and checks that untangle reports the
structural change instead of patching it.
<<untangle check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
work=$TMPDIR/ut
mkdir -p $work
cp ${self}/fixtures/hello.cob $work/hello.cob
cd $work
$cob tangle hello.cob --out .
# An in-place edit to a non-hole line maps back to a .cob patch.
sed -i 's|    tokens.push(c);|    tokens.push(c); // edited|' src/main.rs
$cob untangle hello.cob > patch.diff
grep -q '^+tokens.push(c); // edited' patch.diff
# The patch applies, and a re-tangle reproduces the edit — the round trip.
git apply patch.diff
grep -q '^tokens.push(c); // edited' hello.cob
$cob tangle hello.cob --out out
grep -q '    tokens.push(c); // edited' out/src/main.rs
# A structural edit (an added line) is a reported conflict, not a silent patch.
printf '// added\n' >> out/src/main.rs
$cob untangle hello.cob --out out 2> conflicts.txt > structural.diff
grep -q 'lines added or removed' conflicts.txt
test ! -s structural.diff
touch $out
@
### reader {#sec:c8DE}

This check guards the native reader (§4.1). The reader makes the \code{markup} event
stream in Rust, so cob reads its own source with no noweb process. The check runs
the native reader over each fixture and diffs its events against the frozen
\code{markup} golden for that fixture — \code{cob dump-ir <file>.cob} against \code{cob dump-ir
--from-markup <file>.markup}, which parses the committed IR. The two must be
identical for the noweb-era subset (a docs line, chunk uses, `%def`, indentation).
The reader departs from noweb on `[[…]]`, which noweb quotes but cob reads as plain
text (§6.4 uses \code{\code{…}}), so no fixture uses it. The crate, \code{cobito.cob},
and the flake are read by the \code{selfhost} and \code{dogfood} checks, so a reader
break there fails those too.
<<the reader check>>=
# Reader differential (§4.1): the native reader (`cob dump-ir`) must make
# the same events as the frozen `markup` golden (`cob dump-ir --from-markup`
# over the committed .markup). Hermetic — no live noweb.
reader = pkgs.runCommand "cob-reader" { } ''
  <<reader script>>
'';
@
The script walks every fixture and diffs the native reader against the frozen
\code{markup} golden.
<<reader script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
cd ${self}
for nw in fixtures/*.cob; do
  $cob dump-ir "$nw" > "$TMPDIR/reader"
  $cob dump-ir --from-markup "''${nw%.cob}.markup" > "$TMPDIR/golden"
  if ! diff -u "$TMPDIR/golden" "$TMPDIR/reader"; then
    echo "reader diverged from the frozen markup golden for $nw" >&2
    exit 1
  fi
done
touch $out
@
### dogfood {#sec:NJXp}

This check closes the loop. \code{flake.nix.cob}, this page, is the flake as a literate
program. \code{packages.flake} is the tangled output of this page. The Nix wrapper
hands the work to one Bash chunk, which runs two groups.
<<the dogfood check>>=
# Dogfood (§13): flake.nix.cob is this flake told as a literate program, and
# packages.flake is `cob tangle flake.nix.cob` as a buildable output. The
# committed flake.nix must equal it, or the self-host loop has drifted.
dogfood = pkgs.runCommand "cob-dogfood" { } ''
  <<dogfood script>>
'';
@
The script sets the \code{cob} path and runs the two groups.
<<dogfood script>>=
cd ${self}
cob=${self.packages.${system}.cobDoc}/bin/cob
<<assert the flake round-trips>>
<<assert cob highlights its own nix>>
touch $out
@
This group closes the tangle loop. The committed \code{flake.nix} must equal the
tangled output. It then weaves this page two times and diffs the result, so the
page is deterministic.
<<assert the flake round-trips>>=
# The committed flake.nix must be exactly the tangled output.
diff ${self}/flake.nix ${self.packages.${system}.flake}
# Weave the literate flake twice, byte-diff: the page is deterministic.
$cob weave --locked flake.nix.cob --out $TMPDIR/df-a
$cob weave --locked flake.nix.cob --out $TMPDIR/df-b
diff -r $TMPDIR/df-a $TMPDIR/df-b
@
This group confirms that cob gives color to its own Nix. The Nix grammar colors
an attribute path as a property and \code{let} as a keyword. A chunk-use hole stays
inside its \code{.line} and never gets a color span. The page carries no script but the nav-spy aid.
<<assert cob highlights its own nix>>=
# The Nix grammar coloured the page — an attribute path is a property and
# `let` is a keyword — so cob self-hosts its own highlighter (§5.5).
grep -q 'class="tok-property">' $TMPDIR/df-a/index.html
grep -q 'class="tok-keyword">' $TMPDIR/df-a/index.html
# A chunk-use hole is spliced back inside its `.line`, never coloured.
grep -qE '<span class="line" data-line="[0-9]+">[^<]*<a href="#[^"]*">&lt;<i>' $TMPDIR/df-a/index.html
if grep -qE 'tok-[a-z]+">&lt;<i>' $TMPDIR/df-a/index.html; then
  echo "a chunk-use hole was wrapped in a highlight span; §5.5 wants it opaque" >&2
  exit 1
fi
# Pure CSS coloring: the only script here is the nav-spy aid too.
if grep '<script' $TMPDIR/df-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "dogfood weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
  exit 1
fi
@
### self-host {#sec:mxHP}

This check closes the self-host loop for the crate (§13). Each \code{src/*.rs.cob} is
one module of cob, and \code{templates/cob.css.cob} is its stylesheet, each told as a
literate program. \code{cob} is compiled from \code{cobSource}, the tree stage 0 tangled.
This check tangles every module again with the shipped \code{cob} and diffs against
\code{cobSource} — the very tree \code{cob} was built from. If they match, \code{cob} is a fixed
point of its own tangler: the source it makes is the source it is made of. A
tangler change on \code{main} that the seed has not caught up to shows here as drift,
which is the signal to cut a new release. The Nix wrapper hands the work to one
Bash chunk.
<<the selfhost check>>=
# Self-host (§13): the shipped cob must tangle every module to the same bytes
# as cobSource, the tree it was compiled from. A fixed point of its own
# tangler — no second tangler, no noweb.
selfhost = pkgs.runCommand "cob-selfhost" { } ''
  <<selfhost script>>
'';
@
The script tangles every module with \code{cob} and diffs against \code{cobSource}, then
weaves two modules to prove that cob also colors its own source — one Rust
module for the crate, and the stylesheet itself, which exercises the CSS grammar
(the fourth grammar, and the reason it exists).
<<selfhost script>>=
cd ${self}
cob=${self.packages.${system}.cobDoc}/bin/cob
src=${self.packages.${system}.cobSource}
# cob must reproduce cobSource — the tree it was compiled from. Each src/*.rs.cob
# has one root named for its target; templates/cob.css.cob has two.
for nw in src/*.rs.cob; do
  root="''${nw%.cob}"
  $cob tangle -R "$root" "$nw" > $TMPDIR/lt
  diff "$src/$root" $TMPDIR/lt
done
for root in templates/cob.css templates/cob-syntax.css; do
  $cob tangle -R "$root" templates/cob.css.cob > $TMPDIR/lt
  diff "$src/$root" $TMPDIR/lt
done
# Weave one Rust module to prove cob renders its own source: keywords and
# strings colour, and the page carries no script but the nav-spy aid (§5.5/§6.3).
$cob weave --locked src/diag.rs.cob --out $TMPDIR/sh
grep -q 'class="tok-keyword">' $TMPDIR/sh/index.html
grep -q 'class="tok-string">' $TMPDIR/sh/index.html
# Weave the stylesheet to prove cob colours its own CSS: a property name is a
# tok token, and the page carries no script but the nav-spy aid.
$cob weave --locked templates/cob.css.cob --out $TMPDIR/shcss
grep -q 'class="tok-property">' $TMPDIR/shcss/index.html
for page in $TMPDIR/sh $TMPDIR/shcss; do
  if grep '<script' "$page"/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
    echo "self-host weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
    exit 1
  fi
done
touch $out
@
### modules {#sec:5DHH}

Every crate module is itself a literate document, so the whole crate reads as one
book (§13). This check weaves each \code{src/*.rs.cob} under \code{--locked} and fails if
any does not render — a guard against a module's prose drifting into a construct
the dialect rejects (a bad fence, a bare brace, an unlocked label). The archival
no-script rule (§6.3) holds for every module page too.
<<the modules check>>=
# Every module weaves on its own (§13), so the crate is one literate book. Guards
# against prose that the dialect rejects (bad fence, bare brace, unlocked label).
modules = pkgs.runCommand "cob-modules" { } ''
  cd ${self}
  cob=${self.packages.${system}.cobDoc}/bin/cob
  for m in src/*.rs.cob; do
    if ! $cob weave --locked "$m" --out $TMPDIR/m 2>$TMPDIR/err; then
      echo "module does not weave: $m" >&2; cat $TMPDIR/err >&2; exit 1
    fi
    if grep '<script' $TMPDIR/m/*.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
      echo "$m wove a script other than the nav-spy aid (§6.3)" >&2; exit 1
    fi
  done
  touch $out
'';
@
### macros {#sec:1XOf}

The \code{macros} fence (§6.4) defines KaTeX macros and shows them as a \code{def:} node
(§10). This check writes a small document, mints the \code{def:} id with \code{cob lock},
then weaves it twice under \code{--locked}. It proves the macros expand, the node is
homeless (no in-flow anchor), the node has an \code{n/} page a \code{\ref} points at, and
a \code{\transclude} splices a copy — all deterministic and with no script.
<<the macros check>>=
macros = pkgs.runCommand "cob-macros" { } ''
  <<macros check script>>
'';
@
<<macros check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
work=$TMPDIR/mac
mkdir -p $work
cd $work
cat > mac.cob <<'DOC'
# Macros demo

## Notation

```macros \label{def:basics}
We write $\RR$ for the reals and $\abs{x}$ for the absolute value.

\def\RR{\mathbb{R}}
\def\abs[x]{\lvert \x \rvert}
\let\R=\RR
```

The line is $\RR$, also $\R$; and $\abs{\RR}$. See \ref{def:basics}.

## Later

\transclude{def:basics}
DOC
# A macros fence is a node, so `cob lock` mints its def: id.
$cob lock mac.cob | grep -q 'newly minted'
$cob labels mac.cob | grep -qE '^def:basics[[:space:]]+[0-9A-Za-z]{4}[[:space:]]+Notation$'

# Weave twice, byte-diff: the macros path is deterministic. --archive also emits
# the forest index, so the diff proves it is deterministic too.
$cob weave --locked --archive mac.cob --out a
$cob weave --locked --archive mac.cob --out b
diff -r a b

# §13 the forest index: `cob-exports.json` exports the macro table so another forest can
# `\import` it — name → expansion, including the parametered macro (as KaTeX #1).
grep -q '"schema": "1.2.0"' a/cob-exports.json
grep -q '"\\\\RR": "\\\\mathbb{R}"' a/cob-exports.json
grep -q '"\\\\abs": "\\\\lvert #1 \\\\rvert"' a/cob-exports.json

# The macros expand everywhere: `\RR`/`\R` and the parametered `\abs{…}` render,
# so KaTeX output is present. An unknown macro would be a hard E020 and fail the
# weave.
grep -q 'katex' a/index.html
# Modularity guard (§6.4): a macro goes through KaTeX's `macros` option, never
# prepended to a formula, so no formula's copy-paste annotation carries a `\def`
# or the translated `#1` form. This is the leak we must not reintroduce.
if grep -qE 'application/x-tex">[^<]*\\\\def' a/index.html; then
  echo "a \\def leaked into a formula annotation; macros must use KaTeX's macros option (§6.4)" >&2
  exit 1
fi

# The node is homeless (§10): no canonical `def-` anchor is left in the flow.
if grep -qE 'id="def-[0-9A-Za-z]{4}"' a/index.html; then
  echo "the macros node kept an in-flow anchor; it must be homeless (§10)" >&2
  exit 1
fi
# It has its own page, and a \ref points there, not at a dead fragment. Take the
# node from the \ref (the data-ref link), not a bare n/ link — a section link and
# the transclusion fallback also point into n/.
grep -qE '<a data-ref="def:basics" href="n/[0-9A-Za-z]{4}\.html">Notation [0-9A-Za-z]{4}</a>' a/index.html
node=$(grep -oE 'data-ref="def:basics" href="n/[0-9A-Za-z]{4}\.html"' a/index.html | grep -oE 'n/[0-9A-Za-z]{4}\.html')
test -f "a/$node"
# The node page shows the exposition: the author's prose (macros in scope) and the
# definitions verbatim as a code block — the source, not typeset (§6.4).
grep -q 'We write' "a/$node"
grep -q 'class="macro-src"' "a/$node"
grep -qF '\def\abs[x]{\lvert \x \rvert}' "a/$node"
if grep -q 'macro-def' "a/$node"; then
  echo "a \\def/\\let line was typeset; §6.4 shows the source, not name := expansion" >&2
  exit 1
fi
# `\transclude{def:basics}` splices a scoped copy into the flow.
grep -q 'data-transclude="def:basics"' a/index.html

# The archival page carries no script but the nav-spy aid (§6.3).
if grep '<script' a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude|cob-backlinks)"'; then
  echo "macros weave emitted a script other than the nav-spy aid" >&2
  exit 1
fi
touch $out
@
### imports {#sec:voGO}

One forest imports another's macros and references its nodes (§13). This check
weaves a producer forest that exports a \code{cob-exports.json}, then a consumer that
declares \code{[import.algebra]} in \code{cob.toml}, imports it with \code{\import algebra as
alg}, and uses \code{\alg.RR} and \code{\alg.abs{x}}. The consumer also makes a
cross-document \code{\ref{sec:conv@alg}} and a \code{\transclude{def:basics@alg}}. It
proves the imported macros resolve and render, the cross-document reference lands
on the producer's deployed page, the cross-document transclusion points at the
producer's node page, and no definition leaks into a formula's annotation.
<<the imports check>>=
imports = pkgs.runCommand "cob-imports" { } ''
  <<imports check script>>
'';
@
<<imports check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
work=$TMPDIR/imp
mkdir -p $work/alg $work/topo

# The producer forest exports \RR and a parametered \abs, and gives its Notation
# section a stable label so a cross-document \ref can name it.
cat > $work/alg/algebra.cob <<'DOC'
# Algebra

## Notation {#sec:conv}

```macros \label{def:basics}
\def\RR{\mathbb{R}}
\def\abs[x]{\lvert \x \rvert}
```
DOC
( cd $work/alg && $cob lock algebra.cob >/dev/null && $cob weave --locked --archive algebra.cob --out _site )
# cob-exports.json carries the exported macro table and the label index.
grep -q '"\\\\RR": "\\\\mathbb{R}"' $work/alg/_site/cob-exports.json
grep -q '"sec:conv"' $work/alg/_site/cob-exports.json
grep -q '"def:basics"' $work/alg/_site/cob-exports.json

# The consumer declares the import in cob.toml, with the producer's deployed url so
# a cross-document reference makes a real link, and uses it under an alias.
cat > $work/topo/cob.toml <<DOC
[import.algebra]
path = "$work/alg/_site"
url = "https://alg.example"
DOC
cat > $work/topo/topo.cob <<'DOC'
# Topology

## Setup

```imports
\import algebra as alg
```

The reals are $\alg.RR$, and $\alg.abs{x}$ is the absolute value.

See the conventions in \ref{sec:conv@alg}.

\transclude{def:basics@alg}
DOC
( cd $work/topo && $cob lock topo.cob >/dev/null && $cob weave --locked topo.cob --out _site )

# The imported macros resolved and rendered — `\alg.RR`/`\alg.abs{x}` became KaTeX.
# An unresolved macro would be a hard E020 and fail the weave.
grep -q 'katex' $work/topo/_site/index.html

# §13 cross-document \ref: the reference lands on the producer's deployed page and
# anchor (the label `sec:conv` → anchor `sec-conv`), with the kind-qualified id text.
grep -q 'href="https://alg.example/index.html#sec-conv"' $work/topo/_site/index.html
# §13 cross-document \transclude: a lazy `<cob-transclude>` whose `src` is the
# producer's own node page, so the body stays stored once in the forest that owns it.
grep -q 'cob-transclude src="https://alg.example/n/' $work/topo/_site/index.html
# An import is a declaration, not content (§13): the `\import` line renders nothing
# in the body, but the import shows in the page chrome's "Imports" list.
if grep -q 'import algebra as alg' $work/topo/_site/index.html; then
  echo "an \\import line rendered in the body; it is a declaration (§13)" >&2
  exit 1
fi
grep -q 'class="doc-imports"' $work/topo/_site/index.html
# Modularity guard: no definition leaks into a formula annotation — the import is a
# content-id macro, not a prepended `\def` (§13).
if grep -qE 'application/x-tex">[^<]*\\\\def' $work/topo/_site/index.html; then
  echo "an imported \\def leaked into a formula annotation (§13)" >&2
  exit 1
fi
touch $out
@
### fetch {#sec:f8hV}

A remote import is pinned and cached by \code{cob fetch} (§13). This check proves the
whole path with no network: it makes a local git repo that publishes a
\code{cob-exports.json} at a tag (the committed-index convention), declares a \code{git} import
of it, runs \code{cob fetch}, and then weaves. It asserts the pin lands in \code{cob.lock},
the index is cached by commit, and a \code{git}-import weave resolves the macro and the
cross-document \code{\ref} offline from the cache. \code{git} builds the fixture; cob reads
it with \code{gix} over the pure-Rust \code{file://} transport, so the sandbox needs no
network.
<<the fetch check>>=
fetch = pkgs.runCommand "cob-fetch" { nativeBuildInputs = [ pkgs.git ]; } ''
  <<fetch check script>>
'';
@
<<fetch check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
export HOME=$TMPDIR
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
work=$TMPDIR/fetch
mkdir -p $work/consumer

# The remote forest: a git repo that publishes cob-exports.json at semver tags
# (§13). Two 1.x releases so a `^1` requirement resolves to the higher.
remote=$work/algebra.git
mkdir -p $remote && ( cd $remote && git init -q -b main )
pub() {
  cat > $remote/cob-exports.json <<DOC
{
  "schema": "$2",
  "macros": { "\\\\RR": "\\\\mathbb{R}" },
  "labels": { "sec:conv": { "page": "index", "anchor": "sec-conv", "kind": "section", "id": "qvcX" } }
}
DOC
  ( cd $remote && git add cob-exports.json && git commit -q --allow-empty -m "$1" && git tag "$1" )
}
pub v1.0.0 1.0.0
pub v1.1.0 1.0.0

# The consumer imports by a semver requirement, under an alias.
cat > $work/consumer/cob.toml <<DOC
[import.algebra]
git     = "file://$remote"
version = "^1.0"
url     = "https://alg.example"
DOC
cat > $work/consumer/doc.cob <<'DOC'
# Consumer

## Setup

```imports
\import algebra as alg
```

The reals are $\alg.RR$. See the conventions in \ref{sec:conv@alg}.
DOC

# cob fetch resolves ^1.0 to the highest matching release (1.1.0) and caches it —
# the one networked step.
( cd $work/consumer && $cob fetch )
grep -q '"fetch"' $work/consumer/cob.lock
grep -q '"req": "\^1.0"' $work/consumer/cob.lock
grep -q '"version": "1.1.0"' $work/consumer/cob.lock
# The index is cached, keyed by the resolved commit.
test -f $work/consumer/.cob-cache/imports/*/cob-exports.json
# A second fetch honors the lock and does not drift.
( cd $work/consumer && $cob fetch | grep -q 'up to date' )

# The weave reads only the cache — no git, no network — and resolves the import.
( cd $work/consumer && $cob lock doc.cob >/dev/null && $cob weave --locked doc.cob --out _site )
grep -q 'katex' $work/consumer/_site/index.html
grep -q 'href="https://alg.example/index.html#sec-conv"' $work/consumer/_site/index.html

# cob update re-resolves: a new 1.2.0 release moves the pin forward.
pub v1.2.0 1.0.0
( cd $work/consumer && $cob update )
grep -q '"version": "1.2.0"' $work/consumer/cob.lock

# An exports index with a newer major schema is rejected (E038). A 9.x tag
# publishes schema 2.0.0; requiring it must fail the fetch.
pub v9.0.0 2.0.0
sed -i 's/\^1.0/^9/' $work/consumer/cob.toml
if ( cd $work/consumer && $cob update ) 2>$work/err38; then
  echo "an exports index with a newer major schema must be rejected (§13 E038)" >&2
  exit 1
fi
grep -q 'E038' $work/err38
# Restore the 1.x requirement for the remaining checks.
sed -i 's/\^9/^1.0/' $work/consumer/cob.toml
( cd $work/consumer && $cob update >/dev/null )

# A weave with an unfetched git import is E037. Removing the pin + cache simulates it.
rm -rf $work/consumer/.cob-cache $work/consumer/cob.lock
if ( cd $work/consumer && $cob weave --locked doc.cob --out _site2 ) 2>$work/err; then
  echo "a weave with an unfetched git import must fail (§13 E037)" >&2
  exit 1
fi
grep -q 'E037' $work/err
touch $out
@
### cite {#sec:FnBe}

Citations (§14). This check weaves a document that cites a BibTeX bibliography. It
proves the inline marker is a CSS-drawn `[id]` (no citation text in a node), the
References list carries the formatted entries, the cited ids are stable and
deterministic across weaves, and an unknown key is E040. It also proves a cited
work is a node: it has a node page with the reference and a "Cited by" backlink,
\code{\transclude{cite:key}} inlines it, and the References entry links to that page.
Finally it proves cross-forest \code{\cite{key@alias}}: a producer exports its cited
works, and a consumer cites one, landing on the producer's deployed node page.
<<the cite check>>=
cite = pkgs.runCommand "cob-cite" { } ''
  <<cite check script>>
'';
@
<<cite check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
work=$TMPDIR/cite
mkdir -p $work

cat > $work/references.bib <<'DOC'
@article{smith2020,
  author  = {Jane Smith and John Doe},
  title   = {On the Nature of Things},
  journal = {Journal of Things},
  year    = {2020}
}
@book{knuth1984,
  author    = {Donald E. Knuth},
  title     = {The {\TeX}book},
  publisher = {Addison-Wesley},
  year      = {1984}
}
DOC
cat > $work/cob.toml <<'DOC'
[cite]
bib = "references.bib"
DOC
cat > $work/doc.cob <<'DOC'
# Citing

## Background

Typesetting is old \cite{knuth1984}. Things have a nature \cite{smith2020, knuth1984}.

## Elsewhere

The canonical reference, inlined:

\transclude{cite:knuth1984}
DOC

# `cob lock` mints the citation node ids (like any label); `--locked` then reads them.
( cd $work && $cob lock doc.cob >/dev/null )
grep -q '"cite:knuth1984"' $work/cob.lock
# Two locked weaves are byte-identical — the cited ids are frozen in the lock (§14).
( cd $work && $cob weave --locked doc.cob --out a >/dev/null && $cob weave --locked doc.cob --out b >/dev/null )
diff -r $work/a $work/b

# The inline marker is a CSS-drawn `[id]`: a `data-id` and a link to the References
# entry, with no citation text in a node (§14, §9.2).
grep -qE '<a class="cite" data-id="[^"]+" href="#cite-[^"]+"></a>' $work/a/index.html
# The same work cited twice reuses one id (stable identity, not a position): two
# cited works, so two distinct cite-marker ids.
ids=$(grep -oE '<a class="cite" data-id="[^"]+"' $work/a/index.html | sort -u | wc -l)
test "$ids" -eq 2
# The References list carries the formatted entries; `biblatex` renders the TeX.
grep -q 'class="doc-references"' $work/a/index.html
grep -q 'The TeXbook' $work/a/index.html
grep -q 'Journal of Things' $work/a/index.html
# No citation text leaked into a text node — only the CSS draws `[id]`.
if grep -qE 'class="cite"[^>]*>[^<]' $work/a/index.html; then
  echo "a citation marker carried text; the id must be drawn by CSS (§14)" >&2
  exit 1
fi

# §14 a cited work is a node: it has a node page `n/<id>.html` with the formatted
# reference and a "Cited by" backlink to the section that cites it.
knuth=$(grep -A1 '"cite:knuth1984"' $work/cob.lock | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')
test -n "$knuth"
test -f $work/a/n/$knuth.html
grep -q 'The TeXbook' $work/a/n/$knuth.html
grep -q 'Cited by' $work/a/n/$knuth.html
# \transclude{cite:knuth1984} lowers to a lazy element at the reference node page.
grep -q "cob-transclude src=\"n/$knuth.html\" data-transclude=\"cite:knuth1984\"" $work/a/index.html
# The References entry links to that node page.
grep -q "class=\"cite-uid\" href=\"n/$knuth.html\"" $work/a/index.html

# §14 cross-forest: a consumer cites a work the producer exported. The producer
# cites knuth1984 (so it earns a node page) and exports it in cob-exports.json.
prod=$work/prod
cons=$work/cons
mkdir -p $prod $cons
cp $work/references.bib $prod/references.bib
printf '[cite]\nbib = "references.bib"\n' > $prod/cob.toml
printf '# Producer\n\n## Refs\n\nFoundational \\cite{knuth1984}.\n' > $prod/doc.cob
( cd $prod && $cob lock doc.cob >/dev/null && $cob weave --archive doc.cob --out _site >/dev/null )
grep -q '"citations"' $prod/_site/cob-exports.json
grep -q '"knuth1984"' $prod/_site/cob-exports.json
cat > $cons/cob.toml <<DOC
[import.bibprod]
path = "$prod/_site"
url = "https://prod.example"
DOC
cat > $cons/doc.cob <<'DOC'
# Consumer

## Uses

```imports
\import bibprod as pub
```

As the classic text shows \cite{knuth1984@pub}.
DOC
( cd $cons && $cob lock doc.cob >/dev/null && $cob weave --locked doc.cob --out _site >/dev/null )
# The cross-forest marker is the producer's frozen `[id]`; the References entry
# links to the producer's deployed node page.
grep -qE '<a class="cite" data-id="[^"]+" href="#cite-[^"]+"></a>' $cons/_site/index.html
grep -q 'class="cite-uid" href="https://prod.example/n/' $cons/_site/index.html

# A cited key in no bibliography is E040.
printf '\nA ghost \\cite{nope}.\n' >> $work/doc.cob
if ( cd $work && $cob weave doc.cob --out _err ) 2>$work/e; then
  echo "a \\cite to an unknown key must fail (§14 E040)" >&2
  exit 1
fi
grep -q 'E040' $work/e
touch $out
@
### backlinks {#sec:CDt4}

Reverse backlinks (§16). A producer forest cites a work (so the work has a node
page); a consumer forest cites that same work cross-forest. Both weave with a
\code{[forest] url}, so each exports its identity and its outgoing edges. \code{cob
backlinks} over the two built sites inverts the edges and writes a fragment into the
producer: the producer's node now shows it is "Cited by" the consumer's node,
linking back to the consumer's deployed page. Proves the join-by-url inversion, the
fragment, and the lazy \code{<cob-backlinks>} element.
<<the backlinks check>>=
backlinks = pkgs.runCommand "cob-backlinks" { } ''
  <<backlinks check script>>
'';
@
<<backlinks check script>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
work=$TMPDIR/bl
prod=$work/prod
cons=$work/cons
mkdir -p $prod $cons

# The producer cites a work (so it earns a node page) and declares its own url.
cat > $prod/references.bib <<'DOC'
@book{knuth1984,
  author    = {Donald E. Knuth},
  title     = {The {\TeX}book},
  publisher = {Addison-Wesley},
  year      = {1984}
}
DOC
cat > $prod/cob.toml <<'DOC'
[cite]
bib = "references.bib"
[forest]
url = "https://prod.example"
DOC
printf '# Producer\n\n## Refs\n\nFoundational \\cite{knuth1984}.\n' > $prod/doc.cob
( cd $prod && $cob lock doc.cob >/dev/null && $cob weave --archive doc.cob --out _site >/dev/null )

# The consumer imports the producer and cites its work cross-forest.
cat > $cons/cob.toml <<DOC
[import.bibprod]
path = "$prod/_site"
url = "https://prod.example"
[forest]
url = "https://cons.example"
DOC
cat > $cons/doc.cob <<'DOC'
# Consumer

## Uses

```imports
\import bibprod as pub
```

As the classic text shows \cite{knuth1984@pub}.
DOC
( cd $cons && $cob lock doc.cob >/dev/null && $cob weave --archive doc.cob --out _site >/dev/null )
# The consumer exports its own url and the outgoing cite edge.
grep -q '"url": "https://cons.example"' $cons/_site/cob-exports.json
grep -q '"to_url": "https://prod.example"' $cons/_site/cob-exports.json

# Invert the forest's edges.
$cob backlinks $prod/_site $cons/_site

# The producer's cited node now has a reverse-backlink fragment pointing at the
# consumer's node, and its node page fetches it lazily. The target id is the
# consumer edge's `to_id` (the producer's cited node).
id=$(sed -n 's/.*"to_id": "\([^"]*\)".*/\1/p' $cons/_site/cob-exports.json | head -1)
test -n "$id"
test -f $prod/_site/n/$id.backlinks.html
grep -q '<h2>Cited by</h2>' $prod/_site/n/$id.backlinks.html
grep -q 'href="https://cons.example/n/' $prod/_site/n/$id.backlinks.html
grep -q "<cob-backlinks src=\"$id.backlinks.html\">" $prod/_site/n/$id.html
touch $out
@
### treesitter {#sec:treesitter}

This check guards the editor grammar (§5.5, Tier 1). `tree-sitter-cob` is the
grammar for `.cob` files. The check builds it and parses every `.cob` in the
repository, so a grammar change or a new source construct that the grammar cannot
read fails here. It also proves the web dogfood: cob carries `tree-sitter-cob` as a
grammar (the `cobDoc` build), so cob colors a `.cob` shown as code.
<<the treesitter check>>=
treesitter = pkgs.runCommand "cob-treesitter"
  { nativeBuildInputs = [ pkgs.tree-sitter pkgs.gcc ]; } ''
  <<treesitter check script>>
'';
@
The script builds the parser library where the tree-sitter CLI looks for it, then
parses every `.cob` from a copy of the grammar directory (so the CLI resolves the
`cob` grammar from the working directory, the same as a local run).
<<treesitter check script>>=
export HOME=$TMPDIR
ts=$HOME/tree-sitter-cob
cp -r ${self.packages.${system}.treeSitterCob} $ts
chmod -R +w $ts
# Build the parser lib where the CLI loads it from.
mkdir -p $HOME/.cache/tree-sitter/lib
cc -O2 -fPIC -std=c11 -I $ts/src -shared $ts/src/parser.c $ts/src/scanner.c \
  -o $HOME/.cache/tree-sitter/lib/cob.so
cd $ts
# Every .cob in the repo must parse with no ERROR or MISSING node.
for f in ${self}/fixtures/*.cob ${self}/*.cob ${self}/src/*.rs.cob ${self}/tree-sitter-cob/*.cob; do
  if tree-sitter parse -q "$f" 2>&1 | grep -qE 'ERROR|MISSING'; then
    echo "tree-sitter-cob could not parse $f cleanly:" >&2
    tree-sitter parse "$f" 2>&1 | grep -E 'ERROR|MISSING' | head -3 >&2
    exit 1
  fi
done
<<assert cob colors a .cob as code>>
touch $out
@
The web dogfood: cob carries `tree-sitter-cob` as one of its grammars (§5.5), so a
code chunk whose file is a `.cob` is colored by it. The chunk below shows a chunk
definition, which the grammar colors as a name — a `tok-function` in the weave.
<<assert cob colors a .cob as code>>=
cob=${self.packages.${system}.cobDoc}/bin/cob
# cobDoc knows the cob grammar: a .cob-rooted chunk resolves to "cob".
test "$($cob language ${self}/fixtures/hello.cob src/main.rs)" = rust
work=$TMPDIR/cob-as-code
mkdir -p $work
cd $work
# Show a .cob as code: the body is an escaped chunk-def line, so the cob grammar
# colors it (the chunk name becomes a tok-function in the weave).
printf '@ # cob as code\n\n@<<demo.cob@>>=\n@@<<greeting@@>>=\nhello\n@\n' > d.cob
$cob weave d.cob --out _site
# tree-sitter-cob coloured the chunk name inside the .cob code chunk.
grep -q 'class="tok-function">' _site/index.html
@
