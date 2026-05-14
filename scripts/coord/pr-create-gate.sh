#!/usr/bin/env bash
# scripts/coord/pr-create-gate.sh — INFRA-1219
#
# Dedup gate run BEFORE `gh pr create`. Refuses to open a new PR if an open
# PR already exists for the same gap-ID in title.
#
# 2026-05-14 audit: 57 of 79 closed-not-merged PRs (last 14d) were
# duplicates that shipped via another PR — 72% waste rate. Highest-leverage
# fix in the dedup chain. Catches the 80% case where two agents race to
# ship the same gap.
#
# Usage:
#   scripts/coord/pr-create-gate.sh <GAP-ID>
#   scripts/coord/pr-create-gate.sh <GAP-ID> --justification "<text>"  # with bypass
#
# Exit codes:
#   0  no duplicate found, OK to proceed
#   19 duplicate open PR exists; PR# printed to stderr
#   20 duplicate found but bypass requested without --justification
#   2  usage error or missing GAP-ID
#
# Bypass: CHUMP_PR_DEDUP_BYPASS=1 + --justification "<reason>"
# Disable entirely (CI/test mode): CHUMP_PR_DEDUP_DISABLE=1
#
# Scope: this gate ONLY blocks on OPEN duplicate PRs (the 80% case).
# Closed-not-merged cooldown is tracked separately in INFRA-1220
# (scripts/coord/cooldown-scanner.sh) which is being built in parallel.
# Composing the two: callers should invoke pr-create-gate.sh first, then
# cooldown-scanner.sh — both must pass before `gh pr create`.

set -uo pipefail

if [[ "${CHUMP_PR_DEDUP_DISABLE:-0}" == "1" ]]; then
    exit 0
fi

GAP_ID="${1:-}"
JUSTIFICATION=""
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --justification) JUSTIFICATION="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$GAP_ID" ]]; then
    echo "pr-create-gate: missing GAP-ID" >&2
    echo "usage: $0 <GAP-ID> [--justification '<text>']" >&2
    exit 2
fi

# Validate gap-ID shape (DOMAIN-NNN) — guards against accidentally passing a
# branch name or other token.
if ! [[ "$GAP_ID" =~ ^[A-Z][A-Z0-9-]*-[0-9]+$ ]]; then
    echo "pr-create-gate: gap-ID '$GAP_ID' does not match DOMAIN-NNN shape" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"

emit() {
    local kind="$1"; shift
    local extra="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","source":"pr-create-gate","gap":"%s"%s}\n' \
        "$ts" "$kind" "$GAP_ID" \
        "${extra:+,$extra}" >> "$AMBIENT" 2>/dev/null || true
}

# 1. Scan OPEN PRs for the gap-ID in title — REST only (INFRA-1080).
# `gh api .../pulls?state=open` returns up to 100 per page; for the 15-50
# open-PR steady state this is one call. Use `gh search prs` would be GraphQL.
OPEN_DUP=""
OPEN_PRS_JSON=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" \
    --jq '.[] | select(.draft == false) | [.number, .title] | @tsv' 2>/dev/null || echo "")

while IFS=$'\t' read -r pr title; do
    [[ -z "$pr" ]] && continue
    # Match GAP-ID exactly using word boundary (no substring match for
    # CREDIBLE-1 vs CREDIBLE-10). Use grep -E with word-boundary regex.
    if echo "$title" | grep -qE "\\b${GAP_ID}\\b"; then
        OPEN_DUP="$pr"
        OPEN_DUP_TITLE="$title"
        break
    fi
done <<< "$OPEN_PRS_JSON"

# 2. Decision: open-duplicate refusal only (closed-cooldown deferred to INFRA-1220).
if [[ -z "$OPEN_DUP" ]]; then
    # Clean — proceed.
    exit 0
fi

DUP_KIND="open"
DUP_PR="$OPEN_DUP"
DUP_TITLE="$OPEN_DUP_TITLE"
DUP_NOTE=""

# Bypass path: requires explicit --justification + env var.
if [[ "${CHUMP_PR_DEDUP_BYPASS:-0}" == "1" ]]; then
    if [[ -z "$JUSTIFICATION" ]]; then
        echo "pr-create-gate: CHUMP_PR_DEDUP_BYPASS=1 but no --justification provided" >&2
        echo "pr-create-gate: bypass requires --justification '<reason>' (audit-logged)" >&2
        emit pr_dedup_bypass_rejected "\"dup_kind\":\"$DUP_KIND\",\"dup_pr\":$DUP_PR,\"reason\":\"no_justification\""
        exit 20
    fi
    # Sanitize justification for JSON
    just_esc=$(printf '%s' "$JUSTIFICATION" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || echo "$JUSTIFICATION")
    emit pr_dedup_bypassed "\"dup_kind\":\"$DUP_KIND\",\"dup_pr\":$DUP_PR,\"justification\":\"$just_esc\""
    echo "pr-create-gate: BYPASS — proceeding with PR creation despite duplicate #$DUP_PR ($DUP_KIND)" >&2
    echo "pr-create-gate: justification: $JUSTIFICATION" >&2
    exit 0
fi

# Refusal path.
echo "" >&2
echo "================================================================" >&2
echo "pr-create-gate (INFRA-1219): REFUSING — duplicate PR for $GAP_ID" >&2
echo "  existing: #$DUP_PR ($DUP_KIND) — $DUP_TITLE" >&2
[[ -n "$DUP_NOTE" ]] && echo "  $DUP_NOTE" >&2
echo "" >&2
echo "  Either:" >&2
echo "    1. Push your work to the existing PR's branch instead" >&2
echo "    2. If the existing PR is wrong, close it first, then re-run" >&2
echo "    3. (rare) bypass: CHUMP_PR_DEDUP_BYPASS=1 --justification '<reason>'" >&2
echo "================================================================" >&2
echo "" >&2

emit pr_dedup_blocked "\"dup_kind\":\"$DUP_KIND\",\"dup_pr\":$DUP_PR"
exit 19
