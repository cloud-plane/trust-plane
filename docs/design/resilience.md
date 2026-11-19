---
title: "Root of Trust: Resilience and Recovery"
linkTitle: "Resilience"
weight: 7
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 8. Resilience and recovery

### 8.1 Events and responses

| Event                                           | Response                                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Root CA **lost** (shares gone), not compromised | Freeze intermediate rollover; leaves keep working until intermediates expire. New ceremony and dual-trust rollover before the earliest expiry.                                                                                                                                                                                                                  |
| Root or an intermediate **compromised**         | Remove the compromised CA from **all** trust stores immediately (a trust reset, not a CRL operation): run the rollover with the old CA removed at step 3. Rotate PKI roles, PostgreSQL/etcd certificates and the SPIRE trust bundle. If OpenBao's barrier was exposed, rotate the Transit key and then the DEK (`RotateDek`, emergency path with dual control). |
| All three Tier 1 nodes lost                     | Rebuild from the NixOS closure, ceremony steps 1 and 4 with U rebuilt from 3 escrow shares, restore the OpenBao snapshot, then etcd, PostgreSQL (pgBackRest) and SPIRE.                                                                                                                                                                                         |
| One Tier 1 node replaced (board, TPM clear)     | Re-enrol and re-deliver U to that node only, using U from escrow, never copied from a running node; rejoin.                                                                                                                                                                                                                                                     |
| U exposed or suspected exposed                  | Rekey (8.3). Covers: escrow shares at or above threshold leaked, PCR-policy signing key compromised, a signed closure found to leak U, root on a Tier 1 node.                                                                                                                                                                                                   |
| Custodian leaves or is demoted                  | Re-split U within 30 days ([7.6](../administration/)). If there is any doubt about collusion or share handling, rekey (8.3) instead.                                                                                                                                                                                                                            |
| Firmware update changes PCRs                    | Only matters if PCR 0 was added to the policy.                                                                                                                                                                                                                                                                                                                  |
| Root OpenBao outage                             | Running keystone-rs and KMS OpenBao nodes unaffected; a restarting keystone-rs node waits for the KEK unwrap and a restarting KMS OpenBao node waits for the seal; SPIRE tolerates days ([3.2](../architecture/)).                                                                                                                                              |
| KMS OpenBao or KMS service outage               | Tenant key operations fail; keystone-rs and the trust plane are unaffected.                                                                                                                                                                                                                                                                                     |
| PostgreSQL outage                               | SPIRE agents keep serving cached SVIDs until they expire (1 h default); keep the database recovery time below the SVID TTL or raise it for critical workloads.                                                                                                                                                                                                  |

### 8.2 Dual-trust rollover

1. Generate the new root and intermediates in a ceremony; do not issue yet.
2. Distribute old and new roots to **every** trust store: NixOS
   `security.pki.certificateFiles`, PostgreSQL/etcd CA files, OpenBao transport
   trust, SPIRE trust bundle (bundle APIs), keystone-rs `trusted_domains` and DB
   client CAs, SQL server CA; deploy by colmena and wait for all nodes.
3. Switch issuers: import new intermediates, point SPIRE's UpstreamAuthority at
   `pki-spire`, renew PostgreSQL/etcd certificates and the SPIRE CA.
4. Verify via metrics that nothing chains to the old root.
5. Remove the old root from every store and apply the final closure.

### 8.3 Rekey of the unseal key U

Re-splitting the escrow does not help when U itself may be known. Rekey replaces
U; it is a Tier 0 ceremony with the usual quorum and witness
([7.6](../administration/)).

1. If the PCR-policy signing key is suspect: generate a new one, revoke the old
   key epoch in the policy, and re-sign the current closure. Deploy it before
   step 3, so no node accepts a closure signed by the old key.
2. Run `bao operator rekey` with the current U (from escrow or from the ceremony
   quorum) to produce U'. If the barrier keyring may have been read (root on a
   Tier 1 node), also run `bao operator rotate` so new data is written under a
   new barrier key.
3. Deliver U' to each node's TPM through the EK-bound flow ([4.5](../building/),
   step 4) and seal it under the current policy; delete the old sealed blob.
4. Escrow U' 3-of-5 ([4.5](../building/), step 3) and destroy the old shares,
   with the destruction recorded in the transcript.
5. Take a fresh snapshot. **Snapshots taken before the rekey are still
   decryptable with the old U**: if U was exposed, treat the old snapshots as
   exposed, delete them once object-lock retention allows, and until then
   restrict access to the snapshot target to the restore drill role.
6. Rotate the downstream secrets whose exposure depends on the cause: Transit
   keys (keystone-rs KEK, then `RotateDek`; KMS seal key, then re-seal the KMS
   OpenBao), PKI intermediates by dual-trust rollover (8.2).

### 8.4 SPIRE PostgreSQL

Three nodes on Tier 1 under Patroni with a 3-member etcd; `synchronous_mode`
with `synchronous_mode_strict` so failover cannot lose acknowledged writes;
clients via HAProxy (Patroni REST health check) or libpq multi-host with
`target_session_attrs=read-write`. Certificate-only auth (`hostssl ... cert`,
`clientcert=verify-full`, `pg_ident` map from CN `spire-server-N` to role
`spire`). LUKS with a TPM-sealed key; never a key-management plugin that calls
OpenBao (cycle). pgBackRest or WAL-G to the off-cluster target with WAL
archiving. Cold start: etcd quorum, then Patroni elects the most advanced
replica; drill with a simultaneous power-pull of all three nodes. etcd carries
only Patroni state and uses `pki-infra` certificates.

**Availability trade-off:** with `synchronous_mode_strict` and three nodes, the
primary accepts writes only while at least one synchronous replica is up. If two
nodes are down, SPIRE writes (new registrations, node attestation, SVID issuance
that touches the datastore) stop until a replica returns; reads and cached SVIDs
continue (8.1). This is accepted in exchange for no lost writes on failover.
