#!/usr/bin/env bash
# resolve-env.sh — RESILIENT-266: find the repo's .env from ANY checkout,
# including a claim worktree.
#
# WHY THIS IS A SHARED FILE AND NOT AN INLINE SNIPPET. The same defect appeared
# THREE times in one evening, in three different scripts:
#
#   1. notify-operator.sh   — escalation alerts SKIPPED SILENTLY from a worktree
#                             (RESILIENT-263). Worst shape: it looked fine in logs.
#   2. install-discord-gateway.sh — refused to install, reporting "DISCORD_TOKEN
#                             is not set" when it was set all along.
#   3. discord-gateway-run.sh     — daemon started, then died with
#                             "DISCORD_TOKEN unset".
#
# The cause is always the same: .env is GITIGNORED, so it lives only in the main
# checkout, while `chump claim` creates a worktree for every gap — so most Chump
# code runs somewhere .env is not. Three inline copies would have become three
# places to fix it a fourth time.
#
# `git rev-parse --git-common-dir` resolves a worktree back to the MAIN .git,
# whose parent directory holds the .env.
#
# Usage:
#   source scripts/coord/lib/resolve-env.sh
#   chump_env_file            # prints the first .env found, or nothing
#   chump_env_get DISCORD_TOKEN   # prints the value, or nothing. Never logs it.
#   chump_env_load            # exports everything in that .env
#
# shellcheck shell=bash

_chump_env_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd
}

# Candidate locations, most-specific first.
chump_env_files() {
    local root common
    root="${REPO_ROOT:-$(_chump_env_root)}"
    [[ -n "$root" ]] && printf '%s\n' "$root/.env"
    [[ -n "${CHUMP_HOME:-}" ]] && printf '%s\n' "${CHUMP_HOME}/.env"
    common="$(git -C "${root:-.}" rev-parse --git-common-dir 2>/dev/null)" || true
    if [[ -n "$common" ]]; then
        [[ "$common" != /* ]] && common="${root}/${common}"
        printf '%s\n' "$(dirname "$common")/.env"
    fi
}

chump_env_file() {
    local f
    while read -r f; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done < <(chump_env_files)
    return 1
}

# Read one key. Process environment wins. NEVER echoes to a log — callers that
# want to report presence must report the NAME, never the value.
chump_env_get() {
    local key="$1" f val
    val="${!key:-}"
    if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
    while read -r f; do
        [[ -f "$f" ]] || continue
        val="$(grep -m1 "^${key}=" "$f" 2>/dev/null \
            | cut -d= -f2- \
            | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/[[:space:]]*$//')"
        [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
    done < <(chump_env_files)
    return 1
}

# Export every var from the resolved .env. Returns non-zero if none was found,
# so a caller can fail loudly instead of running credential-less.
chump_env_load() {
    local f
    f="$(chump_env_file)" || return 1
    set -a
    # shellcheck disable=SC1090
    source "$f" 2>/dev/null || true
    set +a
    return 0
}
