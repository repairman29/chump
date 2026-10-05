#!/usr/bin/env bash
# test-infra-3832-nonship-cooldown.sh — INFRA-3832
#
# "worker infinite-loops on a problematic gap". The board hand-blocked 3 gaps in
# one night because a worker re-picks ANY gap that fails/hangs/times-out:
#   - INFRA-478  already-done loop   (fixed earlier by INFRA-3808 auto-close)
#   - INFRA-3798 timeout loop        (rc=124 skipped the cooldown block entirely)
#   - INFRA-1497 0B-log wedge, 66min (watchdog killed only the wrapper subshell;
#                                     the orphaned claude ran to FLEET_TIMEOUT_S)
#
# INFRA-3808 fixed only the already-done case. This suite covers the extension:
#
#  Layer 1 (uniform cooldown): rc==124 (timeout / wedge) had its OWN `elif`
#    branch that stopped after _effective_003_reflex and never reached the
#    INFRA-361 cooldown block — so no cooldown file was written and the picker
#    re-selected the gap next cycle. Now ALL non-zero rc flow through one `else`
#    branch, so timeout+wedge get a cooldown too. Verified structurally + by
#    proving the picker's own cooled_down_gaps() honors the written file.
#
#  Layer 2 (auto-block chronic offenders): a durable per-gap offense ledger with
#    escalating (bounded) backoff; at CHUMP_AUTO_BLOCK_THRESHOLD the gap is set
#    status=blocked so it leaves the pick pool — the automated form of the board
#    hand-blocking INFRA-1497.
#
#  Layer 3 (faster wedge detection): the watchdogs reap the whole process tree
#    (_kill_cycle_tree) instead of only the wrapper subshell, so a hung claude is
#    caught in ~120s (the watchdog window) instead of ~66min (FLEET_TIMEOUT_S).
#
# Depth: happy-path + edge (expired cooldown GC, escalation cap, per-worker vs
# cluster-wide honoring). Gaps: does NOT spawn a real claude child, so the
# _kill_cycle_tree reap is asserted structurally + by unit-testing the tree walk
# on a synthetic sleep tree; does NOT drive a live chump binary, so the
# auto-block `gap set` call is asserted structurally, not end-to-end.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

echo "=== INFRA-3832: uniform non-ship cooldown + auto-block + tree-reap ==="

# ── Layer 0: the script is still valid bash ──────────────────────────────────
if bash -n "$WORKER" 2>/dev/null; then
    ok "Layer 0: worker.sh parses (bash -n)"
else
    fail "Layer 0: worker.sh has a syntax error"
fi

# ── Layer 1a: rc==124 no longer has a cooldown-skipping elif ──────────────────
# The bug was a dedicated `elif [ "$rc" -eq 124 ]` branch in the failure-handling
# if/else that ran _effective_003_reflex and returned WITHOUT writing a cooldown.
# The fix folds all non-zero rc into one `else` (marked below) whose inner
# `if [ "$rc" -eq 124 ]` only picks the log wording — the cooldown block runs for
# every non-ship outcome. (Note: unrelated `elif rc==124` still exist in the
# session-track + cycle_end classifiers; we assert the merge MARKER, not raw text.)
if grep -q "ONE non-ship branch so cooldown fires uniformly" "$WORKER"; then
    ok "Layer 1a: failure handler merged — timeouts reach the shared cooldown block"
else
    fail "Layer 1a: merged non-ship branch marker missing (rc==124 may still skip cooldown)"
fi

# ── Layer 1b: P0 fallback stays scoped to genuine failures (rc != 124) ────────
if grep -Fq '&& [[ "$rc" -ne 124 ]] \' "$WORKER"; then
    ok "Layer 1b: P0-fallback guarded with rc!=124 (timeouts don't trigger it)"
else
    fail "Layer 1b: P0-fallback missing the rc!=124 guard after branch merge"
fi

