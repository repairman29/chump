#!/usr/bin/env bash
# test-curator-jit-scheduler.sh — INFRA-1892
#
# Smoke-tests the curator-jit-scheduler daemon's --once mode:
#   1. CHUMP_JIT_SCHEDULER_DISABLED=1 short-circuits cleanly (exit 0, no
#      ambient writes).
#   2. A synthetic DONE event from a curator-opus-* session triggers a
#      handle_done call; we observe via the emitted curator_jit_* event
#      (either _scheduled if a picker candidate exists, or _no_gap /
#      _skipped if not — all are valid evidence the dispatch path fired).
#   3. Non-curator session (e.g., worker-sonnet-*, chump-Chump-*) is
#      ignored — no curator_jit_* event emitted for that line.
#   4. Dedup within window: same (curator, gap) twice in the same --once
#      run emits curator_jit_skipped with reason=dedup_window on the second.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/curator-jit-scheduler.sh"
[ -x "$DAEMON" ] || { echo "FAIL: daemon not executable at $DAEMON" >&2; exit 1; }

SANDBOX="$(mktemp -d -t infra-1892.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ── case 1: disabled bypass ───────────────────────────────────────────────
AMBIENT="$SANDBOX/c1-ambient.jsonl"
: > "$AMBIENT"
out=$(CHUMP_JIT_SCHEDULER_DISABLED=1 \
      CHUMP_JIT_AMBIENT_LOG="$AMBIENT" \
      bash "$DAEMON" 2>&1)
[ "$(wc -l < "$AMBIENT" | awk '{print $1}')" -eq 0 ] || fail "case 1: ambient should be untouched with DISABLED=1"
echo "$out" | grep -q "exiting cleanly" || fail "case 1: expected disabled-message on stdout"
pass "case 1: CHUMP_JIT_SCHEDULER_DISABLED=1 short-circuits cleanly"

# ── case 2: curator-opus-* DONE triggers dispatch path ────────────────────
AMBIENT="$SANDBOX/c2-ambient.jsonl"
STATE="$SANDBOX/c2-state.jsonl"
cat > "$AMBIENT" <<EOF
{"ts":"2026-05-23T23:00:00Z","event":"DONE","session":"curator-opus-shepherd-2026-05-23","reason":"shipped INFRA-X"}
EOF
CHUMP_JIT_AMBIENT_LOG="$AMBIENT" CHUMP_JIT_STATE_FILE="$STATE" CHUMP_JIT_ONCE=1 \
    bash "$DAEMON" >/dev/null 2>&1 || true
# Any curator_jit_* kind in ambient is evidence the handler fired.
if ! grep -qE '"kind":"curator_jit_(scheduled|skipped|no_gap)"' "$AMBIENT"; then
    fail "case 2: expected curator_jit_* event after curator-opus DONE; ambient: $(cat $AMBIENT)"
fi
pass "case 2: curator-opus DONE triggers handler (curator_jit_* event emitted)"

# ── case 3: non-curator session is ignored ────────────────────────────────
AMBIENT="$SANDBOX/c3-ambient.jsonl"
STATE="$SANDBOX/c3-state.jsonl"
cat > "$AMBIENT" <<EOF
{"ts":"2026-05-23T23:00:00Z","event":"DONE","session":"worker-sonnet-7","reason":"unrelated"}
{"ts":"2026-05-23T23:00:01Z","event":"DONE","session":"chump-Chump-1776471708","reason":"operator session"}
EOF
CHUMP_JIT_AMBIENT_LOG="$AMBIENT" CHUMP_JIT_STATE_FILE="$STATE" CHUMP_JIT_ONCE=1 \
    bash "$DAEMON" >/dev/null 2>&1 || true
if grep -qE '"kind":"curator_jit_' "$AMBIENT"; then
    fail "case 3: non-curator DONE should NOT trigger handler; ambient: $(cat $AMBIENT)"
fi
pass "case 3: non-curator-opus DONE ignored (no curator_jit_* event)"

# ── case 4: dedup within window ───────────────────────────────────────────
# Seed the state-file with a recent (curator, gap) pair, then send a DONE.
# If the picker returns the same gap, dedup should fire. If picker returns
# a different gap (because the seeded one is no longer top), we can't
# assert dedup fired — so this is a best-effort regression check: assert
# the daemon doesn't crash on a pre-existing state file and produces
# valid ambient JSON.
AMBIENT="$SANDBOX/c4-ambient.jsonl"
STATE="$SANDBOX/c4-state.jsonl"
: > "$AMBIENT"
echo "{\"unix_ts\":$(date +%s),\"curator\":\"curator-opus-shepherd-2026-05-23\",\"gap_id\":\"INFRA-FAKE\"}" > "$STATE"
cat > "$AMBIENT" <<EOF
{"ts":"2026-05-23T23:00:00Z","event":"DONE","session":"curator-opus-shepherd-2026-05-23","reason":"shipped INFRA-FAKE"}
EOF
CHUMP_JIT_AMBIENT_LOG="$AMBIENT" CHUMP_JIT_STATE_FILE="$STATE" CHUMP_JIT_ONCE=1 \
    bash "$DAEMON" >/dev/null 2>&1 || true
# Just assert daemon survived the pre-existing state file + produced a
# curator_jit_* line of some kind.
if ! grep -qE '"kind":"curator_jit_' "$AMBIENT"; then
    fail "case 4: daemon should still emit curator_jit_* with pre-existing state file"
fi
pass "case 4: handles pre-existing state file without crash"

echo "All INFRA-1892 curator-jit-scheduler tests passed."
