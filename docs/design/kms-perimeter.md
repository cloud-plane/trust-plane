---
title: "Root of Trust: KMS Perimeter"
linkTitle: "KMS Perimeter"
weight: 5
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 6. KMS perimeter

### 6.1 Components

| Component                 | Role                                                                                  | Exposed to                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Root OpenBao** (Tier 1) | Platform CA, platform Transit (keystone-rs KEK), **seal root** of the KMS OpenBao     | Infrastructure certificate consumers, keystone-rs, KMS OpenBao nodes (seal), admins |
| **KMS OpenBao** (Tier 2)  | Tenant and application key custody; unsealed by the root's Transit                    | The KMS service and its operators. **Never tenants directly**                       |
| **KMS service**           | Tenant-facing API and authorization (Keystone tokens for tenants, SVIDs for services) | Tenants                                                                             |

### 6.2 Properties and rules

- **keystone-rs does not depend on any KMS component.** Its KEK is on the root
  ([5.1](../identity-perimeter/)); a KMS OpenBao or KMS service outage or
  compromise cannot block or expose keystone-rs.
- **Custody vs authorization.** Custody lives in the KMS OpenBao and never
  depends on keystone-rs. The KMS service's tenant authorization does. Controls:
  service callers authenticate with SVIDs; the KMS service enforces its own
  per-project policy and does not trust claimed roles; destructive operations
  (key deletion, raising `min_decryption_version`) need two-person control;
  key-use audit goes to its own stream of the external sink. A forged keystone
  token can at worst use the API for a tenant, not extract key material or reach
  Tier 1 or keystone-rs's KEK.
- **Seal dependency.** The KMS OpenBao needs the root only to unseal (start,
  restart, seal events). A root outage does not stop running KMS OpenBao nodes;
  a restarting node waits. Run at least three nodes and restart them one at a
  time so a root outage during maintenance cannot take the KMS down.
- **Seal-key compromise.** Whoever can use the seal key and read the KMS OpenBao
  storage can unseal it, so seal-key policy is node-bound (token and source
  address), audited and part of the trust-plane two-person flow.
- **Root load.** The root serves only keystone-rs unwraps, KMS OpenBao unseals
  and infrastructure PKI issuance; its API is not tenant-reachable, so tenant
  load cannot affect it.
