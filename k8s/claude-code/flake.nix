{
  description = "Claude Code container";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
          };
        in {
          env = pkgs.symlinkJoin {
            name = "claude-code-env";
            paths = [
              pkgs.claude-code
              pkgs.bashInteractive
              pkgs.coreutils
              pkgs.kubectl
              pkgs.git
              pkgs.gh
              pkgs.cacert
              pkgs.podman
              pkgs.crun
              pkgs.conmon
              pkgs.slirp4netns
              pkgs.fuse-overlayfs
            ];
          };
        });
    };
}
