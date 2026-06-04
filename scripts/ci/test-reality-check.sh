#!/usr/bin/env bash
# scripts/ci/test-reality-check.sh — CREDIBLE-090
#
# Proves the reality-check gate would have caught the 2026-06-04 auth-dead
# misdiagnosis: belief "auth is dead / fleet down" + ground truth "fleet shipped
# 5 min ago" → REFUTED. Also proves it does NOT false-refute a genuine outage,
# correctly reports UNVERIFIED, and enforces the halt-class fresh-eyes gate.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
RC=scripts/dev/reality-check.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-reality-check.sh (CREDIBLE-090) ==="

# 1. parses
bash -n "$RC" 2>/dev/null && p "reality-check.sh parses" || f "reality-check.sh FAILS bash -n"

# helper: run with injected ground truth, capture exit code
rc(){ CHUMP_RC_LAST_MERGE_AGE_MIN="$1" CHUMP_RC_TRUNK="$2" bash "$RC" "${@:3}" >/dev/null 2>&1; echo $?; }

# 2. THE HEADLINE: belief "auth dead / fleet down" + fleet shipped 5min ago → REFUTED (exit 1).
#    This is the exact 2026-06-04 case; the gate stands the session down.
ec="$(rc 5 green 'the fleet is auth-dead and down')"
[ "$ec" = "1" ] && p "REFUTES 'fleet down' when it shipped 5min ago (the 2026-06-04 catch)" || f "did NOT refute a false outage (exit=$ec, want 1)"

# 3. does NOT false-refute a GENUINE outage: no ships in 10h + trunk red → CONFIRMED (exit 0).
ec="$(rc 600 red 'the fleet is down')"
[ "$ec" = "0" ] && p "CONFIRMS a real outage (no ships 10h + trunk red) — no false-refute" || f "false-refuted a real outage (exit=$ec, want 0)"

# 4. UNVERIFIED when ground truth is unreadable (exit 2) — never act on the signal alone.
ec="$(rc 999999 unknown 'the fleet is down')"
[ "$ec" = "2" ] && p "UNVERIFIED when ground truth unreadable (don't act on signal alone)" || f "wrong verdict on unverifiable (exit=$ec, want 2)"

# 5. halt-class: even a CONFIRMED real outage is downgraded to not-yet-actionable (exit 2)
#    pending a fresh-eyes confirm, and the output names the fresh-eyes path.
ec="$(rc 600 red 'stop the fleet' --halt-class)"
[ "$ec" = "2" ] && p "halt-class: CONFIRMED outage still needs fresh-eyes (exit 2, no solo halt)" || f "halt-class did not require fresh-eyes (exit=$ec, want 2)"
hc_out="$(CHUMP_RC_LAST_MERGE_AGE_MIN=600 CHUMP_RC_TRUNK=red bash "$RC" 'stop the fleet' --halt-class 2>&1 || true)"
printf '%s' "$hc_out" | grep -qi 'fresh-eyes' \
  && p "halt-class output names the fresh-eyes second-opinion path" || f "halt-class output omits fresh-eyes"

# 6. signal-reliability: with a --detector that has an OPEN false-positive gap, REFUTE even
#    when ground truth alone would CONFIRM. Soft (depends on a real false-positive gap existing).
fp="$(sqlite3 .chump/state.db "SELECT id FROM gaps WHERE status='open' AND lower(title) LIKE '%false-positive%' AND lower(title) LIKE '%auth%' LIMIT 1;" 2>/dev/null || true)"
if [ -n "$fp" ]; then
  ec="$(rc 600 red 'auth is dead' --detector AUTH_DEAD)"
  [ "$ec" = "1" ] && p "REFUTES on a known-false-positive detector ($fp) even with outage-like ground truth" || f "did not refute on false-positive detector $fp (exit=$ec)"
else
  echo "[skip] no open auth false-positive gap in state.db — detector-reliability path not exercised here"
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
