# flake.nix — expose ainb-toolkit skills + agents as Nix packages.
#
# Usage in consuming flakes:
#   inputs.ainb-toolkit.url = "github:stevengonsalvez/ainb-toolkit";
#   skillsPkg = ainb-toolkit.packages.${system}.skills;
#   agentsPkg = ainb-toolkit.packages.${system}.agents;
#
# The skills/agents live flattened at the repo root, so the derivations use
# local `./skills` / `./agents` sources — no fetchFromGitHub hash needed.

{
  description = "ainb-toolkit — portable AI-agent skills & configs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          skills = pkgs.stdenvNoCC.mkDerivation {
            pname = "ainb-toolkit-skills";
            version = "1.6.1";
            src = ./skills;
            phases = [ "installPhase" ];
            installPhase = ''
              mkdir -p $out/skills
              cp -r $src/* $out/skills/
            '';
          };

          agents = pkgs.stdenvNoCC.mkDerivation {
            pname = "ainb-toolkit-agents";
            version = "1.6.1";
            src = ./agents;
            phases = [ "installPhase" ];
            installPhase = ''
              mkdir -p $out/agents
              cp -r $src/* $out/agents/
            '';
          };

          default = self.packages.${system}.skills;
        });
    };
}
