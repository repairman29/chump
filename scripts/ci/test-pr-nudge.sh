#!/usr/bin/env bash
# scripts/ci/test-pr-nudge.sh — INFRA-1117
#
# Verifies chump-pr-nudge.sh classification + comment-template flow
# end-to-end against a PATH-shimmed gh so no GitHub calls happen.
#
# Asserts:
#   1. classify "dirty" PR → uses dirty.md template
#   2. classify "blocked" + failing required check → blocked-ci.md
#   3. classify "blocked" + all required green → base-modified.md
#   4. classify "clean" + no auto-merge → clean-not-merged.md
#   5. classify "blocked" + no auto-merge + stale → orphan-disarmed.md
#   6. cooldown: second invocation within window is skipped
#   7. --force bypasses cooldown
#   8. --dry-run prints comment but does NOT call gh api POST
#   9. pr_nudged event emitted to ambient on real post
#  10. EVENT_REGISTRY.yaml registers pr_nudged

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# Sandbox: minimal repo with a fake origin remote so OWNER_REPO resolves.
cd "$TMP"
git init --quiet
git remote add origin "https://github.com/test-owner/test-repo.git"
mkdir -p scripts/coord/pr-nudge-templates scripts/coord/lib .chump-locks bin
# Bring in the script + templates + supporting lib (chump_gh).
cp "$REPO_ROOT/scripts/coord/chump-pr-nudge.sh" scripts/coord/chump-pr-nudge.sh
cp "$REPO_ROOT/scripts/coord/pr-nudge-templates/"*.md scripts/coord/pr-nudge-templates/
cp "$REPO_ROOT/scripts/coord/lib/github.sh" scripts/coord/lib/github.sh
chmod +x scripts/coord/chump-pr-nudge.sh

# ── PATH-shimmed gh: serves API responses from $TMP/gh-fixtures/<route> files ──
mkdir -p gh-fixtures
cat > bin/gh <<'STUB'
#!/usr/bin/env bash
# Capture POST calls so the test can assert what was posted.
LOG="$TMP/gh-calls.log"
echo "gh $*" >> "$LOG"

# Recognize: gh api repos/X/pulls/N
# Recognize: gh api repos/X/commits/<sha>/check-runs
# Recognize: gh api repos/X/pulls/N/commits
# Recognize: gh api repos/X/issues/N/comments -X POST --input -
# Recognize: gh api rate_limit
# Recognize: gh api 'repos/X/pulls?state=open...'

# Skip wrapper flags so we get to the path.
ARGS=("$@")
# Strip --paginate and --input - flags
filtered=()
input_mode=0
for a in "${ARGS[@]}"; do
    case "$a" in
        --paginate|--jq) ;;
        --input) input_mode=1 ;;
        -X) ;;
        POST|GET) ;;
        *)
            if [[ "$input_mode" -eq 1 ]]; then
                input_mode=0
            else
                filtered+=("$a")
            fi
            ;;
    esac
done

# filtered[0] == "api", filtered[1] == "<path>".
path="${filtered[1]:-}"

