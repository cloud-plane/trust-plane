---
title: "Root of Trust: Architecture"
linkTitle: "Architecture"
weight: 2
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 3. Architecture

### 3.1 Overview

```text
TIER 0  OFFLINE (ceremonies only)
  Root CA (HSM, or Shamir-split on air-gapped ISO)   Escrow of unseal key U (3-of-5)
  Bao-transport CA, admin CA                          PCR-policy signing key (HSM)
        | signs intermediates, transport and admin certs (annual)
        v
TIER 1  trust plane, 3 bare-metal NixOS hosts (lanzaboote, TPM 2.0)
  OpenBao (ONE Raft HA cluster)
     pki-infra   intermediate: PostgreSQL, etcd, operator certs
     pki-spire   intermediate: SPIRE UpstreamAuthority
     pki-operators intermediate: short-lived human operator certs
     transit-*   platform Transit keys (keystone-rs KEK) and one seal key per
                 downstream OpenBao cluster (the KMS OpenBao)
  PostgreSQL x3 + etcd x3 (Patroni)   SPIRE datastore only
  SPIRE server x3                     CA signed by pki-spire
  SPIRE OIDC discovery provider       JWKS for OpenBao JWT auth
        |
        v
TIER 2  identity and KMS perimeters (separate hosts / dedicated k8s pools)
  keystone-rs Raft voters   KEK = root Transit (encrypt/decrypt/rewrap)
  keystone-rs legacy SQL    separate database, mTLS via SVID
  KMS OpenBao (HA)          tenant key custody; auto-unsealed by root Transit
  KMS service               tenant API and authorization, in front of the KMS OpenBao
  keystone-rs learners      Tier 2-baseline hosts; phase 1: Transit decrypt,
                            phase 2: leader rewrap, no Transit access (5.3)
```

SPIRE agents run on Tier 2 and learner hosts. Tier 1 services authenticate with
OpenBao-issued certificates, so agents are optional on Tier 1.

### 3.2 Cold-start order and acyclicity

```text
TPM / measured boot -> root OpenBao (offline-signed TLS) -> etcd -> PostgreSQL
  -> SPIRE server -> SPIRE agents -> keystone-rs (KEK from root Transit)
  and KMS OpenBao (unsealed by root Transit) -> KMS service
  (tenant authorization via keystone-rs)
```

The SPIRE VM attestor's use of keystone-rs JWKS (rule [2.2.3](../trust-model/))
is deliberately **not** on this path: it only gates tenant VM attestation, after
everything above is running.

- **OpenBao depends on nothing above itself.** Its listener/Raft certificates
  and node client credentials are signed offline ([4.3](../building/)). Only the
  JWT auth mount used by keystone-rs and other consumers calls the SPIRE OIDC
  discovery provider's JWKS; core OpenBao, its PKI and the node cert-auth path
  do not.
- **SPIRE servers authenticate to OpenBao with their node certificate (cert
  auth)**, not with SPIRE-issued JWTs, for UpstreamAuthority access.
- PostgreSQL and etcd certificates come from `pki-infra`, never from SPIRE.
- SPIRE needs OpenBao only at first start and when rotating its signing CA (TTL
  7-14 days, rotation at half-life). It therefore tolerates an OpenBao outage of
  up to half the CA TTL: about 3.5 days with a 7-day TTL, 7 days with 14.
- The Tier 1 audit sink is external to Tier 1; losing it does not stop OpenBao
  as long as a second audit device is healthy ([7.7](../administration/)).

### 3.3 Placement

| Component                                                                   | Where                                                                                                        | Notes                                                                                                        |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Offline root, escrow                                                        | Offline                                                                                                      | ceremonies only                                                                                              |
| OpenBao, SPIRE server (+ OIDC discovery provider), PostgreSQL/Patroni, etcd | Dedicated bare-metal Tier 1 hosts (three hosts shared by these four)                                         | not on shared k8s: cycle with k8s consumers; TPM/PCR lock needs bare metal                                   |
| keystone-rs voters, legacy SQL                                              | Separate Tier 2 hosts, or a dedicated k8s pool built to the same baseline                                    | never on Tier 1 hosts                                                                                        |
| keystone-rs learners                                                        | Tier 2 hosts or dedicated k8s pools built to the identity-perimeter baseline (rule [2.2.4](../trust-model/)) | they hold the DEK; phase 1 decrypt-only Transit role, phase 2 no root access ([5.3](../identity-perimeter/)) |
| KMS OpenBao                                                                 | Tier 2 hosts (bare metal preferred, because its seal token is TPM-sealed) or dedicated k8s pool              | auto-unsealed by root Transit; reachable only by the KMS service and its operators                           |
| KMS service                                                                 | Tier 2 hosts or dedicated k8s pool                                                                           | tenant-facing; talks to the KMS OpenBao                                                                      |

