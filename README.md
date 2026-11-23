# trust-plane

NixOS flake for the root-of-trust perimeter: a single root OpenBao cluster,
SPIRE server/agent backed by PostgreSQL/Patroni/etcd, TPM-bound unseal,
admin access rules, and VM tests. Design: `docs/` (start at `index.md`);
repository structure, merge model and development workflow: `CONTRIBUTING.md`.

## Layout

| Path | Content |
| --- | --- |
| `flake.nix` | inputs, modules, packages, hosts, checks |
| `modules/` | NixOS modules (`trust.tpmUnseal`, `trust.openbaoRoot`, `trust.admin`, SPIRE, Patroni/etcd) |
| `pkgs/trust-tpm-tools/` | shell tools: enroll, makecredential, seal, receive, unseal, lock, openbao-unseal |
| `hosts/` | three Tier 1 nodes, exposed as `nixosConfigurations` and a colmena hive |
| `tests/` | NixOS VM tests (`runNixOSTest`) and a real-TPM smoke test |
| `docs/` | design and roadmap |

## First use

```
nix flake check --no-build
nix build -L .#checks.x86_64-linux.tpm-seal
nix build -L .#checks.x86_64-linux.admin-access
nix build -L .#checks.x86_64-linux.bao-cluster
```

VM tests need KVM to run at a reasonable speed (they also run under TCG,
slowly). CI enables KVM on GitHub runners via a udev rule.

## Status

Verified: flake eval, tool package build (shellcheck clean), tool flow on
swtpm, test drivers build and lint. See `docs/ROADMAP.md` for what is not
yet tested (spire, spire-db) and known gaps.
