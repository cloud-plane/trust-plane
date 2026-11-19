---
title: "Root of Trust: Administration, Access and Audit"
linkTitle: "Administration"
weight: 6
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 7. Administration, access and audit

### 7.1 Principles

1. **Named accounts only**: individual identity in every system; no shared
   accounts, tokens or keys.
2. **No standing privilege**: day-to-day access observes and runs approved
   runbooks; changes go through reviewed code; elevation is time-boxed and
   logged.
3. **Two-person control** for anything that can change trust: policy, PKI,
   Transit key lifecycle, audit configuration, auth methods, seal key material,
   the PCR-policy signing key, admin-domain role assignments.
4. **Logs leave the box and the admin domain.**
5. **Admin access must not depend on what it administers**, nor on keystone-rs,
   except for cloud admins who use the Keystone API itself. Break-glass works
   with every other service down.
6. **Separation of duties** between operating, approving, auditing and custody.

### 7.2 Roles

| Role                        | Can                                                                                                                                          | Cannot                                                                   |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Custodian** (Tier 0)      | Hold one share; attend ceremonies                                                                                                            | Any Tier 1 access by virtue of the role                                  |
| **Ceremony officer**        | Run the signed tooling                                                                                                                       | Act without quorum and a witness                                         |
| **Security officer**        | Approve policy, PKI, Transit, audit and role-model changes; hold the PCR-policy signing approval; review audit; approve emergency operations | Deploy, SSH to hosts, hold shares or operator/admin roles                |
| **Auditor**                 | Read-only on the external log store and audit configuration                                                                                  | Any write                                                                |
| **Trust-plane admin**       | Author and apply NixOS/OpenBao/SPIRE changes through CI after approval; incident response                                                    | Approve own changes; change audit config; read secrets or key material   |
| **Trust-plane operator**    | Observability, approved runbooks (restart service, drain node), bastion SSH                                                                  | Writes to policy/PKI/Transit; sudo outside the allowlist                 |
| **Identity operator**       | `storage-operator` management RPCs within rate limits; observability; runbooks                                                               | Read DEK/KEK/signing keys; approve own emergency rotation; change policy |
| **Identity admin (deploy)** | Author and apply configuration, images and OPA policy through CI after approval                                                              | Approve own changes; touch the log pipeline                              |
| **Cloud admin**             | Keystone administration under OPA policy                                                                                                     | Operate hosts; read key material; change OPA policy                      |
| **Legacy DBA**              | Named DBA on the keystone SQL database; break-glass superuser                                                                                | Access to the SPIRE database or any trust-plane system                   |
| **KMS operator / deployer** | Same split as identity operator/admin for the KMS OpenBao and KMS service                                                                    | Root OpenBao admin; tenant key material                                  |

**Separation of duties:** no one approves their own change; a person holds at
most one of {trust-plane admin, identity admin, KMS deployer, security officer};
trust-plane admins hold no identity or KMS operator/admin roles. **Fewer than
the escrow threshold** of custodians (at most 2 of 5) may also hold a
trust-plane admin or security-officer role, so Tier 1 insiders cannot rebuild U
among themselves. If team size cannot satisfy a rule, record the exception and
its compensating control (extra review, logging alert) in the change system.

### 7.3 Identities and authentication

- **Hosts:** SSH only from the bastion network, only for named accounts with
  hardware-backed keys (FIDO2 `ed25519-sk`, touch and verify), declared in the
  NixOS configuration (so access changes are reviewed commits). SSH does not
  depend on OpenBao. Root login and passwords disabled.
- **OpenBao:** per-person **cert auth** with a client certificate from the
  offline admin CA (1 year), key on a PIV/FIDO token (touch + PIN); one entity
  per person, CN is the person id. OIDC against keystone-rs and userpass/TOTP
  are not used for admin roles. Tokens live <= 1 hour (max 4), are never
  persisted (token helper off), and are re-issued by fresh certificate login.
- **Policies by role** through groups (`bao-operator-ro`, `bao-admin-transit`,
  `bao-admin-pki`, `bao-admin-auth`, `bao-security-officer`, `bao-auditor`,
  `bao-issue-operator-cert`); nobody holds all; no human policy has `sudo` on
  `sys/` paths that change trust.
- **Service identities** (CI, per-node OpenBao Agent, SPIRE upstream authority):
  cert auth, narrow policies, short-lived tokens, no human-readable credentials.
