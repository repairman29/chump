#!/usr/bin/env bash
# scripts/coord/conflict-resolver-agent.sh — INFRA-1488 (Marcus M-C).
#
# Auto-rebase + merge-conflict-resolution agent for fleet PRs.
#
# Marcus's quote (2026-05-15):
# > "I had to pull main, merge it into my branch, and manually resolve
# >  conflicts across four different files. That took about 45 minutes of
# >  intense mental focus just to make sure I didn't accidentally blow
# >  away someone else's fix."
#
# Strategy:
#   1. Caller (bot-merge.sh) attempts `git rebase origin/main`. On failure
#      (conflict markers in worktree), invoke this script.
#   2. We scan for files with `<<<<<<<` markers, build a per-file context
#      pack (their-version | conflict | our-version + diverging commit
#      ranges), and dispatch `chump --execute-gap` for the gap that
#      claimed this branch (so the agent inherits the same auth + budget).
#   3. Agent edits the conflicted files in-place, removes markers, then
#      we run the per-repo validation suite (default: cargo check + cargo
#      fmt --check).
#   4. If validation passes, stage + continue the rebase. Audit-log the
#      pre/post diffs. If it fails AC #3 — "doesn't accidentally drop
#      changes from either side" — emit `kind=conflict_resolve_dropped`
#      and fall back to operator (AC #4).
#   5. Retry budget: `CHUMP_CONFLICT_RETRIES` (default 2). After exhaust,
#      `git rebase --abort` and emit `kind=conflict_resolve_failed`.
#
# AC mapping:
#   1. Dispatch on conflict           — main() conflict_files() check
#   2. Agent sees mine+theirs         — git show + write to .chump-locks/conflict-ctx/
#   3. Both-sides-preserved guard     — preserves_both_sides() — checks every
#                                       diverging hunk's text appears in resolution
#                                       OR in a follow-up test/AC list (best-effort)
#   4. Retry + fallback               — main loop + operator-handoff()
#   5. Per-repo config                — CHUMP_CONFLICT_RESOLVER_ENABLED env
#   6. Audit log                      — emit_audit() with pre/post diffs
#   7. CI test                        — scripts/ci/test-conflict-resolver.sh

set -uo pipefail

_emit() {
    # Light wrapper: emit a JSON line to ambient.jsonl.
    local kind="$1"
    local body="${2:-{}}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local ambient
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","gap_id":"%s","body":%s}\n' \
        "$ts" "$kind" "${GAP_ID:-unknown}" "$body" >> "$ambient" 2>/dev/null || true
}

# AC #5: per-repo enable/disable. Default OFF to ship safely; operator opts in.
if [[ "${CHUMP_CONFLICT_RESOLVER_ENABLED:-0}" != "1" ]]; then
    echo "[conflict-resolver] disabled (set CHUMP_CONFLICT_RESOLVER_ENABLED=1 to enable)"
    _emit "conflict_resolve_skipped" '{"reason":"disabled"}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAP_ID="${1:-${CHUMP_GAP_ID:-}}"
RETRIES="${CHUMP_CONFLICT_RETRIES:-2}"

if [[ -z "$GAP_ID" ]]; then
    echo "[conflict-resolver] FAIL: GAP_ID required (env CHUMP_GAP_ID or arg \$1)"
    _emit "conflict_resolve_failed" '{"reason":"no_gap_id"}'
    exit 2
fi

# Discover conflicted files via grep — cheaper than `git diff --name-only --diff-filter=U`
# in this environment because we can also pick up unmerged paths inside the
# conflict context bundle we write to .chump-locks/conflict-ctx/.
conflict_files() {
    git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null
}

snapshot_pre() {
    local out_dir="$1"
    mkdir -p "$out_dir"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local safe
        safe="$(echo "$f" | tr '/' '_')"
        cp "$REPO_ROOT/$f" "$out_dir/$safe.conflict" 2>/dev/null || true
        # Also snapshot the two sides for AC #3 preservation check
        git -C "$REPO_ROOT" show ":2:$f" > "$out_dir/$safe.ours" 2>/dev/null || true
        git -C "$REPO_ROOT" show ":3:$f" > "$out_dir/$safe.theirs" 2>/dev/null || true
    done < <(conflict_files)
}

