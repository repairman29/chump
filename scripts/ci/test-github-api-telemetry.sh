#!/usr/bin/env bash
# scripts/ci/test-github-api-telemetry.sh — INFRA-999
#
# Verifies scripts/coord/lib/github.sh:
#   1. chump_gh runs the wrapped gh and forwards exit code.
#   2. Each call appends one well-formed github_api_call line to ambient.jsonl
#      with the expected fields.
#   3. chump_gh_api_tag picks 2 tokens for "pr merge" but only "api" when the
#      second token starts with `/`.
#   4. api-cost-report.sh ranks calls by (script, api).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"
REPORT="$REPO_ROOT/scripts/dev/api-cost-report.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

AMBIENT="$TMP/ambient.jsonl"

# ── Fake gh on $PATH. Returns a canned rate_limit payload for
#    `gh api rate_limit ...` and exits 0 for everything else.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# Args: $1 = subcommand (api/pr/run), rest = subargs
if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
    # The wrapper calls: gh api rate_limit --jq '"\(.resources.core.remaining) \(.resources.graphql.remaining)"'
    # We emulate jq by inspecting --jq and printing the formatted answer.
    echo "4321 87"
    exit 0
fi
# For "pr merge 123 --auto --squash" or anything else, succeed with no output.
exit 0
EOF
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH"

export CHUMP_AMBIENT_OVERRIDE="$AMBIENT"
export CHUMP_GH_SCRIPT="test-harness.sh"

# Source the lib in a subshell so we can re-test fresh later if needed.
# shellcheck disable=SC1090
source "$LIB"

# ── Test 1: api tag picker ───────────────────────────────────────────────────
tag1="$(chump_gh_api_tag pr merge 123 --auto)"
[[ "$tag1" == "pr merge" ]] || fail "api_tag(pr merge ...) got '$tag1', want 'pr merge'"
tag2="$(chump_gh_api_tag api /rate_limit)"
[[ "$tag2" == "api" ]] || fail "api_tag(api /rate_limit) got '$tag2', want 'api'"
tag3="$(chump_gh_api_tag pr view --json state)"
[[ "$tag3" == "pr view" ]] || fail "api_tag(pr view --json) got '$tag3', want 'pr view'"
ok "chump_gh_api_tag handles 1/2-token gh calls correctly"

# ── Test 2: chump_gh forwards rc + emits one event ───────────────────────────
rm -f "$AMBIENT"
chump_gh pr merge 123 --auto --squash >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "chump_gh returned rc=$rc, want 0"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl not created"
lines=$(wc -l <"$AMBIENT" | tr -d ' ')
[[ "$lines" == "1" ]] || fail "expected 1 line in ambient, got $lines: $(cat "$AMBIENT")"
ok "chump_gh emitted exactly one ambient line and forwarded rc=0"

# ── Test 3: emitted line has all required fields ─────────────────────────────
line="$(cat "$AMBIENT")"
for f in '"kind":"github_api_call"' '"script":"test-harness.sh"' '"api":"pr merge"' \
         '"remaining_core":' '"remaining_graphql":' '"used_ms":' '"rc":' '"ts":' ; do
    grep -q "$f" <<<"$line" || fail "ambient line missing field $f: $line"
done
ok "ambient line shape includes all required fields"

# ── Test 4: rate-limit values parsed from fake gh ────────────────────────────
grep -q '"remaining_core":4321' <<<"$line" || fail "expected remaining_core=4321: $line"
grep -q '"remaining_graphql":87' <<<"$line" || fail "expected remaining_graphql=87: $line"
ok "rate-limit values pulled from fake gh and recorded"

# ── Test 5: chump_gh_record (record-only path, e.g. gh_with_backoff) ─────────
rm -f "$AMBIENT"
chump_gh_record "pr create" 123 0 "bot-merge.sh"
[[ -f "$AMBIENT" ]] || fail "chump_gh_record did not write ambient line"
line="$(cat "$AMBIENT")"
grep -q '"script":"bot-merge.sh"' <<<"$line" || fail "chump_gh_record: script tag override failed: $line"
grep -q '"api":"pr create"' <<<"$line"      || fail "chump_gh_record: api tag missing: $line"
grep -q '"used_ms":123' <<<"$line"          || fail "chump_gh_record: used_ms missing: $line"
ok "chump_gh_record emits with caller-provided script + api + timing"

# ── Test 6: CHUMP_GH_SILENT=1 suppresses emission ────────────────────────────
rm -f "$AMBIENT"
CHUMP_GH_SILENT=1 chump_gh pr view 1 --json state >/dev/null 2>&1
[[ ! -f "$AMBIENT" ]] || {
    if [[ -s "$AMBIENT" ]]; then
        fail "CHUMP_GH_SILENT=1 did NOT suppress emission: $(cat "$AMBIENT")"
    fi
}
ok "CHUMP_GH_SILENT=1 suppresses emission"

# ── Test 7: api-cost-report.sh ranks by (script, api) ────────────────────────
rm -f "$AMBIENT"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr merge","remaining_core":1,"remaining_graphql":2,"used_ms":1,"rc":0}\n' "$NOW"
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr merge","remaining_core":1,"remaining_graphql":2,"used_ms":1,"rc":0}\n' "$NOW"
    printf '{"ts":"%s","kind":"github_api_call","script":"bot-merge.sh","api":"pr view","remaining_core":1,"remaining_graphql":2,"used_ms":1,"rc":0}\n' "$NOW"
    printf '{"ts":"%s","kind":"github_api_call","script":"queue-driver.sh","api":"pr list","remaining_core":1,"remaining_graphql":2,"used_ms":1,"rc":0}\n' "$NOW"
} >"$AMBIENT"

CHUMP_AMBIENT_OVERRIDE="$AMBIENT" bash "$REPORT" --window 24h >"$TMP/report.txt"
grep -q "total calls: 4" "$TMP/report.txt" || fail "report missing total 4: $(cat "$TMP/report.txt")"
# First row in ranking should be bot-merge.sh pr merge with 2 calls.
head_data="$(grep -E '^(bot-merge\.sh|queue-driver\.sh)' "$TMP/report.txt" | head -1)"
grep -q "bot-merge.sh" <<<"$head_data" || fail "top row not bot-merge.sh: $head_data"
grep -q "pr merge" <<<"$head_data"     || fail "top row not pr merge: $head_data"
grep -q " 2 calls" <<<"$head_data"     || fail "top row count != 2: $head_data"
ok "api-cost-report.sh ranks by (script, api) and shows correct totals"

# ── Test 8: --json output ────────────────────────────────────────────────────
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" bash "$REPORT" --window 24h --json >"$TMP/report.json"
python3 -c "
import json, sys
d = json.load(open('$TMP/report.json'))
assert d['total_calls'] == 4, d
assert d['by_script_api'][0] == {'script':'bot-merge.sh','api':'pr merge','calls':2}, d['by_script_api']
" || fail "--json output malformed: $(cat "$TMP/report.json")"
ok "api-cost-report.sh --json output is well-formed"

echo
echo "All github API telemetry tests passed."
