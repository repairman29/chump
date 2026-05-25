#!/usr/bin/env bash
# scripts/ci/test-api-cost-leaderboard.sh — INFRA-1077
#
# Verifies scripts/dev/api-cost-leaderboard.sh:
#   1. Default text mode renders a ranked table
#   2. --json mode emits valid JSON with expected fields
#   3. --window filters out old events correctly
#   4. --emit-ambient appends one kind=api_cost_digest_emitted to ambient.jsonl
#   5. EVENT_REGISTRY.yaml registers api_cost_digest_emitted
#   6. Launchd plist + installer present

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LB="$REPO_ROOT/scripts/dev/api-cost-leaderboard.sh"
PLIST="$REPO_ROOT/launchd/com.chump.api-cost-digest.plist"
INST="$REPO_ROOT/scripts/setup/install-api-cost-digest-launchd.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Build a synthetic ambient.jsonl: 5 in-window + 2 out-of-window events.
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD_TS="$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

AMB="$TMP/ambient.jsonl"
{
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr merge","used_ms":500}\n' "$NOW_TS"
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr merge","used_ms":600}\n' "$NOW_TS"
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr view","used_ms":100}\n' "$NOW_TS"
    printf '{"ts":"%s","kind":"github_api_call","script":"queue-driver.sh","api":"pr list","used_ms":200}\n' "$NOW_TS"
    printf '{"ts":"%s","kind":"github_api_call","script":"queue-driver.sh","api":"pr list","used_ms":250}\n' "$NOW_TS"
    # Out-of-window (30 days ago) — should be filtered
    printf '{"ts":"%s","kind":"github_api_call","script":"old-script.sh","api":"pr view","used_ms":999}\n' "$OLD_TS"
    # Non-github_api_call event — should be ignored
    printf '{"ts":"%s","kind":"session_start"}\n' "$NOW_TS"
} > "$AMB"

# ── Test 1: text mode ───────────────────────────────────────────────────────
CHUMP_AMBIENT_OVERRIDE="$AMB" bash "$LB" --window 24h >"$TMP/text.out" 2>&1
grep -q "total kind=github_api_call events: 5" "$TMP/text.out" \
    || fail "text mode wrong total: $(cat "$TMP/text.out")"
grep -q "bot-merge.sh" "$TMP/text.out" || fail "text mode missing bot-merge row"
grep -q "queue-driver.sh" "$TMP/text.out" || fail "text mode missing queue-driver row"
! grep -q "old-script.sh" "$TMP/text.out" || fail "text mode included out-of-window event"
ok "text mode: 5 in-window events ranked, out-of-window filtered"

# ── Test 2: --json shape ─────────────────────────────────────────────────────
CHUMP_AMBIENT_OVERRIDE="$AMB" bash "$LB" --window 24h --json >"$TMP/leader.json" 2>&1
python3 - <<PY
import json, sys
d = json.load(open("$TMP/leader.json"))
assert d["total_calls"] == 5, d
assert d["window"] == "24h", d
assert len(d["rows"]) >= 2, d
# Top row should be bot-merge.sh pr merge (2 calls × 5 points = 10) — highest
top = d["rows"][0]
assert top["script"] == "bot-merge.sh", top
assert top["api"] == "pr merge", top
assert top["calls"] == 2, top
assert top["est_points"] == 10, top
print("ok json")
PY
ok "--json validates as JSON with correct ranking and field shape"

# ── Test 3: --top filter ─────────────────────────────────────────────────────
CHUMP_AMBIENT_OVERRIDE="$AMB" bash "$LB" --window 24h --json --top 1 >"$TMP/top1.json" 2>&1
python3 -c "
import json
d = json.load(open('$TMP/top1.json'))
assert len(d['rows']) == 1, d
print('ok top filter')
"
ok "--top 1 caps to single row"

# ── Test 4: --window filter to 1m (essentially none) ─────────────────────────
# Won't filter out the now-events but verifies the window arg shape doesn't error.
CHUMP_AMBIENT_OVERRIDE="$AMB" bash "$LB" --window 1h --json >"$TMP/1h.json"
python3 -c "
import json
d = json.load(open('$TMP/1h.json'))
assert d['window'] == '1h', d
print('ok window arg')
"
ok "--window 1h shape works"

# ── Test 5: --emit-ambient writes one digest event ──────────────────────────
EMIT_AMB="$TMP/emit-ambient.jsonl"
mkdir -p "$TMP/fake-repo/.chump-locks"
cp "$AMB" "$TMP/fake-repo/.chump-locks/ambient.jsonl"
cd "$TMP/fake-repo"
git init -q && git config user.email t@t.test && git config user.name t
echo "x" > x && git add . && git commit -qm init
CHUMP_AMBIENT_OVERRIDE="$AMB" bash "$LB" --window 24h --emit-ambient >/dev/null 2>&1
DIGESTS=$(grep -c '"kind":"api_cost_digest_emitted"' "$TMP/fake-repo/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)
[[ "$DIGESTS" -eq 1 ]] || fail "expected 1 digest event, got $DIGESTS in $TMP/fake-repo/.chump-locks/ambient.jsonl"
LINE=$(grep '"kind":"api_cost_digest_emitted"' "$TMP/fake-repo/.chump-locks/ambient.jsonl")
for f in '"window_hours":24' '"total_calls":5' '"top_script":"bot-merge.sh"' '"top_api":"pr merge"' ; do
    grep -q "$f" <<<"$LINE" || fail "digest event missing $f: $LINE"
done
ok "--emit-ambient writes exactly one digest event with all required fields"

# ── Test 6: registry + plist + installer ────────────────────────────────────
grep -q 'kind: api_cost_digest_emitted' "$REG" \
    || fail "EVENT_REGISTRY missing api_cost_digest_emitted"
[[ -f "$PLIST" ]] || fail "launchd plist missing"
[[ -x "$INST" ]] || fail "installer not present or not executable"
grep -q 'resolve_main_worktree' "$INST" || fail "installer not using INFRA-451 resolver"
ok "EVENT_REGISTRY registered + plist + installer all present"

echo
echo "All INFRA-1077 api-cost-leaderboard tests passed."
