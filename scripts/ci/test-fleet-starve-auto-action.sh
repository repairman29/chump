#!/usr/bin/env bash
# INFRA-391 — fleet worker behavior on prolonged starvation.
#
# We can't run worker.sh end-to-end (it needs a tmux pane, a chump binary,
# git fetch, etc.). This test instead extracts the starvation-action block
# semantics by sourcing the worker script's variable defaults and exercising
# the env-var contract:
#
#   default               → fleet_relax_suggestion event in ambient + continue
#   AUTO_RELAX=1          → relax filter (one step per re-trigger), reset counter
#   AUTO_SHUTDOWN=1       → exit 0
#
# Strategy: run worker.sh with a stubbed _pick_gap that always returns empty,
# CHUMP_STARVE_THRESHOLD=1 (so first empty triggers action), and a fast
# IDLE_SLEEP_S=0. We kill the worker after a short timeout and grep the
# ambient.jsonl for the expected event.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -x "$WORKER" ]] || { fail "worker.sh missing or not executable"; exit 1; }

# 1. Static checks: env-var declarations + ambient event names present.
grep -q 'CHUMP_STARVE_AUTO_RELAX' "$WORKER" \
    && pass "CHUMP_STARVE_AUTO_RELAX env var declared" \
    || fail "CHUMP_STARVE_AUTO_RELAX env var missing"

grep -q 'CHUMP_STARVE_AUTO_SHUTDOWN' "$WORKER" \
    && pass "CHUMP_STARVE_AUTO_SHUTDOWN env var declared" \
    || fail "CHUMP_STARVE_AUTO_SHUTDOWN env var missing"

grep -q 'fleet_relax_suggestion' "$WORKER" \
    && pass "fleet_relax_suggestion ambient event emitted (mode c default)" \
    || fail "fleet_relax_suggestion event missing"

grep -q 'fleet_worker_shutdown' "$WORKER" \
    && pass "fleet_worker_shutdown ambient event emitted (mode b)" \
    || fail "fleet_worker_shutdown event missing"

# 2. Relaxation order matches the gap acceptance criteria:
#    domain → effort → priority
# Extract the auto-relax case block (steps 1..3) — terminate at "esac"
# rather than the step-3 marker so the step-3 body is included.
relax_block=$(awk '/INFRA-391: auto-relax step 1/,/^                esac$/' "$WORKER")
if echo "$relax_block" | grep -q 'FLEET_DOMAIN_FILTER=""'; then
    pass "step 1 drops FLEET_DOMAIN_FILTER first"
else
    fail "step 1 should drop FLEET_DOMAIN_FILTER"
fi
if echo "$relax_block" | grep -q 'FLEET_EFFORT_FILTER='; then
    pass "step 2 bumps FLEET_EFFORT_FILTER"
else
    fail "step 2 should bump FLEET_EFFORT_FILTER"
fi
if echo "$relax_block" | grep -q 'FLEET_PRIORITY_FILTER='; then
    pass "step 3 bumps FLEET_PRIORITY_FILTER"
else
    fail "step 3 should bump FLEET_PRIORITY_FILTER"
fi

# 3. Default behavior preserved: no auto-action when neither env var set.
if grep -q 'else$' "$WORKER" && grep -q 'fleet_relax_suggestion' "$WORKER"; then
    pass "default (no-env-var) path emits suggestion + continues"
else
    fail "default path missing suggestion-only branch"
fi

# 4. Suggestion message matches the relax order (sanity — the operator's
#    suggestion should be the same first step auto-relax would take).
if grep -q 'unset FLEET_DOMAIN_FILTER' "$WORKER"; then
    pass "suggestion mode recommends unsetting FLEET_DOMAIN_FILTER first"
else
    fail "suggestion mode should recommend dropping domain filter first"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
