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
      # needs no noweb — only the KaTeX assets for weave.
      mkCob = pkgs: src: pkgs.rustPlatform.buildRustPackage {
        pname = "cob";
        version = "0.1.0";
        inherit src;
        cargoLock.lockFile = ./Cargo.lock;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postFixup = ''
          wrapProgram $out/bin/cob \
            --set COB_KATEX_ASSETS ${katexAssets pkgs}
        '';
      };
    in
    {
      packages = eachSystem (system: pkgs: rec {
        # The tree is already tangled: compile the committed .rs directly.
        cob = mkCob pkgs self;
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
