#!/usr/bin/env bash
# test-lint-gate-checklist.sh — CREDIBLE-075
#
# CI guard: any NEW scripts/ci/test-*-lint.sh or test-*-banlist.sh added in
# this PR must ship with a companion self-fixture test.
#
# What is checked:
#   • git diff --name-status against base for newly-ADDED lint/banlist scripts
#   • Each new script must have a companion test-NAME-self-fixture.sh in the
#     same PR diff
#
# Bypass: not provided — self-fixture tests are mandatory for new lint gates.
# If a gate genuinely cannot self-fixture (no documentation file), add a
# comment block in the script header explaining why, and this guard will
# accept a skip-comment in the script as evidence:
#   # Self-fixture-skip: <reason>
#
# Usage:
#   bash scripts/ci/test-lint-gate-checklist.sh [--base <branch>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BASE_BRANCH="main"
RETROACTIVE=0

for arg in "$@"; do
    case "$arg" in
        --base=*)       BASE_BRANCH="${arg#--base=}" ;;
        --base)         shift; BASE_BRANCH="$1" ;;
        --retroactive)  RETROACTIVE=1 ;;
    esac
done

# Build BASE_REF (guard against double origin/ prefix when --base=origin/main)
[[ "$BASE_BRANCH" == */* ]] && BASE_REF="$BASE_BRANCH" || BASE_REF="origin/$BASE_BRANCH"
if ! git -C "$REPO_ROOT" rev-parse "$BASE_REF" &>/dev/null; then
    BASE_REF="HEAD~1"
fi

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Retroactive mode: scan ALL existing lint scripts ─────────────────────────
if [[ "$RETROACTIVE" -eq 1 ]]; then
    echo "Retroactive audit — scanning all scripts/ci/test-*-{lint,banlist}.sh"
    echo ""
    while IFS= read -r script; do
        base="$(basename "$script" .sh)"
        fixture="$REPO_ROOT/scripts/ci/${base}-self-fixture.sh"
        skip_comment=$(grep -c 'Self-fixture-skip:' "$REPO_ROOT/$script" 2>/dev/null || echo 0)
        if [[ -f "$fixture" ]]; then
            ok "$script — self-fixture present"
        elif [[ "$skip_comment" -gt 0 ]]; then
            reason=$(grep 'Self-fixture-skip:' "$REPO_ROOT/$script" | head -1 | sed 's/.*Self-fixture-skip: *//')
            ok "$script — skip-comment present: $reason"
        else
            fail "$script — missing self-fixture: scripts/ci/${base}-self-fixture.sh"
        fi
    done < <(find "$REPO_ROOT/scripts/ci" \( -name 'test-*-lint.sh' -o -name 'test-*-banlist.sh' \) 2>/dev/null \
        | sed "s|$REPO_ROOT/||" | sort)
    echo ""
    echo "Retroactive results: $PASS present, $FAIL missing"
    [[ "$FAIL" -gt 0 ]] && echo "(file follow-up gaps for each FAIL above)" && exit 1
    exit 0
fi

# ── PR mode: check only newly ADDED lint scripts in this diff ─────────────────
new_scripts=$(git -C "$REPO_ROOT" diff --name-status "$BASE_REF..HEAD" 2>/dev/null \
    | grep '^A' \
    | awk -F'	' '{print $2}' \
    | grep -E '^scripts/ci/test-[^/]+-lint\.sh$|^scripts/ci/test-[^/]+-banlist\.sh$' \
    || true)

if [[ -z "$new_scripts" ]]; then
    echo "PASS: no new lint/banlist scripts in this PR — checklist not required"
    exit 0
fi

changed_files=$(git -C "$REPO_ROOT" diff --name-only "$BASE_REF..HEAD" 2>/dev/null || true)

echo "New lint/banlist scripts detected — verifying author checklist:"
echo ""

while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    base="$(basename "$script" .sh)"
    fixture_rel="scripts/ci/${base}-self-fixture.sh"
    full_path="$REPO_ROOT/$script"

    echo "Checking: $script"

    # (a) Self-fixture companion in this PR
    if echo "$changed_files" | grep -qF "$fixture_rel"; then
        ok "(a) self-fixture companion present in PR: $fixture_rel"
    elif grep -q 'Self-fixture-skip:' "$full_path" 2>/dev/null; then
        reason=$(grep 'Self-fixture-skip:' "$full_path" | head -1 | sed 's/.*Self-fixture-skip: *//')
        ok "(a) self-fixture skip-comment: $reason"
    else
        fail "(a) self-fixture companion MISSING: $fixture_rel — add it or add 'Self-fixture-skip: <reason>' to the script header"
        FAIL=$((FAIL+1))
    fi

    # (b) Skip-context filter (code-fence / backtick exempt)
    if grep -qE 'code.fence|in_fence|strip_code|backtick|fenced' "$full_path" 2>/dev/null; then
        ok "(b) skip-context filter present"
    else
        echo "  WARN: (b) no skip-context filter detected — verify banned patterns exempt code fences/backticks"
    fi

    # (c) Bypass trailer documented
    if grep -qiE '\-Bypass:|\-Lint-Bypass:|bypass.*trailer' "$full_path" 2>/dev/null; then
        ok "(c) bypass trailer documented"
    else
        echo "  WARN: (c) no bypass trailer found — add a commit-body bypass mechanism (see test-voice-banlist.sh)"
    fi

    # (d) Tier classification in header comment
    if grep -qiE 'Tier-[ABCD]|tier [ABCD]' "$full_path" 2>/dev/null; then
        ok "(d) Tier classification present"
    else
        echo "  WARN: (d) no Tier classification in header — add Tier-A/B/C/D to script comment"
    fi

    echo ""
done <<< "$new_scripts"

echo "Results: $PASS passed, $FAIL hard failures"
if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "FAIL: $FAIL new lint script(s) missing mandatory self-fixture"
    echo "  See docs/process/CI_GATES_INVENTORY.md §CI Gate Author Checklist"
    exit 1
fi
echo "PASS: lint gate checklist satisfied for all new scripts"
exit 0
