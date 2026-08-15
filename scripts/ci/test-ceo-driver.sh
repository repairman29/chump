#!/usr/bin/env bash
# test-ceo-driver.sh — INFRA-3584: CEO loop driver contract tests.
# Deterministic, no network, no LLM calls. Two duties:
#   1. Chain of custody (AC-5): the committed CEO prompt is byte-identical to
#      the battle-tested v2. A byte change REQUIRES a full bench re-run and a
#      new pinned hash here + in docs/prompts/CEO_LOOP_CHANGELOG.md.
#   2. Validator behavior: golden valid decision passes; hard-deny command,
#      ungated OPERATOR page, and schema-missing decisions each fail.
set -euo pipefail
cd "$(dirname "$0")/../.."

DRIVER=scripts/coord/ceo-loop.py
FIX=scripts/ci/test-fixtures/ceo
PINNED_SHA=fdb753c0036149e166ba698b23fb22610a390445f9f875ea046fd86091128b88

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1 — chain of custody
actual=$(shasum -a 256 docs/prompts/CEO_LOOP_PROMPT.md | cut -d' ' -f1)
[ "$actual" = "$PINNED_SHA" ] || fail "CEO_LOOP_PROMPT.md sha256 $actual != pinned $PINNED_SHA — prompt changed without a bench re-run + pin update (INFRA-3584 AC-5; see docs/prompts/CEO_LOOP_CHANGELOG.md)"

# 2 — validator: golden must pass (exit 0)
CHUMP_CEO_SHADOW_DIR=$(mktemp -d) python3 "$DRIVER" --validate-only "$FIX/golden_valid.json" >/dev/null \
  || fail "golden_valid.json rejected by validator"

# 3 — validator: each bad fixture must be rejected (exit 2)
for bad in bad_deny bad_ungated_page bad_schema; do
  if CHUMP_CEO_SHADOW_DIR=$(mktemp -d) python3 "$DRIVER" --validate-only "$FIX/$bad.json" >/dev/null 2>&1; then
    fail "$bad.json accepted by validator — should have failed"
  fi
done

echo "OK: test-ceo-driver — prompt pin + 4 validator contract checks pass"

# 4 — live-execution plan (v1.1, EFFECTIVE-436): deterministic, no execution.
plan=$(python3 "$DRIVER" --plan-only "$FIX/live_overcap.json")
py() { echo "$plan" | python3 -c "$1" || fail "$2"; }
py 'import sys,json; p=json.load(sys.stdin); assert sum(1 for e in p if e["run"] and e.get("group")=="dispatch")==2' \
   "dispatch cap!=2 in plan"
py 'import sys,json; p=json.load(sys.stdin); assert any(e["reason"].startswith("cap-exhausted") for e in p)' \
   "over-cap dispatch not refused"
py 'import sys,json; p=json.load(sys.stdin); assert [e for e in p if e["action"]=="page"][0]["run"]==False' \
   "page executed despite CHUMP_CEO_ALLOW_PAGE default 0"
py 'import sys,json; p=json.load(sys.stdin); assert any(e["reason"]=="shell-metachar" for e in p)' \
   "metachar cmd not refused"
py 'import sys,json; p=json.load(sys.stdin); assert [e for e in p if e["action"]=="board_update"][0]["run"]==True' \
   "board_update not routed to board log"

echo "OK: test-ceo-driver — prompt pin + validator + live-plan checks pass"

# 5 — almanac translation (v1.2, EFFECTIVE-437)
plan=$(python3 "$DRIVER" --plan-only "$FIX/live_overcap.json")
py 'import sys,json; p=json.load(sys.stdin); a=[e for e in p if e["cmd"].startswith("almanac_search_fleet(query")]; assert a and a[0]["run"] and a[0]["group"]=="almanac"' \
   "well-formed almanac call not planned for execution"
py 'import sys,json; p=json.load(sys.stdin); assert any(e["reason"]=="almanac-parse" for e in p)' \
   "malformed almanac call not refused with almanac-parse"
echo "OK: test-ceo-driver — almanac translation checks pass"
