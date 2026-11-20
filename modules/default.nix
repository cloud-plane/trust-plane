# SPDX-License-Identifier: Apache-2.0
{
  imports = [
    ./trust-common.nix
    ./tpm-unseal.nix
    ./openbao-root.nix
    ./spire-db.nix
    ./spire.nix
    ./admin-access.nix
  ];
}
