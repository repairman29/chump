#!/usr/bin/env bash
# verify-existence.sh — INFRA-1589
#
# Run the four standard checks before filing a "feature X is missing" gap.
# Closes the misdiagnosis class precedented by INFRA-1575 (claimed 10 A2A
# gaps missing when all had shipped) and INFRA-238 (claimed origin/main
# reverted without verifying against the remote).
#
# Returns tri-state via exit code:
#   0 = confirmed_shipped (multiple positive signals across checks)
#   1 = confirmed_absent  (no signal in any check)
#   2 = ambiguous         (exactly one positive signal — investigate manually)
#
# Usage:
#   scripts/dev/verify-existence.sh <ID-or-symbol>
#   scripts/dev/verify-existence.sh --json <ID-or-symbol>
#
# Examples:
#   scripts/dev/verify-existence.sh INFRA-1296          # shipped gap (reaped from active registry)
#   scripts/dev/verify-existence.sh build_provider      # Rust symbol
#   scripts/dev/verify-existence.sh /api/broadcast      # endpoint
#   scripts/dev/verify-existence.sh broadcast.sh        # script
#
# Tools used (graceful skip on missing):
#   - git log --all (always available in a chump worktree)
#   - gh search code (optional — requires gh auth login)
#   - chump gap show + chump gap list --status done (canonical for gap IDs)
#   - ast-grep (optional — INFRA-1589 proposes bootstrap-manifest install)
#   - grep (always)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
JSON_OUT=0
QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUT=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -z "$QUERY" ]]; then QUERY="$1"; fi
            shift
            ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    echo "Usage: $0 [--json] <ID-or-symbol>" >&2
    exit 2
fi

cd "$REPO_ROOT"

# Check 1: Git history for the literal string in commit subjects.
# Catches shipped + reaped gaps (their feat(<ID>): commit survives).
GIT_HIT=0
if git log --all --oneline 2>/dev/null | grep -q -- "$QUERY"; then
    GIT_HIT=1
fi

# Check 2: GitHub code search across the repo's PRs + commits.
# Skip silently when gh is unauthenticated or offline.
GH_HIT=0
GH_AVAILABLE=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GH_AVAILABLE=1
    if gh search code "$QUERY" --limit 1 2>/dev/null | grep -q .; then
        GH_HIT=1
    fi
fi

# Check 3: chump gap registry — both open and done lists.
# Only meaningful for ID-shaped queries (DOMAIN-NUMBER).
GAP_HIT=0
GAP_APPLICABLE=0
if echo "$QUERY" | grep -qE '^[A-Z]+-[0-9]+$'; then
    GAP_APPLICABLE=1
    if chump gap show "$QUERY" >/dev/null 2>&1; then
        GAP_HIT=1
    elif command -v jq >/dev/null 2>&1; then
        if chump gap list --status done --json 2>/dev/null | jq -e --arg q "$QUERY" '.[] | select(.id==$q)' >/dev/null 2>&1; then
            GAP_HIT=1
        fi
    fi
fi

# Check 4: file/directory on disk + ast-grep structural search for symbols.
SYM_HIT=0
if [[ -e "$QUERY" ]]; then
    SYM_HIT=1
elif command -v ast-grep >/dev/null 2>&1; then
    for pattern in "fn $QUERY" "struct $QUERY" "trait $QUERY" "enum $QUERY"; do
        if ast-grep --pattern "$pattern" src 2>/dev/null | grep -q .; then
            SYM_HIT=1
            break
        fi
    done
fi

# Check 5: raw grep fallback across src/ + scripts/ (always available).
GREP_HIT=0
if grep -rln -- "$QUERY" src scripts 2>/dev/null | head -1 | grep -q .; then
    GREP_HIT=1
fi

# Tally. ast-grep + raw grep can both fire for the same symbol; we count
# distinct retrieval mechanisms, not raw hits, to keep the tri-state honest.
TOTAL_HITS=$((GIT_HIT + GH_HIT + GAP_HIT + SYM_HIT + GREP_HIT))

if [[ $TOTAL_HITS -ge 2 ]]; then
    VERDICT="confirmed_shipped"
    EXIT_CODE=0
elif [[ $TOTAL_HITS -eq 0 ]]; then
    VERDICT="confirmed_absent"
    EXIT_CODE=1
else
    VERDICT="ambiguous"
    EXIT_CODE=2
fi

if [[ $JSON_OUT -eq 1 ]]; then
    cat <<JSON
{"query":"$QUERY","git_log":$GIT_HIT,"gh_search":$GH_HIT,"gh_available":$GH_AVAILABLE,"gap_registry":$GAP_HIT,"gap_applicable":$GAP_APPLICABLE,"file_or_symbol":$SYM_HIT,"raw_grep":$GREP_HIT,"total":$TOTAL_HITS,"verdict":"$VERDICT"}
JSON
    exit $EXIT_CODE
fi

echo "verify-existence: $QUERY"
echo "  git log --all --oneline ............. $([[ $GIT_HIT -eq 1 ]] && echo hit || echo miss)"
if [[ $GH_AVAILABLE -eq 1 ]]; then
    echo "  gh search code ...................... $([[ $GH_HIT -eq 1 ]] && echo hit || echo miss)"
else
    echo "  gh search code ...................... skipped (gh unavailable or unauthenticated)"
fi
if [[ $GAP_APPLICABLE -eq 1 ]]; then
    echo "  chump gap registry (open + done) .... $([[ $GAP_HIT -eq 1 ]] && echo hit || echo miss)"
else
    echo "  chump gap registry .................. n/a (query not in ID shape DOMAIN-NUMBER)"
fi
echo "  file / ast-grep symbol .............. $([[ $SYM_HIT -eq 1 ]] && echo hit || echo miss)"
echo "  raw grep src/ scripts/ .............. $([[ $GREP_HIT -eq 1 ]] && echo hit || echo miss)"
echo
echo "VERDICT: $VERDICT"
case "$VERDICT" in
    confirmed_shipped)
        echo "  (multiple positive signals — do NOT file a 'missing' gap; the feature exists)"
        ;;
    confirmed_absent)
        echo "  (no signal in any check — filing a 'missing' gap is supported by evidence)"
        ;;
    ambiguous)
        echo "  (exactly one positive signal — investigate manually before filing)"
        echo "  See AGENTS.md 'Filing meta-patterns' behaviour 4 for the discipline rule."
        ;;
esac

exit $EXIT_CODE
