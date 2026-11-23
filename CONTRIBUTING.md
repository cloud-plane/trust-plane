# Contributing to trust-plane

This document explains the repository structure, how the pieces are merged
together, and how to build, test and extend the project. Start here; for the
_why_ (security goals, perimeters, ceremonies) read the design docs under
[`docs/`](docs/index.md).

---

## 1. What this repository is

trust-plane is a **NixOS flake** that implements the root-of-trust perimeter:

- a single root **OpenBao** Raft cluster on three bare-metal Tier 1 nodes,
- **SPIRE** server (workload identity) backed by a **PostgreSQL/Patroni/etcd**
  datastore that lives inside the trust boundary,
- **TPM-bound unseal**: the OpenBao unseal key is sealed to each node's TPM and
  released only for the right measured-boot PCR state, with a runtime lock PCR,
- an **admin access baseline** (named accounts, key-only SSH, bastion-only
  sources, sudo allowlists, audit),
- **VM tests** that prove the above end to end on swtpm.

Everything is declarative Nix. The flake is the single entry point: hosts,
packages, tests and deployment metadata are all attributes of it.

---

## 2. Repository map

| Path                    | What it is                                                                                                                                    |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `flake.nix`             | The whole build: inputs, `nixosModules`, `packages`, `devShells`, `formatter`, `nixosConfigurations`, `colmenaHive`, `checks`                 |
| `flake.lock`            | Locked inputs (nixpkgs `nixos-26.05`, lanzaboote, colmena). Commit it; update with `nix flake update`                                         |
| `modules/`              | Reusable NixOS modules: `trust.*` options. Importable by any NixOS system (ours or external)                                                  |
| `hosts/`                | The Tier 1 fleet definition: three nodes, shared settings, hardware placeholder. Shared by `nixosConfigurations` **and** the colmena hive     |
| `pkgs/trust-tpm-tools/` | Shell tools for the TPM unseal key: `trust-tpm-{enroll,makecredential,seal,receive,unseal,lock}`, `trust-openbao-unseal`                      |
| `tests/`                | NixOS VM tests (`pkgs.testers.runNixOSTest`): `tpm-seal`, `admin-access`, `bao-cluster`, plus `lib/pki.nix` and a real-TPM smoke script |
| `.github/`              | `workflows/ci.yml` (lint, flake check, package, host closures, VM tests on KVM) and `dependabot.yml`                                          |
| `docs/`                 | Design docs (`docs/design/`, section numbers are global), `docs/ROADMAP.md` (known gaps and test status)                                      |
| `LICENSE`, `README.md`  | Apache-2.0; short orientation (start at `docs/index.md`)                                                                                      |

### Flake inputs

| Input        | Locked to          | Used for                                                     |
| ------------ | ------------------ | ------------------------------------------------------------ |
| `nixpkgs`    | `nixos-26.05`      | Everything; `legacyPackages.<system>` is the pkgs everywhere |
| `lanzaboote` | nix-community HEAD | Measured/Secure Boot UKI for the hosts (design 4.3)          |
| `colmena`    | zhaofengli/colmena | Fleet deployment from the CI runner (design 7.5)             |

Both `lanzaboote` and `colmena` use `inputs.nixpkgs.follows = "nixpkgs"`, so
there is exactly one nixpkgs in the graph.

Supported systems: `x86_64-linux` and `aarch64-linux` for `packages`,
`devShells` and `formatter`. **Hosts and `checks` are x86_64-linux only**
(`hosts/default.nix` hardcodes the system; `checks` is generated for
`x86_64-linux` only in `flake.nix`).

---

## 3. How the pieces are merged

### 3.1 Layering

```
nixpkgs 26.05 (openbao, spire, patroni, etcd, tpm2-tools, systemd, ...)
    |
    +-- modules/          <- this repo's `trust.*` NixOS modules
    |       |
    |       +-- pkgs/trust-tpm-tools  (consumed by trust.tpmUnseal)
    |
    +-- hosts/            <- fleet: which modules, which settings, per node
            |
            +--> nixosConfigurations.trust-node-0{1,2,3}   (deployable closures)
            +--> colmenaHive                                 (same configs + deploy metadata)
            |
            +--> tests/     <- import self.nixosModules.default and build VMs
```

### 3.2 The module bundle (`modules/default.nix`)

`modules/default.nix` is just a bundle that imports the six modules, in this
order:

