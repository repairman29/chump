#!/usr/bin/env bash
# scripts/ci/test-mission-122-build-storm-autosize.sh — MISSION-122
#
# Integration test: node-orchestrator.sh's auto-size enforcement (effective_max
# / enforce_cap / cargo_jobs_cap / scale) prevents the exact build-storm
# overload that hit CJ on 2026-08-22 — 14 workers x CARGO_BUILD_JOBS=4 = 56
# rustc threads on a 4-core box = 1400% load/core (see INFRA-3659, RESILIENT-328
# in scripts/ops/node-orchestrator.sh).
#
#   AC1. Launches a simulated node (sourced node-orchestrator.sh, stubbed
#        systemctl/sudo — no real daemon, no real systemd calls).
#   AC2. Spawns concurrent build jobs that reproduce the >1400%/core overload
#        (WORKERS_UP=14, LOADPCT=1400, CORES=4 — the CJ incident numbers).
#   AC3. Verifies enforce_cap()/cargo_jobs_cap() shed worker count and cap
#        aggregate rustc concurrency, and that scale() keeps shedding while
#        load pressure persists — i.e. new build capacity is rejected/shed,
#        not granted.
#   AC4. Source-contract check: fails loudly if enforce_cap/cargo_jobs_cap/
#        scale/effective_max are missing or renamed, so the test cannot
#        silently pass without the real enforcement in place.

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

echo "=== MISSION-122: build-storm overload prevention (auto-size node) ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

STOPPED_LOG="$TMPDIR_TEST/stopped.log"
STARTED_LOG="$TMPDIR_TEST/started.log"
: > "$STOPPED_LOG"
: > "$STARTED_LOG"

# Stub systemctl/sudo — the "simulated node" (AC1): no real units are
# stopped/started, every decision is recorded so the test can assert on it.
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

# ── AC4: source-contract — fails without the real enforcement in place ─────
for fn in enforce_cap cargo_jobs_cap effective_max scale; do
  if declare -f "$fn" >/dev/null 2>&1; then
    ok "orchestrator defines $fn (sourced without running daemon loop)"
  else
    fail "orchestrator missing $fn or daemon loop ran during source"
  fi
done

# ── AC2: simulated node reproducing the CJ build-storm (56 threads / 4
#    cores = 1400% per-core load) — the "previous overload threshold" ──────
CORES=4
WORKER_MAX=0          # auto: effective_max() falls back to cores-1
WORKERS_UP=14         # the incident's worker count
RAM_AVAIL_MB=8000     # plenty of RAM — this is a CPU-thrash scenario, not OOM
LOADPCT=1400          # 56 rustc threads / 4 cores * 100

naive_threads=$((WORKERS_UP * 4))
naive_loadpct=$(( naive_threads * 100 / CORES ))
echo "  (unenforced baseline: $WORKERS_UP workers x 4 jobs = $naive_threads threads -> ${naive_loadpct}%/core)"

# ── AC3a: enforce_cap() sheds the drifted worker count down to the budget ──
: > "$STOPPED_LOG"
enforce_cap
if [ "$WORKERS_UP" -eq 3 ]; then
  ok "enforce_cap() shed WORKERS_UP 14 -> 3 (effective_max = cores-1 = 3)"
else
  fail "enforce_cap() left WORKERS_UP=$WORKERS_UP, expected 3"
fi
if grep -q "chump-cj-worker14" "$STOPPED_LOG" && grep -q "chump-cj-worker4" "$STOPPED_LOG"; then
  ok "enforce_cap() actually stopped the excess worker units (worker4..worker14)"
else
  fail "enforce_cap() did not record stopping the excess workers: $(tr '\n' ' ' < "$STOPPED_LOG")"
fi

# ── AC3b: cargo_jobs_cap() caps AGGREGATE rustc concurrency to fit CORES ────
jobs=$(cargo_jobs_cap)
if [ "$jobs" -eq 1 ]; then
  ok "cargo_jobs_cap() caps CARGO_BUILD_JOBS to 1 (3 workers x 1 job = 3 threads, within 4 cores)"
else
  fail "cargo_jobs_cap() returned $jobs, expected 1"
fi
enforced_threads=$(( WORKERS_UP * jobs ))
enforced_loadpct=$(( enforced_threads * 100 / CORES ))
echo "  (enforced result: $WORKERS_UP workers x $jobs job(s) = $enforced_threads threads -> ${enforced_loadpct}%/core)"
if [ "$enforced_loadpct" -lt "$SCALE_DN_LOAD" ]; then
  ok "enforced load (${enforced_loadpct}%/core) is back under the shed threshold (${SCALE_DN_LOAD}%/core)"
else
  fail "enforced load (${enforced_loadpct}%/core) still exceeds the shed threshold (${SCALE_DN_LOAD}%/core)"
fi
if [ "$enforced_loadpct" -lt "$naive_loadpct" ]; then
  ok "auto-size enforcement reduced load from ${naive_loadpct}%/core to ${enforced_loadpct}%/core"
else
  fail "auto-size enforcement did not reduce load at all (naive=${naive_loadpct}%/core enforced=${enforced_loadpct}%/core)"
fi

# ── AC3c: new build capacity keeps getting shed while pressure persists ────
# (scale() uses hysteresis — the same shed decision must repeat before it acts)
rm -f "$STATE_DIR_TEST/.orch-scale-intent"
: > "$STOPPED_LOG"
WORKERS_UP=3
LOADPCT=1400   # pressure from the build storm has not cleared
scale   # 1st tick: records shed intent, does not act yet
scale   # 2nd tick: confirms intent -> acts
if grep -q "chump-cj-worker3" "$STOPPED_LOG"; then
  ok "scale() keeps shedding under sustained overload (stopped chump-cj-worker3) instead of granting new build capacity"
else
  fail "scale() did not shed under sustained overload: stopped log = $(tr '\n' ' ' < "$STOPPED_LOG")"
fi

# ── Control: no overload -> no shedding (prove we're not just always shedding) ─
rm -f "$STATE_DIR_TEST/.orch-scale-intent"
: > "$STOPPED_LOG"
WORKER_MAX=2
WORKERS_UP=2
LOADPCT=20
RAM_AVAIL_MB=8000
scale
scale
if [ ! -s "$STOPPED_LOG" ]; then
  ok "scale() does not shed when load is healthy (control case, no stop issued)"
else
  fail "scale() incorrectly shed a worker under healthy load: stopped log = $(tr '\n' ' ' < "$STOPPED_LOG")"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
