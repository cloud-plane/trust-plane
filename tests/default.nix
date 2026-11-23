# SPDX-License-Identifier: Apache-2.0
{
  self,
  lib,
  pkgs,
}:
let
  args = { inherit self lib pkgs; };
in
{
  # Single-purpose component tests (fast).
  tpm-seal = import ./tpm-seal.nix args;
  admin-access = import ./admin-access.nix args;

  # Cluster scenario: init once, TPM-delivered unseal key, cold start, tamper.
  bao-cluster = import ./bao-cluster.nix args;
}