```
trust-common.nix   -> options.trust.domain, options.trust.tier1Nodes (shared base)
tpm-unseal.nix     -> options.trust.tpmUnseal  + openbao-unseal.service
openbao-root.nix   -> options.trust.openbaoRoot + services.openbao config
spire-db.nix       -> options.trust.spireDb     + etcd/patroni/postgresql
spire.nix          -> options.trust.spire.{server,agent} + services.spire
admin-access.nix   -> options.trust.adminAccess + sshd/sudo/pam/nftables/auditd
```

Any module can be imported standalone via the flake (`nixosModules.tpm-unseal`,
...), but hosts always import the bundle (`self.nixosModules.default`). The
modules are decoupled: they do not import each other; they coordinate through
`trust.*` options and through a systemd ordering contract — anything that needs
secrets or the trust-plane network orders itself after `openbao-unseal.service`
(design 4.3).

### 3.3 Module interactions (the runtime merge)

The modules only produce _configuration_; the runtime behaviour emerges from how
the settings interlock:

- `trust.openbaoRoot` configures `services.openbao` with **two listeners**: the
  TLS API/cluster listener (certs delivered via systemd credentials,
  `LoadCredential=tls.crt/tls.key`) and a **local-only unix socket**
  (`trust.tpmUnseal.openbaoSocket`, default `/run/openbao/openbao.sock`) that
  the unseal helper uses. The hosts set `trust.openbaoRoot.joinPeers` on the
  non-bootstrap nodes (empty on the bootstrap node); the module turns that into
  `retry_join` entries that verify the leader against `tls.caFile`.
- `trust.tpmUnseal` writes `/etc/trust/tpm.env` (`TRUST_SEALED_DIR`,
  `TRUST_POLICY_PCRS`, `TRUST_LOCK_PCR`, `TRUST_OPENBAO_SOCKET`,
  `TRUST_UNSEAL_TIMEOUT`) and starts `openbao-unseal.service` (oneshot,
  `After=Requires=openbao.service`). The service runs `trust-openbao-unseal`
  (from the tools package), which reads exactly that env file via
  `pkgs/trust-tpm-tools/common.sh`. That env file is the contract between the
  NixOS side and the shell tools.
- The sealed object is bound to `policyPcrs` **plus** `lockPcr`. After a
  successful unseal the service extends the lock PCR, so any later unseal fails
  until reboot (`RestartPreventExitStatus=3` in the unit). **Consequence:**
  `systemctl restart openbao.service` reseals the node and the lock PCR then
  blocks re-unseal; recover by rebooting (see `hosts/tier1-common.nix` and
  design 4.3).
- `trust.spireDb` runs PostgreSQL under Patroni with a 3-member etcd DCS, all
  mTLS. It asserts exactly three nodes, that this host is one of them, and that
  nftables is on (it opens peer ports via
  `networking.firewall.extraInputRules`). The `spire` DB/role are _not_ created
  here — the day-0 ceremony creates them; clients authenticate with cert-only
  auth (`pg_hba` `cert clientcert=verify-full`) and `pg_ident` maps certificate
  CN `spire-server` to role `spire`.
- `trust.spire.server` connects to the DB with `sslmode=verify-full` (a
  comma-separated host list lets the driver follow the Patroni leader), uses a
  **memory KeyManager** (no long-term signing key on disk) and a **vault
  UpstreamAuthority** (OpenBao `pki-spire` mount, cert auth). The agent section
  is for downstream workloads.
- `trust.adminAccess` sets `users.mutableUsers = false`, locks root, configures
  sshd (`PermitRootLogin no`, key-only, `AllowUsers` = declared users +
  `extraAllowedUsers`, agent forwarding allowed **only** for admins via a
  trailing `Match User` block), opens SSH to the bastion sources in nftables,
  restricts the `sudo` setuid wrapper to group `trust-sudo`, gives operators a
  NOPASSWD allowlist of exact commands, and lets admins authenticate to sudo
  with their SSH key through `pam_ssh_agent_auth` (`security.pam.rssh`).
  `auditd` records privileged `execve`s (`-k exec`).

### 3.4 The fleet (`hosts/`)

`hosts/default.nix` is imported by the flake with `{ lib, inputs, self }` and
returns **one fleet definition** consumed twice:

```
fleet = import ./hosts { inherit lib inputs self; }

nixosConfigurations = fleet.nixosConfigurations   # lib.nixosSystem per node
colmenaHive         = colmena.lib.makeHive fleet.colmena
```

