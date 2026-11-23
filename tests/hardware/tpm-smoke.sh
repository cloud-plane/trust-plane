#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Smoke test against the real TPM (/dev/tpmrm0): enroll, then print EK/AK.
set -euo pipefail
test -e /dev/tpmrm0
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
trust-tpm-enroll "$d"
ls "$d"
