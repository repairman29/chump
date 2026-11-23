#!/bin/bash
# test-fleet-dry-run.sh — INFRA-569: verify worker.sh --dry-run behavior.
#
# ACs:
#   (a) CHUMP_FLEET_DRY_RUN=1 env var activates dry-run mode.
#   (b) Prints the would-be branch name and worktree path.
#   (c) Exits 0 cleanly.
#   (d) No .chump-locks/fleet-*.json lease is written.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$WORKER" ]] || { echo "FAIL: $WORKER missing"; exit 1; }
[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

lock_dir="$TMP/.chump-locks"
mkdir -p "$lock_dir"

# Minimal fake gap list — two P1/xs INFRA gaps so the picker has something to pick.
cat > "$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-900","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":"","status":"open"},
  {"id":"INFRA-901","domain":"INFRA","priority":"P1","effort":"xs","created_at":1001,"depends_on":"","status":"open"}
]
EOF

# Stub chump: gap list returns fixture; everything else is a no-op.
mkdir -p "$TMP/bin"
gaps_json="$(cat "$TMP/gaps.json")"
cat > "$TMP/bin/chump" <<CHUMP
#!/bin/bash
case "\$*" in
  "gap list --status open --json") printf '%s\n' '$gaps_json' ;;
  *) exit 0 ;;
esac
CHUMP
chmod +x "$TMP/bin/chump"

# Common env for both test runs.
_common_env=(
    PATH="$TMP/bin:$PATH"
    AGENT_ID="1"
    FLEET_SESSION="testfleet"
    FLEET_LOG_DIR="$TMP/logs"
    FLEET_PRIORITY_FILTER="P0,P1"
    FLEET_EFFORT_FILTER="xs,s,m"
    FLEET_DOMAIN_FILTER="INFRA"
    FLEET_MODEL="haiku"
    IDLE_SLEEP_S="1"
    CHUMP_LOCK_DIR="$lock_dir"
    CHUMP_STARVE_AUTO_SHUTDOWN="1"
    CHUMP_STARVE_THRESHOLD="1"
)

# ── Test 1: --dry-run CLI flag ────────────────────────────────────────────────
echo "=== Test 1: --dry-run CLI flag exits 0 and prints WOULD claim ==="

out=$(
    env "${_common_env[@]}" bash "$WORKER" --dry-run 2>/dev/null || true
)

if echo "$out" | grep -q "^WOULD claim"; then
    echo "  PASS: output contains 'WOULD claim'"
else
    echo "  FAIL: expected 'WOULD claim' in output, got:"
    echo "$out"
    exit 1
fi

if echo "$out" | grep -q "^branch: chump/"; then
    echo "  PASS: output contains branch name"
else
    echo "  FAIL: expected 'branch: chump/...' line in output"
    echo "$out"
    exit 1
fi

if echo "$out" | grep -q "^worktree:"; then
    echo "  PASS: output contains worktree path"
else
    echo "  FAIL: expected 'worktree:' line in output"
    echo "$out"
    exit 1
fi

# ── Test 2: no fleet-*.json lease written (AC d) ──────────────────────────────
echo "=== Test 2: no fleet-*.json lease written ==="
lease_count=$(find "$lock_dir" -name "fleet-*.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$lease_count" == "0" ]]; then
    echo "  PASS: no fleet-*.json files in lock_dir"
else
    echo "  FAIL: found $lease_count fleet-*.json lease(s) — dry-run must not write leases:"
    find "$lock_dir" -name "fleet-*.json"
    exit 1
fi

# ── Test 3: CHUMP_FLEET_DRY_RUN=1 env var path (AC a) ────────────────────────
echo "=== Test 3: CHUMP_FLEET_DRY_RUN=1 env var activates dry-run ==="
rm -f "$lock_dir"/fleet-*.json 2>/dev/null || true
# Also clear any gap locks left by Test 1 so the picker sees fresh gaps.
rm -f "$lock_dir"/.gap-*.lock 2>/dev/null || true

out2=$(
    env "${_common_env[@]}" CHUMP_FLEET_DRY_RUN=1 bash "$WORKER" 2>/dev/null || true
)

if echo "$out2" | grep -q "^WOULD claim"; then
    echo "  PASS: CHUMP_FLEET_DRY_RUN=1 activates dry-run"
else
    echo "  FAIL: expected 'WOULD claim' with CHUMP_FLEET_DRY_RUN=1, got:"
    echo "$out2"
    exit 1
fi

lease_count2=$(find "$lock_dir" -name "fleet-*.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$lease_count2" == "0" ]]; then
    echo "  PASS: no fleet-*.json lease written via env var path"
else
    echo "  FAIL: found $lease_count2 fleet-*.json lease(s) via env var path"
    find "$lock_dir" -name "fleet-*.json"
    exit 1
fi

echo ""
echo "All fleet-dry-run tests passed."
