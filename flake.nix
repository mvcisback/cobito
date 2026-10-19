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
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system:
        f system nixpkgs.legacyPackages.${system});

      # KaTeX renders to HTML that is version-coupled to its own CSS and font
      # metrics, so these assets must match the version the `katex` crate
      # embeds (0.16.4) — nixpkgs' katex is a different release. See §6.3.
      # Bump both together or math silently mislays.
      katexVersion = "0.16.4";
      katexAssets = pkgs: pkgs.fetchzip {
        url = "https://github.com/KaTeX/KaTeX/releases/download/v${katexVersion}/katex.tar.gz";
        sha256 = "0pgajj8vqfvgws3wnn5bfy4h3w75n4dz8jvjsxcw8s80jnp0md8c";
      };

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
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # Stage 0: build cob from the seed — the committed .rs of the pinned tangled
        # snapshot. The bootstrap only tangles cobSource, which needs no grammars, so it
        # builds with an empty set and skips the tests.
        cobBootstrap = mkCob pkgs seed (seed + "/Cargo.lock") [ ] false;
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
        # `nix build .#flake` re-tangles flake.nix.cob and emits the flake.nix this
        # very output was built from — the dogfood loop as a buildable artifact
        # (§13). checks.dogfood diffs the committed file against this.
        flake = pkgs.runCommand "flake.nix" { } ''
          cd ${self}
          ${cob}/bin/cob tangle flake.nix.cob --out $TMPDIR
          cp $TMPDIR/flake.nix $out
        '';
        default = cob;
      });

      devShells = eachSystem (system: pkgs: {
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
      });

      checks = eachSystem (system: pkgs: {
        # The shipped cob builds with an empty grammar registry (§5.5).
        build = self.packages.${system}.cob;
        # The grammar-ful development build runs the hermetic cargo tests.
        tests = self.packages.${system}.cobDoc;

        # Weave twice, compare bytes. Determinism is the property §8's JSON
        # contract and the archival goal both rest on. The book fixture also
        # exercises M2: page splitting, cross-page refs, and numbering.
        determinism = pkgs.runCommand "cob-determinism" { } ''
          cd ${self}
          cob=${self.packages.${system}.cobDoc}/bin/cob
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
          # §10 a `node` fence is a small document, a separate file transcluded in place,
          # with an explicit extent: exactly the fence. Its first line is its title with the
          # taxon and label on it. It is a labelled section with a title paragraph (never a
          # heading), it earns an opaque id, a typed ref ("Definition <id>"), and a node
          # page, and the prose after the fence is in none of them. It inherits the macros
          # in scope: the one used inside it is defined outside it, and the weave fails
          # on an unknown macro if the node did not see it.
          nf=$TMPDIR/nodefence
          mkdir -p $nf
          cat > $nf/n.cob <<'PAGE'
          # N

          ```macros \label{def:n-notation}
          We write $\thing$ for a thing.

          \def\thing{\mathcal{T}}
          ```

          ## Basics

          ```node
          # A thing \taxon{definition} \label{def:x}
          A thing is an element of $\thing$.
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
          touch $out
        '';

        # §7.1 the committed cob.lock is the source of truth. If a float were
        # added without running `cob lock` and committing the grown lock, a
        # `--locked` weave would trip E031 — so a green `determinism` check above
        # already proves the lock is complete. Here we exercise the read-only CLI
        # surface: `cob id` returns a four-char base62 id, `cob labels` lists them.
        lock = pkgs.runCommand "cob-lock" { } ''
          cd ${self}
          cob=${self.packages.${system}.cobDoc}/bin/cob
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
          # `cob tokens` prints whole-file semantic tokens in .cob buffer coordinates (#2).
          # `let` opens line 7 as a keyword at column 0.
          $cob tokens fixtures/hello.cob | grep -qx '7:0 3 keyword'
          # The `;` after the chunk-use hole on line 7 is at buffer column 21 — holes
          # removed it is at 8, so this proves the hole width is mapped back.
          $cob tokens fixtures/hello.cob | grep -qx '7:21 1 operator'
          touch $out
        '';

        section-anchors = pkgs.runCommand "cob-section-anchors" { } ''
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
        '';

        # Tangle goldens (§11): `cob tangle` must byte-match the frozen notangle
        # goldens in fixtures/tangled/, and `--check` must be clean after a tangle
        # and flag drift after an edit. The goldens are the oracle now — no live
        # noweb runs.
        tangle = pkgs.runCommand "cob-tangle" { } ''
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
          touch $out
        '';

        untangle = pkgs.runCommand "cob-untangle" { nativeBuildInputs = [ pkgs.git ]; } ''
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
        '';

        # Reader differential (§4.1): the native reader (`cob dump-ir`) must make
        # the same events as the frozen `markup` golden (`cob dump-ir --from-markup`
        # over the committed .markup). Hermetic — no live noweb.
        reader = pkgs.runCommand "cob-reader" { } ''
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
        '';

        # Dogfood (§13): flake.nix.cob is this flake told as a literate program, and
        # packages.flake is `cob tangle flake.nix.cob` as a buildable output. The
        # committed flake.nix must equal it, or the self-host loop has drifted.
        dogfood = pkgs.runCommand "cob-dogfood" { } ''
          cd ${self}
          cob=${self.packages.${system}.cobDoc}/bin/cob
          # The committed flake.nix must be exactly the tangled output.
          diff ${self}/flake.nix ${self.packages.${system}.flake}
          # Weave the literate flake twice, byte-diff: the page is deterministic.
          $cob weave --locked flake.nix.cob --out $TMPDIR/df-a
          $cob weave --locked flake.nix.cob --out $TMPDIR/df-b
          diff -r $TMPDIR/df-a $TMPDIR/df-b
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
          touch $out
        '';

        # Self-host (§13): the shipped cob must tangle every module to the same bytes
        # as cobSource, the tree it was compiled from. A fixed point of its own
        # tangler — no second tangler, no noweb.
        selfhost = pkgs.runCommand "cob-selfhost" { } ''
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
        '';

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

        macros = pkgs.runCommand "cob-macros" { } ''
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
        '';

        imports = pkgs.runCommand "cob-imports" { } ''
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
        '';

        fetch = pkgs.runCommand "cob-fetch" { nativeBuildInputs = [ pkgs.git ]; } ''
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
        '';

        cite = pkgs.runCommand "cob-cite" { } ''
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
        '';

        backlinks = pkgs.runCommand "cob-backlinks" { } ''
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
        '';

        treesitter = pkgs.runCommand "cob-treesitter"
          { nativeBuildInputs = [ pkgs.tree-sitter pkgs.gcc ]; } ''
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
          cob=${self.packages.${system}.cobDoc}/bin/cob
          # cobDoc knows the cob grammar: a .cob-rooted chunk resolves to "cob".
          test "$($cob language ${self}/fixtures/hello.cob src/main.rs)" = rust
          work=$TMPDIR/cob-as-code
          mkdir -p $work
          cd $work
          # Show a .cob as code: the body is an escaped chunk-def line, so the cob grammar
          # colors it (the chunk name becomes a tok-function in the weave).
          printf '@ # cob as code\n\n<<demo.cob>>=\n@<<greeting@>>=\nhello\n@\n' > d.cob
          $cob weave d.cob --out _site
          # tree-sitter-cob coloured the chunk name inside the .cob code chunk.
          grep -q 'class="tok-function">' _site/index.html
          touch $out
        '';
      });
    };
}