case "$path" in
    rate_limit)
        echo '4000 4000 0'
        exit 0
        ;;
    repos/*/pulls/*)
        # Detail or comments?
        if [[ "$path" == */comments ]]; then
            # POST issues comments
            echo '{"id":99}'
            exit 0
        fi
        if [[ "$path" == */commits ]]; then
            cat "$TMP/gh-fixtures/pr-commits.json" 2>/dev/null || echo '[]'
            exit 0
        fi
        if [[ "$path" == */merge ]]; then
            echo '{"merged":true}'
            exit 0
        fi
        cat "$TMP/gh-fixtures/pr-detail.json" 2>/dev/null || echo '{}'
        ;;
    repos/*/issues/*/comments)
        echo '{"id":99}'
        exit 0
        ;;
    repos/*/commits/*/check-runs)
        cat "$TMP/gh-fixtures/check-runs.json" 2>/dev/null || echo '{"check_runs":[]}'
        ;;
    repos/*/pulls)
        cat "$TMP/gh-fixtures/pulls-list.json" 2>/dev/null || echo '[]'
        ;;
    *)
        echo '{}'
        ;;
esac
STUB
chmod +x bin/gh
export PATH="$TMP/bin:$PATH"
export TMP
export CHUMP_GH_NO_PATH_INJECT=1
export CHUMP_GH_SILENT=1
export CHUMP_GH_NO_THROTTLE=1
export CHUMP_GH_NO_PREEMPT=1

# Helper to set the fixtures for one diagnosis class.
set_fixture() {
    local mergeable_state="$1" auto="$2" failing_required="$3" last_age_h="$4"
    cat > gh-fixtures/pr-detail.json <<EOF
{
  "state": "open",
  "head": {"sha": "deadbeefcafe000000000000000000000000abcd"},
  "mergeable_state": "$mergeable_state",
  "auto_merge": $([ "$auto" = "1" ] && echo '{"enabled_by":{"login":"x"}}' || echo 'null')
}
EOF
    # check-runs: include test/audit/ACP; mark named failures.
    python3 - "$failing_required" > gh-fixtures/check-runs.json <<'PY'
import json, sys
failing = set(s for s in sys.argv[1].split(',') if s)
required = ["test","audit","ACP protocol smoke test (Zed / JetBrains compatible)"]
runs = []
for name in required:
    runs.append({
        "name": name,
        "status": "completed",
        "conclusion": "failure" if name in failing else "success",
    })
print(json.dumps({"check_runs": runs}))
PY
    # pr-commits: one commit with an ISO timestamp last_age_h hours ago.
    python3 - "$last_age_h" > gh-fixtures/pr-commits.json <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
age_h = int(sys.argv[1])
ts = (datetime.now(timezone.utc) - timedelta(hours=age_h)).strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps([{"commit": {"committer": {"date": ts}}}]))
PY
}

# ── Test 1: dirty PR → dirty.md ─────────────────────────────────────────────
set_fixture "dirty" 0 "" 1
out=$(scripts/coord/chump-pr-nudge.sh 100 --dry-run 2>&1)
if echo "$out" | grep -q 'class=dirty' && echo "$out" | grep -q 'rebase'; then
    ok "dirty PR → dirty.md template rendered"
else
    fail "test 1: $out"
fi

# ── Test 2: blocked + failing required → blocked-ci.md ──────────────────────
set_fixture "blocked" 0 "test" 1
out=$(scripts/coord/chump-pr-nudge.sh 101 --dry-run 2>&1)
if echo "$out" | grep -q 'class=blocked-ci' && echo "$out" | grep -q 'Failing required checks'; then
    ok "blocked + failing test → blocked-ci.md template rendered"
else
    fail "test 2: $out"
fi

# ── Test 3: blocked + all required green → base-modified.md ─────────────────
set_fixture "blocked" 1 "" 1
out=$(scripts/coord/chump-pr-nudge.sh 102 --dry-run 2>&1)
if echo "$out" | grep -q 'class=base-modified' && echo "$out" | grep -q 'base branch'; then
    ok "blocked + all green → base-modified.md template rendered"
else
    fail "test 3: $out"
fi

# ── Test 4: clean + no auto-merge → clean-not-merged.md ─────────────────────
set_fixture "clean" 0 "" 1
out=$(scripts/coord/chump-pr-nudge.sh 103 --dry-run 2>&1)
if echo "$out" | grep -q 'class=clean-not-merged'; then
    ok "clean + no auto-merge → clean-not-merged.md template rendered"
else
    fail "test 4: $out"
fi

# ── Test 5: blocked + no auto-merge + stale commit (12h) → orphan-disarmed ──
set_fixture "blocked" 0 "" 12
out=$(scripts/coord/chump-pr-nudge.sh 104 --dry-run 2>&1)
if echo "$out" | grep -q 'class=orphan-disarmed' && echo "$out" | grep -q 'orphan'; then
    ok "blocked + stale (12h) + no auto-merge → orphan-disarmed.md template rendered"
else
    fail "test 5: $out"
fi

# ── Test 6: cooldown after a real post ──────────────────────────────────────
set_fixture "dirty" 0 "" 1
scripts/coord/chump-pr-nudge.sh 200 >/dev/null 2>&1 || true
out=$(scripts/coord/chump-pr-nudge.sh 200 2>&1)
if echo "$out" | grep -q 'NOTE recent nudge'; then
    ok "cooldown: second invocation within window emits NOTE"
else
    fail "test 6: expected cooldown NOTE, got: $out"
fi

# ── Test 7: --force bypasses cooldown ───────────────────────────────────────
out=$(scripts/coord/chump-pr-nudge.sh 200 --force 2>&1)
if echo "$out" | grep -q 'posted nudge'; then
    ok "--force bypasses cooldown"
else
    fail "test 7: expected forced post, got: $out"
fi

# ── Test 8: --dry-run does not call gh issues/N/comments POST ───────────────
> "$TMP/gh-calls.log"
set_fixture "dirty" 0 "" 1
scripts/coord/chump-pr-nudge.sh 300 --dry-run >/dev/null 2>&1 || true
if ! grep -q '/comments' "$TMP/gh-calls.log"; then
    ok "--dry-run does NOT POST a comment"
else
    fail "test 8: dry-run leaked a comment POST: $(grep comments "$TMP/gh-calls.log")"
fi

# ── Test 9: pr_nudged emitted on real post ──────────────────────────────────
> .chump-locks/ambient.jsonl
set_fixture "dirty" 0 "" 1
scripts/coord/chump-pr-nudge.sh 400 >/dev/null 2>&1 || true
if grep -q '"kind":"pr_nudged"' .chump-locks/ambient.jsonl; then
    ok "pr_nudged event emitted to ambient on real post"
else
    fail "test 9: no pr_nudged in ambient (lines: $(wc -l < .chump-locks/ambient.jsonl))"
fi

# ── Test 10: EVENT_REGISTRY.yaml registers pr_nudged ───────────────────────
if grep -q '^  - kind: pr_nudged$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "EVENT_REGISTRY.yaml registers pr_nudged"
else
    fail "test 10: pr_nudged NOT registered in EVENT_REGISTRY.yaml"
fi

echo
echo "===== INFRA-1117 results: $PASS pass, $FAIL fail ====="
[[ $FAIL -eq 0 ]]
