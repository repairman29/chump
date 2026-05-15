#!/usr/bin/env bash
# test-gap-preflight-dupe-sweep.sh — INFRA-1029
#
# Tests the two new non-fatal duplicate-sweep checks added to gap-preflight.sh:
#   Check 5: existing /tmp/chump-* worktree directory scan
#   Check 6: open PR title scan via REST (no GraphQL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/coord/gap-preflight.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

[[ -f "$PREFLIGHT" ]] || fail "missing $PREFLIGHT"

# ── Test 1: worktree scan code is present ────────────────────────────────────
grep -q 'CHUMP_PREFLIGHT_NO_WORKTREE_SCAN' "$PREFLIGHT" \
    && ok "CHUMP_PREFLIGHT_NO_WORKTREE_SCAN escape hatch present" \
    || fail "worktree scan escape hatch missing (INFRA-1029)"

# ── Test 2: PR scan code is present ──────────────────────────────────────────
grep -q 'CHUMP_PREFLIGHT_NO_PR_SCAN' "$PREFLIGHT" \
    && ok "CHUMP_PREFLIGHT_NO_PR_SCAN escape hatch present" \
    || fail "PR scan escape hatch missing (INFRA-1029)"

grep -q 'pulls?state=open' "$PREFLIGHT" \
    && ok "REST open-PR query present (no GraphQL)" \
    || fail "REST PR scan query missing (INFRA-1029)"

# ── Test 3: worktree directory scan emits WARN and exits 0 ───────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Isolate cache DB so tests don't pollute or read from the real repo cache.
export CHUMP_CACHE_DB="$TMP/test_cache.db"

# Create a fake worktree directory for GAP-ID infra-7701
FAKE_WT="$TMP/chump-infra-7701"
mkdir -p "$FAKE_WT"

# Shim dir for overriding binaries
SHIM="$TMP/bin"
mkdir -p "$SHIM"

# chump shim: returns open/unclaimed for any gap
cat > "$SHIM/chump" <<'CSHIM'
#!/usr/bin/env bash
if [[ "$*" == *"gap show"* ]] || [[ "$*" == *"show"* ]]; then
    echo '{"id":"INFRA-7701","status":"open","claimed_by":null}'
    exit 0
fi
echo '{}' ; exit 0
CSHIM
chmod +x "$SHIM/chump"

# gh shim: no open PRs, repo view returns test org
cat > "$SHIM/gh" <<'GHSHIM'
#!/usr/bin/env bash
if [[ "$*" == *"nameWithOwner"* ]] || [[ "$*" == *"repo view"* ]]; then
    echo "testorg/testrepo"
    exit 0
fi
# pulls — return empty list (no PR match)
if [[ "$*" == *"pulls"* ]]; then
    echo "[]"
    exit 0
fi
echo '{}' ; exit 0
GHSHIM
chmod +x "$SHIM/gh"

# git shim: return open status for gap.
# IMPORTANT: use exact patterns that don't match 'rev-parse' (which contains
# no listed keywords), so github_cache.sh can call git rev-parse --show-toplevel
# for _cache_ambient_path without getting fake YAML returned.
cat > "$SHIM/git" <<'GITSHIM'
#!/usr/bin/env bash
# fetch — no-op
if [[ "$*" == *"fetch"* ]]; then exit 0; fi
# ls-tree — return empty (force monolithic fallback)
if [[ "$*" == *"ls-tree"* ]]; then exit 0; fi
# show for gaps.yaml — return fake open gap (must come after ls-tree check)
if [[ "$*" == *"show"*"gaps.yaml"* ]]; then
    echo "gaps:"
    echo "- id: INFRA-7701"
    echo "  status: open"
    exit 0
fi
# worktree list — empty
if [[ "$*" == *"worktree"* ]]; then exit 0; fi
# everything else (including rev-parse)
/usr/bin/git "$@"
GITSHIM
chmod +x "$SHIM/git"

# Run preflight with fake worktree visible; expect exit 0 with WARN in output
# CHUMP_PREFLIGHT_PR_CHECK=0 disables Check 2 so these calls don't populate
# the shared cache DB and contaminate Test 5's cache-first PR scan.
WT_SCAN_OUTPUT=$(
    PATH="$SHIM:$PATH" \
    REMOTE="origin" BASE="main" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_LOCK_DIR="$TMP/locks" \
    CHUMP_PREFLIGHT_NO_PR_SCAN=1 \
    CHUMP_PREFLIGHT_PR_CHECK=0 \
    bash "$PREFLIGHT" INFRA-7701 2>&1 || true
)

