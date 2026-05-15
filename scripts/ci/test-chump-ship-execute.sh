#!/usr/bin/env bash
# INFRA-1229 slice 2: smoke test for `chump ship execute` CLI.
#
# Exercises the executor in --dry-run mode against synthetic ShipPlan
# inputs covering each variant. Does NOT run live git/gh operations —
# those are exercised through bot-merge.sh's existing test surface
# until slice 4 swaps the callers.

set -euo pipefail

BIN="${CHUMP_BIN:-target/debug/chump}"
# Resolve to absolute path if needed
if [[ ! -x "$BIN" ]]; then
    BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
fi
if [[ ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found — build first with cargo build --bin chump" >&2
    exit 2
fi

# ── 1. --help shows usage ─────────────────────────────────────────────
OUT=$("$BIN" ship execute --help 2>&1)
if ! echo "$OUT" | grep -q "Usage: chump ship execute"; then
    echo "[test] FAIL: --help did not show usage line" >&2
    echo "$OUT" >&2
    exit 1
fi
echo "[test] PASS: --help shows usage"

# ── 2. AlreadyDone variant yields no steps ────────────────────────────
OUT=$(echo '{"plan":{"action":"AlreadyDone","pr":1,"state":"merged","recovery_hint":"x"}}' \
      | "$BIN" ship execute --stdin --dry-run 2>/dev/null)
ACTION=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan_action"])')
N_STEPS=$(echo "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["steps"]))')
EXECUTED=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executed"])')
if [[ "$ACTION" != "AlreadyDone" || "$N_STEPS" != "0" || "$EXECUTED" != "False" ]]; then
    echo "[test] FAIL: AlreadyDone expected 0 steps, executed=false; got action=$ACTION steps=$N_STEPS exec=$EXECUTED" >&2
    exit 1
fi
echo "[test] PASS: AlreadyDone yields zero steps"

# ── 3. RebaseAndPush yields 3 git steps in dry-run ────────────────────
OUT=$(echo '{"plan":{"action":"RebaseAndPush","behind_count":3}}' \
      | "$BIN" ship execute --stdin --dry-run 2>/dev/null)
N_STEPS=$(echo "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["steps"]))')
PROG_LIST=$(echo "$OUT" | python3 -c 'import json,sys; print(",".join(s["program"] for s in json.load(sys.stdin)["steps"]))')
if [[ "$N_STEPS" != "3" || "$PROG_LIST" != "git,git,git" ]]; then
    echo "[test] FAIL: RebaseAndPush expected 3 git steps; got $N_STEPS programs=$PROG_LIST" >&2
    exit 1
fi
echo "[test] PASS: RebaseAndPush yields 3 git steps (git,git,git)"

# ── 4. ArmAutoMerge yields 1 gh step ──────────────────────────────────
OUT=$(echo '{"plan":{"action":"ArmAutoMerge","pr":1985,"reason":"test"}}' \
      | "$BIN" ship execute --stdin --dry-run 2>/dev/null)
N_STEPS=$(echo "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["steps"]))')
FIRST_PROG=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["steps"][0]["program"])')
FIRST_ARGS=$(echo "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["steps"][0]["args"]))')
if [[ "$N_STEPS" != "1" || "$FIRST_PROG" != "gh" ]]; then
    echo "[test] FAIL: ArmAutoMerge expected 1 gh step; got $N_STEPS programs=$FIRST_PROG" >&2
    exit 1
fi
if [[ "$FIRST_ARGS" != "pr,merge,1985,--auto,--squash" ]]; then
    echo "[test] FAIL: ArmAutoMerge args wrong: $FIRST_ARGS" >&2
    exit 1
fi
echo "[test] PASS: ArmAutoMerge yields gh pr merge 1985 --auto --squash"

# ── 5. RestDirectMerge yields 1 gh api PUT step ───────────────────────
OUT=$(echo '{"plan":{"action":"RestDirectMerge","pr":1985,"head_sha":"abc1234","checks_verified":7}}' \
      | "$BIN" ship execute --stdin --dry-run 2>/dev/null)
FIRST_ARGS=$(echo "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["steps"][0]["args"]))')
if ! echo "$FIRST_ARGS" | grep -q 'pulls/1985/merge'; then
    echo "[test] FAIL: RestDirectMerge args missing pulls/1985/merge: $FIRST_ARGS" >&2
    exit 1
fi
if ! echo "$FIRST_ARGS" | grep -q 'PUT'; then
    echo "[test] FAIL: RestDirectMerge args missing PUT: $FIRST_ARGS" >&2
    exit 1
fi
echo "[test] PASS: RestDirectMerge yields gh api PUT for /pulls/N/merge"

# ── 6. envelope shape: top-level .plan or bare ShipPlan both accepted ──
OUT_BARE=$(echo '{"action":"AlreadyDone","pr":1,"state":"merged","recovery_hint":"x"}' \
      | "$BIN" ship execute --stdin --dry-run 2>/dev/null)
ACTION=$(echo "$OUT_BARE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan_action"])')
if [[ "$ACTION" != "AlreadyDone" ]]; then
    echo "[test] FAIL: bare ShipPlan envelope not accepted: action=$ACTION" >&2
    exit 1
fi
echo "[test] PASS: bare ShipPlan envelope accepted (no top-level wrapper)"

# ── 7. unknown flag → exit 2 ──────────────────────────────────────────
set +e
"$BIN" ship execute --not-a-real-flag >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 2 ]]; then
    echo "[test] FAIL: unknown flag should exit 2, got $rc" >&2
    exit 1
fi
echo "[test] PASS: unknown flag rejected with exit 2"

# ── 8. missing required input → exit 2 ────────────────────────────────
set +e
"$BIN" ship execute >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 2 ]]; then
    echo "[test] FAIL: missing --plan/--stdin should exit 2, got $rc" >&2
    exit 1
fi
echo "[test] PASS: missing required input rejected with exit 2"

echo ""
echo "[test] ALL CHUMP-SHIP-EXECUTE CHECKS PASSED — INFRA-1229 slice 2 CLI verified"
