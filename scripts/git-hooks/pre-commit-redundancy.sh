#!/usr/bin/env bash
# pre-commit-redundancy.sh — META-063 (slice 1: pre-commit gate)
#
# Refuses NEW shell files in critical dirs (scripts/coord/, scripts/ops/,
# scripts/dispatch/) when their function-name shape overlaps >= 0.6 with
# an existing file in the SAME dir — strong signal that the new file is a
# duplicate of work that already exists.
#
# Why: today's audit (2026-05-14) found 7 worktree reapers, 4 gh wrappers,
# 8 lease parsers — each added independently. Each shipped 200-700 LOC of
# duplicate work that we then had to consolidate retroactively. This gate
# is the prevention forcing-function.
#
# Heuristic: Jaccard similarity over bash function names (`^[a-z_]+\(\)`
# regex extracted from the new file vs. each existing *.sh in the same
# dir). max(jaccard) is the score. > 0.6 → block. <= 0.6 → allow.
#
# Bypass: commit body trailer 'Redundancy-OK: <one-sentence reason>'.
# Logged to ambient as kind=redundancy_bypass_used for audit.
#
# Future layers (filed as follow-up gaps):
#   - 'chump audit-redundancy' Rust subcommand (better similarity engine,
#     handles n-grams, shared-command profile, hardcoded-path collisions)
#   - weekly launchd auto-run that surfaces clusters as gaps
#
# Env hatch: CHUMP_REDUNDANCY_CHECK=0

set -uo pipefail

[[ "${CHUMP_REDUNDANCY_CHECK:-1}" == "0" ]] && exit 0

THRESHOLD="${CHUMP_REDUNDANCY_THRESHOLD:-0.6}"

# New .sh files only, in critical dirs.
NEW_SH="$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
    | grep -E '^scripts/(coord|dispatch|ops)/[^/]+\.sh$' || true)"

[[ -z "$NEW_SH" ]] && exit 0

# Compute Jaccard similarity over bash function-name sets.
# Returns "<score> <best-match-path>" or empty if no candidates.
best_match_jaccard() {
    local new_file="$1"
    local dir; dir="$(dirname "$new_file")"
    local new_fns; new_fns="$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$new_file" 2>/dev/null | sort -u)"
    [[ -z "$new_fns" ]] && return 0  # No functions, no signal
    local new_count; new_count="$(printf '%s\n' "$new_fns" | wc -l | tr -d ' ')"
    [[ "$new_count" -lt 3 ]] && return 0  # < 3 functions = too small to score reliably

    local best_score="0.0"
    local best_path=""
    for cand in "$dir"/*.sh; do
        [[ -f "$cand" ]] || continue
        [[ "$cand" == "$new_file" ]] && continue
        local cand_fns; cand_fns="$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$cand" 2>/dev/null | sort -u)"
        [[ -z "$cand_fns" ]] && continue
        # Intersection / union via comm
        local intersect; intersect="$(comm -12 <(printf '%s\n' "$new_fns") <(printf '%s\n' "$cand_fns") | wc -l | tr -d ' ')"
        local union; union="$(printf '%s\n%s\n' "$new_fns" "$cand_fns" | sort -u | wc -l | tr -d ' ')"
        [[ "$union" -eq 0 ]] && continue
        local score; score="$(awk "BEGIN { printf \"%.3f\", $intersect / $union }")"
        if awk "BEGIN { exit !($score > $best_score) }"; then
            best_score="$score"
            best_path="$cand"
        fi
    done
    [[ -n "$best_path" ]] && printf '%s %s\n' "$best_score" "$best_path"
}

VIOLATIONS=()
DETAILS=()

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue
    match="$(best_match_jaccard "$f")"
    [[ -z "$match" ]] && continue
    score="${match%% *}"
    path="${match#* }"
    if awk "BEGIN { exit !($score >= $THRESHOLD) }"; then
        VIOLATIONS+=("$f")
        DETAILS+=("$score similarity to $path")
    fi
done <<< "$NEW_SH"

(( ${#VIOLATIONS[@]} == 0 )) && exit 0

# Bypass trailer check.
MSG_FILE="$(git rev-parse --git-dir)/COMMIT_EDITMSG"
if [[ -f "$MSG_FILE" ]] && grep -qE '^Redundancy-OK:' "$MSG_FILE" 2>/dev/null; then
    # Log bypass.
    AMBIENT="${CHUMP_AMBIENT_LOG:-$(git rev-parse --show-toplevel)/.chump-locks/ambient.jsonl}"
    reason="$(grep -E '^Redundancy-OK:' "$MSG_FILE" | head -1 | sed 's/^Redundancy-OK:[[:space:]]*//')"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"redundancy_bypass_used","files":"%s","reason":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(IFS=,; echo "${VIOLATIONS[*]}")" \
            "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"unparseable"')" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

# Block.
red='\033[0;31m'
nc='\033[0m'
echo "" >&2
echo -e "${red}❌ META-063 redundancy gate blocked this commit.${nc}" >&2
echo "" >&2
echo "New shell file(s) overlap significantly with existing files in the same dir:" >&2
for i in "${!VIOLATIONS[@]}"; do
    echo "" >&2
    echo "  ${VIOLATIONS[$i]}" >&2
    echo "    ${DETAILS[$i]}" >&2
    echo "    (Jaccard threshold: $THRESHOLD; >= triggers this gate)" >&2
done
echo "" >&2
echo "Why: today's redundancy audit (2026-05-14) found 7 worktree reapers," >&2
echo "4 gh wrappers, 8 lease parsers — each added independently as a 'new'" >&2
echo "script, each shipped 200-700 LOC of duplicate work that had to be" >&2
echo "retroactively consolidated. The signal: function-name shape matches" >&2
echo "an existing file in the same dir means the work likely belongs there." >&2
echo "" >&2
echo "Fix one of:" >&2
echo "  1. Extend the existing file (preferred — refactor + add a flag)" >&2
echo "  2. Bypass with a reason — add this trailer to the commit body:" >&2
echo "       Redundancy-OK: <one-sentence reason>" >&2
echo "" >&2
echo "Full rule: META-063. Sibling: META-064 (Rust-first), META-065 (curator)." >&2
echo "Disable (rare): CHUMP_REDUNDANCY_CHECK=0 git commit ..." >&2
echo "Threshold tuning: CHUMP_REDUNDANCY_THRESHOLD=<float> (default 0.6)" >&2
exit 1
