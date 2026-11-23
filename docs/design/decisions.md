---
title: "Root of Trust: Decisions and Open Items"
linkTitle: "Decisions"
weight: 9
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 10. Decisions and open items

### Resolved

- Root OpenBao Transit serves platform consumers and seals the KMS OpenBao;
  tenant key custody is the KMS OpenBao behind the KMS service (D3).
- keystone-rs depends only on the trust plane, not on any KMS component (D6).
- Direct users of the root are the trust plane, keystone-rs and the KMS OpenBao;
  other control-plane services are exceptions only, under the direct-consumer
  register (rule [2.2.7](../trust-model/)).
- Learners get the DEK in two phases: decrypt-only Transit on Tier 2-baseline
  hosts first, leader-side rewrap with no root access later
  ([5.3](../identity-perimeter/)).
- The post-unseal TPM lock uses PCR 14 (non-resettable, unused by systemd), not PCR 15 or the resettable PCR 23 ([4.3](../building/)).
- The SPIRE VM attestor's dependency on keystone-rs is the single, scoped
  exception to rule [2.2.1](../trust-model/) (rule [2.2.3](../trust-model/)).
- KMS OpenBao seal tokens: per node, 7-day period, re-provisioned by a
  two-person light step ([4.2](../building/)).

### Boot chain options

Open item 1 depends on the boot chain. lanzaboote is the working assumption; it
is documented as experimental, so the alternatives stay on the table until it
passes the gate below. The table is from general knowledge and has not been
verified against the chosen versions.

| Option                                                             | Approach                                                      | Strengths                                                  | Weaknesses                                                                                             |
| ------------------------------------------------------------------ | ------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| lanzaboote (current)                                               | NixOS-native Secure Boot, signing on the host                 | Best NixOS integration; generations stay cheap             | Experimental; stub is not a full systemd-stub UKI; signing key on the host; `.pcrsig` support unproven |
| systemd-boot + signed UKIs (fallback)                              | Build UKIs with `ukify`, sign, measure with `systemd-measure` | Upstream systemd path; signed PCR 11 policy is first-class | Thinner NixOS support; large images on the ESP limit rollback depth                                    |
| Signed UKIs from a CI/HSM signing host                             | Same as above, but built and signed off-host                  | Signing key never on a node; best fit for a root of trust  | Own pipeline to maintain; nodes cannot build their own generations                                     |
| GRUB with Secure Boot                                              | Signed shim and GRUB                                          | Mature; wide hardware support                              | Weaker measured-boot story; larger attack surface                                                      |
| `systemd-pcrlock`                                                  | Policy follows the TPM event log instead of fixed PCR values  | Tolerates firmware and boot-order changes                  | Young; could complement the signed PCR 11 policy rather than replace it                                |
| Remote attestation (Keylime) or network-bound unseal (Clevis/Tang) | A verifier or server releases the secret                      | No local PCR policy to maintain                            | Adds a runtime dependency and breaks unattended recovery                                               |
| Other OS (CoreOS, Flatcar, mkosi images)                           | Upstream Secure Boot and UKI tooling                          | Better supported chain                                     | Loses the declarative NixOS model this design relies on                                                |

Gate for keeping lanzaboote, to be proven on the target hardware:

- Unattended unseal works after a rebuild and a reboot.
- Rollback works after a bad generation.
- A firmware update does not break the PCR 7 policy.
- Key rotation works.

Preferred if the gate fails: signed UKIs from an off-host signing step. Pin the
chosen version and keep a recovery runbook for a node that fails to boot.

### Open

1. **Signed PCR 11 policy with lanzaboote ([item A15](../assumptions/)).** The
   unattended-unseal design depends on it. lanzaboote's stub is not a full
   systemd-stub UKI, and its support for signed PCR policies (`.pcrsig`) must be
   proven on the target hardware before anything else is built. Fallback:
   systemd-boot with signed UKIs.
2. **D3 (PKI):** PKI is assumed to stay on the root cluster; confirm.
3. SPIRE node attestor for TPM: a community plugin or `x509pop` with node
   certificates from the transport CA; confirm maintenance status
   ([item A10](../assumptions/)).
4. Verify every item in [Appendix A](../assumptions/) against the chosen
   versions.
5. Patroni/etcd sizing and failure drills on the target hardware.
6. Delivery date of leader-side rewrap (phase 2, [5.3](../identity-perimeter/));
   edge learners wait for it.
7. Who holds the five escrow shares and the PCR-policy signing key; whether the
   team size can satisfy the separation-of-duties rules without exceptions.
8. Capacity test for N concurrent Transit decrypts at the target fleet size
   (phase 1).
