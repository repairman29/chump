#!/usr/bin/env bash
# scripts/ci/test-doc-only-clippy-skip.sh — INFRA-1042
#
# Static-grep verification: bot-merge.sh detects doc-only diffs and skips
# cargo clippy entirely (in addition to the INFRA-920 skip-cargo-test path).
#
# We don't run bot-merge end-to-end (too many cargo deps); instead we assert
# the source has the right gate shape: DOC_ONLY flag set in the auto-detect
# block AND a top-level DOC_ONLY check before the FAST/full-clippy branches.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

grep -q 'INFRA-1042' "$BM" || fail "INFRA-1042 banner missing"
ok "INFRA-1042 reference in bot-merge.sh"

grep -q 'DOC_ONLY=0' "$BM" || fail "DOC_ONLY=0 initializer missing"
grep -q 'DOC_ONLY=1' "$BM" || fail "DOC_ONLY=1 set-on-doc-only-detect missing"
ok "DOC_ONLY flag declared + set in auto-detect block"

# The clippy section must check DOC_ONLY before FAST. Extract lines 1180-1210ish.
clippy_block="$(awk '/^# ── 3\. cargo clippy/,/^# ── 4\./' "$BM")"
grep -q 'DOC_ONLY:-0' <<<"$clippy_block" \
    || fail "clippy block does not gate on DOC_ONLY"
grep -q 'skipping cargo clippy entirely' <<<"$clippy_block" \
    || fail "clippy block missing user-visible 'skipping ... entirely' message"
ok "cargo clippy gated on DOC_ONLY before FAST + full-clippy branches"

# Sanity: the if-then-elif chain orders DOC_ONLY before FAST so doc-only
# wins over --fast (which itself still runs clippy --fix). Confirm by line order.
doc_only_line=$(grep -n '"\${DOC_ONLY:-0}"' "$BM" | head -1 | cut -d: -f1)
fast_line=$(grep -nE 'if \[\[ \$FAST -eq 1 \]\]; then|elif \[\[ \$FAST -eq 1 \]\]; then' "$BM" | head -1 | cut -d: -f1)
[[ -n "$doc_only_line" && -n "$fast_line" && "$doc_only_line" -lt "$fast_line" ]] \
    || fail "DOC_ONLY check (line $doc_only_line) must come BEFORE FAST check (line $fast_line)"
ok "DOC_ONLY check precedes FAST check in the if/elif chain"

# Auto-detect logic preserved: SKIP_TESTS=1 still set on doc-only (regression
# guard for INFRA-920).
grep -q 'SKIP_TESTS=1' "$BM" || fail "SKIP_TESTS=1 setter missing (INFRA-920 regression)"
ok "INFRA-920 SKIP_TESTS=1 setter still in place"

echo
echo "All INFRA-1042 doc-only-clippy-skip tests passed."
