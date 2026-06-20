#!/usr/bin/env bash
# test-conductor-loop.sh — EFFECTIVE-088 minimal conductor v1 smoke.
# Verifies: parses; obeys the autonomy dial (0 → halt); on a wedge it PROPOSES on
# the consensus bus and (dry-run) decides WITHOUT touching real state.
set -uo pipefail
SD="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$SD/coord/conductor-loop.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

bash -n "$GATE" && ok "conductor-loop.sh parses" || no "syntax error"

TMP="$(mktemp -d)"; AL="$TMP/AL"; AMB="$TMP/amb.jsonl"; PAUSE="$TMP/paused"

# 1. autonomy dial = 0 → stand down (no proposal, halted tick)
echo 0 > "$AL"
CHUMP_AUTONOMY_LEVEL_FILE="$AL" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO_ROOT="$TMP" \
    bash "$GATE" >/dev/null 2>&1 || true
grep -q '"state":"halted"' "$AMB" 2>/dev/null && ok "dial=0 → halted (stands down)" || no "dial=0 did not halt"

# 2. wedge (fake pause) + dial up + dry-run → proposes + dryrun, real state untouched
: > "$AMB"; echo 5 > "$AL"; touch "$PAUSE"
CHUMP_AUTONOMY_LEVEL_FILE="$AL" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO_ROOT="$TMP" \
    CHUMP_FLEET_PAUSE_FILE="$PAUSE" CHUMP_CONDUCTOR_GRACE_OVERRIDE_S=1 CHUMP_CONDUCTOR_ACT=0 \
    bash "$GATE" >/dev/null 2>&1 || true
grep -q '"kind":"conductor_proposed"' "$AMB" 2>/dev/null && ok "wedge → proposes on consensus bus" || no "no proposal on wedge"
grep -q '"kind":"conductor_dryrun"' "$AMB" 2>/dev/null && ok "dry-run → conductor_dryrun emitted" || no "no dryrun emit"
[ -f "$PAUSE" ] && ok "dry-run did NOT touch the pause file (ACT=0 safe)" || no "dry-run cleared pause (must not in ACT=0)"

rm -rf "$TMP"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "[OK] conductor v1 smoke passed"
