#!/usr/bin/env bash
# META-163: curator-sentinel — producer side for META-158 fan-out-to-inbox.
#
# Every curator loop sources this lib and calls `_create_curator_sentinel
# <role>` at startup + `_setup_sentinel_trap <role>` so that the file
# `.chump-locks/.curator-opus-<role>.lock` exists for as long as the
# curator is alive. Once these sentinel files exist, broadcast.sh's
# META-158 FEEDBACK fan-out path can glob them and deliver proposals to
# each live curator's inbox.
#
# Without producers, every fan-out broadcast fires `feedback_fanout_skipped
# reason=no_curator_locks` (HONEST EMPTY DELIVERY). This lib is the
# missing complement to META-158 — discovered during 2026-05-30 wave 1
# meta-recursive proof attempt.
#
# Lifecycle:
#   1. curator-loop starts; sources this lib
#   2. _create_curator_sentinel <role>  → touches sentinel; writes PID
#   3. _setup_sentinel_trap <role>      → installs EXIT/INT/TERM handler
#   4. broadcast.sh fan-out greps .curator-opus-*.lock → finds this curator
#   5. curator-loop exits (any reason); trap fires _remove_curator_sentinel
#
# Idempotent: _create is safe to call repeatedly (just updates mtime so the
# stale-sentinel reaper considers the curator alive).
#
# Stale recovery: a separate launchd reaper (filed as META-164 follow-up)
# removes any .curator-opus-*.lock whose PID is dead OR mtime > 30 min.

# Resolve repo root and lock dir consistently with the rest of the coord
# tooling. Allow CHUMP_LOCK_DIR override for test isolation.
_chump_sentinel_lock_dir() {
    local override="${CHUMP_LOCK_DIR:-}"
    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    local repo
    repo="$(git -C "${BASH_SOURCE[0]%/*}" rev-parse --show-toplevel 2>/dev/null \
        || git rev-parse --show-toplevel 2>/dev/null \
        || pwd)"
    printf '%s/.chump-locks\n' "$repo"
}

# Validate role name: only [a-z0-9-] allowed so we don't open a glob/path
# injection vector when broadcast.sh later uses the basename in fan-out.
_chump_sentinel_valid_role() {
    [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]
}

# _create_curator_sentinel <role>
#   Touch + PID-write the sentinel file for <role>. Idempotent.
#   Returns 0 on success, 1 if role name invalid, 2 if lock_dir not writable.
_create_curator_sentinel() {
    local role="${1:-}"
    if ! _chump_sentinel_valid_role "$role"; then
        printf '[curator-sentinel] WARN: invalid role name "%s" (need [a-z][a-z0-9-]*)\n' "$role" >&2
        return 1
    fi
    local lock_dir
    lock_dir="$(_chump_sentinel_lock_dir)"
    if ! mkdir -p "$lock_dir" 2>/dev/null; then
        printf '[curator-sentinel] WARN: cannot mkdir %s\n' "$lock_dir" >&2
        return 2
    fi
    local sentinel="$lock_dir/.curator-opus-${role}.lock"
    # Touch + PID for stale-reaper discovery. Overwrite OK on idempotent
    # reentry (same role re-claiming after a crash or restart).
    printf '%s\n' "$$" > "$sentinel" 2>/dev/null || {
        printf '[curator-sentinel] WARN: cannot write %s\n' "$sentinel" >&2
        return 2
    }
    # Emit observable event for the deliberator and operator dashboards.
    local ambient="$lock_dir/ambient.jsonl"
    printf '{"ts":"%s","kind":"curator_sentinel_created","role":"%s","pid":%d,"session":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$role" "$$" "${CHUMP_SESSION_ID:-curator-opus-$role}" \
        >> "$ambient" 2>/dev/null || true
    return 0
}

# _remove_curator_sentinel <role>
#   Remove the sentinel file for <role>. Safe to call when missing.
_remove_curator_sentinel() {
    local role="${1:-}"
    if ! _chump_sentinel_valid_role "$role"; then
        return 1
    fi
    local lock_dir
    lock_dir="$(_chump_sentinel_lock_dir)"
    local sentinel="$lock_dir/.curator-opus-${role}.lock"
    if [[ -e "$sentinel" ]]; then
        rm -f "$sentinel" 2>/dev/null || true
        local ambient="$lock_dir/ambient.jsonl"
        printf '{"ts":"%s","kind":"curator_sentinel_removed","role":"%s","pid":%d,"session":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$role" "$$" "${CHUMP_SESSION_ID:-curator-opus-$role}" \
            >> "$ambient" 2>/dev/null || true
    fi
    return 0
}

# _setup_sentinel_trap <role>
#   Install an EXIT trap that removes the sentinel on any normal or
#   signal-induced exit. Idempotent — re-calling chains traps cleanly.
_setup_sentinel_trap() {
    local role="${1:-}"
    if ! _chump_sentinel_valid_role "$role"; then
        return 1
    fi
    # Preserve any existing EXIT handler (chain rather than clobber).
    local existing
    existing="$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
    if [[ -n "$existing" ]]; then
        # shellcheck disable=SC2064
        trap "_remove_curator_sentinel '$role'; $existing" EXIT
    else
        # shellcheck disable=SC2064
        trap "_remove_curator_sentinel '$role'" EXIT
    fi
    trap "_remove_curator_sentinel '$role'; exit 130" INT
    trap "_remove_curator_sentinel '$role'; exit 143" TERM
    return 0
}

# _curator_sentinel_alive <role>
#   Helper used by stale-reaper (META-164 follow-up) and ad-hoc operator
#   checks: returns 0 if the sentinel exists AND its PID is still alive.
_curator_sentinel_alive() {
    local role="${1:-}"
    if ! _chump_sentinel_valid_role "$role"; then
        return 1
    fi
    local lock_dir
    lock_dir="$(_chump_sentinel_lock_dir)"
    local sentinel="$lock_dir/.curator-opus-${role}.lock"
    [[ -e "$sentinel" ]] || return 1
    local pid
    pid="$(head -1 "$sentinel" 2>/dev/null)"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}
