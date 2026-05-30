#!/usr/bin/env bash
# scripts/coord/md-links-loop.sh — Chump curator-opus-md-links role CLI (harness-neutral)
#
# Productizes the curator-opus-md-links role per INFRA-1925 + META-097.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/md-links.md + .claude/skills/md-links/
# wrappers delegate here; they are convenience, not capability.
#
# Role: scan docs/**/*.md for broken internal cross-references, stale gap
# references, and (opt-in) broken external URLs. File follow-up gaps for
# cohorts of broken links. Emit heartbeat.
#
# Rust-First-Bypass: glue between grep + bash + chump CLI; <200 LOC at first
# commit; read-only (no state mutation beyond ambient.jsonl emit lines which
# are already append-idempotent). Will be ported to Rust as part of a
# follow-up if the surface grows past the shell-OK criteria.
#
# Usage:
#   scripts/coord/md-links-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick                 One fast-scan cycle (docs/process/*.md). Prints
#                        BROKEN/STALE items found. Exit 0 if items found,
#                        exit 1 if clean, exit 2 on bad input.
#   scan [path]          Full scan of <path> (default: docs/). Prints
#                        BROKEN/STALE items. Same exit codes as tick.
#   heartbeat            Emit kind=md_links_heartbeat to ambient.jsonl.
#                        Exit 0 always.
#   help                 Print this help.
#
# Exit codes:
#   0 — actionable: broken/stale links found (tick/scan) OR heartbeat ok
#   1 — clean: no broken/stale links found
#   2 — bad subcommand or missing required arg
#   3 — docs directory not found
#
# Env:
#   CHUMP_SESSION_ID     session id used for ambient emits (default: md-links-<pid>)
#   CHUMP_AMBIENT_LOG    ambient.jsonl path override
#   CHUMP_MD_LINKS_DOCS  override default docs root (default: $REPO_ROOT/docs)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-md-links-$$}"
DOCS_ROOT="${CHUMP_MD_LINKS_DOCS:-$REPO_ROOT/docs}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Helpers ───────────────────────────────────────────────────────────────────

_emit() {
    # _emit kind [extra_json_fields...]
    local kind="$1"; shift
    local extras=""
    for kv in "$@"; do extras="$extras, $kv"; done
    printf '{"ts":"%s","kind":"%s","session":"%s"%s}\n' \
        "$(_now_iso)" "$kind" "$SESSION_ID" "$extras" \
        >> "$AMBIENT" 2>/dev/null || true
}
# scanner-anchor: "kind":"md_links_heartbeat"
# scanner-anchor: "kind":"md_links_scan_done"
# scanner-anchor: "kind":"md_links_lane_override"

_resolve_anchor() {
    # Check whether $2 (anchor slug, no leading #) exists as a heading in $1
    local target_file="$1"
    local anchor="$2"
    # Generate heading slugs: lowercase, spaces→hyphens, strip non-alnum except hyphens
    grep -E '^#{1,6} ' "$target_file" 2>/dev/null \
        | sed 's/^#\+ //' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[[:space:]]/-/g; s/[^a-z0-9_-]//g' \
        | grep -qxF "$anchor" 2>/dev/null
}

