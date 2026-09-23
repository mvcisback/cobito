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

  outputs = { self, nixpkgs, seed }:
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
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # Stage 0: build cob from the seed — the committed .rs of the pinned tangled
        # snapshot. This is why `main` needs no tangler of its own to start.
        cobBootstrap = mkCob pkgs seed (seed + "/Cargo.lock");
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
        # Stage 1: the default package, compiled from the cob-tangled .cob sources.
        cob = mkCob pkgs cobSource ./Cargo.lock;
        # The standalone single static binary (embedded KaTeX), from the same tree.
        static = mkCobStatic pkgs cobSource ./Cargo.lock;
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
        # Building the package also runs the (hermetic) cargo tests.
        build = self.packages.${system}.cob;

        # Weave twice, compare bytes. Determinism is the property §8's JSON
        # contract and the archival goal both rest on. The book fixture also
        # exercises M2: page splitting, cross-page refs, and numbering.
        determinism = pkgs.runCommand "cob-determinism" { } ''
          cd ${self}
          cob=${self.packages.${system}.cob}/bin/cob
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
            if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
          if grep '<script' $TMPDIR/md-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
          if grep '<script' $TMPDIR/hl-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
            echo "highlighted weave emitted a script other than the nav-spy aid; coloring must be pure CSS" >&2
            exit 1
          fi
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
          if grep '<script' $TMPDIR/tx-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
            if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
            if grep '<script' "$p" | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
          cob=${self.packages.${system}.cob}/bin/cob
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
          touch $out
        '';

        section-anchors = pkgs.runCommand "cob-section-anchors" { } ''
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
          if grep '<script' out/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
        '';

        # Reader differential (§4.1): the native reader (`cob dump-ir`) must make
        # the same events as the frozen `markup` golden (`cob dump-ir --from-markup`
        # over the committed .markup). Hermetic — no live noweb.
        reader = pkgs.runCommand "cob-reader" { } ''
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
        '';

        # Dogfood (§13): flake.nix.cob is this flake told as a literate program, and
        # packages.flake is `cob tangle flake.nix.cob` as a buildable output. The
        # committed flake.nix must equal it, or the self-host loop has drifted.
        dogfood = pkgs.runCommand "cob-dogfood" { } ''
          cd ${self}
          cob=${self.packages.${system}.cob}/bin/cob
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
          if grep '<script' $TMPDIR/df-a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
            if grep '<script' "$page"/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
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
          cob=${self.packages.${system}.cob}/bin/cob
          for m in src/*.rs.cob; do
            if ! $cob weave --locked "$m" --out $TMPDIR/m 2>$TMPDIR/err; then
              echo "module does not weave: $m" >&2; cat $TMPDIR/err >&2; exit 1
            fi
            if grep '<script' $TMPDIR/m/*.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
              echo "$m wove a script other than the nav-spy aid (§6.3)" >&2; exit 1
            fi
          done
          touch $out
        '';

        macros = pkgs.runCommand "cob-macros" { } ''
          cob=${self.packages.${system}.cob}/bin/cob
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

          # Weave twice, byte-diff: the macros path is deterministic.
          $cob weave --locked mac.cob --out a
          $cob weave --locked mac.cob --out b
          diff -r a b

          # The macros expand everywhere: `\RR`/`\R` and the parametered `\abs{…}` render,
          # so KaTeX output is present. An unknown macro would be a hard E020 and fail the
          # weave.
          grep -q 'katex' a/index.html

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
          if grep '<script' a/index.html | grep -qvE 'script id="(nav-spy|cob-transclude)"'; then
            echo "macros weave emitted a script other than the nav-spy aid" >&2
            exit 1
          fi
          touch $out
        '';
      });
    };
}