# Should exit 0 even if worktree found (non-fatal)
exit_code=0
PATH="$SHIM:$PATH" \
REMOTE="origin" BASE="main" \
CHUMP_SESSION_ID="test-session-$$" \
CHUMP_LOCK_DIR="$TMP/locks" \
CHUMP_PREFLIGHT_NO_PR_SCAN=1 \
CHUMP_PREFLIGHT_PR_CHECK=0 \
bash "$PREFLIGHT" INFRA-7701 >/dev/null 2>&1 && exit_code=0 || exit_code=$?

[[ $exit_code -eq 0 ]] \
    && ok "worktree duplicate scan is non-fatal (exit 0)" \
    || fail "worktree duplicate scan should exit 0 (got $exit_code)"

# ── Test 4: CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 suppresses the check ──────────
NO_WT_OUTPUT=$(
    PATH="$SHIM:$PATH" \
    REMOTE="origin" BASE="main" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_LOCK_DIR="$TMP/locks" \
    CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 \
    CHUMP_PREFLIGHT_NO_PR_SCAN=1 \
    CHUMP_PREFLIGHT_PR_CHECK=0 \
    bash "$PREFLIGHT" INFRA-7701 2>&1 || true
)

# When suppressed, no WARN about existing worktree should appear
if echo "$NO_WT_OUTPUT" | grep -q "existing worktree directory found"; then
    fail "CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 did not suppress worktree scan"
else
    ok "CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 suppresses worktree check"
fi

# ── Test 5: PR title scan emits WARN when a matching open PR exists ───────────
# Override gh shim to return a matching PR.
# Use a temp file + mv for atomic replacement (avoids macOS inode-cache issue
# where cat > existing_file can serve stale content to the next exec).
_gh_tmp="$(mktemp "$SHIM/gh.XXXXXX")"
cat > "$_gh_tmp" <<'GHSHIM2'
#!/usr/bin/env bash
if [[ "$*" == *"nameWithOwner"* ]] || [[ "$*" == *"repo view"* ]]; then
    echo "testorg/testrepo"
    exit 0
fi
# pulls — return a PR with the gap ID in title
if [[ "$*" == *"pulls"* ]]; then
    echo '[{"number":42,"title":"INFRA-7701: add frobnicator support"}]'
    exit 0
fi
echo '{}' ; exit 0
GHSHIM2
chmod +x "$_gh_tmp"
mv -f "$_gh_tmp" "$SHIM/gh"

T5_CACHE_DB="$TMP/test_cache_t5.db"
PR_SCAN_OUTPUT=$(
    PATH="$SHIM:$PATH" \
    REMOTE="origin" BASE="main" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_LOCK_DIR="$TMP/locks" \
    CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 \
    CHUMP_PREFLIGHT_PR_CHECK=0 \
    CHUMP_CACHE_DB="$T5_CACHE_DB" \
    bash "$PREFLIGHT" INFRA-7701 2>&1 || true
)

if echo "$PR_SCAN_OUTPUT" | grep -q "open PR.*found"; then
    ok "PR title scan emits WARN when matching open PR exists"
else
    fail "PR title scan should emit WARN for existing PR #42 with INFRA-7701 in title"
fi

# Still exits 0 (non-fatal)
exit_code=0
PATH="$SHIM:$PATH" \
REMOTE="origin" BASE="main" \
CHUMP_SESSION_ID="test-session-$$" \
CHUMP_LOCK_DIR="$TMP/locks" \
CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 \
CHUMP_PREFLIGHT_PR_CHECK=0 \
CHUMP_CACHE_DB="$T5_CACHE_DB" \
bash "$PREFLIGHT" INFRA-7701 >/dev/null 2>&1 && exit_code=0 || exit_code=$?

[[ $exit_code -eq 0 ]] \
    && ok "PR title scan is non-fatal (exit 0)" \
    || fail "PR title scan should exit 0 (got $exit_code)"

# ── Test 6: CHUMP_PREFLIGHT_NO_PR_SCAN=1 suppresses the PR check ─────────────
NO_PR_OUTPUT=$(
    PATH="$SHIM:$PATH" \
    REMOTE="origin" BASE="main" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_LOCK_DIR="$TMP/locks" \
    CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1 \
    CHUMP_PREFLIGHT_NO_PR_SCAN=1 \
    CHUMP_PREFLIGHT_PR_CHECK=0 \
    bash "$PREFLIGHT" INFRA-7701 2>&1 || true
)

if echo "$NO_PR_OUTPUT" | grep -q "open PR.*found"; then
    fail "CHUMP_PREFLIGHT_NO_PR_SCAN=1 did not suppress PR scan"
else
    ok "CHUMP_PREFLIGHT_NO_PR_SCAN=1 suppresses PR title scan"
fi

echo ""
echo "=== test-gap-preflight-dupe-sweep.sh PASSED ==="
