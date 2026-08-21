#!/usr/bin/env bash
# CI test for INFRA-1324: scripts/coord/network-sync-daemon.sh
#
# Exercises `tick` against a throwaway repo with a synthetic
# pending-push.jsonl queue. No real network calls: CHUMP_NETWORK_CHECK_URL
# points at a local-only stub so we can drive both the "network available"
# and "network unavailable" branches deterministically, and
# CHUMP_NETWORK_SYNC_CACHE=0 disables the (optional) GitHub cache refresh so
# the test makes zero outbound calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DAEMON="${REPO_ROOT}/scripts/coord/network-sync-daemon.sh"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-network-sync-daemon] INFRA-1324 — network sync daemon"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.chump-locks"
cd "$REPO"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo "root" > README.md
git add README.md
git commit -q -m "root commit"

# Bare "origin" so a real push can succeed without network.
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
git remote add origin "$ORIGIN"
git push -q origin main

export CHUMP_LOCK_DIR="$REPO/.chump-locks"
export CHUMP_PENDING_PUSH_QUEUE="$CHUMP_LOCK_DIR/pending-push.jsonl"
export CHUMP_NETWORK_SYNC_CACHE=0
touch "$CHUMP_LOCK_DIR/ambient.jsonl"

# ── 1. Network unavailable — tick is a clean no-op, exits 0 ────────────────
echo
echo "[1. Network unavailable]"
export CHUMP_NETWORK_CHECK_URL="http://127.0.0.1:1/unreachable"
export CHUMP_NETWORK_CHECK_TIMEOUT_S=1
bash "$DAEMON" tick || fail "tick should exit 0 even when network is unavailable"
grep -q '"kind":"network_sync_tick".*"network_available":false' "$CHUMP_LOCK_DIR/ambient.jsonl" \
    && ok "network_sync_tick emitted with network_available:false" \
    || fail "expected network_available:false tick event"

# ── 2. Network available — flush a synthetic pending-push queue ────────────
echo
echo "[2. Network available — flush pending pushes]"
git checkout -q -b chump/gap-1 main
echo "feature-1" > feature-1.txt
git add feature-1.txt
git commit -q -m "GAP-1: add feature 1"
sha1="$(git rev-parse chump/gap-1)"
git checkout -q main

git checkout -q -b chump/gap-missing main
echo "feature-missing" > feature-missing.txt
git add feature-missing.txt
git commit -q -m "GAP-MISSING: will be deleted"
git checkout -q main
git branch -D chump/gap-missing >/dev/null

cat > "$CHUMP_PENDING_PUSH_QUEUE" << EOF
{"branch":"chump/gap-1","sha":"$sha1","ts":"2026-08-21T00:00:00Z","gap":"GAP-1"}
{"branch":"chump/gap-missing","sha":"deadbeef","ts":"2026-08-21T00:00:00Z","gap":"GAP-MISSING"}
EOF

# Use a real, always-reachable local server for the network check: since we
# have a local bare "origin", curl against the loopback isn't representative
# of api.github.com, so instead we point the check at a trivially-true probe
# via a `file://` URL curl can resolve locally.
export CHUMP_NETWORK_CHECK_URL="file://$WORK/origin.git/HEAD"
export CHUMP_NETWORK_CHECK_TIMEOUT_S=2

bash "$DAEMON" tick || fail "tick failed with network available"

n_synced="$(grep -c '"kind":"pending_push_synced"' "$CHUMP_LOCK_DIR/ambient.jsonl" || true)"
[[ "$n_synced" == "1" ]] && ok "1 kind=pending_push_synced event emitted (chump/gap-1)" \
    || fail "expected 1 pending_push_synced event, found $n_synced"

n_failed="$(grep -c '"kind":"pending_push_failed"' "$CHUMP_LOCK_DIR/ambient.jsonl" || true)"
[[ "$n_failed" == "1" ]] && ok "1 kind=pending_push_failed event emitted (chump/gap-missing, branch_missing)" \
    || fail "expected 1 pending_push_failed event, found $n_failed"

grep -q '"kind":"pending_push_failed".*"reason":"branch_missing"' "$CHUMP_LOCK_DIR/ambient.jsonl" \
    && ok "permanent failure correctly classified as branch_missing" \
    || fail "expected reason=branch_missing on the permanent failure"

remaining="$(wc -l < "$CHUMP_PENDING_PUSH_QUEUE" | tr -d ' ')"
[[ "$remaining" == "0" ]] && ok "pending-push queue drained to 0 entries (synced+permanent-failed both dequeue)" \
    || fail "expected 0 remaining queue entries, found $remaining"

git --git-dir="$ORIGIN" rev-parse --verify chump/gap-1 >/dev/null 2>&1 \
    && ok "chump/gap-1 landed on origin" \
    || fail "expected chump/gap-1 to be pushed to origin"

# ── 3. Cache sync skipped (disabled) is DEGRADED, not an error ─────────────
echo
echo "[3. Cache sync disabled — degraded, tick still succeeds]"
grep -q '"kind":"github_cache_sync_skipped".*"reason":"disabled"' "$CHUMP_LOCK_DIR/ambient.jsonl" \
    && ok "github_cache_sync_skipped emitted with reason=disabled" \
    || fail "expected github_cache_sync_skipped reason=disabled"

echo
echo "[test-network-sync-daemon] all checks passed."
