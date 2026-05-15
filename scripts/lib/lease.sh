#!/usr/bin/env bash
# scripts/lib/lease.sh — INFRA-1212
#
# Shared reader for `.chump-locks/*.json` lease files. Replaces 8 ad-hoc
# parsers across the reaper / scanner / driver scripts. Keeps the parsers
# in ONE place so when the lease JSON schema gains a field, every consumer
# picks it up consistently.
#
# Usage: source scripts/lib/lease.sh
#
# Public API
#   lease_dir [--repo <path>]            echo the canonical lease dir
#   lease_iter [--repo <path>]           emit one lease file path per line
#   lease_field <path> <field>           echo a string field value (empty if absent)
#   lease_int_field <path> <field>       echo an integer field value (empty if absent)
#   lease_heartbeat_age_s <path>         seconds since heartbeat_at (or 0 if missing)
#   lease_is_fresh <path> [grace_s=900]  return 0 iff heartbeat is within grace
#   lease_is_expired <path> [grace_s=30] return 0 iff expires_at is past now+grace
#   lease_session_id <path>              shortcut for `lease_field … session_id`
#   lease_gap_id <path>                  shortcut for `lease_field … gap_id`
#   lease_worktree <path>                shortcut for `lease_field … worktree`
#
# Implementation notes
# - Parsers grep-based on purpose: jq is not always present on minimal CI
#   images / fresh CCR sandboxes. We do however fall back to jq when it
#   IS available because it handles deeply-quoted strings correctly.
# - All functions are read-only. No writer is exposed — leases are written
#   by atomic_claim::write_basic_lease + write_or_merge_lease (Rust). This
#   library is for consumers only.

# Idempotent guard.
if [[ -n "${__CHUMP_LIB_LEASE_LOADED:-}" ]]; then return 0; fi
__CHUMP_LIB_LEASE_LOADED=1

# ── Helpers ──────────────────────────────────────────────────────────────────

# Echo the canonical .chump-locks dir for the given repo (default: cwd's repo).
lease_dir() {
    local repo=""
    if [[ "${1:-}" == "--repo" && -n "${2:-}" ]]; then repo="$2"; shift 2; fi
    if [[ -z "$repo" ]]; then
        repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    printf '%s\n' "${CHUMP_LOCK_DIR:-$repo/.chump-locks}"
}

# Iterate all lease files in the canonical lease dir. Skips ambient.jsonl
# and the cooldown/ subdir which are not lease files.
lease_iter() {
    local dir; dir="$(lease_dir "$@")"
    [[ -d "$dir" ]] || return 0
    # Use nullglob-safe iteration via find — handles the empty-dir case.
    find "$dir" -maxdepth 1 -type f -name '*.json' \
        ! -name 'ambient.jsonl' 2>/dev/null
}

# Generic field extractor. Prefers jq when available; falls back to a
# grep + sed pattern that matches the canonical pretty-printed shape
# written by atomic_claim::write_basic_lease + write_or_merge_lease.
lease_field() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$field" '.[$f] // empty' "$path" 2>/dev/null
        return
    fi
    grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$path" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# Integer field extractor — matches { "field": 1234 } (no quotes).
lease_int_field() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$field" '.[$f] // empty' "$path" 2>/dev/null
        return
    fi
    grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*-?[0-9]+" "$path" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*(-?[0-9]+).*/\1/"
}

# Convenience shortcuts.
lease_session_id() { lease_field "$1" session_id; }
lease_gap_id()     { lease_field "$1" gap_id; }
lease_worktree()   { lease_field "$1" worktree; }

# Heartbeat age in seconds since `heartbeat_at`. Returns -1 if absent
# or unparseable (INFRA-1356: was 0, which collided with the legitimate
# age=0 case when a heartbeat is written and immediately re-read).
lease_heartbeat_age_s() {
    local path="$1"
    local hb; hb="$(lease_field "$path" heartbeat_at)"
    [[ -z "$hb" ]] && { printf '%s\n' "-1"; return; }
    # ISO8601 like "2026-05-14T07:21:50Z" — strip trailing Z, parse as UTC.
    local hb_epoch
    if hb_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${hb%Z}" +%s 2>/dev/null)"; then
        :
    elif hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null)"; then
        :
    else
        printf '%s\n' "-1"; return
    fi
    local now; now="$(date -u +%s)"
    printf '%d\n' "$(( now - hb_epoch ))"
}

# Return 0 iff heartbeat_at is within `grace_s` seconds (default 900 = 15 min).
# Mirrors the INFRA-1074 reaper safety threshold.
# INFRA-1356: age=0 (heartbeat just written) is now correctly treated as fresh.
# age=-1 means missing/unparseable heartbeat → stale.
lease_is_fresh() {
    local path="$1" grace="${2:-900}"
    local age; age="$(lease_heartbeat_age_s "$path")"
    [[ "$age" != "-1" ]] || return 1   # missing/parse-failed heartbeat == not fresh
    [[ "$age" -le "$grace" ]]
}

# Return 0 iff expires_at is in the past (with `grace_s` slack, default 30s).
lease_is_expired() {
    local path="$1" grace="${2:-30}"
    local exp; exp="$(lease_field "$path" expires_at)"
    [[ -z "$exp" ]] && return 1   # no expiry == not expired
    local exp_epoch
    if exp_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${exp%Z}" +%s 2>/dev/null)"; then
        :
    elif exp_epoch="$(date -u -d "$exp" +%s 2>/dev/null)"; then
        :
    else
        return 1
    fi
    local now; now="$(date -u +%s)"
    [[ "$now" -gt "$(( exp_epoch + grace ))" ]]
}
