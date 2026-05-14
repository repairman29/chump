#!/usr/bin/env bash
# scripts/ci/test-doc-only-clippy-skip.sh — INFRA-1042 + INFRA-1061
#
# Verifies bot-merge.sh's doc-only fastpath:
#   1. DOC_ONLY init + setter both present (INFRA-1042)
#   2. Detection runs UNCONDITIONALLY, not gated on `if SKIP_TESTS==0`
#      (INFRA-1061 regression fix — original INFRA-1042 wrap silently disabled
#      doc-only under --fast since --fast pre-sets SKIP_TESTS=1)
#   3. Clippy block checks DOC_ONLY before FAST and full-clippy
#   4. DOC_ONLY check appears BEFORE FAST check in the if/elif chain
#   5. INFRA-920 SKIP_TESTS=1 setter still in place
#   6. wc -l replaces fragile `grep -c .` for file count (grep -c returns 1
#      on 0 matches, which propagates under set -o pipefail)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

grep -q 'INFRA-1042' "$BM" || fail "INFRA-1042 banner missing"
grep -q 'INFRA-1061' "$BM" || fail "INFRA-1061 banner missing"
ok "INFRA-1042 + INFRA-1061 references in bot-merge.sh"

grep -q 'DOC_ONLY=0' "$BM" || fail "DOC_ONLY=0 initializer missing"
grep -q 'DOC_ONLY=1' "$BM" || fail "DOC_ONLY=1 set-on-doc-only-detect missing"
ok "DOC_ONLY flag declared + set in auto-detect block"

# INFRA-1061 critical regression check: detection must NOT be wrapped in
# `if [[ $SKIP_TESTS -eq 0 ]]; then` — that's the bug merged in INFRA-1042's
# original PR which defeated the entire fastpath under --fast.
# The fixed code has `_changed_files=` at column 0 (not indented inside any if).
grep -E '^_changed_files=' "$BM" >/dev/null \
    || fail "_changed_files= not at column-0 — detection appears to still be wrapped (INFRA-1061 regression)"
ok "doc-only detection runs UNCONDITIONALLY (works under --fast / --skip-tests) — INFRA-1061 regression check"

# Clippy block
clippy_block="$(awk '/^# ── 3\. cargo clippy/,/^# ── 4\./' "$BM")"
grep -q 'DOC_ONLY:-0' <<<"$clippy_block" \
    || fail "clippy block does not gate on DOC_ONLY"
grep -q 'skipping cargo clippy entirely' <<<"$clippy_block" \
    || fail "clippy block missing user-visible 'skipping ... entirely' message"
ok "cargo clippy gated on DOC_ONLY before FAST + full-clippy branches"

# Ordering check
doc_only_line=$(grep -n '"\${DOC_ONLY:-0}"' "$BM" | head -1 | cut -d: -f1)
fast_line=$(grep -nE 'if \[\[ \$FAST -eq 1 \]\]; then|elif \[\[ \$FAST -eq 1 \]\]; then' "$BM" | head -1 | cut -d: -f1)
[[ -n "$doc_only_line" && -n "$fast_line" && "$doc_only_line" -lt "$fast_line" ]] \
    || fail "DOC_ONLY check (line $doc_only_line) must come BEFORE FAST check (line $fast_line)"
ok "DOC_ONLY check precedes FAST check in the if/elif chain"

# INFRA-920 regression
grep -q 'SKIP_TESTS=1' "$BM" || fail "SKIP_TESTS=1 setter missing (INFRA-920 regression)"
ok "INFRA-920 SKIP_TESTS=1 setter still in place"

# INFRA-1061: file-count uses wc -l (grep -c . returns 1 on 0 matches and
# breaks under set -o pipefail).
grep -q 'wc -l' "$BM" \
    || fail "wc -l not found — file-count should use wc -l per INFRA-1061"
! grep -qE 'echo[^|]*\| grep -c \.' "$BM" \
    || fail "still uses 'echo … | grep -c .' (fragile under pipefail)"
ok "file-count uses wc -l (not grep -c .); no SIGPIPE hazard under pipefail"

echo
echo "All INFRA-1042 + INFRA-1061 doc-only-clippy-skip tests passed."
