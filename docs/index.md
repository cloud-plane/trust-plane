---
title: "Technical Design: Bare-Metal Root of Trust and Identity Platform"
linkTitle: "Root of Trust"
weight: 10
---

## 0. Summary

- An **offline root CA** (Tier 0) anchors everything and is touched only in
  scripted ceremonies. An **OpenBao cluster on three bare-metal NixOS nodes**
  (Tier 1) is the online platform CA. Its Transit engine serves platform
  consumers (e.g., keystone-rs's KEK) and is the auto-unseal seal of the KMS
  OpenBao; it holds no tenant keys. It is initialised **once**; its unseal key
  is delivered to each node's TPM through an EK-bound credential and also
  escrowed 3-of-5 offline, so reboots are unattended **and** recovery is
  possible. Because U is in every TPM, the **PCR-policy signing key** is as
  critical as the escrow quorum.
- **SPIRE** provides workload identity. Its datastore is a PostgreSQL cluster
  (Patroni + etcd) that is part of the trust plane. SPIRE's signing CA is an
  intermediate issued by OpenBao.
- **keystone-rs** (Raft storage plus legacy SQL) is the identity service. It
  uses SVIDs for peer mTLS and a **Transit KEK held on the root OpenBao** to
  wrap the Raft DEK, so keystone-rs depends only on the trust plane, but is not
  part of it. Every host that holds the DEK, learners included, is in the
  identity perimeter and meets its baseline.
- The system has three overlapping **perimeters**: root of trust (trust plane),
  identity (trust plane + keystone-rs) and KMS (trust plane + KMS OpenBao + KMS
  service). Dependencies point downward only; compromise propagates upward.
  keystone-rs belongs to the identity perimeter but is **not** part of the root
  of trust.
- Administration is by **named accounts, hardware tokens, reviewed code and
  two-person control**; there is no root token after day 0; all logs leave the
  boxes into a write-once store.

---

## 1. Scope and decisions

### 1.1 Goals

1. A trust anchor whose compromise requires a physical quorum.
2. Unattended reboot of Tier 1 nodes with hardware-bound keys **and** a tested
   human recovery path.
3. One Tier 1 (root) OpenBao cluster as platform CA, platform Transit KMS
   (keystone-rs KEK) and seal root of the KMS OpenBao. Tenant-facing key
   management never touches it.
4. SPIRE workload identity; keystone-rs peers authenticate with SVIDs.
5. A large fleet of keystone-rs Raft learners serving local reads: nothing may
   cost more per learner than one unwrap at start, rotation frequency must not
   grow with learner count, and the root OpenBao API must not become reachable
   from the whole fleet in the long run ([5.3](design/identity-perimeter/)).
6. Clear perimeters with enforceable admin, logging and placement rules.

### 1.2 Decisions taken

| #   | Decision                                                                                                                                                                                                                                                                                                                                                                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | keystone-rs runs **Raft storage** and, separately, the **legacy SQL drivers** on a dedicated database that is not SPIRE's.                                                                                                                                                                                                                                              |
| D2  | The SPIRE datastore is **inside the trust boundary**, not an external service. PostgreSQL with Patroni and etcd was chosen over CockroachDB and MySQL/Galera, because SPIRE documents PostgreSQL and recovery needs no custom bootstrap logic.                                                                                                                          |
| D3  | The root OpenBao serves Transit to **platform consumers** (keystone-rs's KEK; other platform services approved by the trust plane) and as the **auto-unseal seal** of the KMS OpenBao. It holds no tenant keys and is never exposed to tenants. Tenant-facing key management is a separate OpenBao (the KMS OpenBao) plus a KMS service. PKI stays on the root cluster. |
| D4  | The TPM KEK stays single-node; clusters use a shared KEK source (here: Transit, or PKCS#11 for FIPS). FIPS random IVs only under the `fips` feature. Breaking on-disk and key-hierarchy changes are acceptable; no migration.                                                                                                                                           |
| D5  | Trust plane services may share the three Tier 1 hosts; keystone-rs, the KMS OpenBao and the KMS service never run on them.                                                                                                                                                                                                                                              |
| D6  | keystone-rs depends **only** on the trust plane (root OpenBao Transit, SPIRE, PKI): not on the KMS OpenBao or the KMS service.                                                                                                                                                                                                                                          |

### 1.3 Non-goals

Multi-region OpenBao, FIPS-validated operation of the Transit path
([section 9](design/crypto-inventory/)), tenant-facing KMS API design.

## Parts of this design

Section numbers are global across all parts; cross-references link to the part
that holds the section.

| Part                                             | Sections   | Content                                                                 |
| ------------------------------------------------ | ---------- | ----------------------------------------------------------------------- |
| [Trust Model](design/trust-model/)               | 2          | Tiers, perimeters, trust rules, threat model                            |
| [Architecture](design/architecture/)             | 3          | Overview, cold-start order, placement, network flows                    |
| [Building the Root of Trust](design/building/)   | 4          | Root CA, OpenBao cluster, TPM policy, lifecycle, day-0 ceremony         |
| [Identity Perimeter](design/identity-perimeter/) | 5          | keystone-rs KEK, Raft DEK, learner fleet                                |
| [KMS Perimeter](design/kms-perimeter/)           | 6          | KMS OpenBao and KMS service                                             |
| [Administration](design/administration/)         | 7          | Roles, authentication, break-glass, two-person control, audit, staffing |
| [Resilience](design/resilience/)                 | 8          | Events, dual-trust rollover, rekey of U, SPIRE PostgreSQL               |
| [Crypto Inventory](design/crypto-inventory/)     | 9          | FIPS and crypto inventory                                               |
| [Decisions](design/decisions/)                   | 10         | Resolved and open decisions                                             |
| [Assumptions](design/assumptions/)               | Appendix A | Behaviour to verify against deployed versions                           |
