#!/usr/bin/env bash
# test-orphan-closer-immunity.sh — INFRA-1406
#
# Verifies the orphan-pr-closer's per-PR immunity mechanisms:
#   1. Existing title-marker 'orphan-pr-closer-skip' is still honored
#      (regression guard)
#   2. NEW commit-body trailer 'Orphan-Closer-Immunity: <reason>' is
#      honored — skips close + emits kind=orphan_pr_close_immunity_honored
#   3. Recovery script scripts/coord/pr-rescue-false-close.sh exists +
#      validates inputs

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOSER="$REPO_ROOT/scripts/coord/orphan-pr-closer.sh"
RESCUE="$REPO_ROOT/scripts/coord/pr-rescue-false-close.sh"

echo "=== INFRA-1406 orphan-pr-closer immunity tests ==="

[[ -f "$CLOSER" ]] || { echo "FAIL: $CLOSER missing"; exit 2; }
[[ -f "$RESCUE" ]] || { echo "FAIL: $RESCUE missing"; exit 2; }

# ── AC #1: title-marker still honored (regression guard) ────────────────────
if grep -q "orphan-pr-closer-skip" "$CLOSER"; then
    ok "AC #1: title marker 'orphan-pr-closer-skip' still recognized"
else
    fail "AC #1: title-marker check missing — regression!"
fi

# ── AC #2: commit-body trailer recognized ──────────────────────────────────
if grep -q "Orphan-Closer-Immunity:" "$CLOSER"; then
    ok "AC #2: commit-body trailer 'Orphan-Closer-Immunity:' recognized"
else
    fail "AC #2: commit-body trailer not recognized"
fi

# ── AC #2: immunity-honored event emitted ──────────────────────────────────
if grep -q "orphan_pr_close_immunity_honored" "$CLOSER"; then
    ok "AC #2: kind=orphan_pr_close_immunity_honored emitted on skip"
else
    fail "AC #2: immunity-honored audit event missing"
fi

# ── AC #2: closer queries gh for commit messages ───────────────────────────
if grep -q 'gh api "repos/{owner}/{repo}/pulls/\$pr/commits"' "$CLOSER"; then
    ok "AC #2: closer queries PR commits via gh API"
else
    fail "AC #2: closer not fetching commit messages from gh"
fi

# ── AC #3: recovery script exists + executable ──────────────────────────────
if [[ -x "$RESCUE" ]]; then
    ok "AC #3: pr-rescue-false-close.sh present + executable"
else
    fail "AC #3: pr-rescue-false-close.sh missing or not executable"
fi

# ── AC #3: rescue script validates input ───────────────────────────────────
# Workaround for `set -o pipefail`: capture the rescue output to a var,
# then grep the var (so the failing rc of bash doesn't propagate through
# the pipe).
out1="$(bash "$RESCUE" 2>&1 || true)"
if echo "$out1" | grep -qE "usage:|Usage:"; then
    ok "AC #3: rescue script shows usage on missing PR arg"
else
    fail "AC #3: rescue script does not validate input"
fi
out2="$(bash "$RESCUE" notanumber 2>&1 || true)"
if echo "$out2" | grep -qE "usage:|Usage:"; then
    ok "AC #3: rescue script rejects non-numeric PR arg"
else
    fail "AC #3: rescue script accepts non-numeric PR arg"
fi

# ── AC #3: rescue script integrates with INFRA-1439 arm-auto-merge ─────────
if grep -q "arm-auto-merge.sh" "$RESCUE"; then
    ok "AC #3: rescue script uses INFRA-1439 arm-auto-merge wrapper"
else
    fail "AC #3: rescue script doesn't integrate with arm-auto-merge wrapper"
fi

# ── AC #3: rescue script emits kind=orphan_pr_rescued ──────────────────────
if grep -q "orphan_pr_rescued" "$RESCUE"; then
    ok "AC #3: rescue script emits kind=orphan_pr_rescued"
else
    fail "AC #3: rescue script doesn't emit recovery event"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
