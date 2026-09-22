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
    url = "git+ssh://gitea@git.chanlatte.casa/marcell/cobito.git?ref=refs/tags/v0.1.0";
    flake = false;
  };

  outputs = { self, nixpkgs, seed }:
    let
      <<system iteration>>

      <<pinned katex assets>>

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

  outputs = { self, nixpkgs }:
    let
      <<system iteration>>

      <<pinned katex assets>>

      <<the cob builder>>
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # The tree is already tangled: compile the committed .rs directly.
        cob = mkCob pkgs self ./Cargo.lock;
        default = cob;
      });

      devShells = eachSystem (system: pkgs: {
        <<the dist dev shell>>
      });

      checks = eachSystem (system: pkgs: {
        # Building the package also runs the hermetic cargo tests.
        build = self.packages.${system}.cob;
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
## The builder {#sec:Mh65}

Two builders, for the two deployment shapes (§6.3). \code{mkCob} is the Nix build:
a \code{buildRustPackage} whose \code{postFixup} wraps the binary to set
\code{COB_KATEX_ASSETS} at the pinned store path, so the small binary reads the dist
from the store at run time. The \code{cob} binary reads and tangles \code{.cob} files
natively (§4.1, §11), so it needs no noweb — only the KaTeX assets for weave. The
build also runs the hermetic cargo tests. It takes the source tree, so the flake
builds the same crate from the committed seed and from the tangled \code{.cob}.
<<the cob builder>>=
# One buildRustPackage, applied to two source trees (the committed seed and
# the freshly tangled .cob). cob reads and tangles .cob natively, so the binary
# needs no noweb — only the KaTeX assets for weave, read from the store at run
# time via the wrapper.
mkCob = pkgs: src: lock: pkgs.rustPlatform.buildRustPackage {
  pname = "cob";
  version = "0.1.0";
  inherit src;
  # Each source tree carries its own lock, so a dependency change on `main` does
  # not force a seed refresh — stage 0 builds the seed with the seed's lock.
  cargoLock.lockFile = lock;
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
mkCobStatic = pkgs: src: lock: pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "cob";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = lock;
  buildFeatures = [ "embed-assets" ];
  # include_bytes! reads this at build time; the pin lives in the flake (§6.3).
  COB_KATEX_ASSETS = katexAssets pkgs;
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
# snapshot. This is why `main` needs no tangler of its own to start.
cobBootstrap = mkCob pkgs seed (seed + "/Cargo.lock");
<<the tangled source tree>>
# Stage 1: the default package, compiled from the cob-tangled .cob sources.
cob = mkCob pkgs cobSource ./Cargo.lock;
# The standalone single static binary (embedded KaTeX), from the same tree.
static = mkCobStatic pkgs cobSource ./Cargo.lock;
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
cobSource = pkgs.runCommand "cob-src" { } ''
  cp -r ${self} $out
  chmod -R +w $out
  cd $out
  for nw in src/*.rs.cob templates/cob.css.cob; do
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

<<the reader check>>

<<the dogfood check>>

<<the selfhost check>>

<<the modules check>>
@
### build {#sec:9hJs}

This is the cheapest check. It builds the package. \code{buildRustPackage} also runs
the cargo tests. A green build shows that the unit tests passed. This check is
one Nix expression, not a shell script, so it stays Nix.
<<the build check>>=
# Building the package also runs the (hermetic) cargo tests.
build = self.packages.${system}.cob;
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
cob=${self.packages.${system}.cob}/bin/cob
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
  if grep '<script' "$p" | grep -qv '<script id="nav-spy">'; then
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
if grep '<script' $TMPDIR/md-a/index.html | grep -qv '<script id="nav-spy">'; then
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
# Both grammars ran: `fn`/`let` are Rust keywords; a Nix attribute path
# is a property. A string token proves literals color in either.
grep -q 'class="tok-keyword">' $TMPDIR/hl-a/index.html
grep -q 'class="tok-property">' $TMPDIR/hl-a/index.html
grep -q 'class="tok-string">' $TMPDIR/hl-a/index.html
# The chunk-use hole is spliced back verbatim, still inside its `.line`,
# and is *never* wrapped in a color span (§5.4/§5.5).
grep -q '<a href="#sec-1">&lt;<i>greeting</i>&gt;</a>' $TMPDIR/hl-a/index.html
if grep -qE 'tok-[a-z]+">&lt;<i>' $TMPDIR/hl-a/index.html; then
  echo "a chunk-use hole was wrapped in a highlight span; §5.5 wants it opaque" >&2
  exit 1
fi
# Highlighting is pure CSS classes — the only script is the nav-spy aid.
if grep '<script' $TMPDIR/hl-a/index.html | grep -qv '<script id="nav-spy">'; then
  echo "highlighted weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
  exit 1
fi
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
# The node is spliced as a transclusion section whose chrome links back to
# the canonical anchor with the heading text.
grep -q '<section class="transclusion" data-transclude="sec:source">' $TMPDIR/tx-a/index.html
grep -q '<a href="#sec-source">The source</a>' $TMPDIR/tx-a/index.html
# Node extent is the markdown heading, not the @ chunk: the h1 that shares
# the source's chunk is NOT pulled into the copy, so the page has one h1.
test "$(grep -oE '<h1[ >]' $TMPDIR/tx-a/index.html | wc -l)" -eq 1
# The copy scopes its ids; the canonical heading keeps the bare id.
grep -q 'id="tx1-sec-source"' $TMPDIR/tx-a/index.html
grep -q 'id="sec-source"' $TMPDIR/tx-a/index.html
# The node runs across the following code chunk, so the copy reproduces it
# — one canonical chunk body, one in the copy.
test "$(grep -oE 'class="chunk-body"' $TMPDIR/tx-a/index.html | wc -l)" -eq 2
# Transclusion duplicates finished HTML, so it adds no script: the only
# script a page may carry is the nav-spy aid (§6.3).
if grep '<script' $TMPDIR/tx-a/index.html | grep -qv '<script id="nav-spy">'; then
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
# A node page is archival too: it carries no script at all.
if grep -q '<script' $TMPDIR/tx-a/n/*.html; then
  echo "a node page emitted a script" >&2
  exit 1
fi
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
# The figure is transcluded on its own: a transclusion section keyed to the
# float, and the copy scopes the figure id with the tx prefix.
grep -q '<section class="transclusion" data-transclude="fig:demo">' $TMPDIR/txf-a/index.html
grep -q 'id="tx1-fig-demo"' $TMPDIR/txf-a/index.html
grep -q '<section class="transclusion" data-transclude="eq:demo">' $TMPDIR/txf-a/index.html
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
# A float node page is archival too: no script at all.
if grep -q '<script' $TMPDIR/txf-a/n/*.html; then
  echo "a float node page emitted a script" >&2
  exit 1
fi
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
cob=${self.packages.${system}.cob}/bin/cob
<<assert the frozen label lock>>
<<assert the language resolver>>
touch $out
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
cob=${self.packages.${system}.cob}/bin/cob
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
if grep '<script' out/index.html | grep -qv '<script id="nav-spy">'; then
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
cob=${self.packages.${system}.cob}/bin/cob
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
cob=${self.packages.${system}.cob}/bin/cob
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
cob=${self.packages.${system}.cob}/bin/cob
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
if grep '<script' $TMPDIR/df-a/index.html | grep -qv '<script id="nav-spy">'; then
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
cob=${self.packages.${system}.cob}/bin/cob
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
  if grep '<script' "$page"/index.html | grep -qv '<script id="nav-spy">'; then
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
  cob=${self.packages.${system}.cob}/bin/cob
  for m in src/*.rs.cob; do
    if ! $cob weave --locked "$m" --out $TMPDIR/m 2>$TMPDIR/err; then
      echo "module does not weave: $m" >&2; cat $TMPDIR/err >&2; exit 1
    fi
    if grep '<script' $TMPDIR/m/*.html | grep -qv '<script id="nav-spy">'; then
      echo "$m wove a script other than the nav-spy aid (§6.3)" >&2; exit 1
    fi
  done
  touch $out
'';
@
