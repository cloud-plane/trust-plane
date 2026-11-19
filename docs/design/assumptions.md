---
title: "Root of Trust: Assumptions to Verify"
linkTitle: "Assumptions"
weight: 10
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## Appendix A: Assumptions to verify against deployed versions

Sections refer to these items by number. Each must be confirmed against the
deployed versions before the dependent part is built.

### OpenBao

- **A1.** Transit seal authenticates with a token only (no auth method);
  periodic-token renewal works for the seal; `token_bound_cidrs` is enforced
  ([4.2](../building/)).
- **A2.** Static-key or PKCS#11 seal availability, and the resulting
  recovery-key model ([4.2](../building/)).
- **A3.** Namespaces, if used to separate consumers.
- **A4.** JWT auth against the SPIRE OIDC discovery provider's JWKS
  ([5.1](../identity-perimeter/)).
- **A5.** Behaviour of `generate-root`, `operator rekey` and `operator rotate`
  with the 1/1 Shamir seal ([7.4](../administration/), [8.3](../resilience/)).
- **A6.** Absence of control groups; the CI gate is used instead
  ([7.5](../administration/)).
- **A7.** Audit-device failover: requests continue while one of two devices is
  healthy ([7.7](../administration/)).
- **A8.** Rate-limit quotas per auth role or path ([3.4](../architecture/),
  [5.3](../identity-perimeter/)).

### SPIRE

- **A9.** Vault-compatible UpstreamAuthority plugin against OpenBao
  ([4.4](../building/)).
- **A10.** Maintained TPM node attestor (10, open item 3).
- **A11.** Bundle rotation across a changing upstream root
  ([8.2](../resilience/)).

### PostgreSQL/Patroni/etcd on NixOS

- **A12.** `services.patroni` options.
- **A13.** etcd reloading rotated TLS files on new connections.

### TPM and boot

- **A14.** Nothing in the boot chain (firmware, systemd, initrd) extends PCR 14
  (non-resettable, unused without shim) before the unseal step ([4.3](../building/)).
- **A15.** `systemd-measure` signed PCR 11 policy flow with lanzaboote on the
  chosen hardware ([4.3](../building/); open item 1).
- **A16.** TPM PKCS#11 provider with a PCR policy on the node client key
  ([4.3](../building/)).
