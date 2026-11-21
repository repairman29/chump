#!/usr/bin/env bash
# scripts/coord/lib/fleet-identity.sh — INFRA-8652
#
# Fleet workers today push and open PRs under whichever identity `gh`/`git`
# already has lying around on the host — in practice the operator's own
# repairman29 login. That means the review organ (also running as that same
# login) can never leave a real APPROVED review on a fleet PR: GitHub refuses
# self-review.
#
# This lib gives fleet workers (bot-merge.sh et al.) a distinct machine
# identity, driven by one env var:
#
#   GH_TOKEN_FLEET   PAT (fine-grained: Contents RW, Pull requests RW,
#                    Metadata R) belonging to the fleet machine account.
#                    See docs/process/FLEET_IDENTITY.md for scopes + rotation.
#
# Usage (source, then call once near the top of a shipping script):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-identity.sh"
#   fleet_identity_init
#
# With GH_TOKEN_FLEET set:
#   - GH_TOKEN is exported to that value, so every subsequent `gh` call
#     (pr create, pr merge, api) authenticates as the machine account.
#   - git user.name/user.email (local repo config only) are set to the
#     machine account's login/noreply email so commits on the branch carry
#     that identity too.
#
# Without GH_TOKEN_FLEET (fallback):
#   - No env/config is touched — behavior is identical to before this gap.
#   - kind=fleet_identity_missing is emitted once per boot (debounced via a
#     sentinel under /tmp, which is cleared on reboot on every target OS).

[[ -n "${_CHUMP_FLEET_IDENTITY_LIB_LOADED:-}" ]] && return 0
_CHUMP_FLEET_IDENTITY_LIB_LOADED=1

_fleet_identity_ambient_log() {
    if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
        printf '%s' "$CHUMP_AMBIENT_LOG"
        return 0
    fi
    local repo_root git_common main_repo
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    git_common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$git_common" == ".git" ]]; then
        main_repo="$repo_root"
    else
        main_repo="$(cd "$git_common/.." 2>/dev/null && pwd || echo "$repo_root")"
    fi
    printf '%s/.chump-locks/ambient.jsonl' "$main_repo"
}

_fleet_identity_emit() {
    local kind="$1"
    local ambient_log; ambient_log="$(_fleet_identity_ambient_log)"
    mkdir -p "$(dirname "$ambient_log")" 2>/dev/null || true
    local json_line
    json_line="$(printf '{"ts":"%s","kind":"%s","script":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "${CHUMP_GH_SCRIPT:-$(basename "${0:-fleet-identity}")}")"
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/ambient-write.sh" ]]; then
        # shellcheck source=./ambient-write.sh
        # shellcheck disable=SC1091
        source "$(dirname "${BASH_SOURCE[0]}")/ambient-write.sh"
        _ambient_write "$ambient_log" "$json_line"
    else
        printf '%s\n' "$json_line" >> "$ambient_log" 2>/dev/null || true
    fi
}

# Once-per-boot debounce. /tmp is tmpfs-or-reaped-on-reboot on every target
# OS this fleet runs on, so an existence check there is an adequate boot
# epoch marker without needing to parse uptime.
_FLEET_IDENTITY_MISSING_SENTINEL="${CHUMP_FLEET_IDENTITY_SENTINEL:-/tmp/.chump-fleet-identity-missing-logged}"

# fleet_identity_init
#   Returns 0 always (never blocks the caller). Sets FLEET_IDENTITY_ACTIVE=1
#   and FLEET_IDENTITY_LOGIN=<login> on success so callers can log/assert.
fleet_identity_init() {
    FLEET_IDENTITY_ACTIVE=0
    FLEET_IDENTITY_LOGIN=""

    if [[ -z "${GH_TOKEN_FLEET:-}" ]]; then
        if [[ ! -e "$_FLEET_IDENTITY_MISSING_SENTINEL" ]]; then
            _fleet_identity_emit "fleet_identity_missing"
            : > "$_FLEET_IDENTITY_MISSING_SENTINEL" 2>/dev/null || true
        fi
        return 0
    fi

    export GH_TOKEN="$GH_TOKEN_FLEET"

    local login email
    login="$(GH_TOKEN="$GH_TOKEN_FLEET" gh api user --jq '.login' 2>/dev/null || true)"
    if [[ -z "$login" ]]; then
        # Token present but unusable (revoked/expired/wrong scopes) — don't
        # pretend we have an identity; leave GH_TOKEN set (gh will surface
        # the real auth error on the next call) but skip the git-config
        # rewrite, since we have no login to attribute commits to.
        return 0
    fi

    email="${login}@users.noreply.github.com"
    git config user.name "$login" 2>/dev/null || true
    git config user.email "$email" 2>/dev/null || true

    FLEET_IDENTITY_ACTIVE=1
    FLEET_IDENTITY_LOGIN="$login"
    return 0
}
