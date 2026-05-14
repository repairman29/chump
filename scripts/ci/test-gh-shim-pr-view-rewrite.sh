#!/usr/bin/env bash
# scripts/ci/test-gh-shim-pr-view-rewrite.sh — INFRA-1282

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRANSLATOR="$REPO_ROOT/scripts/coord/lib/gh-shim/pr-view-translate.py"
SHIM="$REPO_ROOT/scripts/coord/lib/gh-shim/gh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$TRANSLATOR" ]] || fail "translator not executable"
[[ -x "$SHIM" ]] || fail "shim not executable"
ok "translator + shim present and executable"

TMP=$(mktemp -d -t pr-view-rewrite-test-XXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump" "$TMP/.chump-locks"

PR_JSON='{"number":9999,"state":"open","title":"test PR","html_url":"https://github.com/owner/repo/pull/9999","draft":false,"mergeable":true,"mergeable_state":"dirty","head":{"ref":"test-branch","sha":"abc123"},"base":{"ref":"main","sha":"def456"},"user":{"login":"octocat"},"created_at":"2026-05-14T10:00:00Z","updated_at":"2026-05-14T10:30:00Z","closed_at":null,"merged_at":null,"auto_merge":{"merge_method":"squash","enabled_by":{"login":"octocat"}}}'

python3.12 - "$TMP/.chump/github_cache.db" "$PR_JSON" <<'PY'
import json, sqlite3, sys
from datetime import datetime, timezone
db_path, payload = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY, head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT, auto_merge_enabled INTEGER NOT NULL DEFAULT 0, draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT, updated_at_api TEXT NOT NULL,
    fetched_at_local TEXT NOT NULL, raw_payload_json TEXT);
""")
pr = json.loads(payload)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
conn.execute("INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (pr["number"], pr["head"]["ref"], pr["head"]["sha"], pr["base"]["ref"], pr["base"]["sha"],
     pr["mergeable_state"], 1, 0, pr["merged_at"], pr["title"], pr["user"]["login"],
     pr["updated_at"], now, payload))
conn.commit(); conn.close()
PY

export CHUMP_REPO="$TMP"

out=$(python3.12 "$TRANSLATOR" 9999 --json state)
echo "$out" | grep -q '"state": "OPEN"' || fail "state not uppercased: $out"
ok "numeric arg: state field uppercased OPEN"

out=$(python3.12 "$TRANSLATOR" test-branch --json number,state)
echo "$out" | grep -q '"number": 9999' || fail "branch lookup failed: $out"
echo "$out" | grep -q '"state": "OPEN"' || fail "branch lookup state: $out"
ok "branch-name arg: resolved via cache head_ref"

python3.12 "$TRANSLATOR" 9999 --json state --watch >/dev/null 2>&1
[[ "$?" == "2" ]] || fail "--watch should fall through"
ok "--watch falls through (rc=2)"

python3.12 "$TRANSLATOR" 9999 --json statusCheckRollup >/dev/null 2>&1
[[ "$?" == "2" ]] || fail "unsupported field should fall through"
ok "unsupported field (statusCheckRollup) falls through"

out=$(python3.12 "$TRANSLATOR" 9999 --json mergeStateStatus)
echo "$out" | grep -q '"mergeStateStatus": "DIRTY"' || fail "mergeStateStatus not uppercased: $out"
ok "mergeStateStatus uppercased DIRTY"

out=$(python3.12 "$TRANSLATOR" 9999 --json autoMergeRequest)
echo "$out" | grep -q '"mergeMethod": "SQUASH"' || fail "autoMergeRequest missing mergeMethod: $out"
ok "autoMergeRequest reshape: mergeMethod added"

out=$(python3.12 "$TRANSLATOR" 9999 --json headRefName -q .headRefName)
[[ "$out" == "test-branch" ]] || fail "jq projection failed: '$out'"
ok "-q jq post-processing works"

grep -q "CHUMP_GH_SHIM_NO_REWRITE" "$SHIM" || fail "shim missing CHUMP_GH_SHIM_NO_REWRITE bypass"
ok "shim wires CHUMP_GH_SHIM_NO_REWRITE bypass"

[[ -f "$TMP/.chump-locks/ambient.jsonl" ]] || fail "no ambient.jsonl after translation"
grep -q '"kind": "cache_hit"' "$TMP/.chump-locks/ambient.jsonl" || fail "no cache_hit event"
ok "ambient cache_hit event emitted"

out=$(python3.12 "$TRANSLATOR" 9999 --json state,mergeStateStatus,headRefName,number)
echo "$out" | python3.12 -c "
import json, sys
d = json.load(sys.stdin)
assert d['state'] == 'OPEN' and d['mergeStateStatus'] == 'DIRTY'
assert d['headRefName'] == 'test-branch' and d['number'] == 9999
" 2>&1 || fail "multi-field projection broken: $out"
ok "multi-field projection: state, mergeStateStatus, headRefName, number"

python3.12 "$TRANSLATOR" nonexistent-branch --json state >/dev/null 2>&1
[[ "$?" == "2" ]] || fail "branch-not-in-cache should fall through"
ok "branch not in cache: falls through"

echo
echo "All INFRA-1282 gh-shim-pr-view-rewrite tests passed."
