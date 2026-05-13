#!/usr/bin/env bash
# test-fixture-git-identity.sh — INFRA-1024
#
# Verifies that test fixtures do NOT mutate the main repo's or any linked
# worktree's local git config (user.email / user.name) with sentinel values.
#
# The guard checks two things:
# 1. No sentinel value (t@t.t, t@t, empty) in the main repo's .git/config
# 2. No 'git config user.email <sentinel>' call without using env vars or
#    the -c flag in fixture scripts (static grep check)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# ── Test 1: main repo .git/config has no sentinel user.email ─────────────────
MAIN_EMAIL=$(git -C "$REPO_ROOT" config --local --get user.email 2>/dev/null || echo "")
case "$MAIN_EMAIL" in
    ""|t@t|t@t.t|test@test|test@test.test|fixture@*)
        if [[ -n "$MAIN_EMAIL" ]]; then
            fail "main repo .git/config has sentinel user.email='$MAIN_EMAIL' — run: git config --local --unset user.email"
        fi
        ok "main repo has no local user.email set (clean)"
        ;;
    *)
        ok "main repo local user.email='$MAIN_EMAIL' (non-sentinel)"
        ;;
esac

# ── Test 2: linked worktrees don't have sentinel identity ────────────────────
sentinel_found=0
while IFS= read -r wt_path; do
    [[ -z "$wt_path" ]] && continue
    wt_email=$(git -C "$wt_path" config --local --get user.email 2>/dev/null || echo "")
    case "$wt_email" in
        t@t|t@t.t|test@test|test@test.test|fixture@*)
            echo "FAIL: worktree $wt_path has sentinel user.email='$wt_email'" >&2
            sentinel_found=1
            ;;
    esac
done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep '^worktree ' | awk '{print $2}')

[[ $sentinel_found -eq 0 ]] \
    && ok "no linked worktree has sentinel git identity" \
    || fail "one or more worktrees have sentinel git identity (see above)"

# ── Test 3: test-all-gates-force-fire.sh fixtures don't use 'git config' ─────
GATES="$REPO_ROOT/scripts/ci/test-all-gates-force-fire.sh"
if [[ -f "$GATES" ]]; then
    # Look for 'git config user.email' or 'git config user.name' lines in
    # fixture functions (between fixture_* and the next closing brace).
    # Allow lines that are comments.
    BAD=$(grep -n 'git config user\.\(email\|name\)' "$GATES" \
        | grep -v '^\s*#' || true)
    if [[ -n "$BAD" ]]; then
        echo "FAIL: test-all-gates-force-fire.sh uses 'git config user.*' (writes to .git/config):" >&2
        echo "$BAD" >&2
        echo "  Fix: use GIT_AUTHOR_EMAIL/GIT_COMMITTER_EMAIL env vars or 'git -c user.email=...' per-command" >&2
        exit 1
    fi
    ok "test-all-gates-force-fire.sh: no 'git config user.*' in fixture functions"
fi

# ── Test 4: src/version.rs test fixture doesn't write to git config ──────────
VERSION_RS="$REPO_ROOT/src/version.rs"
if [[ -f "$VERSION_RS" ]]; then
    BAD=$(grep -n '"config", "user\.' "$VERSION_RS" | grep -v '^\s*//' || true)
    if [[ -n "$BAD" ]]; then
        echo "FAIL: src/version.rs uses git config to set user identity:" >&2
        echo "$BAD" >&2
        echo "  Fix: use .env(\"GIT_AUTHOR_EMAIL\", ...) on the Command builder" >&2
        exit 1
    fi
    ok "src/version.rs: no 'git config user.*' in test fixture"
fi

echo ""
echo "=== test-fixture-git-identity.sh PASSED ==="
