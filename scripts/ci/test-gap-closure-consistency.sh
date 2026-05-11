#!/usr/bin/env bash
# test-gap-closure-consistency.sh — CREDIBLE-028 + CREDIBLE-039: detect
# premature gap closure AND stale-post-merge gaps.
#
# Forward mode (CREDIBLE-028): queries state.db for gaps with status=done and
# closed_pr=N, then verifies each PR is actually merged on GitHub.
#
# Reverse mode (CREDIBLE-039): queries state.db for gaps with status=open and
# closed_pr=N, then checks if that PR is merged → emits stale_post_merge_gap.
#
# --auto-fix mode (CREDIBLE-039): for premature closures where the referenced
# PR is BLOCKED or DIRTY, flips state.db status back to in_progress.
#
# Usage:
#   bash scripts/ci/test-gap-closure-consistency.sh                     # info
#   bash scripts/ci/test-gap-closure-consistency.sh --strict            # exit 1 on drift
#   bash scripts/ci/test-gap-closure-consistency.sh --emit-alert        # emit ambient event
#   bash scripts/ci/test-gap-closure-consistency.sh --auto-fix          # self-heal mode
#   bash scripts/ci/test-gap-closure-consistency.sh --reverse           # reverse-mode only
#
# Exit codes:
#   0 — no drift found
#   1 — drift detected (with --strict), or fatal error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

STRICT=0
EMIT_ALERT=0
AUTO_FIX=0
REVERSE=0
LIMIT=30
ALL=0
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --strict)      STRICT=1 ;;
        --emit-alert)  EMIT_ALERT=1 ;;
        --auto-fix)    AUTO_FIX=1 ;;
        --reverse)     REVERSE=1 ;;
        --all)         ALL=1; LIMIT=999999 ;;
    esac
    if [[ "$prev_arg" == "--limit" ]]; then
        LIMIT="$arg"
    fi
    prev_arg="$arg"
done

# ── Resolve state.db ─────────────────────────────────────────────────────────
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi
DB="$MAIN_REPO/.chump/state.db"
if [[ ! -f "$DB" ]]; then
    warn "state.db not found at $DB — skipping closure consistency check"
    exit 0
fi

if ! command -v gh &>/dev/null; then
    warn "gh CLI not found — skipping GitHub PR state check"
    exit 0
fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
emit_alert() {
    local kind="$1" json_payload="$2"
    mkdir -p "$LOCK_DIR"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"ALERT","kind":"%s","source":"test-gap-closure-consistency","%s}\n' \
        "$TS" "$kind" "$json_payload" >> "$AMBIENT" 2>/dev/null || true
}

overall_drift=0

