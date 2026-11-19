# Roadmap and known gaps

- Signed PCR 11 policy (PolicyAuthorize via systemd-measure) instead of
  plain PCR 7 policy; PCR 0/2 deliberately unused.
- Replace the shell unseal helper with a Rust helper that mlocks and
  zeroizes the secret.
- Forward audit logs off-host; session recording on bastions.
- VM tests for `spire-db` (Patroni/etcd failover), `spire` (vault
  UpstreamAuthority).
- Lock PCR is 14 (non-resettable; systemd uses 15, 23 is resettable). Verify on the real image that nothing extends 14 before unseal.
- Modules `spire-db`, `spire` evaluate but are untested.

## Test status (TCG, no KVM)

- `tpm-seal`: passes (9 subtests).
- `admin-access`: passes (10 subtests).
- `bao-cluster`: passes (12 subtests: init, EK-bound key delivery, TPM unseal
  without a human, three-voter Raft ring, lock PCR, two audit devices with a
  failing sink, root-token revocation + unauthenticated generate-root, cold
  start, voter-loss failover with ring healing, tampered boot state staying
  sealed, clean boot).
