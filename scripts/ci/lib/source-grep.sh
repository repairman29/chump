#!/usr/bin/env bash
# scripts/ci/lib/source-grep.sh — INFRA-1214
#
# Helper functions for CI tests that need to locate Rust source files
# and grep for kind= emission patterns. Eliminates repeated if/else
# fallback blocks that break when crate layout changes.
#
# Usage (source this file from any CI test):
#   source "$(dirname "$0")/lib/source-grep.sh"
#   GAP_STORE=$(find_gap_store_path)
#   find_kind_emission "gap_id_allocator_collision_avoided"
#
# REPO_ROOT must be set before sourcing (or it defaults to git toplevel).

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# find_gap_store_path — returns canonical path to the gap store Rust source.
# Checks crates/chump-gap-store/src/lib.rs first (post-INFRA-693 layout),
# falls back to src/gap_store.rs for older checkouts.
find_gap_store_path() {
    local crate_path="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
    local legacy_path="$REPO_ROOT/src/gap_store.rs"
    if [[ -f "$crate_path" ]]; then
        echo "$crate_path"
    elif [[ -f "$legacy_path" ]]; then
        echo "$legacy_path"
    else
        echo "$legacy_path"  # return expected path even if missing (caller decides)
    fi
}

# find_rust_module <name> — locate a Rust module file anywhere under src/ or crates/.
# Returns the first matching path, or empty string if not found.
# Example: find_rust_module "atomic_claim" → src/atomic_claim.rs or crates/.../atomic_claim.rs
find_rust_module() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    # Normalize: strip .rs suffix if provided
    name="${name%.rs}"
    local result
    result=$(find "$REPO_ROOT/src" "$REPO_ROOT/crates" -name "${name}.rs" 2>/dev/null | head -1)
    echo "$result"
}

# find_kind_emission <kind> — grep src/ + crates/ for ambient event emission of <kind>.
# Matches: kind="X", kind='X', "kind":"X", 'kind=X', kind=X (shell printf patterns).
# Returns 0 (success) if found, 1 if not found.
# Prints matching file:line entries to stdout.
find_kind_emission() {
    local kind="$1"
    [[ -z "$kind" ]] && { echo "Usage: find_kind_emission <kind>" >&2; return 2; }
    local found=0
    # Grep across Rust source and shell coord scripts for the kind string.
    while IFS= read -r match; do
        echo "$match"
        found=1
    done < <(grep -rn \
        -e "\"kind\":\"${kind}\"" \
        -e "\"kind\": \"${kind}\"" \
        -e "kind=\"${kind}\"" \
        -e "kind='${kind}'" \
        -e "kind=${kind}" \
        "$REPO_ROOT/src" "$REPO_ROOT/crates" "$REPO_ROOT/scripts/coord" \
        2>/dev/null)
    return $(( 1 - found ))
}