- **Joiner/mover/leaver:** access by reviewed commit plus ticket; offboarding
  within 24 hours (remove key and OpenBao alias, revoke certificates, rotate
  anything readable). Each admin has two hardware tokens registered separately.

### 7.4 Root token and break-glass

- **No root token exists after day 0** (ceremony step 8). Tokens are never
  stored, put in CI or used for routine work.
- **Quorum path:** `generate-root` requires U. The intended path is **3 of 5
  custodians** in a Tier 0 ceremony. U can also be obtained from any node's TPM
  by someone who controls the PCR-policy signing key ([4.2](../building/)),
  which is why that key has the same custody as the escrow. The root token is
  used for one approved task, short TTL, revoked immediately, alerted and
  reviewed within 24 hours.
- **Sealed emergency identity:** a pre-issued admin certificate and key on a
  hardware token in a dual-control safe, bound to a full-admin role. Retrieval
  needs two people and a ticket; first use pages immediately; afterwards it is
  revoked and replaced in the next light ceremony; review within 24 hours. This
  identity is an **explicit exception to the CI-only write rule (7.5)**: it can
  write directly. Every write made with it must be reconciled into the
  repository by a normal reviewed pull request within 24 hours, and the drift
  job (7.5) stays red until that is done.
- **Host break-glass** (dual-control retrieval of emergency access) also covers
  the keystone-rs quorum-bypass path (7.6).

### 7.5 Two-person control and change flow

- **OpenBao trust-changing writes** (policy, auth method, audit device, PKI
  mount/import, Transit key deletion, `min_decryption_version`) are applied
  **only by the CI service identity** after a pull request with two approvals
  including the security officer; human admin policies are denied write there.
  The only exception is the sealed emergency identity (7.4).
  Vault-Enterprise-style control groups are not assumed in OpenBao
  ([item A6](../assumptions/)). A scheduled job diffs live configuration against
  the repository and alerts on drift.
- **Deployment** (colmena) runs from a dedicated CI runner in the Tier 1 admin
  network: protected `main`, signed commits, two approvals, CI builds and signs
  the closure; deploy credentials are short-lived and held by the runner. A new
  closure also needs a **signed PCR 11 policy**: a separate gate performed by
  the security officer with the signing key in an HSM, never on the runner. A
  compromised runner can therefore not ship a closure that unseals U.
- **The PCR-policy signing key is equivalent to the escrow quorum**
  ([4.2](../building/)): a signed policy for a malicious closure releases U on
  any node. Signing therefore needs the security officer **and** a second
  approver present (HSM M-of-N authentication or dual-control access), every
  signature is logged to the external store with the closure hash, and its
  backup lives in the escrow set. Suspected compromise triggers revocation of
  the key epoch and a rekey of U ([8.3](../resilience/)).
- **Cross-perimeter requests** (rule [2.2.6](../trust-model/)): new OpenBao
  roles, SPIRE entries or Transit keys for keystone-rs or the KMS are pull
  requests against the trust-plane repository, approved by the trust-plane
  security officer.
- **SPIRE** registration entries are code, applied by CI; the admin API is on a
  local socket; manual entries are break-glass and alert.

### 7.6 Per-area rules

**Tier 0.** Root and shares are used only in scheduled or pre-approved
ceremonies (annual intermediate signing, transport and admin CA renewal,
rollover, restore drill, emergency recovery). Each ceremony has a script in the
repository, an approved ticket, a witness who is not the officer, all required
custodians, a reproducibly built live ISO hash-verified by two people, an
air-gapped machine, recorded video and a signed transcript. Media custody is
logged (tamper-evident bags, two-person safe access, shares at separate sites).
Shares are verified annually; a leaving or demoted custodian triggers
re-splitting within 30 days. Admin enrolment is a light ceremony with two
approvals and in-person token provisioning.

**Trust plane (Tier 1).** Hosts are immutable NixOS, no standing interactive
root. `sudo` is allowlisted by role with I/O logging; sessions are recorded
(`auditd` + `tlog` or equivalent) and shipped off-box. PostgreSQL has named DBA
accounts with cert auth, superuser only through break-glass, `pgaudit` on DDL
and role changes. etcd and Patroni use per-person admin certs from the admin CA,
no shared root credentials.

#### Identity perimeter

