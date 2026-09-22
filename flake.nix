{
  description = "cobito — buildable release snapshot (the tangled branch)";

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
        # The tree is already tangled: compile the committed .rs directly.
        cob = mkCob pkgs self ./Cargo.lock;
        default = cob;
      });

      devShells = eachSystem (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer ];
          shellHook = ''
            export COB_KATEX_ASSETS="${katexAssets pkgs}"
          '';
        };
      });

      checks = eachSystem (system: pkgs: {
        # Building the package also runs the hermetic cargo tests.
        build = self.packages.${system}.cob;
      });
    };
}
