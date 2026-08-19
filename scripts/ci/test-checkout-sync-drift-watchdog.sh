#!/usr/bin/env bash
# scripts/ci/test-checkout-sync-drift-watchdog.sh — RESILIENT-149
#
# Verifies scripts/coord/checkout-sync-drift-watchdog.sh: the alarm on top
# of MISSION-027's checkout-sync daemon. If checkout-sync stalls (dead
# daemon, unloaded plist), the running checkout can drift silently behind
# origin/main — this watchdog catches that within a bounded commit-count /
# age tolerance and self-heals.
#
# Acceptance criteria verified (RESILIENT-149):
#   (1) A checkout already current with origin/main emits
#       checkout_sync_drift_ok and does nothing else (AC 3, quiet path).
#   (2) A checkout drifted past the commit-count tolerance emits
#       checkout_sync_drift_exceeded AND self-heals (fast-forwards the
#       checkout directly) without requiring human "git show origin/main:
#       script > file" surgical deploy (AC 1 + AC 2 + AC 3).
#   (3) A non-main branch is never touched.
#   (4) checkout_sync_drift_ok / checkout_sync_drift_exceeded are
#       scanner-anchored AND registered in EVENT_REGISTRY.yaml.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/coord/checkout-sync-drift-watchdog.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Static checks ───────────────────────────────────────────────────────────
[[ -x "$WATCHDOG" ]] || fail "checkout-sync-drift-watchdog.sh missing or not executable"
grep -q 'RESILIENT-149' "$WATCHDOG" || fail "RESILIENT-149 banner missing"

for kind in checkout_sync_drift_ok checkout_sync_drift_exceeded; do
    grep -q "scanner-anchor: \"kind\":\"$kind\"" "$WATCHDOG" \
        || fail "$kind missing its scanner-anchor comment"
    grep -q "kind: $kind" "$REG" \
        || fail "EVENT_REGISTRY.yaml missing kind: $kind"
done
ok "drift-watchdog events are scanner-anchored and registered"

# ── Fixtures ─────────────────────────────────────────────────────────────────
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"

CHECKOUT="$TMP/checkout"
git clone -q "$ORIGIN" "$CHECKOUT"
(
    cd "$CHECKOUT" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "v1" > pick_gap.py
    git add pick_gap.py
    git commit -q -m init
    git push -q -u origin main
)
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

run_watchdog() {
    CHUMP_SYNC_TARGET_DIR="$CHECKOUT" "$@" bash "$WATCHDOG"
}

# ── (1) Already-current checkout: quiet ok path ─────────────────────────────
OUT="$(CHUMP_SYNC_TARGET_DIR="$CHECKOUT" bash "$WATCHDOG" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "already-current watchdog run should exit 0, got $RC: $OUT"
grep -q '"kind":"checkout_sync_drift_ok"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    || fail "already-current watchdog run should emit checkout_sync_drift_ok"
ok "already-current checkout is a clean, quiet ok path"

# ── (2) Drift within tolerance: quiet, no alert ─────────────────────────────
SECOND="$TMP/second-clone"
git clone -q "$ORIGIN" "$SECOND"
(
    cd "$SECOND" || exit 1
    git config user.email "test2@example.com"
    git config user.name "Test2"
    git checkout -q main
    echo "v2" > pick_gap.py
    git add pick_gap.py
    git commit -q -m "one commit behind"
    git push -q origin main
)
: > "$CHECKOUT/.chump-locks/ambient.jsonl"
OUT="$(CHUMP_SYNC_TARGET_DIR="$CHECKOUT" CHUMP_CHECKOUT_DRIFT_MAX_COMMITS=10 CHUMP_CHECKOUT_DRIFT_SLO_SECS=1800 bash "$WATCHDOG" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "within-tolerance drift should exit 0, got $RC: $OUT"
grep -q '"kind":"checkout_sync_drift_exceeded"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    && fail "within-tolerance drift should NOT emit checkout_sync_drift_exceeded"
[[ "$(cat "$CHECKOUT/pick_gap.py")" == "v1" ]] \
    || fail "within-tolerance drift should not self-heal / mutate the checkout"
ok "drift within tolerance stays quiet and does not touch the checkout"

# ── (3) Drift past commit-count threshold: alert + self-heal ───────────────
(
    cd "$SECOND" || exit 1
    for i in 2 3 4; do
        echo "v$i" > pick_gap.py
        git add pick_gap.py
        git commit -q -m "commit $i"
    done
    git push -q origin main
)
: > "$CHECKOUT/.chump-locks/ambient.jsonl"
OUT="$(CHUMP_SYNC_TARGET_DIR="$CHECKOUT" CHUMP_CHECKOUT_DRIFT_MAX_COMMITS=2 CHUMP_CHECKOUT_DRIFT_SLO_SECS=999999 bash "$WATCHDOG" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "exceeded-drift watchdog run should exit 0, got $RC: $OUT"
grep -q '"kind":"checkout_sync_drift_exceeded"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    || fail "checkout_sync_drift_exceeded not emitted when commit-count threshold exceeded"
[[ "$(cat "$CHECKOUT/pick_gap.py")" == "v4" ]] \
    || fail "watchdog did not self-heal (fast-forward) the drifted checkout"
ok "drift past the commit-count threshold alerts AND self-heals with no manual deploy"

# ── (4) Non-main branch is never touched ────────────────────────────────────
FEATURE="$TMP/feature-checkout"
git clone -q "$ORIGIN" "$FEATURE"
(
    cd "$FEATURE" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b some-feature-branch
)
BEFORE_SHA="$(cd "$FEATURE" && git rev-parse HEAD)"
OUT="$(CHUMP_SYNC_TARGET_DIR="$FEATURE" bash "$WATCHDOG" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "non-main branch watchdog run should exit 0 (clean skip), got $RC: $OUT"
AFTER_SHA="$(cd "$FEATURE" && git rev-parse HEAD)"
[[ "$BEFORE_SHA" == "$AFTER_SHA" ]] || fail "non-main branch checkout was mutated"
ok "a non-main checkout is never inspected/synced"

echo
echo "All checkout-sync-drift-watchdog tests passed."
