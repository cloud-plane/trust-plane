---
title: "Root of Trust: Building the Root of Trust"
linkTitle: "Building the Root"
weight: 3
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 4. Building the root of trust

### 4.1 Tier 0: root CA, hierarchy and escrow

- **Root CA:** ECC P-384, 10-year validity. Option A: generated on an air-gapped
  live ISO and Shamir-split (M-of-N) onto offline media, existing whole only in
  ceremony RAM. Option B: generated inside an HSM with M-of-N authentication
  (e.g. YubiHSM 2 or quorum-card HSM) and kept offline. PIV tokens with
  touch-always are for the offline root only.
- **Runtime HSM** (optional, for FIPS or HSM-sealed barrier): a network HSM or
  YubiHSM-class device without a touch policy; nothing at runtime needs a touch.
- **PKI hierarchy:**

```text
Offline Root (10y)
 |- Bao transport CA (offline, 1y)       Bao TLS + node client certs
 |- Admin CA (offline, 1y)               human admin client certs
 |- pki-infra intermediate (1y, in Bao)  PostgreSQL, etcd, SPIRE-to-DB clients
 |- pki-operators intermediate (1y, in Bao)  human operator certs (<= 8 h)
 '- pki-spire intermediate (1y, in Bao)  SPIRE UpstreamAuthority
```

`pki-operators` is separate from `pki-infra` because operator certificates are
issued to people on demand, while infrastructure certificates are issued to
services; a misused operator role must not be able to mint a service identity.

- Intermediate keys are **generated inside OpenBao**
  (`intermediate/generate/internal`); only the CSR leaves and only the signed
  certificate is imported. Each is **name-constrained** (infra DNS suffix;
  SPIFFE trust domain URI constraint for `pki-spire`; operator name space for
  `pki-operators`; Tier 1 DNS names for the transport CA).
- Verifiers trust the root plus the active intermediates. Most (rustls, SPIFFE
  libraries, PostgreSQL) do not check CRLs, so a compromised intermediate is
  handled by **dual-trust rollover ([8.2](../resilience/))**, not CRL. Short
  leaf TTLs bound the exposure meanwhile.
- **Escrow set**, reviewed annually: 3-of-5 shares of unseal key U; offline root
  shares; PCR-policy signing key backup (same quorum as U, see 4.2); LUKS
  recovery passphrases; location and credentials of the OpenBao snapshots.

### 4.2 The OpenBao cluster

- **Initialised exactly once**, on `trust-node-01`, in the day-0 ceremony. Nodes
  2 and 3 join the Raft ring and never run `operator init`; all three use the
  **same** unseal key U.
- Seal: Shamir **1/1**. U exists only in the three TPMs and the escrow. The
  consequence must be stated plainly: **U can be obtained either from 3 of 5
  custodians or from any one node's TPM**, by booting a closure whose PCR 11
  policy is signed. Control of the PCR-policy signing key is therefore
  equivalent to the escrow quorum, and both get the same custody
  ([7.5](../administration/)). A seal threshold with several keys per node would
  not change this, because every node must be able to unseal alone. If the
  deployed OpenBao offers a static-key seal or a PKCS#11 seal
  ([Appendix A](../assumptions/), [item A2](../assumptions/)), prefer it so the
  barrier key is wrapped by a key we control; with a network HSM use
  `seal "pkcs11"` and skip TPM delivery of U. With an auto-unseal seal,
  `generate-root` and rekey use **recovery keys**, not U: escrow the recovery
  keys 3-of-5 instead and adjust 4.5 and [7.4](../administration/).
- Raft on local NVMe, TLS everywhere, Autopilot on, **hourly snapshots** to an
  off-cluster object-lock target. Snapshots are barrier-encrypted: restoring
  needs U from escrow.
