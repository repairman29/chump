#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase.sh — INFRA-1777
#
# Source-contract + behavioural smoke for scripts/coord/pr-auto-rebase.sh.
# Doesn't hit the live `gh pr list` (network-free CI). Instead, it
# stubs `gh` on PATH and verifies the script's cooldown + selection logic.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/pr-auto-rebase.sh"

echo "=== INFRA-1777 pr-auto-rebase tests ==="

# Source contract
[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "script executable" || fail "$TARGET not executable"

for needle in \
    "MAX_PER_HOUR" \
    "cooldown_count" \
    "autoMergeRequest != null" \
    "mergeStateStatus == \"DIRTY\"" \
    "mergeStateStatus == \"BEHIND\"" \
    "gh pr update-branch" \
    "pr_auto_rebased" \
    "pr_auto_rebase_skipped" \
    "pr_auto_rebase_failed"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# Behaviour smoke with a stubbed gh.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh for the smoke test.
# - `gh pr list ...` returns a deterministic fixture
# - `gh pr update-branch <N>` returns 0 silently
case "$1" in
    pr)
        case "$2" in
            list)
                # Two PRs: one DIRTY+armed (target), one BLOCKED+armed (skip), one DIRTY+unarmed (skip)
                cat <<JSON
[
  {"number": 9001, "mergeStateStatus": "DIRTY", "autoMergeRequest": {"mergeMethod": "SQUASH"}},
  {"number": 9002, "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}},
  {"number": 9003, "mergeStateStatus": "DIRTY", "autoMergeRequest": null}
]
JSON
                ;;
            update-branch)
                # Succeed silently for the smoke fixture.
                exit 0
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

# Run against a synthetic CHUMP_REPO so cooldown/ambient stay isolated.
SYN="$TMP/syn-repo"
mkdir -p "$SYN/.chump-locks"

OUT="$(PATH="$TMP/bin:$PATH" bash "$TARGET" --dry-run 2>&1)"
if echo "$OUT" | grep -qE "would rebase #9001"; then
    ok "dry-run selects DIRTY+armed PR"
else
    fail "dry-run did not pick #9001; got: $OUT"
fi
if echo "$OUT" | grep -q "would rebase #9002"; then
    ok "dry-run selects #9002 (BLOCKED+armed, INFRA-1838)"
else
    fail "dry-run did NOT select #9002 — INFRA-1838 regression (BLOCKED+armed must be picked up)"
fi
# INFRA-1838: bypass env var should restore pre-1838 behavior (skip BLOCKED)
OUT_BYPASS="$(PATH="$TMP/bin:$PATH" CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED=1 bash "$TARGET" --dry-run 2>&1)"
if echo "$OUT_BYPASS" | grep -q "would rebase #9002"; then
    fail "CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED=1 should have excluded #9002 (BLOCKED) but didn't"
else
    ok "CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED=1 restores pre-1838 filter (skips #9002)"
fi
if echo "$OUT" | grep -q "would rebase #9003"; then
    fail "dry-run incorrectly selected #9003 (no auto-merge)"
else
    ok "dry-run skips #9003 (no auto-merge armed)"
fi

# Live (no --dry-run): rebase should emit an event.
# Run from the synthetic-repo's coord/ relative path so ambient file lands there.
SCRIPT_COPY="$SYN/scripts/coord/pr-auto-rebase.sh"
mkdir -p "$(dirname "$SCRIPT_COPY")"
cp "$TARGET" "$SCRIPT_COPY"

OUT2="$(PATH="$TMP/bin:$PATH" bash "$SCRIPT_COPY" 2>&1)"
if echo "$OUT2" | grep -qE "OK #9001"; then
    ok "live rebase reports OK for #9001"
else
    fail "live rebase did not OK #9001; got: $OUT2"
fi
if grep -q '"kind":"pr_auto_rebased"' "$SYN/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "ambient.jsonl received pr_auto_rebased event"
else
    fail "no pr_auto_rebased event in $SYN/.chump-locks/ambient.jsonl"
fi
if grep -q '"pr":9001' "$SYN/.chump-locks/pr-auto-rebase-cooldown.jsonl" 2>/dev/null; then
    ok "cooldown log records the rebase"
else
    fail "cooldown log missing #9001 record"
fi

# Cooldown check: simulate 4 prior rebases in last hour → 5th should skip.
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for _ in 1 2 3 4; do
    printf '{"ts":"%s","pr":9001,"state":"DIRTY"}\n' "$NOW_TS" >> "$SYN/.chump-locks/pr-auto-rebase-cooldown.jsonl"
done
OUT3="$(PATH="$TMP/bin:$PATH" bash "$SCRIPT_COPY" --dry-run 2>&1)"
if echo "$OUT3" | grep -q "SKIP #9001 — cooldown"; then
    ok "cooldown gates re-rebasing past MAX_PER_HOUR"
else
    fail "cooldown failed to gate; got: $OUT3"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
