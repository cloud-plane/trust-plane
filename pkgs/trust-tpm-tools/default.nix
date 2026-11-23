# SPDX-License-Identifier: Apache-2.0
#
# Shell tooling for the TPM-bound unseal key (design 4.3 / 4.5).
#
# SKELETON: these scripts hold the secret in shell memory and files on tmpfs.
# They prove the flow in VM tests; production should replace the unseal helper
# with a small mlock'ing program (see docs/ROADMAP.md).
{
  lib,
  writeShellApplication,
  symlinkJoin,
  tpm2-tools,
  coreutils,
  gnugrep,
  jq,
  curl,
  xxd,
}:
let
  mk =
    name: runtimeInputs: text:
    writeShellApplication {
      inherit name text;
      runtimeInputs = [
        tpm2-tools
        coreutils
        gnugrep
        xxd
      ]
      ++ runtimeInputs;
      # shellcheck stays on; only the helpers each script does not use are muted.
      excludeShellChecks = [
        "SC2034"
        "SC2329"
      ];
    };

  # Inlined (not sourced) so shellcheck sees the shared definitions.
  commonSrc = builtins.readFile ./common.sh;

  enroll = mk "trust-tpm-enroll" [ ] ''
    ${commonSrc}
    out="''${1:?usage: trust-tpm-enroll OUTDIR}"
    mkdir -p "$out"

    # EK (deterministic from the endorsement seed) and a persistent AK.
    if handle_exists "$EK_HANDLE"; then
      tpm2_readpublic -c "$EK_HANDLE" -o "$out/ek.pub" > /dev/null
    else
      tpm2_createek -c "$EK_HANDLE" -G rsa -u "$out/ek.pub"
    fi

    if handle_exists "$AK_HANDLE"; then
      tpm2_readpublic -c "$AK_HANDLE" -o "$out/ak.pub" -n "$out/ak.name" > /dev/null
    else
      tpm2_createak -C "$EK_HANDLE" -c "$work/ak.ctx" -G rsa -g sha256 -s rsassa \
        -u "$out/ak.pub" -n "$out/ak.name"
      tpm2_evictcontrol -C o -c "$work/ak.ctx" "$AK_HANDLE" > /dev/null
    fi
    flush_transients
    xxd -p -c 256 "$out/ak.name" | tr -d '\n' > "$out/ak.name.hex"

    # EK certificate (real hardware only; verified against the vendor chain
    # and the hardware inventory by the ceremony, design 4.5 step 1).
    tpm2_getekcertificate -o "$out/ek.cert" 2> /dev/null || true
    echo "enrolled: $out"
  '';

  makecredential = mk "trust-tpm-makecredential" [ ] ''
    ${commonSrc}
    ek=""; name=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ek) ek="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) echo "usage: trust-tpm-makecredential --ek ek.pub --name HEX --out cred.blob < secret" >&2; exit 2 ;;
      esac
    done
    [ -n "$ek" ] && [ -n "$name" ] && [ -n "$out" ] || { echo "missing argument" >&2; exit 2; }
    umask 077
    cat > "$work/secret"
    tpm2_makecredential -T none -e "$ek" -s "$work/secret" -n "$name" -o "$out"
  '';

  seal = mk "trust-tpm-seal" [ ] ''
    ${commonSrc}
    force=0
    [ "''${1:-}" = "--force" ] && force=1
    mkdir -p "$SEALED_DIR"
    if [ -e "$SEALED_DIR/seal.priv" ] && [ "$force" -ne 1 ]; then
      echo "a sealed object already exists in $SEALED_DIR (use --force)" >&2
      exit 1
    fi
    make_primary
    tpm2_startauthsession -S "$work/sess.ctx"
    tpm2_policypcr -S "$work/sess.ctx" -l "$(pcr_selection)" -L "$work/policy.dat" > /dev/null
    tpm2_flushcontext "$work/sess.ctx"
    umask 077
    cat > "$work/secret"
    tpm2_create -C "$work/prim.ctx" -L "$work/policy.dat" -i "$work/secret" \
      -u "$SEALED_DIR/seal.pub" -r "$SEALED_DIR/seal.priv" > /dev/null
    echo "sealed to PCRs $(pcr_selection)" >&2
  '';

  receive = mk "trust-tpm-receive" [ seal ] ''
    ${commonSrc}
    [ "''${1:-}" = "--cred" ] && [ -n "''${2:-}" ] || { echo "usage: trust-tpm-receive --cred cred.blob" >&2; exit 2; }
    umask 077
    tpm2_startauthsession --policy-session -S "$work/sess.ctx"
    tpm2_policysecret -S "$work/sess.ctx" -c e > /dev/null
    tpm2_activatecredential -c "$AK_HANDLE" -C "$EK_HANDLE" -i "$2" \
      -o "$work/secret" -P "session:$work/sess.ctx" > /dev/null
    tpm2_flushcontext "$work/sess.ctx"
    # Seal immediately; the plaintext never leaves tmpfs and is removed on exit.
    trust-tpm-seal < "$work/secret"
  '';

  unseal = mk "trust-tpm-unseal" [ ] ''
    ${commonSrc}
    make_primary
    if ! tpm2_load -C "$work/prim.ctx" -u "$SEALED_DIR/seal.pub" -r "$SEALED_DIR/seal.priv" \
      -c "$work/seal.ctx" > /dev/null; then
      # The blob is missing or unparseable; no reboot can fix that.
      echo "cannot load the sealed object from $SEALED_DIR (corrupt or missing blobs)" >&2
      exit 4
    fi
    tpm2_startauthsession --policy-session -S "$work/sess.ctx"
    tpm2_policypcr -S "$work/sess.ctx" -l "$(pcr_selection)" > /dev/null
    tpm2_unseal -c "$work/seal.ctx" -p "session:$work/sess.ctx"
  '';

  lock = mk "trust-tpm-lock" [ ] ''
    ${commonSrc}
    # Extend the lock PCR with a fixed marker; any later unseal now fails.
    tpm2_pcrextend "$LOCK_PCR:sha256=0000000000000000000000000000000000000000000000000000000000000001"
  '';

  openbaoUnseal = mk "trust-openbao-unseal" [ jq curl unseal lock ] ''
    ${commonSrc}
    sock="''${TRUST_OPENBAO_SOCKET:-/run/openbao/openbao.sock}"
    timeout_s="''${TRUST_UNSEAL_TIMEOUT:-600}"

    api() { curl -sS --unix-socket "$sock" "$@"; }

    if [ ! -e "$SEALED_DIR/seal.priv" ]; then
      echo "no sealed unseal key in $SEALED_DIR: waiting for the provisioning ceremony" >&2
      exit 1
    fi

    # Release the key. Policy failure (tampered boot chain, lock already
    # taken) ends here and leaves the node sealed.
    rc=0
    key="$(trust-tpm-unseal)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 4 ]; then
        echo "sealed object in $SEALED_DIR cannot be loaded (corrupt or missing); re-run the sealing ceremony" >&2
      else
        echo "TPM refused to release the unseal key (policy mismatch or lock taken); reboot required" >&2
      fi
      exit 3
    fi

    deadline=$(( $(date +%s) + timeout_s ))
    # jq's `//` would swallow sealed:false (false is falsy), so compare tostring.
    sealed() { api http://localhost/v1/sys/seal-status | jq -r '.sealed | tostring'; }
    while :; do
      if [ "$(sealed)" = "false" ]; then
        break
      fi
      # The key goes through a pipe, never through argv.
      printf '%s' "$key" | jq -Rn '{key: input}' |
        api -X PUT --data @- http://localhost/v1/sys/unseal > /dev/null || true
      if [ "$(sealed)" = "false" ]; then
        break
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "timed out waiting for unseal" >&2
        unset key
        exit 1
      fi
      sleep 2
    done
    unset key
    trust-tpm-lock
    echo "unsealed; lock PCR $LOCK_PCR extended" >&2
  '';
in
symlinkJoin {
  name = "trust-tpm-tools";
  paths = [
    enroll
    makecredential
    seal
    receive
    unseal
    lock
    openbaoUnseal
  ];
  meta = {
    description = "TPM sealing and OpenBao unseal helpers for the root-of-trust hosts";
    license = lib.licenses.asl20;
  };
}