_scan_file_internal() {
    # Print BROKEN lines for all internal-link problems in $1
    local mdfile="$1"
    local mddir
    mddir="$(dirname "$mdfile")"

    # Extract markdown links: [text](target) — capture the target portion
    # Handles: [text](path.md), [text](path.md#anchor), [text](../path.md#anchor)
    # Skips: [text](https://...), [text](http://...)
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Extract all ](target) occurrences on this line
        # shellcheck disable=SC2034  # targets is populated in the while-read below
        local targets
        # Use grep to pull out the (target) portion — allow multiple per line
        while IFS= read -r raw_target; do
            [[ -z "$raw_target" ]] && continue
            # Skip external URLs
            [[ "$raw_target" == http://* || "$raw_target" == https://* ]] && continue
            # Strip leading ./ normalizations
            local target="$raw_target"
            target="${target#./}"

            # Split path and anchor
            local path_part anchor_part=""
            if [[ "$target" == *"#"* ]]; then
                path_part="${target%%#*}"
                anchor_part="${target##*#}"
            else
                path_part="$target"
            fi

            # Skip pure anchors (same-file links like #section)
            [[ -z "$path_part" ]] && continue

            # Only check .md links (skip images, bare dirs, etc.)
            [[ "$path_part" != *.md ]] && continue

            # Resolve the path relative to the linking file's directory
            local resolved="$mddir/$path_part"
            # Normalize away ../ sequences by using cd+pwd trick (no realpath needed)
            resolved="$(cd "$mddir" 2>/dev/null && cd "$(dirname "$path_part")" 2>/dev/null && pwd)/$(basename "$path_part")" 2>/dev/null || resolved="$mddir/$path_part"

            if [[ ! -f "$resolved" ]]; then
                printf 'BROKEN\t%s:%d\t[...](%s)\treason: target-missing\n' \
                    "$mdfile" "$lineno" "$target"
            elif [[ -n "$anchor_part" ]]; then
                if ! _resolve_anchor "$resolved" "$anchor_part"; then
                    printf 'BROKEN\t%s:%d\t[...](%s)\treason: anchor-missing\n' \
                        "$mdfile" "$lineno" "$target"
                fi
            fi
        done < <(
            printf '%s\n' "$line" \
                | grep -oE '\]\([^)]+\.md(#[^)]+)?\)' \
                | sed 's/^\](\(.*\))$/\1/'
        )
    done < "$mdfile"
}

_scan_file_gaprefs() {
    # Print STALE lines for gap-id references in $1 that don't exist in state.db
    local mdfile="$1"

    # Extract gap IDs: INFRA-NNNN, META-NNN, CREDIBLE-NNN, RESILIENT-NNN, etc.
    local lineno=0
    local seen_ids=()
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        while IFS= read -r gap_id; do
            [[ -z "$gap_id" ]] && continue
            # Deduplicate per-file
            local already=0
            for s in "${seen_ids[@]:-}"; do [[ "$s" == "$gap_id" ]] && already=1 && break; done
            [[ $already -eq 1 ]] && continue
            seen_ids+=("$gap_id")

            # Query state.db — if chump not available, skip gracefully
            if command -v chump >/dev/null 2>&1; then
                if ! chump gap show "$gap_id" >/dev/null 2>&1; then
                    printf 'STALE\t%s:%d\t%s\treason: gap-not-in-state-db\n' \
                        "$mdfile" "$lineno" "$gap_id"
                fi
            fi
        done < <(
            printf '%s\n' "$line" \
                | grep -oE '\b(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|ZERO-WASTE|FLEET|MISSION|DOC|W)-[0-9]+\b' \
                || true
        )
    done < "$mdfile"
}

_do_scan() {
    local scan_path="${1:-$DOCS_ROOT}"

    if [[ ! -d "$scan_path" && ! -f "$scan_path" ]]; then
        printf 'ERROR: scan path not found: %s\n' "$scan_path" >&2
        exit 3
    fi

    local found=0
    local file_count=0

    # Collect all .md files under scan_path
    while IFS= read -r mdfile; do
        file_count=$((file_count + 1))
        local file_results
        file_results="$(_scan_file_internal "$mdfile"; _scan_file_gaprefs "$mdfile")"
        if [[ -n "$file_results" ]]; then
            printf '%s\n' "$file_results"
            found=1
        fi
    done < <(
        if [[ -f "$scan_path" ]]; then
            printf '%s\n' "$scan_path"
        else
            find "$scan_path" -name "*.md" -type f | sort
        fi
    )

    _emit "md_links_scan_done" \
        '"scan_path":"'"$scan_path"'"' \
        '"files_checked":'"$file_count" \
        '"broken_found":'"$found"

    if [[ $found -eq 1 ]]; then
        return 0
    else
        printf 'Clean: no broken internal links or stale gap refs found in %s (%d files checked).\n' \
            "$scan_path" "$file_count"
        return 1
    fi
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_tick() {
    # Fast scan: docs/process/*.md only
    local fast_path="$DOCS_ROOT/process"
    if [[ ! -d "$fast_path" ]]; then
        fast_path="$DOCS_ROOT"
    fi
    _do_scan "$fast_path"
}

cmd_scan() {
    local scan_path="${1:-$DOCS_ROOT}"
    _do_scan "$scan_path"
}

cmd_heartbeat() {
    _emit "md_links_heartbeat"
    printf 'md-links heartbeat: %s session=%s\n' "$(_now_iso)" "$SESSION_ID"
    return 0
}

cmd_help() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//' | head -40
    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

# META-165: curator-sentinel — producer for META-158 fan-out-to-inbox.
# shellcheck source=scripts/coord/lib/curator-sentinel.sh
# shellcheck disable=SC1091  # dynamic path resolved at runtime via dirname
source "$(dirname "$0")/lib/curator-sentinel.sh"
_create_curator_sentinel md-links
_setup_sentinel_trap md-links

SUBCMD="${1:-help}"
shift || true

case "$SUBCMD" in
    tick)
        # INFRA-2262: read fleet wire before doing tick work.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-preamble md-links 2>/dev/null || true
        cmd_tick "$@"
        ;;
    scan)        cmd_scan "$@" ;;
    heartbeat)   cmd_heartbeat "$@" ;;
    help|--help) cmd_help "$@" ;;
    *)
        printf 'Unknown subcommand: %s\nRun: %s help\n' "$SUBCMD" "$0" >&2
        exit 2
        ;;
esac
