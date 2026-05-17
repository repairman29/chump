#!/usr/bin/env bash
# ensure-debug-chump.sh — INFRA-1602
#
# Shared helper for scripts/ci/test-*.sh that need a built chump (or sibling)
# debug binary. Resolves the binary path with this lookup order:
#
#   1. $CHUMP_BIN env var (if set and executable) — operator/CI override
#   2. $REPO_ROOT/target/debug/<bin> (where REPO_ROOT is repo top); if missing,
#      runs `cargo build --bin <bin>` honoring $CARGO_TARGET_DIR (fleet shared
#      cache) and re-checks. CARGO_TARGET_DIR overrides target/debug location.
#   3. PATH fallback via `command -v <bin>`
#
# On success: prints the resolved absolute path to stdout, AND (for the default
# `chump` binary) exports CHUMP_BIN so downstream code can read it.
# On failure: exits 1 with a diagnostic message on stderr.
#
# Why this matters (INFRA-1602):
#   Ubuntu-latest CI runners carry a cargo target cache from prior runs, so
#   ./target/debug/chump exists before the test scripts run. M4 self-hosted
#   runners ("actions-runner-chump-3") have a fresh workspace per job and the
#   binary is missing. Without this helper, ~10 CI scripts fail with
#   "FAIL: chump binary not found at .../target/debug/chump". (See PR #2268.)
#
# Usage (test script header):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck disable=SC1091
#   source "$SCRIPT_DIR/lib/ensure-debug-chump.sh"
#   ensure_debug_chump                # default: chump → exports CHUMP_BIN
#   "$CHUMP_BIN" --version
#
# Or for a non-default binary:
#   MCP_COORD_BIN="$(ensure_debug_chump chump-mcp-coord)"
#   "$MCP_COORD_BIN" < input.json

# Guard against being executed directly with no function call — this file is
# meant to be sourced. Allow direct invocation for the smoke test which calls
# with an arg.
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [[ $# -eq 0 ]]; then
    echo "ensure-debug-chump.sh: this script is meant to be sourced, not executed directly" >&2
    echo "  source $(basename "$0"); ensure_debug_chump [bin-name]" >&2
    exit 2
fi

# Internal: find cargo target-dir. Honors .cargo/config.toml [build] target-dir
# (INFRA-481 shared-target pattern), falls back to $repo_root/target.
_ensure_chump_resolve_target_dir() {
    local repo_root="$1"
    # Walk up from repo_root looking for .cargo/config.toml with target-dir.
    # Cargo itself walks up so we mirror that here.
    local dir="$repo_root"
    while [[ "$dir" != "/" ]] && [[ -n "$dir" ]]; do
        local cfg="$dir/.cargo/config.toml"
        if [[ -f "$cfg" ]]; then
            local td
            td="$(grep -E '^[[:space:]]*target-dir[[:space:]]*=' "$cfg" 2>/dev/null \
                | head -n1 | sed -E 's/^[^=]*=[[:space:]]*"([^"]+)".*/\1/')"
            if [[ -n "$td" ]]; then
                echo "$td"
                return 0
            fi
        fi
        dir="$(dirname "$dir")"
    done
    echo "$repo_root/target"
}

ensure_debug_chump() {
    local bin_name="${1:-chump}"
    local repo_root
    repo_root="${ENSURE_CHUMP_REPO_ROOT:-}"
    if [[ -z "$repo_root" ]]; then
        # Resolve relative to this lib file: scripts/ci/lib/ → repo root
        local lib_dir
        lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        repo_root="$(cd "$lib_dir/../../.." && pwd)"
    fi

    # Step 1: env override
    if [[ "$bin_name" == "chump" ]] && [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "${CHUMP_BIN}" ]]; then
        # CHUMP_BIN only applies to the default chump binary (semantic match)
        echo "$CHUMP_BIN"
        return 0
    fi

    # Step 2: target/debug/<bin>
    #
    # Resolve target dir, honoring:
    #   - $CARGO_TARGET_DIR env (highest)
    #   - .cargo/config.toml [build] target-dir (e.g. INFRA-481 shared target)
    #   - default $repo_root/target
    local target_dir
    target_dir="${CARGO_TARGET_DIR:-}"
    if [[ -z "$target_dir" ]]; then
        target_dir="$(_ensure_chump_resolve_target_dir "$repo_root")"
    fi
    local candidate="$target_dir/debug/$bin_name"

    if [[ ! -x "$candidate" ]]; then
        # Build it
        if ! command -v cargo >/dev/null 2>&1; then
            echo "ensure-debug-chump: cargo not on PATH and $candidate missing" >&2
            # Step 3 fallback before giving up
            local on_path
            on_path="$(command -v "$bin_name" 2>/dev/null || true)"
            if [[ -n "$on_path" ]] && [[ -x "$on_path" ]]; then
                [[ "$bin_name" == "chump" ]] && export CHUMP_BIN="$on_path"
                echo "$on_path"
                return 0
            fi
            return 1
        fi

        echo "ensure-debug-chump: building $bin_name (target dir: $target_dir)" >&2
        if ! ( cd "$repo_root" && cargo build --bin "$bin_name" >&2 ); then
            echo "ensure-debug-chump: cargo build --bin $bin_name failed" >&2
            return 1
        fi
    fi

    if [[ ! -x "$candidate" ]]; then
        echo "ensure-debug-chump: build reported success but $candidate still missing at $candidate" >&2
        return 1
    fi

    # Verify it actually runs (only for chump itself — other bins may not
    # support --version uniformly)
    if [[ "$bin_name" == "chump" ]]; then
        if ! "$candidate" --version >/dev/null 2>&1; then
            echo "ensure-debug-chump: $candidate --version failed; binary is broken" >&2
            return 1
        fi
        export CHUMP_BIN="$candidate"
    fi

    echo "$candidate"
    return 0
}

# If invoked directly with a binary name (smoke-test convenience), resolve and
# print. Sourced callers should call the function themselves.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ensure_debug_chump "$@"
fi
