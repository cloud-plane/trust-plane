---
title: "Root of Trust: Identity Perimeter (keystone-rs)"
linkTitle: "Identity Perimeter"
weight: 4
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 5. Identity perimeter: keystone-rs

### 5.1 KEK and the Raft DEK

keystone-rs generates a 256-bit DEK per cluster, holds it in process memory and
HKDF-derives the log, state, backup and audit keys. The KEK only **wraps and
unwraps that DEK** (`KekProvider::wrap_dek`/`unwrap_dek`). There is **no
per-record KMS call**. keystone-rs does hold key material at runtime; this
design does not claim it is keyless. `KekProvider` is **synchronous** and has
`env` (dev only), `pkcs11` and `tpm` implementations.

Required new work:

1. **`transit` KEK provider** (`storage-crypto-transit`), selected via
   `[distributed_storage] kek_provider = "transit"` (root OpenBao address,
   mount, key, auth). Call from `spawn_blocking` or make the trait async; it is
   used only at startup, after `FetchDek` and on DEK rotation, never on a hot
   path. Own wire envelope `[version][transit key version][ciphertext]`. **Bind
   each wrap to context** with a `derived=true` key and
   `context = cluster_id || dek_version`, so a wrapped DEK cannot be replayed
   into another cluster or substituted with an older DEK version.
2. **Auth to the root OpenBao with a JWT-SVID** (audience `bao`) through the JWT
   auth method against the SPIRE OIDC discovery provider's JWKS
   ([item A4](../assumptions/)), with separate roles bound to the voter and
   learner SPIFFE ID patterns (e.g. `spiffe://<td>/keystone/raft/voter/*`,
   `.../learner/*`).
3. **Least privilege:** voters (and any node that may lead and rotate) get
   `encrypt`, `decrypt`, `rewrap`. Learners fetch the already-wrapped DEK
   through `FetchDek`; their access is phased (5.3). Because the KEK is shared
   by construction, `FetchDek` works unchanged and a KEK mismatch between nodes
   cannot occur.
4. **Startup:** bounded retry with jitter; readiness stays false until unwrap
   succeeds. Running nodes survive a root OpenBao outage; a restarting node
   waits.
5. **Leader-side rewrap for `FetchDek`:** the leader unwraps the DEK and rewraps
   it to the joining learner's per-node TPM key, so the learner never calls
   Transit. Required for phase 2 (5.3). Optional: PCR/policy binding in
   `storage-crypto-tpm`.

### 5.2 Other keystone-rs integration

- **Raft peer mTLS** uses SPIFFE (`SpiffeListener`, trusted domains, `svid_path`
  pin). No OpenBao involvement.
- **Legacy SQL:** dedicated database cluster (any engine keystone-rs supports),
  mTLS via the existing `spiffe_managed` database configuration, DB role bound
  to the keystone-rs SPIFFE ID; unreachable from SPIRE's database segment.
  Rotation is bounded by file write plus reconnect detection, not per handshake.
- **Tokens and application keys:** Fernet/JWS keys stay with `key-repository`
  and `jwt-crypto`; moving them under Transit is a separate ADR.

### 5.3 Scaling to a large learner fleet

**Learners hold the DEK.** Whatever path delivers it, a learner can read all
Raft data, so learner hosts are in the identity perimeter and meet the Tier 2
baseline (rule [2.2.4](../trust-model/)). Decrypt-only Transit stops a learner
from creating wraps; it does not limit what a compromised learner can read.

#### Phased DEK delivery to learners

| Phase                   | How a learner gets the DEK                                                                                                          | Root OpenBao exposure                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 1 (first release)       | `FetchDek` returns the Transit-wrapped DEK; the learner unwraps it with a **decrypt-only** role                                     | Learner networks reach the root API, limited by source network and a rate-limit quota |
| 2 (after leader rewrap) | `FetchDek` returns the DEK rewrapped by the leader to the learner's per-node TPM key (5.1, item 5); the learner never calls Transit | Only voters reach the root API; the learner Transit role and network rule are removed |

The move to phase 2 is a tracked deliverable, not optional: phase 1 is accepted
only because the learner fleet is limited to Tier 2-baseline hosts.

- **Rotation frequency is independent of learner count.** The DEK is
  cluster-wide and rotated by the leader; the per-message HKDF nonce scheme
  removes the random-IV budget dependence on membership size. The Transit KEK
  rotates separately: rotate, the leader rewraps the stored DEK once
  (`transit/rewrap`), and `min_decryption_version` is raised only after every
  retired blob is rewrapped. No learner is contacted for either rotation.
- **Per-learner cost** in phase 1 is one Transit decrypt per process start and
  one per DEK rotation; in phase 2 it is one leader-side rewrap, with no root
  call. Measure the phase 1 volume.
- **Limits (phase 1):** fleet-wide restarts hit the active OpenBao node
  (standbys forward); mitigate with jittered backoff, a rate-limit quota on the
  learner role and a load test of N concurrent decrypts before rollout. A
  simultaneous OpenBao outage and voter restart blocks authentication; keep
  voters on different hosts and do not schedule both maintenance windows
  together.
- **Learners that cannot reach Tier 1** (edge) need phase 2. Until it is
  available they cannot be deployed.
