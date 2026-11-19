# SPDX-License-Identifier: Apache-2.0
# Shared settings for the trust-tpm-* tools. Sourced, not executed.

if [ -r /etc/trust/tpm.env ]; then
  # shellcheck source=/dev/null
  . /etc/trust/tpm.env
fi

SEALED_DIR="${TRUST_SEALED_DIR:-/var/lib/trust/sealed}"
# Comma separated PCRs the sealed object is bound to (the "measured boot" part).
POLICY_PCRS="${TRUST_POLICY_PCRS:-7}"
# Application PCR extended once the secret was released: later unseal attempts
# fail until the next reboot (design 4.3 runtime lock).
LOCK_PCR="${TRUST_LOCK_PCR:-14}"
EK_HANDLE=0x81010001
AK_HANDLE=0x81010002

# A TPM has only a few transient object slots; never leave any behind.
flush_transients() { tpm2_flushcontext -t > /dev/null 2>&1 || true; }

work="$(mktemp -d /dev/shm/trust-tpm.XXXXXX)"
cleanup() {
  flush_transients
  rm -rf "$work"
}
trap cleanup EXIT
flush_transients

pcr_selection() {
  if [ -n "$POLICY_PCRS" ]; then
    echo "sha256:${POLICY_PCRS},${LOCK_PCR}"
  else
    echo "sha256:${LOCK_PCR}"
  fi
}

make_primary() {
  tpm2_createprimary -C o -G ecc -g sha256 -c "$work/prim.ctx" > /dev/null
  flush_transients
}

handle_exists() {
  tpm2_getcap handles-persistent | grep -qi "$1"
}
