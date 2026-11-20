#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase-local-fallback.sh — INFRA-1811
#
# Extends the INFRA-1958 local-rebase fallback with:
#   - kind=pr_auto_rebase_recovered   (success path, carries driver names)
#   - kind=pr_auto_rebase_unresolvable (still-conflicted path, carries conflict_files)
#   - CHUMP_PR_AUTO_REBASE_LOCAL_TIMEOUT_S cost guard on the local rebase attempt
#
# Tests two fixture scenarios end-to-end against a scratch git repo (no
# network / no live gh calls):
#   (1) additive ci.yml conflict resolved cleanly via the custom merge driver
#       -> resolve_merge_drivers() reports the driver name
#   (2) genuine semantic conflict (same line changed two ways) -> unresolvable,
#       conflict_files array populated
#
# Plus source-contract checks for the timeout guard and new event kinds.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/pr-auto-rebase.sh"

echo "=== INFRA-1811 pr-auto-rebase local-fallback tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

# ── (1) Source-contract: new event kinds + timeout guard + driver helper ──
for needle in \
    "pr_auto_rebase_recovered" \
    "pr_auto_rebase_unresolvable" \
    "CHUMP_PR_AUTO_REBASE_LOCAL_TIMEOUT_S" \
    "resolve_merge_drivers" \
    "git check-attr merge" \
    "diff --name-only --diff-filter=U" \
    "timeout \"\${LOCAL_REBASE_TIMEOUT_S}s\""; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# ── (2) Functional: resolve_merge_drivers() against a scratch repo fixture ──
TMP="$(mktemp -d -t pr-auto-rebase-fallback-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/fixture-repo"
mkdir -p "$FIXTURE"
# -b main: pin the initial branch name regardless of the host's
# init.defaultBranch (git 2.43 defaults to "master"), since the fixture
# below rebases feature branches onto a branch literally named "main".
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Test"

cat > "$FIXTURE/.gitattributes" <<'EOF'
ci.yml merge=ci-yml-add-row
EOF
echo "steps: []" > "$FIXTURE/ci.yml"
git -C "$FIXTURE" add .gitattributes ci.yml
git -C "$FIXTURE" commit -q -m "base"

# Register the driver locally (union-merge stand-in for the real
# ci-yml-add-row driver — sufficient to prove attribute resolution works).
git -C "$FIXTURE" config merge.ci-yml-add-row.driver "git merge-file --union %A %O %B"

# Source just the helper function (avoid executing the whole daemon, which
# would try to hit `gh pr list`).
# shellcheck disable=SC1090
FUNC_SRC="$(awk '/^resolve_merge_drivers\(\)/,/^}/' "$TARGET")"
eval "$FUNC_SRC"

DRIVERS="$(resolve_merge_drivers "$FIXTURE" "ci.yml")"
if [[ "$DRIVERS" == "ci-yml-add-row" ]]; then
    ok "resolve_merge_drivers reports ci-yml-add-row for ci.yml (additive fixture)"
else
    fail "resolve_merge_drivers expected 'ci-yml-add-row', got '$DRIVERS'"
fi

DRIVERS_NONE="$(resolve_merge_drivers "$FIXTURE" "some/untracked-attr-file.txt")"
if [[ -z "$DRIVERS_NONE" ]]; then
    ok "resolve_merge_drivers returns empty for a file with no merge attribute"
else
    fail "resolve_merge_drivers expected empty, got '$DRIVERS_NONE'"
fi

# ── (3) Functional: additive ci.yml conflict rebases cleanly with the driver ──
git -C "$FIXTURE" checkout -q -b feature
cat > "$FIXTURE/ci.yml" <<'EOF'
steps: []
# feature-added-step
EOF
git -C "$FIXTURE" commit -q -am "feature: add step"

git -C "$FIXTURE" checkout -q main
cat > "$FIXTURE/ci.yml" <<'EOF'
steps: []
# main-added-step
EOF
git -C "$FIXTURE" commit -q -am "main: add step"

git -C "$FIXTURE" checkout -q feature
if git -C "$FIXTURE" rebase main >/dev/null 2>&1; then
    ok "additive ci.yml fixture rebases cleanly via custom merge driver"
else
    git -C "$FIXTURE" rebase --abort >/dev/null 2>&1 || true
    fail "additive ci.yml fixture failed to rebase (merge driver did not resolve it)"
fi

# ── (4) Functional: genuine semantic conflict is NOT auto-resolved ──
git -C "$FIXTURE" checkout -q main
cat > "$FIXTURE/other.txt" <<'EOF'
line-one
line-two-from-main
EOF
git -C "$FIXTURE" add other.txt
git -C "$FIXTURE" commit -q -m "main: other.txt = main version"

git -C "$FIXTURE" checkout -q -b conflict-branch main~1
cat > "$FIXTURE/other.txt" <<'EOF'
line-one
line-two-from-branch
EOF
git -C "$FIXTURE" add other.txt
git -C "$FIXTURE" commit -q -m "branch: other.txt = branch version"

if git -C "$FIXTURE" rebase main >/dev/null 2>&1; then
    fail "semantic conflict fixture unexpectedly rebased cleanly (test setup bug)"
else
    CONFLICT_FILES="$(git -C "$FIXTURE" diff --name-only --diff-filter=U 2>/dev/null)"
    git -C "$FIXTURE" rebase --abort >/dev/null 2>&1 || true
    if [[ "$CONFLICT_FILES" == *"other.txt"* ]]; then
        ok "semantic conflict correctly surfaces other.txt in conflict_files"
    else
        fail "expected other.txt in conflict file list, got: $CONFLICT_FILES"
    fi
fi

echo
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
