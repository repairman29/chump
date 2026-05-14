#!/usr/bin/env bash
# scripts/ci/auth-tier-audit.sh — INFRA-1078
#
# Enumerates every gh / chump_gh / curl callsite in scripts/coord/,
# scripts/dispatch/, scripts/ops/ and categorizes by auth tier:
#
#   APP_TOKEN     — caller uses actions/create-github-app-token output
#                   (12.5K/hr quota, no secondary rate-limit per-user)
#   PAT           — caller uses gh CLI default keyring auth (5K/hr quota)
#   GITHUB_TOKEN  — caller uses workflow GITHUB_TOKEN (1K secondary)
#   UNKNOWN       — couldn't categorize from static signals
#
# Categorization rules (in order, first match wins):
#   1. Caller file is .github/workflows/*.yml AND uses ${{ steps.app-token.outputs.token }}
#      → APP_TOKEN
#   2. Caller file is .github/workflows/*.yml AND uses ${{ secrets.GITHUB_TOKEN }}
#      → GITHUB_TOKEN
#   3. Caller file is .github/workflows/*.yml with no explicit token
#      → GITHUB_TOKEN (workflow default)
#   4. Caller is a shell script under scripts/ AND env $GH_TOKEN is set in
#      the file or parent workflow → APP_TOKEN
#   5. Caller is a shell script with no GH_TOKEN evidence → PAT (operator
#      keyring; the default when run interactively)
#   6. Otherwise → UNKNOWN
#
# Output:
#   default — human-readable table grouped by tier
#   --json  — machine-readable: [{file, line, tier, evidence}, ...]
#   --fail-on-unknown — exit non-zero if any UNKNOWN callsites found (CI mode)

set -euo pipefail

# Compute REPO_ROOT from script location (not `git rev-parse` which can
# return a sibling worktree path under INFRA-779 gitdir corruption).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AS_JSON=0
FAIL_ON_UNKNOWN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)              AS_JSON=1; shift ;;
        --fail-on-unknown)   FAIL_ON_UNKNOWN=1; shift ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

cd "$REPO_ROOT"

# Find every callsite of gh, chump_gh, or curl with api.github.com.
# Limit to coord/, dispatch/, ops/, .github/workflows/ — the operational
# surface where quota matters.
CALLSITES=$(grep -rnE \
    -e 'gh (api|pr|run|repo|workflow|auth)' \
    -e 'chump_gh ' \
    -e 'curl[^|]*api\.github\.com' \
    scripts/coord/ scripts/dispatch/ scripts/ops/ .github/workflows/ \
    2>/dev/null | grep -v '\.md:' | grep -v '\.bak:' || true)

