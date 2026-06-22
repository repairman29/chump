#!/usr/bin/env bash
# scripts/coord/post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop verification.
#
# Call this in a worktree immediately after a successful `git rebase origin/main`.
# Git sets ORIG_HEAD to the pre-rebase tip automatically; this script uses it to
# compare the original feature-branch file scope against the rebased file scope.
#
# A "hunk drop" is: a file that had >= THRESHOLD added lines in the original
# feature commits has 0 added lines after rebase. This is the failure mode that
# caused PR #2216 (INFRA-1418) to silently lose its 173-line src/main.rs block.
#
# Exits 0 if no drops detected, exits 1 if any drops detected (and emits a
# kind=rebase_hunk_dropped event to ambient.jsonl for each dropped file).
#
# Usage:
#   post-rebase-verify.sh [<pre_rebase_sha>]
#   PRE_REBASE_SHA=<sha> post-rebase-verify.sh
#
# If no SHA is provided, falls back to ORIG_HEAD (set by git after rebase).
#
# Env overrides:
#   CHUMP_REBASE_HUNK_DROP_THRESHOLD   Min added-lines to flag (default: 50)
#   CHUMP_REBASE_VERIFY_VERBOSE        Set to 1 for per-file detail
#   CHUMP_SKIP_REBASE_VERIFY           Set to 1 to skip (emergency bypass)
#
# Pairs with: scripts/coord/wedge-recover.sh, INFRA-1509 (pre-push lint),
#             docs/observability/EVENT_REGISTRY.yaml (kind=rebase_hunk_dropped)

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${REPO_ROOT}/.chump-locks/ambient.jsonl"
THRESHOLD="${CHUMP_REBASE_HUNK_DROP_THRESHOLD:-50}"
VERBOSE="${CHUMP_REBASE_VERIFY_VERBOSE:-0}"
# Upstream ref against which to compare file scope.  Overridable for testing.
UPSTREAM="${CHUMP_REBASE_UPSTREAM:-origin/main}"

if [[ "${CHUMP_SKIP_REBASE_VERIFY:-0}" == "1" ]]; then
    echo "[post-rebase-verify] skipped (CHUMP_SKIP_REBASE_VERIFY=1)"
    exit 0
fi

PRE_REBASE_SHA="${1:-${PRE_REBASE_SHA:-}}"

if [[ -z "$PRE_REBASE_SHA" ]]; then
    if git rev-parse ORIG_HEAD >/dev/null 2>&1; then
        PRE_REBASE_SHA="$(git rev-parse ORIG_HEAD)"
    else
        echo "[post-rebase-verify] WARN: no PRE_REBASE_SHA and ORIG_HEAD not set — skipping"
        exit 0
    fi
fi

REBASED_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
if [[ -z "$REBASED_SHA" ]]; then
    echo "[post-rebase-verify] WARN: cannot resolve HEAD — skipping"
    exit 0
fi

# Find old merge-base (common ancestor of pre-rebase tip and current origin/main).
# git merge-base returns the commit at which the feature branch diverged from main.
OLD_MERGE_BASE="$(git merge-base "$PRE_REBASE_SHA" "$UPSTREAM" 2>/dev/null || echo "")"
if [[ -z "$OLD_MERGE_BASE" ]]; then
    echo "[post-rebase-verify] WARN: cannot compute merge-base for $PRE_REBASE_SHA — skipping"
    exit 0
fi

[[ "$VERBOSE" == "1" ]] && echo "[post-rebase-verify] pre=$PRE_REBASE_SHA post=$REBASED_SHA base=$OLD_MERGE_BASE threshold=${THRESHOLD}"

# ── Detect drops via awk (bash-3.2 compatible — no associative arrays) ────────
#
# Strategy: build two numstat tables (orig and rebased), then join on filename.
# Files present in orig with additions >= THRESHOLD but absent (or 0) in rebased
# are hunk drops.
#
# Temp files hold "added<TAB>file" pairs; awk does the cross-table lookup.
_TMP_ORIG="$(mktemp)"
_TMP_REBASED="$(mktemp)"
# shellcheck disable=SC2064  # $(...) evaluated now — correct
trap "rm -f '$_TMP_ORIG' '$_TMP_REBASED'" EXIT

git diff --numstat "$OLD_MERGE_BASE" "$PRE_REBASE_SHA" 2>/dev/null \
    | awk '$1~/^[0-9]+$/{print $1"\t"$3}' > "$_TMP_ORIG"

git diff --numstat "$UPSTREAM" HEAD 2>/dev/null \
    | awk '$1~/^[0-9]+$/{print $1"\t"$3}' > "$_TMP_REBASED"

# awk: load rebased table, then scan orig for large additions absent from rebased.
# Use FILENAME guard instead of NR==FNR so empty first-file doesn't mis-classify
# all orig rows into the "rebased" loading phase.
DROP_RESULTS="$(awk -v threshold="$THRESHOLD" -v rebased_file="$_TMP_REBASED" '
FILENAME==rebased_file { rebased[$2]=$1+0; next }
{
    added=$1+0; file=$2
    if (added >= threshold) {
        r = (file in rebased) ? rebased[file]+0 : 0
        if (r == 0) print added"\t"file
    }
}
' "$_TMP_REBASED" "$_TMP_ORIG")"

ORIG_FILE_COUNT="$(wc -l < "$_TMP_ORIG" | tr -d ' ')"

# ── Report ────────────────────────────────────────────────────────────────────
if [[ -z "$DROP_RESULTS" ]]; then
    echo "[post-rebase-verify] OK — no hunk drops (checked ${ORIG_FILE_COUNT} files, threshold=${THRESHOLD} lines)"
    exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DROP_COUNT=0
while IFS=$'\t' read -r orig_lines file; do
    [[ -n "$file" ]] || continue
    DROP_COUNT=$((DROP_COUNT+1))
    echo "[post-rebase-verify] HUNK_DROP: $file (orig=+${orig_lines} lines, rebased=+0 — silent data loss)"
    # scanner-anchor: "kind":"rebase_hunk_dropped"
    printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%s,"original_commit":"%s","rebased_commit":"%s"}\n' \
        "$ts" "$file" "$orig_lines" "$PRE_REBASE_SHA" "$REBASED_SHA" \
        >> "$AMBIENT" 2>/dev/null || true
done <<< "$DROP_RESULTS"

echo "[post-rebase-verify] FAIL — ${DROP_COUNT} file(s) with dropped hunks; ambient events emitted"
exit 1
