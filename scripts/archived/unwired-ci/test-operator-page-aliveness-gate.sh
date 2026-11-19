#!/usr/bin/env bash
# Regression test for the CREDIBLE-090 operator_page aliveness gate (farmer.sh).
# The farmer must CHECK THE INSTRUMENT (recent-merge proof of life) before firing
# a fleet/auth-dead halt-class operator_recall. Born from INFRA-2031: a false
# AUTH_DEAD paged the operator ~6x/min while the fleet was demonstrably shipping.
#
# Regression guard required by docs/process/DURABLE_FIX_DOCTRINE.md.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FARMER="$REPO_ROOT/scripts/coord/farmer.sh"

[[ -x "$FARMER" ]] || { echo "[test] FAIL: farmer.sh not executable"; exit 1; }
[[ "$(bash -n "$FARMER" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error"; exit 1; }

WORK="$(mktemp -d /tmp/page-aliveness-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAUX_REPO="$WORK/repo"
mkdir -p "$FAUX_REPO/.chump-locks"

# Run operator_page with a stubbed proof-of-life; capture the last recall event.
#   $1 = alive|dead  (overrides _fleet_shipped_recently)   $2 = reason
_run_page() {
    local _alive="$1" _reason="$2"
    rm -f "$FAUX_REPO/.chump-locks/ambient.jsonl"; touch "$FAUX_REPO/.chump-locks/ambient.jsonl"
    env -i PATH=/usr/bin:/bin HOME=/tmp \
        CHUMP_REPO_ROOT="$FAUX_REPO" \
        CHUMP_AMBIENT_LOG="$FAUX_REPO/.chump-locks/ambient.jsonl" \
        bash -c "
            cd '$FAUX_REPO' 2>/dev/null
            source '$FARMER' 2>/dev/null
            _fleet_shipped_recently() { [[ '$_alive' == 'alive' ]]; }
            operator_page '$_reason' 'test detail' >/dev/null 2>&1
            grep -E '\"kind\":\"operator_recall(_suppressed)?\"' '$FAUX_REPO/.chump-locks/ambient.jsonl' | tail -1
        " 2>&1
}

# (a) AUTH_DEAD + fleet ALIVE -> SUPPRESSED (the cry-wolf, killed)
out=$(_run_page alive AUTH_DEAD)
echo "$out" | grep -q '"kind":"operator_recall_suppressed"' \
    || { echo "[test] FAIL (a) AUTH_DEAD+alive: expected suppressed, got: $out"; exit 1; }
echo "[test] (a) AUTH_DEAD + fleet shipping -> SUPPRESSED: OK"

# (b) AUTH_DEAD + fleet DEAD (no recent merge) -> STILL pages (a real outage alarms)
out=$(_run_page dead AUTH_DEAD)
echo "$out" | grep -q '"class":"halt"' \
    || { echo "[test] FAIL (b) AUTH_DEAD+dead: expected halt page, got: $out"; exit 1; }
echo "[test] (b) AUTH_DEAD + fleet not shipping -> still pages: OK"

# (c) COST_CAP (NOT an aliveness class) + fleet ALIVE -> STILL pages (not over-gated)
out=$(_run_page alive COST_CAP)
echo "$out" | grep -q '"class":"halt"' \
    || { echo "[test] FAIL (c) COST_CAP+alive: expected halt page (not gated), got: $out"; exit 1; }
echo "[test] (c) COST_CAP + fleet alive -> still pages (cost is not aliveness-class): OK"

echo "[test-operator-page-aliveness-gate] PASS"