- **Transit on the root has two uses, both platform-internal.** (1) KEK keys for
  approved platform consumers, today keystone-rs (`transit-keystone/`, one
  policy per consumer, no cross-mount access); (2) one **seal key per downstream
  OpenBao cluster** (initially the KMS OpenBao), with a policy allowing
  `encrypt` and `decrypt` on that key alone. The KMS OpenBao nodes authenticate
  with a **periodic token** read from the transit seal configuration (Appendix
  A, [item A1](../assumptions/): the transit seal takes a token, not an auth
  method).
  - One token per KMS OpenBao node, **period 7 days**, bound by policy to the
    seal key and by `token_bound_cidrs` to that node's address.
  - Delivered in a provisioning step, sealed to the node's TPM under the 4.3
    policy **without** the PCR 14 lock (the renewing agent must read it at
    runtime), and renewed by an agent well inside the period.
  - Consequence: root on a running KMS OpenBao node can use the seal key. This
    is no worse than root on that node already reading the unsealed KMS keyring,
    but seal-key use is audited and alerted ([7.7](../administration/)) and an
    unexpected caller pages.
  - **Recovery:** a node offline for longer than 7 days, or whose token was
    revoked, gets a new token through a **light provisioning step**: two people
    (a KMS operator and a trust-plane admin), a ticket, a CI-applied token
    creation and a fresh TPM sealing on the node. No Tier 0 ceremony is needed.
    The old token is revoked first.

  No tenant or KMS-service key lives on the root.

### 4.3 TPM policy, unseal flow and node identity

**Policy** on the sealed U (per node) is the conjunction of:

- `PolicyPCR(7)`: Secure Boot policy unchanged.
- `PolicyAuthorize` over a **signed PCR 11 policy**: lanzaboote/systemd-stub UKI
  measurements (kernel, initrd, command line) must match a policy signed by the
  PCR-policy signing key (systemd-measure pcrsig). New NixOS generations are
  accepted without re-sealing when CI obtains a signed policy for their expected
  PCR 11; old vulnerable generations are rejected by key epoch or a revocation
  list in the policy.
- `PolicyPCR(14 = zeros)` **lock**: after unsealing, the service extends PCR 14,
  so any later unseal fails until the next reboot. PCR 14 is a
  **non-resettable** PCR: a resettable one (16, 23) would let any process that
  can open the TPM device reset the lock with `tpm2_pcrreset` and unseal again.
  It is used instead of PCR 15 because systemd extends PCR 15 during boot (e.g.
  the LUKS volume key via `tpm2-measure-pcr`, machine-id), which would make a
  "PCR 15 = zeros" policy fail on every boot. Nothing else in the boot chain may
  extend PCR 14 before the unseal step (shim measures MOK state there, so this
  holds only without shim; [Appendix A](../assumptions/),
  [item A14](../assumptions/)). The PCR is configurable per image
  (`trust.tpmUnseal.lockPcr`).

The lock prevents a second unseal of U from the TPM; it does **not** protect
against root on the running node, which can read the keyring from OpenBao's
memory ([2.3](../trust-model/)).

PCR 0 and 2 are not used (firmware and option-ROM updates would brick unattended
recovery). If firmware integrity is required, add PCR 0 and re-run the per-node
delivery (4.5, steps 4-5) after each firmware update.

**LUKS.** Data volumes (OpenBao Raft, etcd, PostgreSQL) are LUKS2 volumes
unlocked by `systemd-cryptenroll --tpm2-device` with the same
`PCR 7 + signed PCR 11` policy (`--tpm2-public-key`), **without** the PCR 14
lock, and unlocked in initrd before the OpenBao unseal step. They protect
against offline disk theft only; once unlocked, the volume key is in kernel
memory. Each volume also has a recovery passphrase held in the escrow set (4.1).

**Boot flow:** OpenBao starts sealed; `openbao-unseal.service` runs before every
service that needs network or secrets: unseal the object, send U to `sys/unseal`
over the local Unix socket from stdin (never argv or the shell), extend PCR 14,
exit. The helper uses `mlock` and zeroizes memory. If the policy fails, the node
stays sealed and alerts; the other two keep quorum.