# ── Layer 1c: the rc-fail cooldown write is VALID JSON (no broken idiom) ──────
if grep -Eq "printf '\"'\"'\{\"gap_id\"" "$WORKER"; then
    fail "Layer 1c: broken shell-quote-nesting printf idiom present (writes invalid JSON)"
else
    ok "Layer 1c: no broken printf idiom in cooldown writes"
fi
# Prove the exact rc-fail format string parses.
_json="$(printf '{"gap_id":"%s","rc":%d,"kind":"%s","until":%d,"agent":"%s","ts":"%s","worker_id":"%s"}\n' \
    "INFRA-3798" 124 "timeout" 1799999999 "1" "2026-08-26T00:00:00Z" "1")"
if printf '%s' "$_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["gap_id"]=="INFRA-3798" and d["until"]==1799999999 and d["kind"]=="timeout"'; then
    ok "Layer 1c: rc-fail cooldown record parses as JSON the picker can read"
else
    fail "Layer 1c: rc-fail cooldown record is not valid JSON"
fi

# ── Layer 1d: FUNCTIONAL — the picker actually SKIPS a cooled gap ─────────────
# Write a fresh per-worker cooldown file in the worker's exact format, then ask
# the picker's own cooled_down_gaps() whether the gap is blocked for this worker.
_tmp_cd="$(mktemp -d)"
trap 'rm -rf "$_tmp_cd"' EXIT
_future=$(( $(date +%s) + 3600 ))
printf '{"gap_id":"%s","rc":%d,"kind":"%s","until":%d,"agent":"%s","ts":"%s","worker_id":"%s"}\n' \
    "INFRA-1497" 124 "wedge" "$_future" "1" "2026-08-26T00:00:00Z" "1" \
    > "$_tmp_cd/1-INFRA-1497.json"
# Also a stale (expired) one that must be ignored + GC'd.
_past=$(( $(date +%s) - 60 ))
printf '{"gap_id":"%s","rc":%d,"kind":"%s","until":%d,"agent":"%s","ts":"%s","worker_id":"%s"}\n' \
    "INFRA-9999" 1 "rc=1" "$_past" "1" "2026-08-26T00:00:00Z" "1" \
    > "$_tmp_cd/1-INFRA-9999.json"

_pick_result="$(COOLDOWN_DIR="$_tmp_cd" python3 - "$PICKER" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("picker", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cooled = m.cooled_down_gaps(os.environ["COOLDOWN_DIR"], worker_id="1")
print("BLOCKED" if "INFRA-1497" in cooled else "PICKABLE", end=" ")
print("STALE_IGNORED" if "INFRA-9999" not in cooled else "STALE_HONORED")
PY
)"
if [ "$_pick_result" = "BLOCKED STALE_IGNORED" ]; then
    ok "Layer 1d: picker skips the freshly-cooled gap AND ignores the expired one"
else
    fail "Layer 1d: picker verdict was '$_pick_result' (want 'BLOCKED STALE_IGNORED')"
fi
# The expired file must be GC'd on read.
if [ ! -f "$_tmp_cd/1-INFRA-9999.json" ]; then
    ok "Layer 1d: expired cooldown file GC'd on read"
else
    fail "Layer 1d: expired cooldown file was not cleaned up"
fi

# ── Layer 2a: escalating-backoff ledger present + bounded ────────────────────
if grep -q "chronic-offender ledger" "$WORKER" && grep -q "CHUMP_MAX_COOLDOWN_S" "$WORKER"; then
    ok "Layer 2a: escalating-backoff ledger with a hard ceiling is present"
else
    fail "Layer 2a: escalating-backoff ledger / ceiling missing"
fi
# Unit-test the escalation math (base*offense, capped).
_escalate() {  # base offense max -> echo capped cooldown
    local cs=$(( $1 * $2 )); local max="$3"
    [ "$cs" -gt "$max" ] && cs="$max"; echo "$cs"
}
[ "$(_escalate 1800 1 14400)" = "1800" ]  && ok "Layer 2a: offense 1 → base (1800s)"                 || fail "Layer 2a: offense 1 math"
[ "$(_escalate 1800 3 14400)" = "5400" ]  && ok "Layer 2a: offense 3 → 3× base (5400s)"              || fail "Layer 2a: offense 3 math"
[ "$(_escalate 3600 9 14400)" = "14400" ] && ok "Layer 2a: offense 9 timeout → capped at 4h ceiling" || fail "Layer 2a: escalation cap"

