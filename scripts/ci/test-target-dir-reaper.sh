#!/usr/bin/env bash
# test-target-dir-reaper.sh — INFRA-1349
#
# Verifies scripts/coord/target-dir-reaper.sh:
#   1. Skips worktrees with an active lease (heartbeat fresh)
#   2. Skips worktrees with target/ idle below threshold
#   3. Reaps worktrees whose target/ is idle ≥ threshold (under pressure or
#      via --force)
#   4. Emits kind=target_artifact_reaped per reaped dir with all required
#      fields
#   5. Honors TARGET_REAPER_WORKTREE_GLOB so the test doesn't have to
#      depend on /private/tmp/chump-* state on the host

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/coord/target-dir-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: $REAPER missing/not executable" >&2; exit 2; }

WORK=$(mktemp -d /tmp/chump-1349-test.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== INFRA-1349 target-dir-reaper tests ==="

# ── Build 3 fake worktrees ──────────────────────────────────────────────────
#   wt-stale     idle 100h, no lease → should reap
#   wt-fresh     idle 1h,  no lease → should KEEP (under threshold)
#   wt-leased    idle 100h, has live lease → should KEEP
for name in wt-stale wt-fresh wt-leased; do
    mkdir -p "$WORK/$name/target/debug"
    echo "artifact" > "$WORK/$name/target/debug/foo.o"
done
# Backdate the stale + leased worktrees' target/ to 100h ago
backdate=$(date -v-100H +%Y%m%d%H%M.%S 2>/dev/null || date -d "100 hours ago" +%Y%m%d%H%M.%S)
find "$WORK/wt-stale/target" "$WORK/wt-leased/target" -exec touch -t "$backdate" {} +

# ── Build the live lease for wt-leased ─────────────────────────────────────
# NB: lease_is_fresh treats `age=0s` as "no heartbeat" (parse-failed sentinel).
# A just-written heartbeat would clock at 0s on a fast machine and incorrectly
# read as stale. Backdate the heartbeat by 10s so it parses as fresh-but-real.
mkdir -p "$WORK/.chump-locks"
past_iso=$(date -u -v-10S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-10 seconds" +%Y-%m-%dT%H:%M:%SZ)
future_iso=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ)
cat > "$WORK/.chump-locks/test-lease.json" <<EOF
{"session_id":"test-lease","gap_id":"INFRA-1349-TEST","worktree":"$WORK/wt-leased","heartbeat_at":"$past_iso","expires_at":"$future_iso"}
EOF

ambient="$WORK/ambient.jsonl"
: > "$ambient"

# Point the reaper at our test setup
export CHUMP_AMBIENT_LOG="$ambient"
export TARGET_REAPER_WORKTREE_GLOB="$WORK/wt-*"
# Point lease lookup at the test's .chump-locks (lease.sh honors this env).
export CHUMP_LOCK_DIR="$WORK/.chump-locks"
export CHUMP_LEASE_HEARTBEAT_TTL_S=3600

# ── Run reaper in --execute --force ────────────────────────────────────────
bash "$REAPER" --execute --force >"$WORK/reaper.out" 2>"$WORK/reaper.err" || true

# ── Assertions ────────────────────────────────────────────────────────────
if [[ -d "$WORK/wt-stale/target" ]]; then
    fail "wt-stale/target should have been reaped"
else
    ok "wt-stale/target reaped"
fi
if [[ -d "$WORK/wt-fresh/target" ]]; then
    ok "wt-fresh/target spared (idle below threshold)"
else
    fail "wt-fresh/target was reaped — should have been spared"
fi
if [[ -d "$WORK/wt-leased/target" ]]; then
    ok "wt-leased/target spared (active lease)"
else
    fail "wt-leased/target was reaped despite active lease"
fi

# ── Ambient assertion: target_artifact_reaped event with all required fields ─
if grep -q '"kind":"target_artifact_reaped"' "$ambient"; then
    ok "kind=target_artifact_reaped emitted"
else
    fail "no target_artifact_reaped event in ambient log"
    echo "--- reaper.out ---" >&2
    cat "$WORK/reaper.out" >&2
    echo "--- reaper.err ---" >&2
    cat "$WORK/reaper.err" >&2
    echo "--- ambient ---" >&2
    cat "$ambient" >&2
fi
for f in path freed_gb worktree_age_h reason; do
    if grep -q "\"$f\":" "$ambient"; then
        ok "ambient event has field '$f'"
    else
        fail "ambient event missing field '$f'"
    fi
done

# ── Stale-only event (one reap → exactly one event) ────────────────────────
n=$(grep -c '"kind":"target_artifact_reaped"' "$ambient" || echo 0)
if [[ "$n" -eq 1 ]]; then
    ok "exactly 1 target_artifact_reaped event emitted (1 reap)"
else
    fail "expected exactly 1 ambient event, got $n"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
