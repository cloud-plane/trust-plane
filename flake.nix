# SPDX-License-Identifier: Apache-2.0
{
  description = "Root of trust: NixOS modules, hosts and VM tests for the trust plane";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Measured boot / Secure Boot for the Tier 1 and Tier 2 hosts.
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Fleet deployment (CI runner only; see docs/design/administration.md 7.5).
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      lanzaboote,
      colmena,
      ...
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Fleet definition shared by nixosConfigurations and the colmena hive.
      fleet = import ./hosts { inherit lib inputs self; };

      allTests =
        system:
        import ./tests {
          inherit self lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
    in
    {
      # --- Reusable modules -------------------------------------------------
      nixosModules = {
        default = ./modules;
        trust-common = ./modules/trust-common.nix;
        tpm-unseal = ./modules/tpm-unseal.nix;
        openbao-root = ./modules/openbao-root.nix;
        spire-db = ./modules/spire-db.nix;
        spire = ./modules/spire.nix;
        admin-access = ./modules/admin-access.nix;
      };

      # --- Packages and tools -----------------------------------------------
      packages = forAllSystems (pkgs: {
        trust-tpm-tools = pkgs.callPackage ./pkgs/trust-tpm-tools { };
        default = pkgs.callPackage ./pkgs/trust-tpm-tools { };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              nixfmt
              statix
              deadnix
              tpm2-tools
              swtpm
              openbao
              jq
              openssl
              age
              ssss
              shellcheck
            ]
            ++ lib.optional (
              (colmena.packages.${pkgs.stdenv.hostPlatform.system} or { }) ? colmena
            ) colmena.packages.${pkgs.stdenv.hostPlatform.system}.colmena;
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      # --- Fleet -------------------------------------------------------------
      nixosConfigurations = fleet.nixosConfigurations;
      colmenaHive = colmena.lib.makeHive fleet.colmena;

      # --- Tests (NixOS VM tests; run with `nix flake check` or `nix build .#checks.<system>.<name>`) ---
      checks = lib.genAttrs [ "x86_64-linux" ] (system: allTests system);
    };
}