- _Operations:_ `keystone-manage storage` uses gRPC with mTLS on the internal
  management network and a per-RPC allow-list keyed on client identity. Humans
  use **short-lived operator certificates** (<= 8 hours) from `pki-operators`,
  obtained after authenticating to OpenBao with a policy that can only issue the
  person's own operator certificate; the certificate carries the person id and
  the `storage-operator` tag. The existing limits are the floor: `RotateDek`
  2/hour, `ClearQuarantine` 10/hour per operator, emergency rotation confirmed
  by a second operator within 5 minutes with both identities audited. This
  design adds a ticket reference on each call and a security-officer
  notification for any emergency rotation.
- _Quorum-bypass emergency rotation:_ when quorum is lost, emergency DEK and
  OAuth2 signing-key rotations write only to the node's local emergency store
  (UDS + loopback) and are reconciled later. It needs local root, so it is used
  only through host break-glass, with mandatory reconciliation and review within
  24 hours.
- _Quarantine:_ `ClearQuarantine` is a security event: reason in the ticket,
  security officer notified, cause investigated first.
- _Cloud admins:_ the bootstrap admin is used once to create named
  administrators, then disabled (not a break-glass identity). Admins are
  individual accounts in a dedicated admin domain with WebAuthn, no shared
  account; automation uses application credentials or SPIFFE identities with
  narrow roles. Granting `admin`, changing role mappings or federation rules
  that mint admin is **two-person** through the configuration repository; direct
  human API writes to those objects are denied by OPA policy outside
  break-glass. Delegation decisions are keyed on the authentication chain, never
  on token scope.
- _Policy as code:_ `policy/` and role/mapping configuration have protected
  `main`, signed commits, two approvals, mandatory policy tests, and ship in the
  signed release; no human edits on a running node.
- _k8s pool (if used):_ no human `pods/exec`, `attach`, `portforward`,
  `secrets get/list`, `nodes/proxy` or ephemeral containers in the keystone
  namespace outside break-glass; `cluster-admin` is a separate alarmed group;
  deployments only by GitOps with admission policy requiring digest-pinned,
  release-signed images and denying privileged, `hostPath` and extra
  capabilities (only `IPC_LOCK`); Kubernetes audit at `RequestResponse` for
  secrets, exec, RBAC and admission in the namespace; k8s etcd encryption, if
  used, goes through the root OpenBao Transit as a platform consumer approved by
  the trust plane.
- _Releases:_ built by CI from a tagged commit with `cargo-deny` and `cargo-vet`
  passing, SBOM produced, artifacts and images signed, promotion needs two
  approvals, the deployed digest is audited, rollback uses the prior signed
  release. Key-handling changes also update the keystone-rs crypto inventory.

**KMS perimeter.** Same pattern with its own operator/deployer roles, its own
admin certificates, its own audit stream; destructive key operations are
two-person; no access to root OpenBao administration. KMS OpenBao trust-changing
writes (policy, mounts, audit devices) go through CI with two approvals like the
root's (7.5). The KMS OpenBao's own break-glass root token follows 7.4, with its
recovery material escrowed separately from the root's.

### 7.7 Logging, monitoring and review

#### Sources

- **OpenBao:** at least **two audit devices** (local file on a separate volume
  and a socket/syslog forwarder). OpenBao refuses requests when no audit device
  can log, so a second device keeps the cluster up if one sink fails. Sensitive
  fields remain HMAC-hashed. Audit device changes are trust-changing (7.5).
- **Hosts:** `auditd` (privileged execs, key files), journald remote forwarding,
  SSH/sudo sessions, TPM unseal and PCR-lock logs.
- **Services:** SPIRE server and registration changes, `pgaudit`, Patroni and
  etcd authentication and membership events, CI/deploy logs, ceremony
  transcripts.
- **keystone-rs:** CADF events: authentication, role and mapping changes, admin
  actions, revocations, management RPCs and dual-control events (both
  identities), quarantine, emergency rotation, local-store reconciliation,
  signing-key rotations. Legacy SQL DDL and role audit.
- Streams are separate per perimeter; OpenBao entries for keystone-rs roles
  (Transit calls) live in the trust-plane stream and are correlated by request
  id.

**Transport and storage:** forwarders write to an **append-only, write-once
store** in a separate admin domain; Tier 1 and Tier 2 admins cannot delete or
alter it, auditors read only; sink outages buffer to disk and alert. Time uses
authenticated sources; a daily hash-chain checkpoint is published to a Tier 0
location. Retention 1 year online, 7 years archived (adjust to compliance).

