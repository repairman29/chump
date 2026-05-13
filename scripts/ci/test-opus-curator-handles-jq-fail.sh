#!/usr/bin/env bash
# test-opus-curator-handles-jq-fail.sh — INFRA-963
#
# Reproduces the multi-line jq output that silently killed the opus-curator
# scheduled task for 28h. With the _to_int coercion in place, the curator
# must run cleanly even when its inputs emit JSON-followed-by-non-JSON.
#
# Asserts:
#   1. _to_int correctly collapses "2\n0" → "2" (the actual bug pattern)
#   2. _to_int handles every weird-but-plausible jq output we observed
#   3. opus-curator.sh runs end-to-end with no `syntax error in expression`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"

[[ -f "$CURATOR" ]] || { echo "FAIL: missing $CURATOR"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# 1) Extract and exercise _to_int directly.
_to_int_def="$(sed -n '/^_to_int() {/,/^}$/p' "$CURATOR")"
[[ -n "$_to_int_def" ]] || fail "_to_int function not found in $CURATOR"

eval "$_to_int_def"

multiline_two_zero="$(printf '2\n0')"
multiline_seventeen="$(printf '17\n0\n0')"
cases=(
  "0:0"
  "5:5"
  "${multiline_two_zero}:2"     # the actual bug — "2\n0"
  "${multiline_seventeen}:17"   # longer multi-line
  ":0"                          # empty input → default 0
  "abc:0"                       # non-numeric junk
  "  42  :42"                   # whitespace
  "-3:3"                        # leading minus stripped
)
for c in "${cases[@]}"; do
  in="${c%:*}"
  expected="${c#*:}"
  got="$(_to_int "$in")"
  if [[ "$got" != "$expected" ]]; then
    fail "_to_int($(printf '%q' "$in")) = $(printf '%q' "$got"), expected $(printf '%q' "$expected")"
  fi
done
ok "_to_int handles ${#cases[@]} input shapes including the 2-line bug"

# 2) Run opus-curator.sh end-to-end in dry-run. NO bash syntax errors allowed.
out="$(bash "$CURATOR" --dry-run 2>&1 || true)"
# Bash arithmetic errors look like: "opus-curator.sh: line 81: [[: VALUE: syntax error..."
# Use a tighter regex so we don't false-positive on the literal phrase inside
# echoed JSON content (e.g. the INFRA-963 gap title contains the phrase).
if echo "$out" | grep -qE 'opus-curator\.sh: line [0-9]+: \[\[.*syntax error'; then
  echo "$out" | grep -E 'opus-curator\.sh: line [0-9]+:' | head -5 >&2
  fail "opus-curator.sh emitted bash arithmetic syntax error — INFRA-963 regressed"
fi
# Decision phase must REACH the end (no early exit).
echo "$out" | grep -q "CURATOR AUDIT COMPLETE" \
  || fail "opus-curator.sh did not reach 'CURATOR AUDIT COMPLETE' — script exited early"
ok "opus-curator.sh runs end-to-end with no syntax errors and reaches completion"

echo
echo "=== test-opus-curator-handles-jq-fail.sh PASSED ==="
