#!/usr/bin/env bash
# test-chump-doctor-fresh-reap.sh — ZERO-WASTE-052
# Validates reap_stale_doctor_fresh_tmp() in chump-binary-unwedge.sh: stale
# heal-tmp leaks (>60min) get swept, fresh ones (in-flight heal) survive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNWEDGE="${REPO_ROOT}/scripts/dev/chump-binary-unwedge.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-chump-doctor-fresh-reap.sh ==="

FAKE_TMPDIR=$(mktemp -d)
trap 'rm -rf "$FAKE_TMPDIR"' EXIT

STALE="${FAKE_TMPDIR}/chump-doctor-fresh-stale123"
FRESH="${FAKE_TMPDIR}/chump-doctor-fresh-fresh456"
touch "$STALE" "$FRESH"
touch -d "2 hours ago" "$STALE" 2>/dev/null \
  || python3 -c "import os,time; os.utime('${STALE}', (time.time()-7200, time.time()-7200))"

echo "--- Test: reap_stale_doctor_fresh_tmp sweeps >60min, keeps fresh ---"
(
  set +e
  set -u
  TMPDIR="$FAKE_TMPDIR"
  export TMPDIR
  # shellcheck disable=SC1090
  source "$UNWEDGE"
  reap_stale_doctor_fresh_tmp
)

[ -e "$STALE" ] && fail "stale heal-tmp leak was not reaped: $STALE"
pass "stale heal-tmp leak (2h old) reaped"

[ -e "$FRESH" ] || fail "fresh heal-tmp file (just created) was wrongly reaped: $FRESH"
pass "fresh heal-tmp file (<60min) survived"

echo "=== all tests passed ==="
