#!/usr/bin/env bash
# publish-crates.sh — orchestrate `cargo publish` across the workspace.
#
# Why: 10 publishable crates × remembering the order × remembering to dry-
# run first × catching the failure that aborts the rest = a tedious manual
# process you only do every few releases. This script does it for you.
#
# Usage:
#   scripts/publish-crates.sh                      # dry-run only (default — safe)
#   scripts/publish-crates.sh --execute            # actually publish (after dry-run passes)
#   scripts/publish-crates.sh --only chump-perception   # one crate, dry-run
#   scripts/publish-crates.sh --only chump-perception --execute
#
# Order:
#   Crates are published in the order listed below. For chump's workspace,
#   no crate depends on another (each is independent), so the order is just
#   "smallest/lowest-risk first" — if something breaks early, it's a metadata
#   issue not a dep issue.
#
# Behavior:
#   - dry-run: cargo publish --dry-run -p <name>; print PASS / FAIL
#   - execute: cargo publish -p <name>; halt on first failure (publish is
#     irreversible — don't keep going if one fails)
#   - skips crates that are already published at the current version
#     (crates.io rejects re-publish of the same version)
#
# Auth: assumes `cargo login` has been run with a crates.io API token.

set -euo pipefail

# ── publishable list (order doesn't matter for chump — no inter-deps) ───
CRATES=(
    chump-tool-macro
    chump-cancel-registry
    chump-cost-tracker
    chump-perception
    chump-messaging
    chump-mcp-lifecycle
    chump-mcp-github
    chump-mcp-tavily
    chump-mcp-adb
    chump-agent-lease
)

DRY_RUN=1
ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)  DRY_RUN=0 ;;
        --only)     ONLY="$2"; shift ;;
        -h|--help)
            sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$REPO_ROOT" ]] || { echo "error: not in a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

# ANSI colors when stdout is a tty
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "${BOLD}=== publish-crates.sh DRY RUN ===${RESET}"
    echo "${DIM}Pass --execute to actually publish.${RESET}"
else
    echo "${BOLD}=== publish-crates.sh EXECUTE — will upload to crates.io ===${RESET}"
    if [[ -z "${CARGO_REGISTRY_TOKEN:-}" ]] && [[ ! -f "$HOME/.cargo/credentials.toml" ]]; then
        echo "${RED}error:${RESET} no cargo credentials. Run \`cargo login\` first."
        exit 2
    fi
fi
echo

# ── helpers ────────────────────────────────────────────────────────────
crate_local_version() {
    local name="$1"
    local toml
    toml=$(find . -maxdepth 5 -name Cargo.toml -path "*/$name/Cargo.toml" 2>/dev/null \
        | head -1)
    [[ -z "$toml" ]] && return 1
    grep -E '^version\s*=' "$toml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

crate_published_version() {
    local name="$1"
    curl -sf "https://crates.io/api/v1/crates/$name" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('crate',{}).get('max_version','—'))" 2>/dev/null \
        || echo "—"
}

# ── per-crate work ─────────────────────────────────────────────────────
publish_one() {
    local name="$1"

    local local_v published_v
    local_v=$(crate_local_version "$name") || {
        printf "  %-25s %s\n" "$name" "${RED}MISSING${RESET} (no Cargo.toml)"
        return 1
    }
    published_v=$(crate_published_version "$name")

    if [[ "$local_v" == "$published_v" ]]; then
        printf "  %-25s %s\n" "$name" "${DIM}skip — v$local_v already on crates.io${RESET}"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf "  %-25s " "$name"
        if cargo publish --dry-run -p "$name" --allow-dirty > /tmp/publish-$name.log 2>&1; then
            printf "${GREEN}PASS${RESET}  v$local_v (would replace v$published_v on crates.io)\n"
        else
            printf "${RED}FAIL${RESET}  v$local_v — see /tmp/publish-$name.log\n"
            tail -10 /tmp/publish-$name.log | sed 's/^/    /'
            return 1
        fi
    else
        printf "  %-25s " "$name"
        echo
        if cargo publish -p "$name"; then
            printf "  %-25s ${GREEN}PUBLISHED${RESET} v$local_v\n" "$name"
        else
            echo "${RED}error:${RESET} publish failed for $name. Halting (publish is irreversible)." >&2
            return 1
        fi
    fi
    return 0
}

# ── main loop ──────────────────────────────────────────────────────────
fail_count=0
pub_count=0
skip_count=0

for c in "${CRATES[@]}"; do
    [[ -n "$ONLY" && "$ONLY" != "$c" ]] && continue
    if publish_one "$c"; then
        local_v=$(crate_local_version "$c")
        published_v=$(crate_published_version "$c")
        if [[ "$local_v" == "$published_v" ]]; then
            skip_count=$((skip_count + 1))
        else
            pub_count=$((pub_count + 1))
        fi
    else
        fail_count=$((fail_count + 1))
        if [[ $DRY_RUN -eq 0 ]]; then
            echo
            echo "${RED}halting — publish failures should be investigated before continuing.${RESET}"
            exit 1
        fi
    fi
done

echo
echo "${BOLD}── summary ──${RESET}"
echo "  pub:    $pub_count"
echo "  skip:   $skip_count (already at this version)"
echo "  fail:   $fail_count"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "${DIM}Re-run with --execute to actually publish.${RESET}"
    [[ $fail_count -gt 0 ]] && exit 1
fi
exit 0