Per node, `modulesFor name` merges, in order:

1. `self.nixosModules.default` — the trust-plane module bundle,
2. `inputs.lanzaboote.nixosModules.lanzaboote` — measured boot,
3. `hosts/tier1-common.nix` — shared Tier 1 settings:
   `system.stateVersion = "26.05"`, lanzaboote with the `sbctl` PKI bundle at
   `/var/lib/sbctl`, systemd initrd, no swap (secrets must not be swapped), all
   trust-plane services enabled with their TLS/ceremony paths, the admin
   accounts (still `REPLACE-ME` placeholders), and the `deploy` account + sudo
   rules used by colmena from the CI runner,
4. `hosts/hardware-placeholder.nix` — `mkDefault` file systems
   (`/dev/disk/by-label/nixos`, `/dev/disk/by-label/ESP`) and host platform;
   replace with each machine's generated hardware config (the `mkDefault`s exist
   so real hardware config wins),
5. a per-node attrset: `networking.hostName`, `trust.tier1Nodes` (all three),
   `trust.openbaoRoot.joinPeers` (bootstrap node: none; others: the bootstrap),
   and `trust.spireDb.nodes` (host name -> address, from the placeholder
   `10.0.0.11-13` addressing).

So **adding a node** means: add it to `nodes` and `addresses` in
`hosts/default.nix`, give it a real hardware file, and (for spire-db) make sure
it appears in the address map — the module assertions enforce the three-node
invariant.

`fleet.colmena` adds `meta.nixpkgs` (required by colmena) plus per-node
`deployment` blocks (`targetHost`, `targetUser = "deploy"`,
`tags = [ "tier1" ]`). Addresses are placeholders until the management network
is final (see design 7.5).

### 3.5 The tools package (`pkgs/trust-tpm-tools/`)

`default.nix` is a `callPackage` that builds one `symlinkJoin` containing seven
`writeShellApplication`s. `common.sh` is **inlined into every script** (not
sourced from disk) so shellcheck sees all shared definitions; each script mutes
only the checks it legitimately trips (`SC2034`, `SC2329`).

Runtime contract (all overridable, defaults in `common.sh`):

| Variable               | Default                     | Meaning                                   |
| ---------------------- | --------------------------- | ----------------------------------------- |
| `TRUST_SEALED_DIR`     | `/var/lib/trust/sealed`     | sealed public/private blobs (0700)        |
| `TRUST_POLICY_PCRS`    | `7`                         | measured-boot PCRs the secret is bound to |
| `TRUST_LOCK_PCR`       | `14`                        | extended after release; blocks re-release |
| `TRUST_OPENBAO_SOCKET` | `/run/openbao/openbao.sock` | local unix socket of OpenBao              |
| `TRUST_UNSEAL_TIMEOUT` | `600`                       | seconds the unseal helper keeps retrying  |

Persistent handles: EK `0x81010001`, AK `0x81010002`. All working state lives in
a `mktemp -d` under `/dev/shm` (tmpfs), cleaned by an EXIT trap; the plaintext
secret never touches disk or argv (it goes through pipes/stdin).

The tool flow (design 4.5, mirrored by the VM tests):

```
enroll node            makecredential (admin ws, no TPM)      receive (node)
EK + persistent AK     EK-bound credential from secret  -->  activatecredential
 + ak.name.hex         (secret stays on the admin box)        (AK authenticates to
                                                             EK), then immediately:
                                                                   seal < secret
seal < secret              unseal                    lock
policy session over        load + policy session      extend lock PCR
POLICY_PCRS+LOCK_PCR,      over same PCRs,           with fixed marker -> no
create under primary,      print secret to stdout     process can release again
store pub/priv blobs       until reboot
```

`trust-openbao-unseal` ties it to OpenBao: it refuses to run without a sealed
object, exits `3` (unit: `RestartPreventExitStatus`) when the TPM refuses the
release (tampered boot chain / lock taken — only a reboot helps), otherwise
loops until `sys/seal-status` is unsealed, sending the key to `sys/unseal`
through a pipe, then locks the TPM.

### 3.6 The tests (`tests/`)

`tests/default.nix` takes `{ self, lib, pkgs }` and returns one attrset of
`pkgs.testers.runNixOSTest` derivations:

