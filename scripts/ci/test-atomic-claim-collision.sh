#!/usr/bin/env bash
# scripts/ci/test-atomic-claim-collision.sh — INFRA-1608
#
# Regression test for the INFRA-1602 double-lease collision: two (and, at
# higher concurrency, fifty) synthetic claimants racing for the same gap_id
# via crates/chump-atomic-claim/src/atomic_claim.rs's per-gap claim mutex.
#
# Acceptance criteria verified (INFRA-1608):
#   AC5: exactly one of two racing claimants wins; the loser observes the
#        winner's lease at its mutex-protected re-check.
#   AC6: under 50-way concurrency, exactly one winner and zero double-claims
#        persist in the lock dir.
#
# The mock workers + synthetic backend are Rust threads racing
# `acquire_gap_claim_mutex` / `find_competing_session` / `write_basic_lease`
# against a shared tempdir — see `mod tests` in atomic_claim.rs for the
# actual assertions; this script is the CI-facing entrypoint (INFRA-1673
# local-CI-discipline convention: every gate has a `scripts/ci/test-*.sh`).
#
# See docs/audits/lease-collision-2026-05-17.md for the root-cause writeup.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

export PATH="$HOME/.cargo/bin:$PATH"

OUT="$(cargo test -p chump-atomic-claim --lib gap_claim_mutex -- --test-threads=1 2>&1)"
STATUS=$?

echo "$OUT" | tail -40

[ "$STATUS" -eq 0 ] || fail "gap_claim_mutex test suite failed (exit $STATUS)"

echo "$OUT" | grep -q "gap_claim_mutex_serializes_two_racing_sessions ... ok" \
    || fail "two-racer test did not report ok"
echo "$OUT" | grep -q "gap_claim_mutex_serializes_high_concurrency ... ok" \
    || fail "50-way concurrency test did not report ok"
echo "$OUT" | grep -q "gap_claim_mutex_reclaims_stale_lock ... ok" \
    || fail "stale-lock reclamation test did not report ok"

ok "atomic-claim mutex: exactly-one-winner holds at 2-way and 50-way concurrency"

# Static: lease_overlap is scanner-anchored at its emit site (register/emit
# drift-gate pairing, see docs/observability/EVENT_REGISTRY_FORMAT.md).
grep -q 'scanner-anchor: "kind":"lease_overlap"' \
    crates/chump-atomic-claim/src/atomic_claim.rs \
    || fail "lease_overlap missing its scanner-anchor comment"
ok "lease_overlap is scanner-anchored at its emit site"

grep -q "^  - kind: lease_overlap$" docs/observability/EVENT_REGISTRY.yaml \
    || fail "lease_overlap missing from EVENT_REGISTRY.yaml"
ok "lease_overlap is registered in EVENT_REGISTRY.yaml"

echo "PASS: atomic-claim-collision (INFRA-1608)"