# Helper: classify a callsite line.
classify() {
    local file="$1" line="$2" content="$3"
    # Rule 1: workflow + App token
    if [[ "$file" == .github/workflows/*.yml ]]; then
        if grep -q 'app-token.outputs.token' "$file" 2>/dev/null; then
            # Check if THIS workflow uses the App token (rough heuristic)
            echo "APP_TOKEN|workflow uses actions/create-github-app-token"
            return
        fi
        # Some workflows explicitly set GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        if grep -qE 'GH_TOKEN:\s*\$\{\{\s*secrets\.GITHUB_TOKEN' "$file" 2>/dev/null; then
            echo "GITHUB_TOKEN|workflow sets GH_TOKEN=GITHUB_TOKEN"
            return
        fi
        echo "GITHUB_TOKEN|workflow default (no explicit token)"
        return
    fi
    # Rule 4: shell script with GH_TOKEN env evidence
    if grep -qE 'GH_TOKEN=|export GH_TOKEN|GH_TOKEN must be set|GH_TOKEN:?-' "$file" 2>/dev/null; then
        echo "APP_TOKEN|file references GH_TOKEN env (App-set)"
        return
    fi
    # Rule 5: default for shell scripts
    if [[ "$file" == scripts/*.sh || "$file" == scripts/*/*.sh || "$file" == scripts/*/*.py || "$file" == scripts/*/*/*.sh ]]; then
        echo "PAT|shell script using operator gh keyring (default)"
        return
    fi
    echo "UNKNOWN|no classification rule matched"
}

# Aggregate by tier.
declare -a app_lines=()
declare -a pat_lines=()
declare -a gt_lines=()
declare -a unk_lines=()

while IFS=: read -r file lineno content; do
    [[ -z "$file" ]] && continue
    [[ "$file" == *"AUTH_AUDIT.md" ]] && continue  # skip our own output
    cls="$(classify "$file" "$lineno" "$content")"
    tier="${cls%%|*}"
    ev="${cls#*|}"
    snippet=$(echo "$content" | sed 's/^[[:space:]]*//' | head -c 80)
    entry="${file}:${lineno}|${tier}|${ev}|${snippet}"
    case "$tier" in
        APP_TOKEN)    app_lines+=("$entry") ;;
        PAT)          pat_lines+=("$entry") ;;
        GITHUB_TOKEN) gt_lines+=("$entry") ;;
        *)            unk_lines+=("$entry") ;;
    esac
done <<<"$CALLSITES"

if [[ $AS_JSON -eq 1 ]]; then
    python3 - "${app_lines[@]:+APP|${app_lines[@]}}" "${pat_lines[@]:+PAT|${pat_lines[@]}}" "${gt_lines[@]:+GT|${gt_lines[@]}}" "${unk_lines[@]:+UNK|${unk_lines[@]}}" <<'PY'
import json, sys
rows = []
for arg in sys.argv[1:]:
    if not arg or "|" not in arg:
        continue
    parts = arg.split("|", 4)
    if len(parts) < 5:
        continue
    _label, file_line, tier, ev, snippet = parts
    rows.append({"file_line": file_line, "tier": tier, "evidence": ev, "snippet": snippet})
print(json.dumps({"total": len(rows), "rows": rows}, indent=2))
PY
    exit 0
fi

print_tier() {
    local label="$1"; shift
    local -a arr=("$@")
    [[ "${#arr[@]}" -eq 0 ]] && { echo "  (none)"; return; }
    for entry in "${arr[@]}"; do
        IFS='|' read -r fl tier ev snippet <<<"$entry"
        printf "  %s\n    └─ %s\n    └─ %s\n" "$fl" "$ev" "$snippet"
    done
}

# Relax set -u while we read array sizes — empty arrays trip some bash versions.
set +u
A_COUNT="${#app_lines[@]}"
P_COUNT="${#pat_lines[@]}"
G_COUNT="${#gt_lines[@]}"
U_COUNT="${#unk_lines[@]}"
set -u

echo "=== auth-tier audit — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo
echo "APP_TOKEN (12.5K/hr) — $A_COUNT callsites"
set +u; print_tier APP "${app_lines[@]}"; set -u
echo
echo "PAT (5K/hr operator keyring) — $P_COUNT callsites"
set +u; print_tier PAT "${pat_lines[@]}"; set -u
echo
echo "GITHUB_TOKEN (1K secondary) — $G_COUNT callsites"
set +u; print_tier GT "${gt_lines[@]}"; set -u
echo
echo "UNKNOWN — $U_COUNT callsites"
set +u; print_tier UNK "${unk_lines[@]}"; set -u
echo
echo "=== Migration opportunity ==="
echo "  PAT callsites that could move to APP_TOKEN (2.5× quota): $P_COUNT"
echo "  File a follow-up gap per identified caller after manual review."

if [[ $FAIL_ON_UNKNOWN -eq 1 && "$U_COUNT" -gt 0 ]]; then
    echo
    echo "FAIL: $U_COUNT UNKNOWN callsites found (--fail-on-unknown set)"
    exit 1
fi