**Node identity.** Each Tier 1 node has a client certificate and OpenBao
listener/Raft certificates from the offline Bao transport CA (1 year, renewed in
the annual ceremony). The client key is generated **inside the TPM**
(non-duplicable) with a policy of `PCR 7 + signed PCR 11` (not the PCR 14 lock,
since runtime renewal needs it), used via a TPM PKCS#11 provider. A root process
on a running node can still _use_ it, so the cert-auth role is narrow: issue
from `pki-infra/issue/node-<hostname>` for that hostname only. **No secrets in
sops-nix**; it holds non-secret configuration only (any age identity is sealed
to the TPM under the same policy and unsealed in the same early step before the
lock).

### 4.4 Certificate and identity lifecycle

| Consumer                                     | Source                                                                                  | TTL                     | Renewal                                |
| -------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------- | -------------------------------------- |
| OpenBao listener, node client                | offline transport CA                                                                    | 1 year                  | annual ceremony, reload                |
| PostgreSQL, etcd, SPIRE-to-DB clients        | `pki-infra`                                                                             | 7 days                  | OpenBao Agent at 1/3 remaining, reload |
| Human operator certs                         | `pki-operators`                                                                         | <= 8 hours              | re-issued by the person after login    |
| SPIRE server signing CA                      | `pki-spire` via UpstreamAuthority (Vault-compatible plugin, [item A9](../assumptions/)) | 7-14 days               | SPIRE at half-life                     |
| X.509 SVIDs (Raft mTLS, SQL mTLS, workloads) | SPIRE                                                                                   | 1 hour default          | SPIRE agent                            |
| JWT-SVIDs to OpenBao                         | SPIRE                                                                                   | minutes, audience `bao` | per request                            |

Keys and certificates live in tmpfs (`0600`) except TPM-resident keys; renewal
uses OpenBao Agent templating and alerts at 50% TTL consumed without renewal.

### 4.5 Day-0 provisioning ceremony

Run with the ceremony tool (audited program in the repository, not ad-hoc
shell), from the admin workstation that colmena also uses, with three nodes
booted into their signed closure:

1. **Enrol hardware.** Read each TPM's EK public key and certificate; verify the
   chain to the vendor and compare the fingerprint with the inventory recorded
   at receiving. This prevents a rogue machine from receiving U.
2. **Initialise OpenBao once** on node 1 (`-key-shares=1 -key-threshold=1`). U
   and the initial root token exist only in the tool's memory.
3. **Escrow U.** Split 3-of-5 for five custodians on offline media; verify by
   reconstructing from three shares before continuing.
4. **Deliver U to each TPM.** `tpm2_makecredential` against each node's verified
   EK and the name of a node-created attestation key; the node runs
   `tpm2_activatecredential`, recovers U in RAM and **immediately seals it
   locally** under the 4.3 policy. Only the sealed blob reaches disk. The same
   EK-bound delivery is the recommended pattern wherever a secret must reach
   several TPMs.
5. **Unseal and join** nodes 2 and 3.
6. **Enable two audit devices**, so the rest of the ceremony is logged in
   OpenBao. Steps 1-5 happen before any audit device can exist; their audit
   record is the ceremony transcript and video ([7.6](../administration/)),
   which must cover every command and output of those steps except the secret
   values themselves.
7. **Bootstrap configuration:** cert auth, the CI role, admin roles bound to
   admin certificates, mounts, `pki-*` intermediates including `pki-operators`
   (CSR to Tier 0 for signing), Transit keys (keystone KEK, KMS seal key) and
   their policies, rate-limit quotas, minimal policies. CI applies further
   configuration from the repository afterward.
8. **Revoke the root token.** The tool zeroizes memory and exits.
