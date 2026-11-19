---
title: "Root of Trust: Trust Model"
linkTitle: "Trust Model"
weight: 1
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 2. Trust model

### 2.1 Tiers and perimeters

**Tiers** describe where things run; **perimeters** describe what trusts what.

| Tier   | Contents                                                                                                                                            |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tier 0 | Offline root CA, escrow shares, PCR-policy signing key, ceremony tooling. Offline.                                                                  |
| Tier 1 | Bare-metal trust plane hosts: OpenBao, SPIRE server and OIDC discovery provider, PostgreSQL/Patroni, etcd.                                          |
| Tier 2 | Hosts or dedicated k8s pools for keystone-rs (voters, learners, legacy SQL), the KMS OpenBao and the KMS service, all built to the Tier 2 baseline. |

| Perimeter                       | Guarantee                                                                                 | Members                                                                                          |
| ------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| **Root of trust** (trust plane) | Issues and anchors every infrastructure identity and key; nothing above it can forge them | Tier 0, TPM + measured boot, root OpenBao, SPIRE server and its database                         |
| **Identity**                    | Who a principal is and what it may do                                                     | Trust plane **+** keystone-rs and its legacy SQL database                                        |
| **KMS**                         | Custody of tenant and application keys                                                    | Trust plane **+** the KMS OpenBao (custody) **+** the KMS service (tenant API and authorization) |

The trust plane is the overlap. Neither the identity nor the KMS perimeter
contains the other: keystone-rs does not depend on the KMS OpenBao or the KMS
service, and the KMS OpenBao does not depend on keystone-rs (only the KMS
service's tenant authorization does). keystone-rs is inside the identity
perimeter and outside the root of trust.

### 2.2 Trust rules

1. **Dependencies point downward only.** Nothing a lower layer needs in order to
   start or to issue infrastructure identities may run on, or authenticate
   through, a higher layer. The trust plane never depends on keystone-rs, the
   KMS OpenBao, the KMS service, or any k8s cluster hosting them (no keystone
   OIDC for OpenBao admin roles, no keystone-based attestation of Tier 1 hosts,
   no OpenBao or SPIRE component on shared k8s). The **only** exception is the
   SPIRE VM attestor in rule 3, which is scoped so that it cannot affect SPIRE
   start or infrastructure identities.
2. **Compromise propagates upward, not downward.** A compromised trust plane
   compromises both other perimeters. A compromised keystone-rs cannot forge
   infrastructure identities or read Tier 1 keys; a compromised KMS service
   cannot forge identities or read platform keys.
3. **keystone-rs anchors tenant workload identity only (scoped exception to rule
   1).** SPIRE's planned VM attestor trusts keystone-rs's attestation key and
   fetches it from keystone-rs (`/v4/spiffe/{domain}/jwks`). This is the one
   place where a trust-plane component depends on keystone-rs. It is acceptable
   only under these conditions:
   - It issues **tenant SVIDs only**, under a reserved SPIFFE path
     (`spiffe://<td>/project/<id>/...`). Registration must make it impossible to
     map them to infrastructure entries or Tier 1 selectors.
   - It **fails closed**: if the JWKS is unreachable or invalid, tenant VM
     attestation is refused. It never falls back to cached keys beyond their
     validity or to another attestor.
   - It is **not on the start path**: SPIRE server start, node attestation of
     Tier 1/Tier 2 hosts and infrastructure SVID issuance never wait for
     keystone-rs.
   - The attestation key has its own rotation, audit and access policy, and the
     flow is listed in [3.4](../architecture/).
4. **Hardening follows perimeter membership, not tier.** Tier 2 hosts meet the
   Tier 1 baseline (measured boot, TPM, NixOS profile, restricted admin access,
   external audit).
5. **Caller identity is not key custody.** The KMS OpenBao's custody does not
   depend on keystone-rs; the KMS service's tenant authorization may. A forged
   keystone token can at worst _use_ the KMS API for a tenant, not extract key
   material or reach Tier 1 ([section 6](../kms-perimeter/)).
6. **No perimeter grants itself trust-plane access.** New OpenBao roles, SPIRE
   entries and Transit keys for another perimeter are reviewed and approved by
   the trust plane ([7.5](../administration/)).
7. **Few direct users of the root; everything else goes through them.** The only
   direct users of the root OpenBao are the trust plane itself (SPIRE upstream
   authority, PostgreSQL/etcd certificates, node identities), keystone-rs (KEK)
   and the KMS OpenBao (seal). All other services consume these indirectly:
   identity and certificates from **SPIRE**, who-is-who from **keystone-rs**,
   keys from the **KMS service**. (The KMS service itself talks to the KMS
   OpenBao, never to the root.) An **exception** for another control-plane
   service (e.g. k8s etcd encryption) is allowed but not the preferred route and
   needs: a written justification stating why SPIRE/keystone-rs/KMS cannot serve
   the need; approval by the trust-plane security officer and an entry in a
   **direct-consumer register** in the trust-plane repository; its own Transit
   key or PKI role with a policy bound to its SPIFFE ID; rate limits; no
   dependency on keystone-rs or the KMS (rule 1); and an annual review of
   whether it can move behind the KMS service. Anything a tenant can influence
   is never an exception.

### 2.3 Threat model (what each layer is meant to stop)

| Threat                             | Primary control                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Offline disk theft                 | TPM-sealed unseal key, LUKS bound to TPM, no secrets in sops                                                                                                                                                                                                                                                                                     |
| Tampered boot chain / evil maid    | Secure Boot + PCR 7 + signed PCR 11 policy                                                                                                                                                                                                                                                                                                       |
| Runtime root on a Tier 1 host      | **Not contained: equals full trust-plane compromise**, because OpenBao's process memory holds the keyring. Controls aim to prevent and detect it: immutable NixOS, no standing interactive root, per-service sandboxing, allowlisted sudo with session recording, external audit. The PCR 14 lock only stops a second TPM unseal of U after boot |
| Malicious or compromised CI/deploy | Closures need signed PCR 11 values, which only the security officer can authorise; trust-changing OpenBao writes need two approvals                                                                                                                                                                                                              |
| Compromised PCR-policy signing key | **As critical as the escrow quorum**: whoever holds it can sign a closure that unseals U on any node. Kept in an HSM, used only by the security officer with a second approver, separate from the CI runner; compromise triggers rekey ([8.3](../resilience/))                                                                                   |
| Stolen intermediate CA             | Name constraints, short leaf TTLs, dual-trust rollover (revocation by CRL is not relied on)                                                                                                                                                                                                                                                      |
| Insider with one role              | Separation of duties and two-person control ([7.2](../administration/), [7.3](../administration/))                                                                                                                                                                                                                                               |
| Loss of all Tier 1 TPMs or hosts   | 3-of-5 escrow of the unseal key, off-cluster snapshots, restore drills                                                                                                                                                                                                                                                                           |
| Compromised keystone-rs            | Own perimeter; reserved SPIFFE namespace. **Any node that holds the DEK, a learner included, can read all Raft data**; decrypt-only Transit stops a learner from creating wraps, not from reading. Hence learners run on Tier 2-baseline hosts and, in phase 2, lose Transit access entirely ([5.3](../identity-perimeter/))                     |
| Root OpenBao outage or compromise  | Outage: running keystone-rs and KMS OpenBao nodes keep serving, restarts wait ([8.1](../resilience/)). Compromise: keystone-rs's KEK and the KMS seal key are exposed, which is inherent to the trust plane; seal-key access is node-bound and audited ([4.2](../building/))                                                                     |
