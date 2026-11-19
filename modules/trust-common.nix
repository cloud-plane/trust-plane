# SPDX-License-Identifier: Apache-2.0
#
# Options shared by the trust-plane modules (design 2, 3).
{ lib, ... }:
{
  options.trust = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "trust.example.org";
      description = "SPIFFE trust domain of the fleet.";
    };

    tier1Nodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "trust-node-01"
        "trust-node-02"
        "trust-node-03"
      ];
      description = "Host names of the Tier 1 (trust plane) nodes, in join order.";
    };
  };
}
