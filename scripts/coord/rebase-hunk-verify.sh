#!/usr/bin/env bash
# scripts/coord/rebase-hunk-verify.sh — INFRA-1526
#
# Post-rebase guard: detects when a rebase silently drops hunks from files that
# had significant additions on the original branch.
#
# Root cause: custom append-only merge drivers (e.g. rust-main-append, formerly
# registered for src/main.rs) fall back to standard 3-way merge on
# non-pure-append conflicts, and some git versions drop content near conflict
# boundaries instead of emitting conflict markers. Observed 2026-05-16:
#   PR #2216 lost 173 src/main.rs lines after auto-rebase, while
#   EVENT_REGISTRY.yaml (merge=union) survived intact → orphan event kind.
#   PR #2173 had the opposite drop (src/main.rs survived, registry dropped).
#
# Algorithm (AC#6 from INFRA-1526):
#   1. Compute numstat of original branch (base..original_tip) per file.
#   2. Compute numstat of rebased branch (base..rebased_tip) per file.
#   3. For each file where original_additions > DROP_THRESHOLD (default 50):
#      if rebased_additions == 0 AND file is absent from rebased diff → WARN.
#   4. If any drops found: emit kind=rebase_hunk_dropped to ambient.jsonl,
#      print error, exit 1 (caller should abort the push).
#
# Usage:
#   bash scripts/coord/rebase-hunk-verify.sh <original_tip> <rebased_tip> \
#       <base_ref> [<ambient_log>]
#
# Args:
#   $1  original_tip   — commit SHA before rebase (e.g. ORIG_HEAD)
#   $2  rebased_tip    — commit SHA after rebase (e.g. HEAD)
#   $3  base_ref       — the ref we rebased onto (e.g. origin/main)
#   $4  ambient_log    — optional; defaults to $REPO_ROOT/.chump-locks/ambient.jsonl
#
# Exit codes:
#   0   no drops detected — safe to push
#   1   hunk drop(s) detected — caller should abort the push
#   2   bad arguments or git error
#
# Environment:
#   CHUMP_REBASE_VERIFY_THRESHOLD   — min insertions in original to trigger check
#                                      (default 50)
#   CHUMP_REBASE_VERIFY_SKIP        — set to 1 to bypass entirely (audit-logged)

set -uo pipefail

ORIG_TIP="${1:-}"
REBASED_TIP="${2:-}"
BASE_REF="${3:-origin/main}"
AMBIENT_OVERRIDE="${4:-}"

if [[ -z "$ORIG_TIP" || -z "$REBASED_TIP" ]]; then
    echo "[rebase-hunk-verify] ERROR: usage: $0 <original_tip> <rebased_tip> <base_ref> [<ambient_log>]" >&2
    exit 2
fi

if [[ "${CHUMP_REBASE_VERIFY_SKIP:-0}" == "1" ]]; then
    echo "[rebase-hunk-verify] BYPASSED via CHUMP_REBASE_VERIFY_SKIP=1" >&2
    exit 0
fi

DROP_THRESHOLD="${CHUMP_REBASE_VERIFY_THRESHOLD:-50}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))}"

if [[ -n "$AMBIENT_OVERRIDE" ]]; then
    AMBIENT="$AMBIENT_OVERRIDE"
else
    _GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$_GIT_COMMON" == ".git" ]]; then
        AMBIENT="${REPO_ROOT}/.chump-locks/ambient.jsonl"
    else
        AMBIENT="${REPO_ROOT}/${_GIT_COMMON}/../../.chump-locks/ambient.jsonl"
    fi
fi

_emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

# Resolve full SHAs so the diff commands are deterministic.
ORIG_SHA="$(git rev-parse "$ORIG_TIP" 2>/dev/null)" || {
    echo "[rebase-hunk-verify] ERROR: cannot resolve original_tip '$ORIG_TIP'" >&2
    exit 2
}
REBASED_SHA="$(git rev-parse "$REBASED_TIP" 2>/dev/null)" || {
    echo "[rebase-hunk-verify] ERROR: cannot resolve rebased_tip '$REBASED_TIP'" >&2
    exit 2
}

# Verify base_ref resolves (fetch may be needed, but we don't fetch here).
BASE_SHA="$(git rev-parse "$BASE_REF" 2>/dev/null)" || {
    echo "[rebase-hunk-verify] ERROR: cannot resolve base_ref '$BASE_REF'" >&2
    exit 2
}

# Build associative arrays: file → added_lines in original / rebased branch.
declare -A orig_add
declare -A rebased_add

# git diff --numstat outputs: "<added>\t<removed>\t<path>"
# Binary files output: "-\t-\t<path>" — skip those.
while IFS=$'\t' read -r added removed filepath; do
    [[ "$added" == "-" ]] && continue
    [[ -z "$filepath" ]] && continue
    orig_add["$filepath"]="${added:-0}"
done < <(git diff --numstat "${BASE_SHA}..${ORIG_SHA}" 2>/dev/null || true)

while IFS=$'\t' read -r added removed filepath; do
    [[ "$added" == "-" ]] && continue
    [[ -z "$filepath" ]] && continue
    rebased_add["$filepath"]="${added:-0}"
done < <(git diff --numstat "${BASE_SHA}..${REBASED_SHA}" 2>/dev/null || true)

DROPS=()
for filepath in "${!orig_add[@]}"; do
    o_add="${orig_add[$filepath]}"
    r_add="${rebased_add[$filepath]:-0}"
    if (( o_add > DROP_THRESHOLD && r_add == 0 )); then
        DROPS+=("$filepath:orig+${o_add}->rebased+${r_add}")
    fi
done

if [[ ${#DROPS[@]} -eq 0 ]]; then
    echo "[rebase-hunk-verify] OK — no hunk drops detected (original=${ORIG_SHA:0:8} rebased=${REBASED_SHA:0:8})" >&2
    exit 0
fi

# One or more drops found.
echo "[rebase-hunk-verify] HUNK DROP DETECTED — rebase silently discarded content!" >&2
echo "[rebase-hunk-verify]   original commit : $ORIG_SHA" >&2
echo "[rebase-hunk-verify]   rebased  commit : $REBASED_SHA" >&2
echo "[rebase-hunk-verify]   base ref        : $BASE_REF ($BASE_SHA)" >&2
echo "[rebase-hunk-verify]   threshold       : >${DROP_THRESHOLD} insertions in original" >&2
echo "" >&2
for drop_info in "${DROPS[@]}"; do
    file="${drop_info%%:*}"
    detail="${drop_info#*:}"
    echo "[rebase-hunk-verify]   DROPPED  $file  ($detail)" >&2

    # Emit one ambient event per dropped file.
    _emit "rebase_hunk_dropped" \
        "\"file\":\"${file}\",\"original_commit\":\"${ORIG_SHA}\",\"rebased_commit\":\"${REBASED_SHA}\",\"base_ref\":\"${BASE_REF}\",\"detail\":\"${detail}\""
done
echo "" >&2
echo "[rebase-hunk-verify] Push ABORTED — fix the merge driver causing silent drops," >&2
echo "[rebase-hunk-verify] or resolve the rebase manually and verify content is intact." >&2
echo "[rebase-hunk-verify] See INFRA-1526 (.gitattributes custom merge drivers)." >&2

exit 1
