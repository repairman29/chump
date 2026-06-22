#!/usr/bin/env bash
# scripts/coord/lib/rebase-hunk-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector.
#
# Source this file, capture PRE_REBASE_HEAD before the rebase, then call
# rebase_hunk_verify after the rebase completes.
#
# Usage:
#   source scripts/coord/lib/rebase-hunk-verify.sh
#   PRE_REBASE_HEAD=$(git rev-parse HEAD)
#   git rebase ...
#   rebase_hunk_verify "$PRE_REBASE_HEAD" "$FULL_BASE" "$AMBIENT_LOG"
#
# Arguments:
#   $1  pre_rebase_head  — SHA of HEAD before rebase (captured before git rebase)
#   $2  new_base         — ref or SHA of the target we rebased onto (e.g. origin/main)
#   $3  ambient_log      — path to ambient.jsonl for event emission (optional)
#
# Environment:
#   CHUMP_HUNK_DROP_MIN_LINES  — additions threshold; files below this are ignored
#                                (default 50, per INFRA-1526 AC#6)
#
# Return codes:
#   0  — no drops detected (or check could not run)
#   1  — one or more files had >threshold additions originally but 0 after rebase
#
# Emits kind=rebase_hunk_dropped per dropped file (AC#8).

rebase_hunk_verify() {
    local pre_rebase_head="${1:-}"
    local new_base="${2:-}"
    local ambient_log="${3:-}"
    local min_lines="${CHUMP_HUNK_DROP_MIN_LINES:-50}"

    if [[ -z "$pre_rebase_head" || -z "$new_base" ]]; then
        printf '[rebase-hunk-verify] WARN: missing args; skipping check\n' >&2
        return 0
    fi

    # Verify the pre-rebase SHA is still reachable in the object store.
    if ! git cat-file -e "${pre_rebase_head}^{commit}" 2>/dev/null; then
        printf '[rebase-hunk-verify] WARN: pre-rebase SHA %s not found; skipping\n' \
            "$pre_rebase_head" >&2
        return 0
    fi

    # Compute the old merge-base between the original feature tip and the new base.
    # Both objects are still accessible after the rebase completes.
    local old_base
    old_base="$(git merge-base "$pre_rebase_head" "$new_base" 2>/dev/null)" || {
        printf '[rebase-hunk-verify] WARN: could not compute merge-base; skipping\n' >&2
        return 0
    }

    # Cumulative per-file additions in the original feature branch commits.
    # `git diff --numstat A B` gives tab-separated: additions<TAB>deletions<TAB>file
    declare -A _orig_adds
    while IFS=$'\t' read -r adds _dels file; do
        [[ "$adds" =~ ^[0-9]+$ ]] || continue
        _orig_adds["$file"]="$adds"
    done < <(git diff --numstat "$old_base" "$pre_rebase_head" 2>/dev/null)

    if [[ "${#_orig_adds[@]}" -eq 0 ]]; then
        # No files changed in original branch — nothing to verify.
        return 0
    fi

    # Cumulative per-file additions in the rebased feature branch commits.
    declare -A _new_adds
    while IFS=$'\t' read -r adds _dels file; do
        [[ "$adds" =~ ^[0-9]+$ ]] || continue
        _new_adds["$file"]="$adds"
    done < <(git diff --numstat "$new_base" HEAD 2>/dev/null)

    local drops=0
    local post_sha
    post_sha="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    for file in "${!_orig_adds[@]}"; do
        local orig="${_orig_adds[$file]}"
        local new="${_new_adds[$file]:-0}"
        if [[ "$orig" -gt "$min_lines" && "$new" -eq 0 ]]; then
            printf '[rebase-hunk-verify] DROPPED: %s — %d additions in original, 0 after rebase\n' \
                "$file" "$orig" >&2
            drops=$((drops + 1))
            _rhv_emit_event "$ambient_log" "$ts" "$file" "$orig" "$pre_rebase_head" "$post_sha"
        fi
    done

    if [[ "$drops" -gt 0 ]]; then
        printf '[rebase-hunk-verify] ERROR: %d file(s) had hunks silently dropped.\n' \
            "$drops" >&2
        printf '[rebase-hunk-verify] Inspect kind=rebase_hunk_dropped in ambient.jsonl.\n' >&2
        printf '[rebase-hunk-verify] Do NOT push — abort or restore the missing hunks manually.\n' >&2
        return 1
    fi

    printf '[rebase-hunk-verify] OK: no hunk drops detected (%d files checked, threshold=%d)\n' \
        "${#_orig_adds[@]}" "$min_lines" >&2
    return 0
}

# _rhv_emit_event — internal helper, emits kind=rebase_hunk_dropped to ambient.jsonl.
_rhv_emit_event() {
    local ambient_log="$1" ts="$2" file="$3" lines_dropped="$4"
    local original_commit="$5" rebased_commit="$6"

    [[ -z "$ambient_log" ]] && return 0

    # Escape file path for JSON (replace \ and " only; paths shouldn't have other special chars)
    local safe_file
    safe_file="$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    local json
    json="$(printf \
        '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s"}' \
        "$ts" "$safe_file" "$lines_dropped" "$original_commit" "$rebased_commit")"

    # scanner-anchor: "kind":"rebase_hunk_dropped"
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 200; printf '%s\n' "$json" >> "$ambient_log" ) \
            200>"${ambient_log}.lock" 2>/dev/null \
            || printf '%s\n' "$json" >> "$ambient_log" 2>/dev/null || true
    else
        printf '%s\n' "$json" >> "$ambient_log" 2>/dev/null || true
    fi
}