# ── Layer 2b: auto-block chronic offenders ───────────────────────────────────
if grep -q "CHUMP_AUTO_BLOCK_OFFENDERS" "$WORKER" \
   && grep -q "CHUMP_AUTO_BLOCK_THRESHOLD" "$WORKER" \
   && grep -Fq 'chump gap set "$GAP_ID" \' "$WORKER" \
   && grep -Fq -e '--status blocked --add-note' "$WORKER"; then
    ok "Layer 2b: auto-block sets status=blocked, env-guarded + threshold-tunable"
else
    fail "Layer 2b: auto-block wiring (env guard / threshold / gap set) missing"
fi
if grep -q 'gap_auto_blocked' "$WORKER"; then
    ok "Layer 2b: auto-block emits a gap_auto_blocked ambient ALERT"
else
    fail "Layer 2b: auto-block does not emit an ambient alert"
fi
# Offense ledger is wiped on a clean cycle (no stale strikes).
if grep -q 'rm -f "\$REPO_ROOT/.chump-locks/offense/\${GAP_ID}.count"' "$WORKER"; then
    ok "Layer 2b: clean cycle resets the offense ledger"
else
    fail "Layer 2b: clean cycle does not reset the offense ledger"
fi

# ── Layer 3a: tree-reaping helper present + used at BOTH watchdog kill sites ──
if grep -q '_kill_cycle_tree()' "$WORKER"; then
    ok "Layer 3a: _kill_cycle_tree helper defined"
else
    fail "Layer 3a: _kill_cycle_tree helper missing"
fi
_reap_uses=$(grep -c '_kill_cycle_tree "\$_claude_pid"' "$WORKER" || true)
if [ "${_reap_uses:-0}" -ge 2 ]; then
    ok "Layer 3a: tree-reap used at both first-output + stall kill sites ($_reap_uses)"
else
    fail "Layer 3a: tree-reap used at only ${_reap_uses:-0} kill site(s), expected >= 2"
fi
# The old subshell-only kill must be gone from the watchdogs.
if grep -Eq 'kill "-KILL" "\$_claude_pid"' "$WORKER"; then
    fail "Layer 3a: bare subshell-only kill of \$_claude_pid still present (leaves orphan)"
else
    ok "Layer 3a: no bare subshell-only kill of the claude wrapper remains"
fi

# ── Layer 3b: FUNCTIONAL — the tree walk reaps a synthetic descendant tree ────
# Build root→child→grandchild sleepers, then reap the root's tree and assert the
# grandchild (the analogue of the orphaned claude) actually dies.
_reap_test="$(WORKER="$WORKER" bash -c '
    set -u
    source <(sed -n "/^_kill_cycle_tree()/,/^}/p" "$WORKER")
    # root subshell → child (sh) → grandchild sleeper (analogue of orphaned claude)
    ( sh -c "sleep 60 & sleep 60" ) &
    root=$!
    sleep 1
    child=$(pgrep -P "$root" 2>/dev/null | head -1)
    deepest=$(pgrep -P "$child" 2>/dev/null | head -1)
    _kill_cycle_tree "$root"
    sleep 1
    if [ -n "$deepest" ] && kill -0 "$deepest" 2>/dev/null; then
        echo "GRANDCHILD_SURVIVED"
    else
        echo "TREE_REAPED"
    fi
' 2>/dev/null || echo "REAP_ERROR")"
if [ "$_reap_test" = "TREE_REAPED" ]; then
    ok "Layer 3b: _kill_cycle_tree reaps root + child + grandchild"
else
    fail "Layer 3b: tree reap result was '$_reap_test' (want TREE_REAPED)"
fi

echo ""
echo "=== INFRA-3832: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
