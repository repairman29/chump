#!/usr/bin/env bash
# scripts/ci/test-node-orchestrator-max-throttle.sh — RESILIENT-328
#
# Proves node-orchestrator.sh:
#   1. enforce_cap() stops extras EVERY tick when WORKERS_UP has drifted above
#      WORKER_MAX, regardless of scale()'s own hysteresis mark.
#   2. scale()'s scale-up branch is throttled off when a recent
#      kind=merge_queue_health ambient event has backpressure_recommended=true,
#      even with idle CPU + free RAM that would otherwise trigger scale-up.
#   3. scale() still scales up normally when there is no backpressure signal.
#
# Sources the script (guarded so the daemon while-loop only runs when executed
# directly) and stubs systemctl via a PATH shim — no real systemd calls.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$REPO_ROOT/scripts/ops/node-orchestrator.sh"

[[ -f "$ORCH" ]] || { echo "[FAIL] $ORCH not found"; exit 1; }

echo "=== RESILIENT-328 node-orchestrator WORKER_MAX enforcement + CI-backpressure throttle ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

STOPPED_LOG="$TMPDIR_TEST/stopped.log"
STARTED_LOG="$TMPDIR_TEST/started.log"
: > "$STOPPED_LOG"
: > "$STARTED_LOG"

# Stub systemctl: record stop/start calls, no-op otherwise.
FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  stop)  echo "$2" >> "$STOPPED_LOG"; exit 0 ;;
  start) echo "$2" >> "$STARTED_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_BIN/systemctl"
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$FAKE_BIN/sudo"
export PATH="$FAKE_BIN:$PATH"
export STOPPED_LOG STARTED_LOG

STATE_DIR_TEST="$TMPDIR_TEST/state"
AMBIENT_TEST="$TMPDIR_TEST/ambient.jsonl"
mkdir -p "$STATE_DIR_TEST"

CHUMP_STATE_DIR="$STATE_DIR_TEST" CHUMP_AMBIENT_LOG="$AMBIENT_TEST" \
  source "$ORCH" 2>/dev/null || true

# ── Source-contract ─────────────────────────────────────────────────────────
for fn in enforce_cap ci_backpressure effective_max scale sense; do
  if declare -f "$fn" >/dev/null 2>&1; then
    ok "orchestrator defines $fn (sourced without running daemon loop)"
  else
    fail "orchestrator missing $fn or daemon loop ran during source"
  fi
done

# ── 1. enforce_cap() stops drifted-above-cap extras every tick ─────────────
: > "$STOPPED_LOG"
WORKER_MAX=1
CORES=4
WORKERS_UP=3
enforce_cap
if grep -q "chump-cj-worker3" "$STOPPED_LOG" && grep -q "chump-cj-worker2" "$STOPPED_LOG"; then
  ok "enforce_cap stops extras down to WORKER_MAX (3 workers, max=1 -> stopped worker3+worker2)"
else
  fail "enforce_cap did not stop drifted-above-cap extras (log: $(cat "$STOPPED_LOG" | tr '\n' ' '))"
fi
if [ "$WORKERS_UP" -eq 1 ]; then
  ok "enforce_cap converges WORKERS_UP to WORKER_MAX"
else
  fail "enforce_cap left WORKERS_UP=$WORKERS_UP, expected 1"
fi

# ── 2. enforce_cap() is a no-op when at/under cap ───────────────────────────
: > "$STOPPED_LOG"
WORKER_MAX=3
WORKERS_UP=2
enforce_cap
if [ ! -s "$STOPPED_LOG" ]; then
  ok "enforce_cap no-ops when WORKERS_UP <= WORKER_MAX"
else
  fail "enforce_cap stopped a worker despite being under cap"
fi

# ── 3. ci_backpressure() true on fresh backpressure_recommended=true event ─
cat > "$AMBIENT_TEST" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","kind":"merge_queue_health","queued_workflows":80,"auto_merge_prs":5,"queue_saturation_pct":160,"backpressure_recommended":true}
EOF
if ci_backpressure; then
  ok "ci_backpressure detects fresh backpressure_recommended=true event"
else
  fail "ci_backpressure did not detect fresh backpressure signal"
fi

# ── 4. ci_backpressure() false when latest event says no backpressure ──────
cat > "$AMBIENT_TEST" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","kind":"merge_queue_health","queued_workflows":2,"auto_merge_prs":1,"queue_saturation_pct":4,"backpressure_recommended":false}
EOF
if ! ci_backpressure; then
  ok "ci_backpressure is false when latest signal says no backpressure"
else
  fail "ci_backpressure incorrectly true on backpressure_recommended=false"
fi

# ── 5. ci_backpressure() false (fail-open) when no ambient log / no event ──
rm -f "$AMBIENT_TEST"
if ! ci_backpressure; then
  ok "ci_backpressure fails open (false) when no ambient log present"
else
  fail "ci_backpressure should fail open with no ambient log"
fi

# ── 6. scale() holds (does not scale up) under CI-queue backpressure ───────
cat > "$AMBIENT_TEST" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","kind":"merge_queue_health","queued_workflows":90,"auto_merge_prs":6,"queue_saturation_pct":180,"backpressure_recommended":true}
EOF
: > "$STARTED_LOG"
WORKER_MAX=0
CORES=8
LOADPCT=10
RAM_AVAIL_MB=8000
WORKERS_UP=2
rm -f "$STATE_DIR_TEST/.orch-scale-intent"
scale   # 1st tick: sets intent, no act yet (hysteresis) — but must NOT record scale-up intent target
scale   # 2nd tick: would confirm+act if intent was scale-up
if [ ! -s "$STARTED_LOG" ]; then
  ok "scale() does not start a new worker while CI-queue backpressure is active (idle CPU/RAM notwithstanding)"
else
  fail "scale() started a worker despite active CI-queue backpressure: $(cat "$STARTED_LOG")"
fi

# ── 7. scale() scales up normally once backpressure clears (control case) ──
rm -f "$AMBIENT_TEST"
: > "$STARTED_LOG"
rm -f "$STATE_DIR_TEST/.orch-scale-intent"
WORKERS_UP=2
scale
scale
if grep -q "chump-cj-worker3" "$STARTED_LOG"; then
  ok "scale() scales up normally when no backpressure signal is present (control case)"
else
  fail "scale() failed to scale up in the control (no-backpressure) case: $(cat "$STARTED_LOG")"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