- **`tpm-seal`** (2 swtpm VMs): enrolment idempotence; an EK-bound credential is
  received by the right TPM and **rejected by another TPM**; release works in
  the sealed PCR state (PCR 13 in the VM); tampering PCR 13 blocks release;
  reboot restores it; the lock PCR blocks re-release; reboot clears the lock;
  re-sealing needs `--force`. Proves the whole TPM flow including that the
  plaintext never lands on disk or in the journal.
- **`admin-access`** (3 VMs: target, bastion, intruder): uses the snake-oil keys
  from nixpkgs (`nixos/tests/ssh-keys.nix`); proves bastion-only SSH, no
  root/password login, undeclared users refused, operator sudo allowlist (exact
  commands only), admin sudo via forwarded agent (`pam_ssh_agent_auth`),
  operators cannot forward an agent, `extraAllowedUsers` can log in but have no
  sudo, and that audited execs land in auditd (`ausearch -k exec`).
 - **`bao-cluster`** (4 VMs: 3-node cluster + admin workstation, all with swtpm;
   throw-away PKI from `tests/lib/pki.nix` — offline root, name-constrained
   transport CA, per-node certs): init exactly once, EK-bound delivery of the
   unseal key to every TPM, unseal without a human, 3-node raft ring, lock PCR,
   two audit devices (one sink broken), root-token revocation + `generate-root`
   through the unauthenticated endpoints, cold start, voter-loss failover with
   ring healing, a tampered node staying sealed while quorum survives, clean
   boot unsealing again.
- **`tests/hardware/tpm-smoke.sh`**: manual smoke test against a real
  `/dev/tpmrm0` (enrol + list EK/AK). Not part of the flake.

How a test is wired: each node's NixOS config `imports`
`self.nixosModules.default` (so a VM runs the _same_ module code as the real
hosts), the VM gets `virtualisation.tpm.enable = true` (swtpm), and `testScript`
is a Python script driven by the NixOS test driver. **Building a test runs it**:
the derivation's build phase executes the driver; a failing test fails the
build, and a successful build's output is an empty `vm-test-run-<name>`
directory.

Checks wiring in `flake.nix`: `checks.x86_64-linux` = all tests. Note the
shallow-merge trap: adding a per-system package attribute with `//` at the top
level replaces the whole system attrset — merge inside `forAllSystems` instead.

---

## 4. Development workflow

### 4.1 Setup

```
nix develop                     # nixfmt, statix, deadnix, tpm2-tools, swtpm,
                                # openbao, jq, openssl, age, ssss, shellcheck,
                                # colmena
```

### 4.2 Everyday commands

```
nix flake check --no-build      # evaluate every output (fast, no builds)
nix fmt -- --check <files>      # nixfmt (the flake's formatter); plain
                                # `nix fmt -- <files>` reformats in place
nix build .#                    # default package = trust-tpm-tools
nix build .#trust-tpm-tools
nix build -L .#checks.x86_64-linux.tpm-seal      # builds AND runs the VM test
nix build -L .#checks.x86_64-linux.admin-access
nix build -L .#checks.x86_64-linux.bao-cluster
nix build .#nixosConfigurations.trust-node-01.config.system.build.toplevel
                                                  # a full host closure
                                                  # (NOT .#nixosConfigurations.X —
                                                  # nix build can't address the
                                                  # configuration attr directly)
nix eval .#colmenaHive.deploymentConfig --json   # inspect the deployment hive
```

VM tests boot QEMU VMs: they need **KVM** to run at a reasonable speed (they
work under TCG, slowly; CI enables KVM on GitHub runners via a udev rule). A
passing check takes a few minutes on KVM.

### 4.3 Verifying a change

Run, in order:

1. `nix fmt -- --check $(git ls-files '*.nix')` — formatting,
2. `nix flake check --no-build` — all outputs still evaluate,
3. build the package(s) you touched,
4. re-run the relevant VM check(s) (building a check runs it),
5. if you touched `hosts/` or a host-facing module: build all three
   `nixosConfigurations.*.config.system.build.toplevel`,
6. update `docs/ROADMAP.md` test-status if test behaviour changed.

Content-addressing note: a VM test only re-runs when its derivation input hash
changes. Whitespace-only edits to evaluated code do **not** change derivation
hashes, so "build was a no-op" is valid evidence the existing test result still
applies to the tree.

### 4.4 CI (GitHub Actions)

`.github/workflows/ci.yml` runs on pushes to `main` and on every PR, in three
**sequential** jobs that mirror the 4.3 checklist (they share one GitHub
Actions cache key; parallel jobs race on it and hit the cache API rate limit):

