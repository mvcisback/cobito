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
      # embeds (0.16.4) — nixpkgs' katex is a different release. See SPEC.md
      # §6.3. Bump both together or math silently mislays.
      katexVersion = "0.16.4";
      katexAssets = pkgs: pkgs.fetchzip {
        url = "https://github.com/KaTeX/KaTeX/releases/download/v${katexVersion}/katex.tar.gz";
        sha256 = "0pgajj8vqfvgws3wnn5bfy4h3w75n4dz8jvjsxcw8s80jnp0md8c";
      };
    in
    {
      packages = eachSystem (system: pkgs: rec {
        lit = pkgs.rustPlatform.buildRustPackage {
          pname = "lit";
          version = "0.1.0";
          src = self;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          # noweb's pipeline stages (markup, nt, ...) live in lib/noweb,
          # not bin — see SPEC.md §4.2.
          postFixup = ''
            wrapProgram $out/bin/lit \
              --prefix PATH : ${pkgs.noweb}/bin:${pkgs.noweb}/lib/noweb \
              --set LIT_KATEX_ASSETS ${katexAssets pkgs}
          '';
        };
        default = lit;
      });

      devShells = eachSystem (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer noweb ];
          shellHook = ''
            export PATH="${pkgs.noweb}/lib/noweb:$PATH"
            export LIT_KATEX_ASSETS="${katexAssets pkgs}"
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
          if grep -q 'data-number' $TMPDIR/a/parsing.html; then
            echo "float still carries a sequential data-number; §7.1 wants an opaque id" >&2
            exit 1
          fi
          # The archival artifact must need no JavaScript (§6.3).
          for p in $TMPDIR/a/*.html; do
            if grep -q '<script' "$p"; then
              echo "$p contains <script>; math must render at weave time" >&2
              exit 1
            fi
          done
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
          if grep -q '<script' $TMPDIR/md-a/index.html; then
            echo "Markdown weave emitted <script>; math must render at weave time" >&2
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
          # An unknown label is a nonzero exit, not a silent empty line.
          if $lit id fixtures/book.nw fig:nope; then
            echo "lit id returned success for a label not in the lock" >&2
            exit 1
          fi
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
      });
    };
}
