#!/usr/bin/env bash
# RESILIENT-1560: gate-fail lane flags deterministic-failing PRs, skips fresh/passing ones, alarms over threshold.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CHUMP_AMBIENT_PATH="$T/ambient.jsonl" CHUMP_GATE_FAIL_STATE_FILE="$T/state.json" CHUMP_PR_SHEPHERD_DRY_RUN=1 CHUMP_GATE_FAIL_ALARM_THRESHOLD=2
: > "$CHUMP_AMBIENT_PATH"
old=$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JSON=$(cat <<J
[{"number":1,"title":"RESILIENT-1: x","headRefOid":"a","statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE","completedAt":"$old"}]},
 {"number":2,"title":"INFRA-2: y","headRefOid":"b","statusCheckRollup":[{"name":"rustdoc","conclusion":"FAILURE","completedAt":"$old"}]},
 {"number":3,"title":"INFRA-3: fresh","headRefOid":"c","statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE","completedAt":"$new"}]},
 {"number":4,"title":"INFRA-4: ok","headRefOid":"d","statusCheckRollup":[{"name":"clippy","conclusion":"SUCCESS","completedAt":"$old"}]}]
J
)
# shellcheck disable=SC1090
source <(sed -n '/^GATE_FAIL_HOURS=/,/^cmd_tick() {/p' "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh" | sed '$d')
AMBIENT="$CHUMP_AMBIENT_PATH"; DRY_RUN=1; REPO_ROOT="$REPO_ROOT"
_is_blocked_flake() { return 1; }
_gate_fail_lane "$JSON" 2>/dev/null
n=$(grep -c '"kind":"pr_gate_fail_deterministic"' "$AMBIENT")
[ "$n" = 2 ] || { echo "FAIL: expected 2 deterministic events, got $n"; exit 1; }
grep -q '"pr":3' "$AMBIENT" && { echo "FAIL: fresh PR flagged"; exit 1; }
grep -q '"kind":"pr_gate_fail_alarm"' "$AMBIENT" || { echo "FAIL: no alarm"; exit 1; }
echo "OK"
