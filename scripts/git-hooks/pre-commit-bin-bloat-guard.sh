#!/usr/bin/env bash
# pre-commit-bin-bloat-guard.sh — EFFECTIVE-414
#
# The crate-first half of WHEN_TO_CRATE.md (docs/process/WHEN_TO_CRATE.md):
# new subsystems should be born as their own crates under crates/, not new
# files piled into the ~190k-line `src/` bin. This gate flags (does not
# block — advisory-first per the doctrine, promote to blocking once the
# ~400-line threshold is calibrated) any commit that ADDS a new src/*.rs
# file over the threshold.
#
# Bypass: not applicable — this gate never blocks (advisory-only). It is
# silenced entirely via CHUMP_BIN_BLOAT_GUARD_CHECK=0.
#
# Source: EFFECTIVE-412 (doctrine), EFFECTIVE-414 (this gate).

set -uo pipefail

if [[ "${CHUMP_BIN_BLOAT_GUARD_CHECK:-1}" == "0" ]]; then
    exit 0
fi

THRESHOLD="${CHUMP_BIN_BLOAT_GUARD_THRESHOLD:-400}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT" || exit 0

NEW_RS_FILES="$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
    | grep -E '^src/[^/]+\.rs$' || true)"

[[ -z "$NEW_RS_FILES" ]] && exit 0

FLAGGED_FILES=()
FLAGGED_LINES=()

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue
    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    if [[ "${lines:-0}" -gt "$THRESHOLD" ]]; then
        FLAGGED_FILES+=("$f")
        FLAGGED_LINES+=("$lines")
    fi
done <<< "$NEW_RS_FILES"

if (( ${#FLAGGED_FILES[@]} == 0 )); then
    exit 0
fi

for i in "${!FLAGGED_FILES[@]}"; do
    echo "bin-bloat-guard: New ${FLAGGED_LINES[$i]}-line module in the bin (${FLAGGED_FILES[$i]}, threshold=$THRESHOLD). Should this be crates/chump-<name>? See docs/process/WHEN_TO_CRATE.md." >&2
done

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    files_csv="$(IFS=,; echo "${FLAGGED_FILES[*]}")"
    lines_csv="$(IFS=,; echo "${FLAGGED_LINES[*]}")"
    printf '{"ts":"%s","kind":"bin_bloat_guard_flagged","files":"%s","lines":"%s","threshold":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$files_csv" "$lines_csv" "$THRESHOLD" \
        >> "$AMBIENT" 2>/dev/null || true
fi

# Advisory-only: never blocks the commit.
exit 0