- **`nix-checks`** — nixfmt, `nix flake check --no-build`, build
  `.#trust-tpm-tools`, shellcheck the tools, evaluate the colmena hive.
- **`host-closures`** — build all three `nixosConfigurations.*` toplevels
  (includes the lanzaboote boot closure).
- **`vm-tests`** — `nix build` of the three `checks.x86_64-linux.*` tests,
  **one at a time** (building a check runs its test driver), on a KVM-enabled
  runner; fails fast if KVM is unavailable. Sequential because the hosted
  runner (4 vCPU / 16 GiB) cannot hold all nine test VMs at once.

Nix is installed by `DeterminateSystems/nix-installer-action`, which also
configures the runner for KVM (exporting `DETERMINATE_NIX_KVM`);
`DeterminateSystems/magic-nix-cache-action` shares store paths between runs via
the GitHub Actions cache. Both are pinned to tags and kept current by
Dependabot (`.github/dependabot.yml`), which also opens weekly PRs for the
`flake.lock` inputs (`nixpkgs`, `lanzaboote`, `colmena`).

### 4.5 Adding a module

1. Create `modules/<name>.nix` with `options.trust.<name>.*` + a
   `config = lib.mkIf cfg.enable { ... }` block; keep it importable standalone
   (no imports of sibling modules).
2. Add it to `modules/default.nix` imports and to `nixosModules` in `flake.nix`.
3. Wire it into `hosts/tier1-common.nix` (or a host file) with real values.
4. Add a VM test under `tests/` that imports `self.nixosModules.default` and
   exercises the new option; export it from `tests/default.nix` and add it to
   `checks` (x86_64).
5. Update the Layout table in `README.md`.

### 4.6 Adding a host

1. Add the name to `nodes` and its address to `addresses` in `hosts/default.nix`
   (this also feeds `trust.spireDb.nodes`).
2. Replace `hosts/hardware-placeholder.nix` usage with the machine's generated
   hardware config (keep `mkDefault` so the placeholder keeps working for new
   machines).
3. Build `.#nixosConfigurations.<name>.config.system.build.toplevel`.
4. The colmena hive picks the node up automatically (same `modulesFor`).

### 4.7 Conventions

- Apache-2.0 header on every source file (`# SPDX-License-Identifier`).
- Nix files must pass the flake's `formatter` (nixfmt 1.x).
- Shell scripts in `pkgs/trust-tpm-tools` must stay shellcheck-clean;
  `common.sh` is inlined into every tool, so keep it self-contained.
- Secrets: nothing secret in the repo or in sops-nix; ceremony material and TLS
  material live in host paths under `/var/lib/trust` (see design 4.1). The
  `alice`/`bob` accounts and `10.0.0.11-13` addresses in
  `hosts/tier1-common.nix` / `hosts/default.nix` are placeholders to replace.
- `result`/`result-*` are gitignored build-output symlinks.

---

## 5. Status and known gaps

See `docs/ROADMAP.md` for the authoritative list. Current state:

- `tpm-seal`, `admin-access`, `bao-cluster`: passing (part of `checks`).
- `trust.spire` / `trust.spireDb`: evaluate and build into the host closures,
  but have no VM test yet.
- Signed PCR 11 policy (`PolicyAuthorize`) not implemented; `policyPcrs` is a
  plain PCR list (7 on hosts, 13 in VM tests).

## 6. Design documentation map

Section numbers are global across parts; cross-references in code comments point
at them.

| Part (docs/design/)     | Sections   | Content                                   |
| ----------------------- | ---------- | ----------------------------------------- |
| `index.md` (repo docs/) | 0, 1       | Summary, scope, decisions taken           |
| `trust-model.md`        | 2          | Tiers, perimeters, trust rules, threats   |
| `architecture.md`       | 3          | Overview, cold-start order, placement     |
| `building.md`           | 4          | Root CA, cluster, TPM policy, day-0       |
| `identity-perimeter.md` | 5          | keystone-rs KEK, Raft DEK, learners       |
| `kms-perimeter.md`      | 6          | KMS OpenBao and KMS service               |
| `administration.md`     | 7          | Roles, auth, break-glass, audit, staffing |
| `resilience.md`         | 8          | Failures, rollovers, rekey                |
| `crypto-inventory.md`   | 9          | FIPS and crypto inventory                 |
| `decisions.md`          | 10         | Resolved and open decisions               |
| `assumptions.md`        | Appendix A | Version assumptions to verify             |
