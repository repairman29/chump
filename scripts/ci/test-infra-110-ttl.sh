#!/usr/bin/env bash
# test-infra-110-ttl.sh — Verify reserve-time pending_new_gap TTL is 2h
# in BOTH the shell (gap-reserve.sh) and Rust (gap_store.rs reserve_verified)
# code paths.
#
# INFRA-110 (2026-05-02): pre-INFRA-110 the two paths drifted:
#   - shell  gap-reserve.sh defaulted to 4h (GAP_CLAIM_TTL_HOURS=4)
#   - Rust   reserve_verified() hard-coded   1h (now + 3600 seconds)
#
# Whichever path won the lease-write race set a different squat window.
# This test pins both to 2h (7200s) so the next time someone tweaks one
# they have to tweak the other.
#
# This is a structural / text-grep test — runs in <1s, no SQLite or
# tokio runtime needed. The intent is "the source-of-truth literal
# matches the documented contract" not "a full reserve emits the right
# expires_at" (which the existing reserve tests cover end-to-end).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SHELL_SRC="$REPO_ROOT/scripts/coord/gap-reserve.sh"
# INFRA-1214: use source-grep.sh library instead of inline if/else
source "$(dirname "$0")/lib/source-grep.sh"
RUST_SRC=$(find_gap_store_path)

fail=0

# Shell side: GAP_CLAIM_TTL_HOURS default must be "2".
if ! grep -qE 'GAP_CLAIM_TTL_HOURS",[[:space:]]*"2"' "$SHELL_SRC"; then
    echo "FAIL: $SHELL_SRC does not default GAP_CLAIM_TTL_HOURS to \"2\" (INFRA-110)" >&2
    grep -nE 'GAP_CLAIM_TTL_HOURS' "$SHELL_SRC" >&2 || true
    fail=1
fi

# Rust side: reserve_verified() pending_new_gap expires_at must be now + 7200.
# (3600 = the old 1h default we are unifying away from.)
if grep -qE 'unix_to_iso_full\(now \+ 3600\)' "$RUST_SRC"; then
    echo "FAIL: $RUST_SRC still contains the pre-INFRA-110 1h TTL (now + 3600)" >&2
    grep -nE 'unix_to_iso_full\(now \+ 3600\)' "$RUST_SRC" >&2 || true
    fail=1
fi

if ! grep -qE 'unix_to_iso_full\(now \+ 7200\)' "$RUST_SRC"; then
    echo "FAIL: $RUST_SRC missing the INFRA-110 2h TTL literal (unix_to_iso_full(now + 7200))" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "OK: INFRA-110 reserve-time TTL is unified at 2h across shell + Rust paths"
fi

exit "$fail"
