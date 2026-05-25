#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase-falsepositive.sh — INFRA-1958
#
# Regression test for the local-rebase fallback added to pr-auto-rebase.sh
# after the 2026-05-24 wedge: `gh pr update-branch` returned false-positive
# conflicts for 8 PRs that local `git rebase origin/main` resolved cleanly
# with ZERO conflicts. The fleet sat for hours on a tooling bug.
#
# This test asserts:
#  (1) the script source contains the fallback code path + new event-kind
#  (2) the script accepts CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1 to disable it
#  (3) when gh API "fails" but local rebase would succeed, the fallback is
#      attempted (verified by source inspection; live rebase is out of scope
#      for a network-free CI smoke).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/pr-auto-rebase.sh"

echo "=== INFRA-1958 pr-auto-rebase fallback tests ==="

# (1) Source contract — fallback code path is present.
[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

for needle in \
    "INFRA-1958" \
    "pr_auto_rebase_fallback" \
    "CHUMP_PR_AUTO_REBASE_NO_FALLBACK" \
    "local-rebase fallback" \
    "git rebase origin/main" \
    "gh pr view" \
    "worktree add" \
    "git push origin" \
    "force-with-lease" \
    "rebase --abort"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "fallback-contract: $needle"
    else
        fail "fallback-contract missing: $needle"
    fi
done

# (2) Failure escalation discipline — only emit pr_auto_rebase_failed when
#     BOTH gh API AND local rebase have failed (or fallback was bypassed).
if grep -q 'local rebase OK but push failed' "$TARGET"; then
    ok "push-failure path is distinct event"
else
    fail "push-failure path missing"
fi

if grep -q 'true conflict confirmed by local rebase' "$TARGET"; then
    ok "true-conflict path is distinct (post-fallback)"
else
    fail "true-conflict post-fallback path missing"
fi

# (3) Behaviour smoke — invoke with CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1 +
#     a stubbed gh that returns no targets; should exit clean.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub: gh pr list returns empty array.
if [[ "$1 $2" == "pr list" ]]; then
    echo '[]'
    exit 0
fi
echo "stub gh: unexpected args: $*" >&2
exit 1
EOF
chmod +x "$TMP/bin/gh"

if CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1 PATH="$TMP/bin:$PATH" \
        bash "$TARGET" --dry-run >/dev/null 2>&1; then
    ok "no-fallback bypass env accepted (script exits clean on empty pr list)"
else
    fail "script failed to run with CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1"
fi

echo
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