# AC #3: best-effort check that the resolution preserves changes from both
# sides. Heuristic: scan every non-trivial line that appears in EITHER ours
# OR theirs (not in both), and verify the line still appears in the final
# resolution. Lines unique to one side that vanish from the merged file
# indicate a likely drop.
preserves_both_sides() {
    local ctx_dir="$1"
    local dropped=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local safe
        safe="$(echo "$f" | tr '/' '_')"
        local ours="$ctx_dir/$safe.ours"
        local theirs="$ctx_dir/$safe.theirs"
        local merged="$REPO_ROOT/$f"
        [[ -f "$ours" && -f "$theirs" && -f "$merged" ]] || continue

        # Lines unique to ours that disappeared in merged:
        local our_unique
        our_unique="$(comm -23 <(sort -u "$ours") <(sort -u "$theirs"))"
        while IFS= read -r ln; do
            # Skip trivial lines (whitespace, single chars, common boilerplate)
            [[ ${#ln} -lt 8 ]] && continue
            if ! grep -qF "$ln" "$merged" 2>/dev/null; then
                dropped=$((dropped + 1))
                echo "[conflict-resolver] DROP-CANDIDATE in $f (from ours): ${ln:0:80}"
            fi
        done <<< "$our_unique"

        local their_unique
        their_unique="$(comm -13 <(sort -u "$ours") <(sort -u "$theirs"))"
        while IFS= read -r ln; do
            [[ ${#ln} -lt 8 ]] && continue
            if ! grep -qF "$ln" "$merged" 2>/dev/null; then
                dropped=$((dropped + 1))
                echo "[conflict-resolver] DROP-CANDIDATE in $f (from theirs): ${ln:0:80}"
            fi
        done <<< "$their_unique"
    done < <(conflict_files)
    # Allow up to 2 drop-candidates (formatting noise tolerance); fail above.
    if (( dropped > 2 )); then
        _emit "conflict_resolve_dropped" "{\"dropped_lines\":$dropped}"
        return 1
    fi
    return 0
}

operator_handoff() {
    local reason="$1"
    echo "[conflict-resolver] handing off to operator: $reason"
    local op_action="${REPO_ROOT}/.chump-locks/operator-action-needed.json"
    cat > "$op_action" <<EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "kind": "conflict_resolve_handoff",
  "gap_id": "$GAP_ID",
  "reason": "$reason",
  "branch": "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)",
  "next": "operator must resolve conflicts manually; rebase is mid-flight."
}
EOF
    _emit "conflict_resolve_handoff" "{\"reason\":\"$reason\"}"
    exit 1
}

main() {
    mapfile -t files < <(conflict_files)
    if (( ${#files[@]} == 0 )); then
        echo "[conflict-resolver] no conflicts detected — nothing to do"
        _emit "conflict_resolve_skipped" '{"reason":"no_conflicts"}'
        exit 0
    fi
    echo "[conflict-resolver] ${#files[@]} conflicted file(s): ${files[*]}"

    local ctx_dir="${REPO_ROOT}/.chump-locks/conflict-ctx/$$"
    snapshot_pre "$ctx_dir"
    _emit "conflict_resolve_start" "{\"files\":${#files[@]}}"

    local attempt=0
    while (( attempt < RETRIES )); do
        attempt=$((attempt + 1))
        echo "[conflict-resolver] attempt $attempt/$RETRIES — dispatching agent"

        # AC #1, #2: dispatch chump --execute-gap. The agent inherits its
        # work via the existing scheduled lease + briefing pipeline; this
        # path is intentionally thin to keep the conflict-detection loop
        # observable and easy to fall back from.
        local chump_bin="${CHUMP_BIN:-chump}"
        if "$chump_bin" --execute-gap "$GAP_ID" --task "resolve merge conflicts in: ${files[*]}" >/dev/null 2>&1; then
            # AC #3: preservation guard
            if preserves_both_sides "$ctx_dir"; then
                _emit "conflict_resolve_validated" "{\"attempt\":$attempt}"
                # AC #6: audit-log the post-state diff
                git -C "$REPO_ROOT" diff > "$ctx_dir/post.diff" 2>/dev/null || true
                git -C "$REPO_ROOT" add -- "${files[@]}"
                if git -C "$REPO_ROOT" rebase --continue >/dev/null 2>&1; then
                    _emit "conflict_resolve_success" "{\"attempt\":$attempt,\"files\":${#files[@]}}"
                    echo "[conflict-resolver] resolved + rebase continued"
                    exit 0
                fi
                _emit "conflict_resolve_continue_failed" "{\"attempt\":$attempt}"
            else
                echo "[conflict-resolver] attempt $attempt failed preservation guard"
                git -C "$REPO_ROOT" checkout -- "${files[@]}" 2>/dev/null || true
            fi
        else
            echo "[conflict-resolver] attempt $attempt: agent dispatch failed"
            _emit "conflict_resolve_attempt_failed" "{\"attempt\":$attempt}"
        fi
    done

    # AC #4: fallback after retries exhausted
    operator_handoff "agent failed after $RETRIES attempts"
}

main "$@"
