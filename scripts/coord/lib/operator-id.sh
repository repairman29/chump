#!/usr/bin/env bash
# scripts/coord/lib/operator-id.sh — INFRA-1297
#
# Stable operator identity for the two-way A2A comms chain.
# Without this, every PWA tab is a fresh session ID and the operator
# can't have a durable inbox or filter rules.
#
# Resolution order:
#   1. $CHUMP_OPERATOR_ID env var (explicit override)
#   2. .chump/operator_id (per-repo) — set by `chump init` or first PWA load
#   3. ~/.chump/operator_id (per-user, machine-wide fallback)
#   4. Generate: operator-<8-char-uuid>, persist to both files
#
# The operator-id is a STABLE identifier; per-tab session IDs are children
# (e.g. operator-abc12345.tab-1778800000). Inbox path: $LOCK_DIR/inbox/<operator-id>.jsonl.

[[ -n "${_CHUMP_OPERATOR_ID_LOADED:-}" ]] && return 0
_CHUMP_OPERATOR_ID_LOADED=1

_operator_id_repo_path() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump/operator_id' "$root"
}

_operator_id_home_path() {
    printf '%s/.chump/operator_id' "${HOME:-/tmp}"
}

# Generate a stable id: operator-<8hex>. Short enough to type, long enough
# to avoid collisions across a few thousand operators on shared machines.
_operator_id_generate() {
    local raw
    if command -v uuidgen >/dev/null 2>&1; then
        raw="$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | head -c 8)"
    else
        raw="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:8])')"
    fi
    printf 'operator-%s' "$raw"
}

# Public: emits the resolved operator-id to stdout. Creates the file(s)
# on first call so future invocations are stable.
operator_id() {
    if [[ -n "${CHUMP_OPERATOR_ID:-}" ]]; then
        printf '%s' "$CHUMP_OPERATOR_ID"
        return 0
    fi
    local repo_path home_path id
    repo_path="$(_operator_id_repo_path)"
    home_path="$(_operator_id_home_path)"
    if [[ -f "$repo_path" ]]; then
        id="$(head -c 64 "$repo_path" | tr -d '[:space:]')"
        [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
    fi
    if [[ -f "$home_path" ]]; then
        id="$(head -c 64 "$home_path" | tr -d '[:space:]')"
        if [[ -n "$id" ]]; then
            # Backfill repo path so future calls are repo-stable too.
            mkdir -p "$(dirname "$repo_path")" 2>/dev/null || true
            printf '%s' "$id" > "$repo_path" 2>/dev/null || true
            printf '%s' "$id"
            return 0
        fi
    fi
    # Generate fresh.
    id="$(_operator_id_generate)"
    mkdir -p "$(dirname "$repo_path")" 2>/dev/null || true
    mkdir -p "$(dirname "$home_path")" 2>/dev/null || true
    printf '%s' "$id" > "$repo_path" 2>/dev/null || true
    printf '%s' "$id" > "$home_path" 2>/dev/null || true
    printf '%s' "$id"
}