# ── Forward mode: done gaps with closed_pr, verify PR is merged ────────────
run_forward_check() {
    local rows=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done < <(
        sqlite3 "$DB" \
            "SELECT id, closed_pr FROM gaps WHERE status='done' AND closed_pr IS NOT NULL AND closed_pr != '' AND CAST(closed_pr AS INTEGER) > 0 ORDER BY CAST(closed_pr AS INTEGER) DESC LIMIT $LIMIT;" \
            2>/dev/null || true
    )

    [[ ${#rows[@]} -eq 0 ]] && { pass "No done gaps with closed_pr — forward check clean"; return 0; }

    local scope_note="most recent $LIMIT"
    [[ "$ALL" -eq 1 ]] && scope_note="all"
    info "Forward: checking ${#rows[@]} done gap(s) ($scope_note) with closed_pr…"

    local drift_ids=() drift_details=() auto_fix_ids=()
    for row in "${rows[@]}"; do
        local gap_id="${row%%|*}"
        local pr_num="${row##*|}"
        local merged_at pr_state pr_state_raw
        merged_at="$(gh pr view "$pr_num" --json mergedAt --jq '.mergedAt' 2>/dev/null || echo "ERROR")"
        [[ "$merged_at" == "ERROR" ]] && { warn "$gap_id: could not query PR #$pr_num — skipping"; continue; }

        if [[ -z "$merged_at" || "$merged_at" == "null" ]]; then
            pr_state_raw="$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
            warn "$gap_id: state=done closed_pr=#$pr_num but PR is $pr_state_raw (not merged)"
            drift_ids+=("$gap_id")
            drift_details+=("$gap_id:#$pr_num/$pr_state_raw")

            # --auto-fix: if PR is BLOCKED or DIRTY, flip state.db back to in_progress.
            if [[ "$AUTO_FIX" -eq 1 ]]; then
                local mergeable
                mergeable="$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")"
                if [[ "$mergeable" == "BLOCKED" || "$mergeable" == "DIRTY" ]]; then
                    info "$gap_id: auto-fix — flipping status from done to in_progress (PR #$pr_num is $mergeable)"
                    CHUMP_ALLOW_RECYCLE=1 chump gap set "$gap_id" --status in_progress 2>/dev/null || \
                        warn "$gap_id: auto-fix failed — chump gap set returned non-zero"
                    emit_alert "premature_closure_auto_fixed" \
                        '"gap_id":"'"$gap_id"'","pr":'"$pr_num"',"old_status":"done","new_status":"in_progress","mergeable":"'"$mergeable"'"'
                    auto_fix_ids+=("$gap_id")
                else
                    info "$gap_id: PR #$pr_num is $mergeable — skipping auto-fix (only BLOCKED/DIRTY qualify)"
                fi
            fi
        else
            pass "$gap_id: PR #$pr_num merged ($merged_at)"
        fi
    done

    if [[ ${#drift_ids[@]} -gt 0 ]]; then
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            local ids_json="$(printf '"%s",' "${drift_ids[@]}" | sed 's/,$//')"
            local note="${#drift_ids[@]} done gap(s) have closed_pr set but PR not merged"
            emit_alert "gap_drift_premature_close" '"ids":['"$ids_json"'],"note":"'"$note"'"'
            info "Emitted gap_drift_premature_close ALERT"
        fi
        echo ""
        echo "Forward: ${#drift_ids[@]} gap(s) marked done but PR not merged:"
        for d in "${drift_details[@]}"; do echo "  $d"; done
        [[ ${#auto_fix_ids[@]} -gt 0 ]] && echo "Auto-fixed: ${auto_fix_ids[*]}"
        [[ "$STRICT" -eq 1 ]] && overall_drift=1
    else
        pass "Forward: all ${#rows[@]} done gaps verified against GitHub"
    fi
}

# ── Reverse mode: open gaps with closed_pr, check if PR is now merged ──────
run_reverse_check() {
    local rows=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done < <(
        sqlite3 "$DB" \
            "SELECT id, closed_pr FROM gaps WHERE status='open' AND closed_pr IS NOT NULL AND closed_pr != '' AND CAST(closed_pr AS INTEGER) > 0 ORDER BY CAST(closed_pr AS INTEGER) DESC LIMIT $LIMIT;" \
            2>/dev/null || true
    )

    [[ ${#rows[@]} -eq 0 ]] && { pass "No open gaps with closed_pr — reverse check clean"; return 0; }

    local scope_note="most recent $LIMIT"
    [[ "$ALL" -eq 1 ]] && scope_note="all"
    info "Reverse: checking ${#rows[@]} open gap(s) ($scope_note) with closed_pr…"

    local stale_ids=() stale_details=()
    for row in "${rows[@]}"; do
        local gap_id="${row%%|*}"
        local pr_num="${row##*|}"
        local merged_at pr_title
        merged_at="$(gh pr view "$pr_num" --json mergedAt --jq '.mergedAt' 2>/dev/null || echo "ERROR")"
        [[ "$merged_at" == "ERROR" ]] && { warn "$gap_id: could not query PR #$pr_num — skipping"; continue; }

        if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
            pr_title="$(gh pr view "$pr_num" --json title --jq '.title' 2>/dev/null || echo "?")"
            warn "$gap_id: status=open but closed_pr=#$pr_num IS merged ($merged_at) — gap should be done"
            stale_ids+=("$gap_id")
            stale_details+=("$gap_id:#$pr_num merged")
        else
            pass "$gap_id: PR #$pr_num not yet merged (consistent with status=open)"
        fi
    done

    if [[ ${#stale_ids[@]} -gt 0 ]]; then
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            local ids_json="$(printf '"%s",' "${stale_ids[@]}" | sed 's/,$//')"
            local note="${#stale_ids[@]} open gap(s) have closed_pr set but PR is merged — run chump gap ship <ID>"
            emit_alert "stale_post_merge_gap" '"ids":['"$ids_json"'],"note":"'"$note"'"'
            info "Emitted stale_post_merge_gap ALERT"
        fi
        echo ""
        echo "Reverse: ${#stale_ids[@]} gap(s) still open but closed_pr PR is merged:"
        for d in "${stale_details[@]}"; do echo "  $d"; done
        [[ "$STRICT" -eq 1 ]] && overall_drift=1
    else
        pass "Reverse: all ${#rows[@]} open gaps verified against GitHub"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== gap-closure-consistency check ==="
echo ""

if [[ "$REVERSE" -eq 0 ]]; then
    run_forward_check
else
    info "Skipping forward check (--reverse mode)"
fi
run_reverse_check

echo ""
if [[ "$overall_drift" -eq 0 ]]; then
    echo "All closure consistency checks passed."
    exit 0
else
    echo "Closure consistency drift detected (--strict mode)."
    exit 1
fi
