#!/usr/bin/env bash
# inbox-routing.sh — A2A inbox alias resolution helpers (INFRA-2006).
#
# Provides:
#   resolve_inbox_targets  — prints all inbox file paths the current session
#                            should read (env-id + all owned lease-ids).
#   resolve_inbox_target <target>  — given a session-or-gap-id the SENDER
#                                    wants to address, returns the canonical
#                                    inbox file path for writing.
#
# Source this file; do not execute directly.
# bash 3.2-compatible (macOS system bash).
#
# Environment:
#   CHUMP_SESSION_ID / CLAUDE_SESSION_ID — primary session id (reader)
#   CHUMP_GAP_ID                         — current gap (used in lease lookup)
#   LOCK_DIR                             — override .chump-locks location

# ── internals ─────────────────────────────────────────────────────────────────

_ir_lock_dir() {
    # Honour explicit LOCK_DIR override first (needed by tests that run in
    # a synthetic workspace rather than a real git repo).
    if [[ -n "${LOCK_DIR:-}" ]]; then
        printf '%s' "$LOCK_DIR"
        return
    fi
    local repo; repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local git_common; git_common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    local main_repo
    if [[ "$git_common" == ".git" ]]; then
        main_repo="$repo"
    else
        main_repo="$(cd "$git_common/.." && pwd)"
    fi
    printf '%s/.chump-locks' "$main_repo"
}

_ir_primary_session() {
    local sid="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [[ -z "$sid" ]]; then
        local lock_dir; lock_dir="$(_ir_lock_dir)"
        [[ -f "$lock_dir/.wt-session-id" ]] && sid="$(cat "$lock_dir/.wt-session-id" 2>/dev/null || true)"
    fi
    if [[ -z "$sid" && -f "$HOME/.chump/session_id" ]]; then
        sid="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
    fi
    printf '%s' "$sid"
}

# Return all lease session-ids associated with the current process.
# A lease "belongs" to the current session when its session_id matches
# the primary env-session-id OR its gap_id matches CHUMP_GAP_ID.
_ir_owned_lease_ids() {
    local primary; primary="$(_ir_primary_session)"
    local gap_id="${CHUMP_GAP_ID:-}"
    local lock_dir; lock_dir="$(_ir_lock_dir)"

    local f lease_session lease_gap
    for f in "$lock_dir"/claim-*.json; do
        [[ -f "$f" ]] || continue
        lease_session="$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('session_id',''))" 2>/dev/null || true)"
        lease_gap="$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('gap_id',''))" 2>/dev/null || true)"
        if [[ -n "$primary" && "$lease_session" == "$primary" ]]; then
            printf '%s\n' "$lease_session"
        elif [[ -n "$gap_id" && "$lease_gap" == "$gap_id" ]]; then
            printf '%s\n' "$lease_session"
        fi
    done
}

# ── public API ────────────────────────────────────────────────────────────────

# resolve_inbox_targets [--all]
#
# Prints one inbox file path per line — the union of:
#   1. .chump-locks/inbox/<primary-session-id>.jsonl
#   2. .chump-locks/inbox/<lease-session-id>.jsonl  (for each owned lease)
#   3. .chump-locks/inbox/opus-inbox/session_<lease-session-id>.jsonl  (legacy)
#
# Only paths that exist on disk are printed unless --all is passed.
# bash 3.2-compatible: deduplication via a temp file of seen paths.
resolve_inbox_targets() {
    local include_missing=0
    [[ "${1:-}" == "--all" ]] && include_missing=1

    local primary; primary="$(_ir_primary_session)"
    local lock_dir; lock_dir="$(_ir_lock_dir)"
    local inbox_dir="$lock_dir/inbox"

    # Deduplication scratch file (no associative arrays in bash 3.2).
    local seen_file; seen_file="$(mktemp /tmp/ir-seen.XXXXXX)"
    # INFRA-2495: single-quoted trap defers $seen_file expansion until RETURN,
    # by which point the `local` variable is out of scope. Under `set -u` this
    # crashes with "seen_file: unbound variable" and breaks the MANDATORY
    # pre-flight `chump-inbox.sh read --no-advance` from CLAUDE.md.
    # Fix: bake the path into the trap command at SET time via double-quoting
    # (the mktemp path has no shell metacharacters so single-quote wrapping
    # after expansion is safe).
    trap "rm -f '$seen_file'" RETURN

    _ir_maybe_print() {
        local p="$1"
        # Check if already seen (grep -qxF is POSIX and bash 3.2-safe).
        if grep -qxF "$p" "$seen_file" 2>/dev/null; then
            return
        fi
        printf '%s\n' "$p" >> "$seen_file"
        if [[ "$include_missing" -eq 1 ]] || [[ -f "$p" ]]; then
            printf '%s\n' "$p"
        fi
    }

    # 1. Primary env-session inbox.
    if [[ -n "$primary" ]]; then
        _ir_maybe_print "$inbox_dir/$primary.jsonl"
    fi

    # 2 + 3. Each owned lease.
    local lease_sid
    while IFS= read -r lease_sid; do
        [[ -z "$lease_sid" ]] && continue
        _ir_maybe_print "$inbox_dir/$lease_sid.jsonl"
        _ir_maybe_print "$inbox_dir/opus-inbox/session_$lease_sid.jsonl"
    done < <(_ir_owned_lease_ids)
}

# resolve_inbox_target <session-or-gap-id>
#
# Given an id the SENDER wants to address, return the canonical inbox path
# for WRITING. Resolution order:
#   a. If a live claim-*.json has session_id == <input> → use that lease-id
#      inbox (what broadcast.sh writes; reader union covers it).
#   b. If a live claim-*.json has gap_id == <input> → ditto.
#   c. Fallback: return .chump-locks/inbox/<input>.jsonl (literal, safe).
#
# Emits kind=a2a_inbox_alias_resolved to ambient when resolution succeeds
# (i.e. not the literal fallback).
resolve_inbox_target() {
    local target="${1:-}"
    [[ -z "$target" ]] && { printf ''; return 1; }

    local lock_dir; lock_dir="$(_ir_lock_dir)"
    local inbox_dir="$lock_dir/inbox"
    local ambient="$lock_dir/ambient.jsonl"

    local f canonical_path="" lease_session lease_gap
    for f in "$lock_dir"/claim-*.json; do
        [[ -f "$f" ]] || continue
        lease_session="$(python3 -c "import json; d=json.load(open('$f')); print(d.get('session_id',''))" 2>/dev/null || true)"
        lease_gap="$(python3 -c "import json; d=json.load(open('$f')); print(d.get('gap_id',''))" 2>/dev/null || true)"
        if [[ "$lease_session" == "$target" ]] || [[ "$lease_gap" == "$target" ]]; then
            canonical_path="$inbox_dir/$lease_session.jsonl"
            local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"ts":"%s","kind":"a2a_inbox_alias_resolved","primary_session":"%s","alias_session":"%s","target_input":"%s","resolved_path":"%s"}\n' \
                "$ts" "$(_ir_primary_session)" "$lease_session" "$target" "$canonical_path" \
                >> "$ambient" 2>/dev/null || true
            break
        fi
    done

    if [[ -z "$canonical_path" ]]; then
        canonical_path="$inbox_dir/$target.jsonl"
    fi

    printf '%s' "$canonical_path"
}