**Why keystone-rs is not on Tier 1 hosts:** it is the most exposed service (user
API traffic, auth and plugin code). A compromise on a Tier 1 host reaches the
local OpenBao socket and process memory, etcd, the database and the node's
TPM-held identity; root on a Tier 1 host is a full trust-plane compromise
([2.3](../trust-model/)). It also competes for fsync-sensitive NVMe with etcd,
OpenBao Raft and the PostgreSQL WAL, so bursts or snapshot catch-up can trigger
etcd elections or Patroni failovers.

**Co-locating the four trust-plane services on three hosts** requires: a
dedicated system user and systemd sandbox per service with strict socket
permissions; separate NVMe volumes for etcd, OpenBao Raft and the PostgreSQL WAL
with cgroup `IOWeight`/`MemoryMax`; per-service nftables; one-host-at-a-time
reboots behind a quorum-health gate; hosts spread across racks and power feeds
(two simultaneous host losses stop all four services).

**keystone-rs on k8s** is acceptable only if: the cluster is built to the
identity-perimeter baseline (kube-admin and the k8s etcd become part of
keystone's trusted base); a dedicated tainted node pool, namespace and
NetworkPolicy; `restricted` pod security, no `hostPath`, no shared service
accounts; an SPIRE agent issuing SVIDs only to keystone selectors; `IPC_LOCK`
for the mlocked DEK with swap off and core dumps disabled; Raft voters as a
StatefulSet on local NVMe with PodDisruptionBudgets; the **Transit KEK** from
the root OpenBao (a node-bound TPM KEK cannot follow a rescheduled pod); and a
k8s API that does **not** authenticate through keystone-rs.

### 3.4 Network flows (default deny; one row per allowed flow)

| From                                | To                                       | Purpose                                                                                                    |
| ----------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Tier 1 nodes                        | Tier 1 nodes                             | OpenBao Raft (8201), etcd peer (2380), PostgreSQL replication (5432), Patroni REST (8008), SPIRE server HA |
| Tier 1 services and OpenBao Agents  | OpenBao API (8200)                       | cert issuance and renewal, SPIRE upstream authority                                                        |
| Root OpenBao                        | SPIRE OIDC discovery provider (443)      | JWKS for the JWT auth mount                                                                                |
| SPIRE servers                       | PostgreSQL (5432) via HAProxy/multi-host | datastore                                                                                                  |
| SPIRE servers                       | keystone-rs attestation JWKS             | VM attestor, tenant SVIDs only, fail closed (rule [2.2.3](../trust-model/))                                |
| SPIRE agents                        | SPIRE servers (8081)                     | attestation, SVIDs                                                                                         |
| keystone-rs voters                  | Root OpenBao API (8200)                  | Transit KEK (JWT-SVID auth)                                                                                |
| keystone-rs learners (phase 1 only) | Root OpenBao API (8200)                  | Transit decrypt (JWT-SVID auth), rate-limited; removed in phase 2 ([5.3](../identity-perimeter/))          |
| keystone-rs voters                  | keystone-rs voters and learners          | Raft replication, `FetchDek` (SVID mTLS)                                                                   |
| keystone-rs learners                | keystone-rs voters                       | Raft, `FetchDek`, write forwarding (SVID mTLS)                                                             |
| keystone-rs                         | Legacy SQL database                      | SQL over SVID mTLS                                                                                         |
| KMS OpenBao nodes                   | Root OpenBao API (8200)                  | seal (Transit encrypt/decrypt on their seal key only)                                                      |
| KMS service                         | KMS OpenBao API (8200)                   | tenant key operations                                                                                      |
| KMS service                         | keystone-rs API                          | tenant token validation                                                                                    |
| Tier 1 nodes                        | Off-cluster backup target                | OpenBao snapshots, pgBackRest/WAL archive (write-only, object lock)                                        |
| keystone-rs voters                  | Off-cluster backup target                | Raft backups (write-only, object lock)                                                                     |
| Tenants                             | KMS service only                         | never the KMS OpenBao or the root                                                                          |
| Identity operators                  | keystone-rs management gRPC              | `keystone-manage`, management network only                                                                 |
| Admins                              | Tier 1 via bastion only                  | SSH, OpenBao API                                                                                           |
| All components                      | External log sink                        | write-only                                                                                                 |
| keystone-rs SQL                     | SPIRE's PostgreSQL                       | **denied**                                                                                                 |

(Ports shown are the products' defaults. Root OpenBao access from Tier 2 is
limited by source network per role, and every Tier 2 role has a rate-limit
quota.)
