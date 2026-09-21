{
  description = "a tiny flake";
  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = [ pkgs.hello pkgs.ripgrep ];
  };
}
