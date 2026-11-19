# SPDX-License-Identifier: Apache-2.0
#
# Tier 1 fleet definition. Reused by `nixosConfigurations` and the colmena hive.
{
  lib,
  inputs,
  self,
}:
let
  system = "x86_64-linux";
  nodes = [
    "trust-node-01"
    "trust-node-02"
    "trust-node-03"
  ];
  # Placeholder addressing; replace with the real management network.
  addresses = {
    trust-node-01 = "10.0.0.11";
    trust-node-02 = "10.0.0.12";
    trust-node-03 = "10.0.0.13";
  };
  bootstrapNode = lib.head nodes;

  modulesFor = name: [
    self.nixosModules.default
    inputs.lanzaboote.nixosModules.lanzaboote
    ./tier1-common.nix
    ./hardware-placeholder.nix
    {
      networking.hostName = name;
      trust.tier1Nodes = nodes;

      trust.openbaoRoot.joinPeers = lib.optional (name != bootstrapNode) bootstrapNode;
      trust.spireDb.nodes = lib.mapAttrs (_: ip: { inherit ip; }) addresses;
    }
  ];
in
{
  inherit nodes;

  nixosConfigurations = lib.genAttrs nodes (
    name:
    lib.nixosSystem {
      inherit system;
      modules = modulesFor name;
    }
  );

  # Consumed by `colmena.lib.makeHive` in flake.nix.
  colmena = {
    meta.nixpkgs = import inputs.nixpkgs { inherit system; };
  }
  // lib.genAttrs nodes (name: {
    imports = modulesFor name;
    deployment = {
      targetHost = addresses.${name};
      targetUser = "deploy";
      tags = [ "tier1" ];
    };
  });
}
