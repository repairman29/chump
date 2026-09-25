#!/usr/bin/env bash
# check-bypass-line-presence.sh — INFRA-5429: false-positive heuristic-check
# audit. Every CI gate script that can FAIL (`exit 1`) must print a line
# matching `How to bypass cleanly: <instructions>` so a human hitting a
# false-positive has a documented, honest escape hatch instead of reaching
# for --no-verify or hand-editing the gate.
#
# Usage:
#   bash scripts/ci/check-bypass-line-presence.sh              # audit scripts/ci/check-*.sh
#   bash scripts/ci/check-bypass-line-presence.sh <file> ...    # audit specific files
#
# Exceptions: scripts/ci/bypass-line-exceptions.txt (basename + reason).
#
# Exit codes:
#   0 — every non-excepted, exit-1-capable script has a bypass line
#   1 — one or more scripts are missing it

set -uo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXCEPTIONS_FILE="$SCRIPT_DIR/bypass-line-exceptions.txt"

BYPASS_RE='How to bypass cleanly:'

is_excepted() {
    local base="$1"
    [[ -f "$EXCEPTIONS_FILE" ]] || return 1
    grep -qE "^${base}[[:space:]]" "$EXCEPTIONS_FILE"
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
    while IFS= read -r -d '' f; do
        targets+=("$f")
    done < <(find "$REPO_ROOT/scripts/ci" -maxdepth 1 -name 'check-*.sh' -print0 | sort -z)
fi

violations=0
checked=0
for f in "${targets[@]}"; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"

    if is_excepted "$base"; then
        pass "$base: allowlisted (see bypass-line-exceptions.txt)"
        continue
    fi

    if ! grep -qE 'exit 1\b' "$f"; then
        pass "$base: no 'exit 1' FAIL path — nothing to check"
        continue
    fi

    checked=$((checked + 1))
    if grep -qE "$BYPASS_RE" "$f"; then
        pass "$base: has a 'How to bypass cleanly:' line"
    else
        fail "$base exits 1 but has no 'How to bypass cleanly: <instructions>' line in its output"
        fail "  How to bypass cleanly: add a line printed on the FAIL path matching 'How to bypass cleanly: <instructions>' to $f, OR — if this script structurally has no clean bypass (e.g. a local dev preflight where the only fix is the real fix) — add '$base   # reason: <why>' to $EXCEPTIONS_FILE."
        violations=$((violations + 1))
    fi
done

echo ""
if [[ "$violations" -eq 0 ]]; then
    echo "check-bypass-line-presence: $checked gate script(s) checked, all document a bypass."
    exit 0
else
    echo "check-bypass-line-presence: $violations of $checked gate script(s) missing a 'How to bypass cleanly:' line." >&2
    exit 1
fi
