{
  description = "lit — a web-first literate programming system built on noweb";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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

      # One buildRustPackage, applied to two source trees (the bootstrap seed and
      # the tangled .nw). noweb's pipeline stages (markup, nt, ...) live in
      # lib/noweb, not bin — see §4.2 — so the wrapper adds both to PATH.
      mkLit = pkgs: src: pkgs.rustPlatform.buildRustPackage {
        pname = "lit";
        version = "0.1.0";
        inherit src;
        cargoLock.lockFile = ./Cargo.lock;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postFixup = ''
          wrapProgram $out/bin/lit \
            --prefix PATH : ${pkgs.noweb}/bin:${pkgs.noweb}/lib/noweb \
            --set LIT_KATEX_ASSETS ${katexAssets pkgs}
        '';
      };
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # Stage 0 source: notangle every .nw into the .rs/.css cargo needs, with no
        # lit binary. notangle ships with noweb and makes the same bytes lit tangle
        # makes (§15). templates/lit.css.nw has two roots; the rest one each.
        bootstrapSource = pkgs.runCommand "lit-bootstrap-src" { } ''
          cp -r ${self} $out
          chmod -R +w $out
          cd $out
          export PATH="${pkgs.noweb}/bin:${pkgs.noweb}/lib/noweb:$PATH"
          for nw in src/*.rs.nw; do
            notangle -R"''${nw%.nw}" "$nw" > "''${nw%.nw}"
          done
          notangle -R'templates/lit.css' templates/lit.css.nw > templates/lit.css
          notangle -R'templates/lit-syntax.css' templates/lit.css.nw > templates/lit-syntax.css
        '';
        # Stage 0: build the tangler from the notangle-bootstrapped sources.
        litBootstrap = mkLit pkgs bootstrapSource;
        # Stage 1 tangles every .nw with lit, so the shipped binary compiles from a
        # tree lit itself made (§13). templates/lit.css is include_str!'d into the
        # weaver, so it and its imported palette must be tangled here too.
        litSource = pkgs.runCommand "lit-src" { } ''
          cp -r ${self} $out
          chmod -R +w $out
          cd $out
          for nw in src/*.rs.nw templates/lit.css.nw; do
            ${litBootstrap}/bin/lit tangle "$nw" --out .
          done
        '';
        # Stage 1: the default package, compiled from the lit-tangled .nw sources.
        lit = mkLit pkgs litSource;
        # `nix build .#flake` re-tangles flake.nix.nw and emits the flake.nix this
        # very output was built from — the dogfood loop as a buildable artifact
        # (§13). checks.dogfood diffs the committed file against this.
        flake = pkgs.runCommand "flake.nix" { } ''
          cd ${self}
          ${lit}/bin/lit tangle flake.nix.nw --out $TMPDIR
          cp $TMPDIR/flake.nix $out
        '';
        default = lit;
      });

      devShells = eachSystem (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer noweb ];
          shellHook = ''
            export PATH="${pkgs.noweb}/bin:${pkgs.noweb}/lib/noweb:$PATH"
            export LIT_KATEX_ASSETS="${katexAssets pkgs}"
            # The .rs/.css are generated from the .nw (§13). On a fresh checkout they
            # are absent, so notangle-bootstrap them once, the same as stage 0.
            if [ ! -f src/main.rs ]; then
              for nw in src/*.rs.nw; do
                notangle -R"''${nw%.nw}" "$nw" > "''${nw%.nw}"
              done
              notangle -R'templates/lit.css' templates/lit.css.nw > templates/lit.css
              notangle -R'templates/lit-syntax.css' templates/lit.css.nw > templates/lit-syntax.css
            fi
          '';
        };
      });

      checks = eachSystem (system: pkgs: {
        # Building the package also runs the (hermetic) cargo tests.
        build = self.packages.${system}.lit;

        # Weave twice, compare bytes. Determinism is the property §8's JSON
        # contract and the archival goal both rest on. The book fixture also
        # exercises M2: page splitting, cross-page refs, and numbering.
        determinism = pkgs.runCommand "lit-determinism" { } ''
          cd ${self}
          lit=${self.packages.${system}.lit}/bin/lit
          # The Nix sandbox is read-only, so every weave runs `--locked`: it reads
          # the committed lit.lock and never mints (§7.1). This also proves the
          # frozen ids are stable across runs — the whole point of the lock.
          # --archive brings site.json + per-page JSON under the byte-diff too,
          # which is the whole point of §8's determinism requirement.
          $lit weave --locked --archive fixtures/book.nw --out $TMPDIR/a
          $lit weave --locked --archive fixtures/book.nw --out $TMPDIR/b
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
          # The syntax palette is imported by lit.css; both files must be in the output.
          test -f $TMPDIR/a/lit-syntax.css
          # §6.4 Markdown dialect: ring.nw is authored in CommonMark (the default
          # dialect, so no lit.toml needed). Weave twice, byte-diff, and confirm
          # prose actually became HTML rather than passing through literally.
          $lit weave --locked examples/ring.nw --out $TMPDIR/md-a
          $lit weave --locked examples/ring.nw --out $TMPDIR/md-b
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
          # The md.nw fixture additionally exercises the ```figure``` fence: a real
          # <figure> carrying its opaque id and its raw-HTML body passed through,
          # deterministically.
          $lit weave --locked fixtures/md.nw --out $TMPDIR/mdfx-a
          $lit weave --locked fixtures/md.nw --out $TMPDIR/mdfx-b
          diff -r $TMPDIR/mdfx-a $TMPDIR/mdfx-b
          grep -qE '<figure id="fig-diagram" data-id="[0-9A-Za-z]{4}">' $TMPDIR/mdfx-a/index.html
          grep -qE '<figcaption data-id="[0-9A-Za-z]{4}">' $TMPDIR/mdfx-a/index.html
          # §5.5 syntax highlighting: hl.nw has a Rust root and a Nix root, each
          # pulling an abstract chunk in through a hole. Weave twice, byte-diff,
          # and confirm the coloring is deterministic and structurally sound.
          $lit weave --locked fixtures/hl.nw --out $TMPDIR/hl-a
          $lit weave --locked fixtures/hl.nw --out $TMPDIR/hl-b
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
          # §10 transclusion: tx.nw puts a title, an intro, and the source heading
          # in one @ chunk, then transcludes the source into a later section. Weave
          # twice, byte-diff, and confirm the node model and scoping are sound.
          $lit weave --locked fixtures/tx.nw --out $TMPDIR/tx-a
          $lit weave --locked fixtures/tx.nw --out $TMPDIR/tx-b
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
          # §10 floats are nodes: txf.nw labels an equation and a figure, then
          # transcludes each into a later section. Weave twice, byte-diff, and
          # confirm a float is cut, paged, linked, and transcludable.
          $lit weave --locked fixtures/txf.nw --out $TMPDIR/txf-a
          $lit weave --locked fixtures/txf.nw --out $TMPDIR/txf-b
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
          touch $out
        '';

        # §7.1 the committed lit.lock is the source of truth. If a float were
        # added without running `lit lock` and committing the grown lock, a
        # `--locked` weave would trip E031 — so a green `determinism` check above
        # already proves the lock is complete. Here we exercise the read-only CLI
        # surface: `lit id` returns a four-char base62 id, `lit labels` lists them.
        lock = pkgs.runCommand "lit-lock" { } ''
          cd ${self}
          lit=${self.packages.${system}.lit}/bin/lit
          $lit id fixtures/book.nw fig:pipeline | grep -qE '^[0-9A-Za-z]{4}$'
          $lit labels examples/ring.nw | grep -qE '^eq:wrap\s+[0-9A-Za-z]{4}\s+Equation$'
          # §7.1 a `sec:`-labelled heading is a first-class label: it has an id
          # and lists with kind Section, exactly like a float.
          $lit id fixtures/book.nw sec:lexing | grep -qE '^[0-9A-Za-z]{4}$'
          $lit labels fixtures/book.nw | grep -qE '^sec:lexing\s+[0-9A-Za-z]{4}\s+Section$'
          # An unknown label is a nonzero exit, not a silent empty line.
          if $lit id fixtures/book.nw fig:nope; then
            echo "lit id returned success for a label not in the lock" >&2
            exit 1
          fi
          # §5.5 `lit language` is the shared resolver: a root resolves from its
          # own extension, an abstract chunk from the root that reaches it, and an
          # unknown chunk is a nonzero exit (so a build can gate on it).
          test "$($lit language fixtures/hl.nw src/demo.rs)" = rust
          test "$($lit language fixtures/hl.nw flake.nix)" = nix
          test "$($lit language fixtures/hl.nw greeting)" = rust
          test "$($lit language fixtures/hl.nw packages)" = nix
          if $lit language fixtures/hl.nw nope; then
            echo "lit language returned success for a chunk with no known language" >&2
            exit 1
          fi
          touch $out
        '';

        section-anchors = pkgs.runCommand "lit-section-anchors" { } ''
          lit=${self.packages.${system}.lit}/bin/lit
          # `lit lock` edits the source in place, so work on a writable copy; the
          # store path is read-only.
          work=$TMPDIR/sec
          mkdir -p $work
          cp ${self}/fixtures/sections.nw $work/sections.nw
          chmod u+w $work/sections.nw
          cd $work

          # The three headings start unlabelled. `lit lock` mints an id for each.
          grep -qE '^## Lexing$' sections.nw
          $lit lock sections.nw | grep -q '3 newly minted'

          # §7.1 lit lock writes a {#sec:<id>} anchor into the source, in place …
          grep -qE '^## Lexing \{#sec:[0-9A-Za-z]{4}\}$' sections.nw
          grep -qE '^### Cost \{#sec:[0-9A-Za-z]{4}\}$' sections.nw
          grep -qE '^## Parsing \{#sec:[0-9A-Za-z]{4}\}$' sections.nw
          # … and a matching Section entry into the lock.
          $lit labels sections.nw | grep -qE '^sec:[0-9A-Za-z]{4}\s+[0-9A-Za-z]{4}\s+Section$'

          # The weave draws a clickable permalink prefix and a stable heading id.
          $lit weave --locked sections.nw --out out
          grep -qE '<h2 id="sec-[0-9A-Za-z]{4}"><a class="sec-uid" href="#sec-[0-9A-Za-z]{4}" data-id="[0-9A-Za-z]{4}">' out/index.html
          # The only script the archival page carries is the nav-spy aid (§6.3).
          if grep '<script' out/index.html | grep -qv '<script id="nav-spy">'; then
            echo "section weave emitted a script other than the nav-spy aid" >&2
            exit 1
          fi

          # §7.1 lit rename-label gives an auto id a human name; the id never changes.
          label=$(grep -oE 'sec:[0-9A-Za-z]{4}' sections.nw | head -1)
          id=$(printf '%s' "$label" | cut -c5-)
          $lit rename-label $id lexing
          grep -qE '^## Lexing \{#sec:lexing\}$' sections.nw
          test "$($lit id sections.nw sec:lexing)" = "$id"
          # The old auto label is gone: a rename moves the name, not the id.
          if $lit id sections.nw $label; then
            echo "the old auto label survived a rename" >&2
            exit 1
          fi

          # A second lock is idempotent: an already-anchored heading is left alone.
          $lit lock sections.nw | grep -q '0 newly minted'
          touch $out
        '';

        # Tangle differential (§15): `lit tangle` must byte-match `notangle`
        # itself, and `--check` must be clean after a tangle and flag drift
        # after an edit. This is also the acceptance test for the eventual Rust
        # reimplementation (§11).
        tangle = pkgs.runCommand "lit-tangle" { } ''
          lit=${self.packages.${system}.lit}/bin/lit
          nw=${self}/fixtures/hello.nw
          $lit tangle "$nw" --out $TMPDIR/out
          test -f $TMPDIR/out/src/main.rs
          ${pkgs.noweb}/bin/notangle -R'src/main.rs' "$nw" > $TMPDIR/oracle
          diff $TMPDIR/out/src/main.rs $TMPDIR/oracle
          # Clean immediately after a tangle.
          $lit tangle --check "$nw" --out $TMPDIR/out
          # An edited root must be reported as drift (nonzero exit).
          echo '// drift' >> $TMPDIR/out/src/main.rs
          if $lit tangle --check "$nw" --out $TMPDIR/out; then
            echo "--check passed despite an edited root" >&2
            exit 1
          fi
          touch $out
        '';

        # Golden guard: `markup` output for the fixture corpus must not drift
        # across noweb/nixpkgs updates. If this fails, inspect the diff, then
        # regenerate with:  markup fixtures/NAME.nw > fixtures/NAME.markup
        noweb-drift = pkgs.runCommand "noweb-drift" { } ''
          cd ${self}
          for f in fixtures/*.nw; do
            ${pkgs.noweb}/lib/noweb/markup "$f" > "$TMPDIR/got"
            diff -u "''${f%.nw}.markup" "$TMPDIR/got"
          done
          touch $out
        '';

        # Full-corpus differential (§4.1): the native reader (`lit dump-ir`) must
        # make the same events as noweb `markup` (`lit dump-ir --oracle`) for every
        # tracked .nw file. Two independent readers that agree prove the port.
        reader = pkgs.runCommand "lit-reader" { } ''
          lit=${self.packages.${system}.lit}/bin/lit
          cd ${self}
          for nw in *.nw src/*.nw fixtures/*.nw; do
            $lit dump-ir "$nw" > "$TMPDIR/reader"
            $lit dump-ir --oracle "$nw" > "$TMPDIR/oracle"
            if ! diff -u "$TMPDIR/oracle" "$TMPDIR/reader"; then
              echo "reader diverged from noweb markup for $nw" >&2
              exit 1
            fi
          done
          touch $out
        '';

        # Dogfood (§13): flake.nix.nw is this flake told as a literate program, and
        # packages.flake is `lit tangle flake.nix.nw` as a buildable output. The
        # committed flake.nix must equal it, or the self-host loop has drifted.
        dogfood = pkgs.runCommand "lit-dogfood" { } ''
          cd ${self}
          lit=${self.packages.${system}.lit}/bin/lit
          # The committed flake.nix must be exactly the tangled output.
          diff ${self}/flake.nix ${self.packages.${system}.flake}
          # Weave the literate flake twice, byte-diff: the page is deterministic.
          $lit weave --locked flake.nix.nw --out $TMPDIR/df-a
          $lit weave --locked flake.nix.nw --out $TMPDIR/df-b
          diff -r $TMPDIR/df-a $TMPDIR/df-b
          # The Nix grammar coloured the page — an attribute path is a property and
          # `let` is a keyword — so lit self-hosts its own highlighter (§5.5).
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
          touch $out
        '';

        # Self-host (§13): with no committed .rs/.css, two independent tanglers —
        # notangle and lit — must make the same bytes for every module. Their
        # agreement is what makes the notangle-then-lit bootstrap sound.
        selfhost = pkgs.runCommand "lit-selfhost" { } ''
          cd ${self}
          lit=${self.packages.${system}.lit}/bin/lit
          export PATH="${pkgs.noweb}/bin:${pkgs.noweb}/lib/noweb:$PATH"
          # notangle and lit must tangle every module to the same bytes. Each src/*.rs.nw
          # has one root named for its target; templates/lit.css.nw has two.
          for nw in src/*.rs.nw; do
            root="''${nw%.nw}"
            notangle -R"$root" "$nw" > $TMPDIR/nt
            $lit tangle -R "$root" "$nw" > $TMPDIR/lt
            diff $TMPDIR/nt $TMPDIR/lt
          done
          for root in templates/lit.css templates/lit-syntax.css; do
            notangle -R"$root" templates/lit.css.nw > $TMPDIR/nt
            $lit tangle -R "$root" templates/lit.css.nw > $TMPDIR/lt
            diff $TMPDIR/nt $TMPDIR/lt
          done
          # Weave one Rust module to prove lit renders its own source: keywords and
          # strings colour, and the page carries no script but the nav-spy aid (§5.5/§6.3).
          $lit weave --locked src/diag.rs.nw --out $TMPDIR/sh
          grep -q 'class="tok-keyword">' $TMPDIR/sh/index.html
          grep -q 'class="tok-string">' $TMPDIR/sh/index.html
          # Weave the stylesheet to prove lit colours its own CSS: a property name is a
          # tok token, and the page carries no script but the nav-spy aid.
          $lit weave --locked templates/lit.css.nw --out $TMPDIR/shcss
          grep -q 'class="tok-property">' $TMPDIR/shcss/index.html
          for page in $TMPDIR/sh $TMPDIR/shcss; do
            if grep '<script' "$page"/index.html | grep -qv '<script id="nav-spy">'; then
              echo "self-host weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
              exit 1
            fi
          done
          touch $out
        '';
      });
    };
}
