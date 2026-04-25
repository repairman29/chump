#!/usr/bin/env bash
# test-bot-merge-syntax.sh — regression test for INFRA-BOT-MERGE-HEREDOC.
#
# Verifies that `scripts/bot-merge.sh` passes `bash -n` (syntax check).
# The bug this guards against: literal backticks inside a
# `$(cat <<'EOF' ... EOF)` heredoc body confused bash's pre-parser,
# causing "line NNN: unexpected EOF while looking for matching `" —
# which aborted bot-merge.sh after `gh pr create` but before the
# `gh pr merge --auto --squash` arming step, silently dropping PRs
# into the queue without auto-merge.
#
# Observed on PRs #482, #488, #491 (2026-04-24) before the fix.
#
# Run:
#   ./scripts/test-bot-merge-syntax.sh
#
# Exits non-zero if bot-merge.sh (or any sibling script) fails bash -n.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== bot-merge.sh + sibling scripts syntax regression tests ==="
echo

for f in bot-merge.sh gap-preflight.sh gap-claim.sh gap-reserve.sh chump-commit.sh; do
    path="$SCRIPT_DIR/$f"
    if [[ ! -f "$path" ]]; then
        continue
    fi
    if bash -n "$path" 2>/tmp/.bm-syntax-err; then
        ok "$f passes bash -n"
    else
        fail "$f bash -n failed: $(cat /tmp/.bm-syntax-err)"
    fi
done

# Targeted check: grep bot-merge.sh for the specific antipattern —
# a $(cat <<'...') with an un-escaped backtick-containing line before the
# delimiter. This is a tight lint, but it flags the exact regression.
BM="$SCRIPT_DIR/bot-merge.sh"
if [[ -f "$BM" ]]; then
    if python3 - "$BM" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
# Match $(cat <<'TAG'  ...  TAG) blocks and check body for raw backticks.
pat = re.compile(r"\$\(cat\s*<<'(\w+)'\n(.*?)\n\s*\1\s*\)", re.S)
bad = False
for m in pat.finditer(text):
    body = m.group(2)
    if '`' in body:
        print(f"FAIL: $(cat <<'{m.group(1)}' ...) body contains un-escaped backtick")
        bad = True
sys.exit(1 if bad else 0)
PY
    then
        ok "no \$(cat <<'EOF' ...) heredocs contain raw backticks"
    else
        fail "bot-merge.sh has a \$(cat <<'EOF' ...) body with un-escaped backticks"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
