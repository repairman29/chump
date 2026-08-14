#!/usr/bin/env bash
# scripts/coord/lib/test-sandbox.sh — INFRA-2088
#
# Single canonical sandbox primitive for CI test scripts that need to run
# `chump` commands against an isolated state.db instead of the real repo's.
#
# Why this exists: INFRA-2080 showed that hand-rolled sandbox setup (each
# test script picking its own subset of CHUMP_HOME / CHUMP_REPO /
# CHUMP_REPO_ROOT / CHUMP_STATE_DB / CHUMP_LOCK_DIR) drifts — one script
# forgets a var, `chump` falls through to the real repo's state.db, and a
# "test" gap lands in production data. This file is the one place that
# knows "which env vars fully isolate a chump invocation from the real
# state.db" — when a new one is added, fix it here once and every test
# that sources this file inherits the fix.
#
# Usage (in a CI test script):
#
#     # shellcheck source=scripts/coord/lib/test-sandbox.sh
#     source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
#
#     chump_test_sandbox_setup "$SANDBOX" --seed-yaml "$FIXTURE_YAML"
#     ( cd "$SANDBOX" && chump gap reserve --domain FOO --title "..." )
#     chump_test_sandbox_cleanup "$SANDBOX"
#
# chump_test_sandbox_setup writes the isolation env vars into a file at
# "$sandbox/.chump-test-sandbox-env" and also exports them into the calling
# shell, so both `source`d callers and subshells (`( cd "$sandbox" && ... )`)
# pick them up without re-deriving the list.

set -uo pipefail

# The single source of truth: every env var that must be set for a `chump`
# invocation to be fully isolated from the real repo's state.db, leases,
# and ambient stream. Add new vars here (and ONLY here) as chump grows new
# state-carrying env vars.
chump_test_sandbox_env_vars() {
    local sandbox="$1"
    cat <<EOF
CHUMP_HOME=$sandbox
CHUMP_REPO=$sandbox
CHUMP_REPO_ROOT=$sandbox
CHUMP_STATE_DB=$sandbox/.chump/state.db
CHUMP_LOCK_DIR=$sandbox/.chump-locks
EOF
}

# chump_test_sandbox_setup <sandbox-dir> [--seed-yaml <fixture-yaml-path>]
#
# Creates sandbox-dir with a `.chump/state.db`, seeded from --seed-yaml
# (via `chump gap import`) when given. Exports the isolation env vars into
# the calling shell.
chump_test_sandbox_setup() {
    local sandbox="$1"
    shift
    local seed_yaml=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --seed-yaml)
                seed_yaml="$2"
                shift 2
                ;;
            *)
                echo "chump_test_sandbox_setup: unknown arg: $1" >&2
                return 2
                ;;
        esac
    done

    mkdir -p "$sandbox/.chump" "$sandbox/.chump-locks" "$sandbox/docs"

    local env_file="$sandbox/.chump-test-sandbox-env"
    chump_test_sandbox_env_vars "$sandbox" > "$env_file"

    # Export into the calling shell (this function runs in the caller's
    # process because callers `source` this file — no subshell here).
    local line key val
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        export "$key=$val"
    done < "$env_file"

    if [[ -n "$seed_yaml" ]]; then
        if [[ ! -f "$seed_yaml" ]]; then
            echo "chump_test_sandbox_setup: --seed-yaml file not found: $seed_yaml" >&2
            return 1
        fi
        if [[ "$(cd "$(dirname "$seed_yaml")" && pwd)/$(basename "$seed_yaml")" != "$sandbox/docs/gaps.yaml" ]]; then
            cp "$seed_yaml" "$sandbox/docs/gaps.yaml"
        fi
        local chump_bin="${CHUMP_TEST_SANDBOX_BIN:-chump}"
        CHUMP_HOME="$sandbox" \
        CHUMP_REPO="$sandbox" \
        CHUMP_REPO_ROOT="$sandbox" \
        CHUMP_GAP_IMPORT_NO_SIMILARITY=1 \
        "$chump_bin" gap import --yaml "$sandbox/docs/gaps.yaml" >/dev/null 2>&1
    fi
}

# chump_test_sandbox_cleanup <sandbox-dir>
#
# Removes the sandbox atomically and unsets the isolation env vars this
# helper exported, so a script that sets up multiple sandboxes in
# sequence doesn't leak a prior sandbox's env into the next one.
chump_test_sandbox_cleanup() {
    local sandbox="$1"
    local key
    while IFS='=' read -r key _; do
        [[ -n "$key" ]] && unset "$key"
    done < <(chump_test_sandbox_env_vars "$sandbox")
    rm -rf "$sandbox"
}
