#!/usr/bin/env bash
# scripts/ci/test-pwa-visual-diff-workflow.sh — INFRA-1605
#
# Smoke test for .github/workflows/pwa-visual-diff.yml. Validates the
# workflow YAML parses (actionlint), declares the required structure
# (path-filter scope, single job, upsert-not-append comment logic, AC
# coverage markers), and that the forward-compat no-op path (AC #6) is
# wired so the bot doesn't blow up when INFRA-1591 isn't landed yet.
#
# This test never invokes Playwright — it is a structural smoke check.
# Functional verification of the snapshot suite belongs to INFRA-1591.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WF="$REPO_ROOT/.github/workflows/pwa-visual-diff.yml"

echo "=== INFRA-1605 pwa-visual-diff workflow smoke test ==="
echo

# 1. File exists.
if [ -f "$WF" ]; then
    ok "pwa-visual-diff.yml exists"
else
    fail "pwa-visual-diff.yml missing at $WF"
    echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# 2. INFRA-1605 marker.
if grep -q 'INFRA-1605' "$WF"; then
    ok "INFRA-1605 marker present"
else
    fail "INFRA-1605 marker missing"
fi

# 3. Triggers on pull_request with path-filter on PWA paths (AC #1).
if grep -qE '^\s*pull_request:' "$WF"; then
    ok "pull_request trigger present"
else
    fail "pull_request trigger missing"
fi
if grep -qE "^\s*-\s*'web/\*\*'" "$WF"; then
    ok "path-filter includes web/** (AC #1)"
else
    fail "path-filter missing web/**"
fi
if grep -qE "^\s*-\s*'desktop/src-tauri/\*\*'" "$WF"; then
    ok "path-filter includes desktop/src-tauri/** (AC #1)"
else
    fail "path-filter missing desktop/src-tauri/**"
fi

# 4. The job is non-blocking (continue-on-error at job level — design
#    review signal, not a merge gate).
if awk '/^jobs:/,0' "$WF" | grep -qE 'continue-on-error:\s*true'; then
    ok "job is continue-on-error (non-blocking design signal)"
else
    fail "job should be continue-on-error (matches e2e-pwa-advisory pattern)"
fi

# 5. Detect step for INFRA-1591 wiring (AC #6 — forward-compat).
if grep -q 'Detect INFRA-1591 snapshot suite' "$WF"; then
    ok "INFRA-1591 detection step present (AC #6 forward-compat)"
else
    fail "INFRA-1591 detection step missing — AC #6 requires no-op-when-not-wired"
fi
if grep -q 'pwa-visual' "$WF"; then
    ok "snapshot-suite glob references pwa-visual"
else
    fail "snapshot-suite glob missing pwa-visual reference"
fi

# 6. Comment body builder covers all three variants (AC #2-5 + #6).
if grep -q 'waiting on INFRA-1591' "$WF"; then
    ok "no-op-pending-INFRA-1591 comment variant present (AC #6)"
else
    fail "no-op-pending-INFRA-1591 comment variant missing"
fi
if grep -q 'no changes detected' "$WF"; then
    ok "no-diff comment variant present"
else
    fail "no-diff comment variant missing"
fi
if grep -qE 'View \| Viewport \| Pixel delta \| Diff' "$WF"; then
    ok "markdown table header for changed-views present (AC #4)"
else
    fail "markdown table header missing — AC #4 requires view/viewport/delta/diff columns"
fi

# 7. Footer includes re-baseline command + artifact link (AC #5).
if grep -q -- '--update-snapshots' "$WF"; then
    ok "footer includes --update-snapshots re-baseline command (AC #5)"
else
    fail "footer missing re-baseline command (AC #5)"
fi
if grep -qE 'Artifact bundle|artifact bundle|#artifacts' "$WF"; then
    ok "footer includes artifact-bundle link (AC #5)"
else
    fail "footer missing artifact-bundle link (AC #5)"
fi

# 8. Upsert-not-append logic (AC #4 — single comment, never spam).
if grep -q 'BOT_MARKER' "$WF" && grep -q 'chump-visual-diff-bot:INFRA-1605' "$WF"; then
    ok "bot marker declared for find-and-replace"
else
    fail "bot marker missing — needed for upsert semantics"
fi
if grep -qE 'issues/comments/.*PATCH|PATCH.*issues/comments' "$WF"; then
    ok "upsert path uses PATCH on existing comment (AC #4 no-spam)"
else
    fail "upsert PATCH path missing — AC #4 requires updating existing comment"
fi
if grep -q "gh pr comment" "$WF"; then
    ok "fall-through path uses gh pr comment for first-time post"
else
    fail "first-time-post path (gh pr comment) missing"
fi

# 9. Permissions narrowed appropriately.
if grep -qE '^\s*pull-requests:\s*write' "$WF"; then
    ok "permissions: pull-requests: write (required for comment)"
else
    fail "missing pull-requests: write permission"
fi
if grep -qE '^\s*contents:\s*read' "$WF"; then
    ok "permissions: contents: read (minimal)"
else
    fail "missing contents: read permission"
fi

# 10. actionlint clean (the canonical structural gate).
if command -v actionlint > /dev/null 2>&1; then
    if actionlint "$WF" > /dev/null 2>&1; then
        ok "actionlint clean"
    else
        fail "actionlint reported issues:"
        actionlint "$WF" 2>&1 | sed 's/^/    /'
    fi
else
    echo "  SKIP: actionlint not installed (install via 'brew install actionlint')"
fi

# 11. Documentation exists (AC #7).
DOC="$REPO_ROOT/docs/process/PWA_VISUAL_DIFF_BOT.md"
if [ -f "$DOC" ]; then
    ok "docs/process/PWA_VISUAL_DIFF_BOT.md exists (AC #7)"
    if grep -q 'INFRA-1605' "$DOC"; then
        ok "doc references INFRA-1605"
    else
        fail "doc missing INFRA-1605 reference"
    fi
    if grep -qi 'add a new view\|adding views\|adding a view' "$DOC"; then
        ok "doc covers 'how to add a new view to the diff set' (AC #7)"
    else
        fail "doc missing 'how to add a view' section (AC #7)"
    fi
else
    fail "docs/process/PWA_VISUAL_DIFF_BOT.md missing — AC #7 requires it"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
