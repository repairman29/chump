#!/bin/sh
# scripts/coord/lib/lease.sh
#
# Shared logic for locating and parsing chump lease/claim files
# (.chump-locks/claim-*.json). Consolidates redundant jq/grep parsers
# identified in META-063.

# get_active_claim_file [root]
#   Returns the path to the first claim-*.json found in .chump-locks.
get_active_claim_file() {
    local root="${1:-${REPO_ROOT:-.}}"
    find "$root/.chump-locks" -maxdepth 1 -name 'claim-*.json' 2>/dev/null | head -1
}

# parse_lease_field <file> <field>
#   Extracts a top-level field from a lease JSON file.
parse_lease_field() {
    local file="${1:?parse_lease_field <file> <field>}"
    local field="${2:?parse_lease_field <file> <field>}"
    if [ ! -f "$file" ]; then return 1; fi
    jq -r ".$field // empty" "$file" 2>/dev/null
}

# get_claimed_gap [file]
#   Returns the gap_id from the given file (or auto-locates the active claim).
get_claimed_gap() {
    local file="$1"
    if [ -z "$file" ]; then
        file=$(get_active_claim_file)
    fi
    [ -n "$file" ] && parse_lease_field "$file" "gap_id"
}

# get_claim_paths [file]
#   Returns the paths[] array from the given file, one per line.
get_claim_paths() {
    local file="$1"
    if [ -z "$file" ]; then
        file=$(get_active_claim_file)
    fi
    if [ -n "$file" ] && [ -f "$file" ]; then
        jq -r '.paths[]? // empty' "$file" 2>/dev/null | grep -v '^$' || true
    fi
}
