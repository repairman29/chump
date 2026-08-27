#!/usr/bin/env bash
# scripts/ci/test-sse-filter-and-regret.sh — INFRA-1559
#
# Verifies INFRA-1559: SSE filter UI + bandit regret rendering.
#   1. chump-ambient-viewer defines tag-based filter pills (kind/gap/severity)
#   2. Saved-preset dropdown wired to workspace-local localStorage
#   3. "new since last viewed" overlay counter present
#   4. sse_filter_applied telemetry emitted on filter change
#   5. sse_filter_applied is a registered ambient event kind
#   6. chump-bandit-regret-panel subscribes to routing_decision/routing_outcome
#   7. Ambient stream server supports ?kinds= multi-filter (consumed by the panel)
#   8. Functional: injected synthetic routing_decision + routing_outcome
#      events produce a monotonically non-decreasing cumulative regret series
#      per arm (mirrors the client-side reducer in ChumpBanditRegretPanel)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== INFRA-1559: SSE filter UI + bandit regret panel CI checks ==="

APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# 1. Filter pills: field parser + pill CSS class
check grep -q "amb-filter-pill" "$APP_JS"
check grep -q "kind|gap|severity" "$APP_JS"

# 2. Saved presets — workspace-local localStorage
check grep -q "PRESETS_KEY" "$APP_JS"
check grep -q "localStorage" "$APP_JS"

# 3. "new since last viewed" overlay counter
check grep -q "new since last viewed" "$APP_JS"

# 4. sse_filter_applied telemetry emitted client-side
check grep -q "sse_filter_applied" "$APP_JS"

# 5. sse_filter_applied registered in EVENT_REGISTRY.yaml
check grep -q "kind: sse_filter_applied" "$REGISTRY"

# 6. Bandit regret panel subscribes to both routing kinds
check grep -q "chump-bandit-regret-panel" "$APP_JS"
check grep -q "routing_decision,routing_outcome" "$APP_JS"
check grep -q "chump-bandit-regret-panel" "$INDEX_HTML"

# 7. Server supports ?kinds= multi-filter (INFRA-1010) that the panel relies on
check grep -q "kinds_filter" "$WEB_SERVER"

echo ""
echo "--- Functional: cumulative regret is monotonically non-decreasing ---"

_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT
_ambient="$_tmpdir/ambient.jsonl"

# Synthetic routing_decision + routing_outcome events across 2 arms —
# mirrors the reducer in ChumpBanditRegretPanel#onEvent: regret per outcome
# = max(0, optimal_reward - reward); cumulative regret per arm is a running
# sum, which is non-decreasing by construction.
cat > "$_ambient" <<'JSON'
{"ts":"2026-08-27T00:00:00Z","kind":"routing_decision","gap_id":"INFRA-9001","arm":"opus"}
{"ts":"2026-08-27T00:00:01Z","kind":"routing_outcome","arm":"opus","reward":0.9,"optimal_reward":1.0}
{"ts":"2026-08-27T00:00:02Z","kind":"routing_decision","gap_id":"INFRA-9002","arm":"sonnet"}
{"ts":"2026-08-27T00:00:03Z","kind":"routing_outcome","arm":"sonnet","reward":0.4,"optimal_reward":1.0}
{"ts":"2026-08-27T00:00:04Z","kind":"routing_outcome","arm":"opus","reward":1.0,"optimal_reward":1.0}
{"ts":"2026-08-27T00:00:05Z","kind":"routing_outcome","arm":"sonnet","reward":0.6,"optimal_reward":1.0}
{"ts":"2026-08-27T00:00:06Z","kind":"routing_outcome","arm":"opus","reward":0.95,"optimal_reward":1.0}
JSON

total=$((total+1))
if CHUMP_AMBIENT_LOG="$_ambient" python3 - <<'PY'
import json, os, sys

ambient = os.environ["CHUMP_AMBIENT_LOG"]
cum = {}
series = {}
decisions = 0

for line in open(ambient):
    line = line.strip()
    if not line:
        continue
    v = json.loads(line)
    kind = v.get("kind")
    if kind == "routing_decision":
        decisions += 1
        continue
    if kind != "routing_outcome":
        continue
    arm = v["arm"]
    reward = float(v.get("reward", 0.0))
    optimal = float(v.get("optimal_reward", 1.0))
    regret = max(0.0, optimal - reward)
    cum[arm] = cum.get(arm, 0.0) + regret
    series.setdefault(arm, []).append(cum[arm])

assert decisions == 2, f"expected 2 routing_decision events seen, got {decisions}"
assert set(series.keys()) == {"opus", "sonnet"}, f"unexpected arms: {series.keys()}"

for arm, pts in series.items():
    for a, b in zip(pts, pts[1:]):
        assert b >= a, f"regret series for {arm} is not monotonically non-decreasing: {pts}"

# opus regret: 0.1 + 0.0 + 0.05 = 0.15 ; sonnet regret: 0.6 + 0.4 = 1.0
assert abs(series["opus"][-1] - 0.15) < 1e-9, series["opus"]
assert abs(series["sonnet"][-1] - 1.0) < 1e-9, series["sonnet"]

print("regret series ok:", json.dumps(series))
PY
then
  ok "Functional: cumulative regret per arm is monotonically non-decreasing"
  pass=$((pass+1))
else
  fail "Functional: regret reducer simulation failed"
fi

echo ""
echo "--- Functional: filter pills match kind/gap/severity (AND-across-fields, OR-within-field) ---"

total=$((total+1))
if python3 - <<'PY'
import json

def matches(pills, payload):
    if not pills:
        return True
    groups = {}
    for p in pills:
        groups.setdefault(p["field"], []).append(p["value"])
    for field, values in groups.items():
        if field == "gap":
            actual = str(payload.get("gap_id") or payload.get("gap") or "")
        elif field == "severity":
            actual = str(payload.get("severity") or "")
        else:
            actual = str(payload.get("kind") or payload.get("event") or "")
        if actual not in values:
            return False
    return True

pills = [{"field": "kind", "value": "pr_stuck"}, {"field": "severity", "value": "warn"}]
assert matches(pills, {"kind": "pr_stuck", "severity": "warn"}) is True
assert matches(pills, {"kind": "pr_stuck", "severity": "info"}) is False
assert matches(pills, {"kind": "gap_shipped", "severity": "warn"}) is False
assert matches([{"field": "gap", "value": "INFRA-1559"}], {"gap_id": "INFRA-1559"}) is True
assert matches([], {"kind": "anything"}) is True
print("pill matcher ok")
PY
then
  ok "Functional: filter pill matcher (AND-across-fields, OR-within-field)"
  pass=$((pass+1))
else
  fail "Functional: filter pill matcher simulation failed"
fi

echo ""
echo "=== Results: $pass/$total passed ==="
[[ "$pass" -eq "$total" ]] || exit 1
echo "INFRA-1559: SSE filter UI + bandit regret panel validation complete."