#### Alerts (page security officer / on-call)

- Trust plane: any `generate-root` or root-policy token use; any emergency
  identity use; any PCR-policy signature (with closure hash); KMS seal-key use
  from an unexpected token or address; seal/unseal events, TPM unseal or PCR
  failures, Raft peer changes; audit device added/removed/failing; policy,
  auth-method or mount changes not made by CI; drift; Transit key deletion or
  config change outside schedule; SPIRE entries created outside CI; new SSH
  login or sudo outside the allowlist; PostgreSQL/etcd role changes.
- Identity: emergency rotation, emergency-store write, quarantine or
  `ClearQuarantine`, DEK rotation outside schedule; management RPC from an
  unknown identity, denied operator action or rate-limit hit; new admin-domain
  role assignment, bootstrap-admin login, unusual admin login, mass revocation;
  OPA/mapping change outside CI; deployed digest differing from the signed
  release; k8s exec/RBAC change in the namespace; Raft membership change or
  learner join from an unexpected identity; abnormal Transit decrypt volume;
  attestation-key change.

**Review cadence:** weekly privileged-access review by the security officer;
monthly recertification of all roles, certificates and tokens; quarterly drills
(single-node rebuild, break-glass, quorum-loss emergency rotation and
reconciliation, quarantine recovery, learner join during an OpenBao outage);
yearly full restore from escrow and a full Tier 0 rehearsal including custodian
verification.

### 7.8 Staffing

Headcount follows from the rules in 7.1-7.6. These figures are derived from this
design, not from an external standard; the KMS perimeter is not counted (add 2-3
people if it is operated).

#### Constraints that drive the numbers

- Escrow is 3-of-5, so there are **5 custodians**, of whom **at most 2** may
  also be trust-plane admins or the security officer.
- Trust-plane changes need an author, a peer reviewer and the security officer
  as second approver; the security officer holds no admin or operator role.
- PCR-policy signing needs the security officer plus a second approver who is
  not the closure's author (a second security officer, or a custodian).
- Trust-plane admins hold no identity or KMS roles.
- Emergency DEK rotation needs **two distinct identity operators**.
- Ceremonies need three custodians, a ceremony officer and a witness who is not
  the officer.
- Auditor is independent of approvers.

#### Minimum by area

| Area                 | Hard minimum                                               | Recommended                       | Notes                                                                                                                   |
| -------------------- | ---------------------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Tier 0               | 5 custodians (3 per ceremony)                              | 5                                 | Officer and witness come from existing staff. Three custodians must hold no trust-plane admin or security-officer role. |
| Tier 1 (trust plane) | 2 admins/operators                                         | 3                                 | Author plus peer; security officer is the second approver.                                                              |
| Identity perimeter   | 2 (operators, deploy admins, cloud admins and DBA overlap) | 3                                 | Two operators satisfy dual control; a third covers absence.                                                             |
| Shared               | 1 security officer                                         | 2 security officers and 1 auditor | A single security officer blocks all trust changes and PCR signing when absent.                                         |

#### Totals

| Level         | People                                                                                                     | What it means                                                                                                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hard minimum  | **6**: 1 security officer, 2 trust-plane admins, 2 identity admins, 1 further custodian (e.g. the auditor) | Rules are satisfiable on paper. Custodians: 2 from the security officer and a trust-plane admin, 2 from identity admins, 1 other. Any absence blocks approvals, trust changes or ceremonies. |
| Recommended   | **9**: 2 security officers, 3 trust-plane admins, 3 identity admins, 1 auditor                             | Tolerates one absence per role. Response is business-hours with best-effort paging.                                                                                                          |
| 24/7 rotation | **about 12-14**: 4+ trust-plane, 5+ identity, 2 security officers, 1-2 auditors                            | Sustainable 1-in-4 to 1-in-5 pager rotation per perimeter.                                                                                                                                   |

#### If the team is smaller than the target

- Reduce the escrow to 2-of-3 custodians or use an HSM with quorum cards. This
  lowers custodian headcount but weakens the quorum guarantee.
- Borrow the security officer or auditor from another team or organisation, as
  long as they stay independent of operators and deployers.
- Have another team run ceremonies as officer and witness.
- Record every exception in the change system with a compensating control (extra
  review, additional alerting) and revisit it at the annual access-model review.
  Never merge approver and author roles for trust-changing changes.
