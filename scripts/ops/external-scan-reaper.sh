#!/usr/bin/env bash
# external-scan-reaper.sh (MISSION-036, Phase-B Tier-1 of MISSION-032)
# — Per-repo onboard-scan rotation under ~/.chump/external/<owner>/<repo>/scans/.
#
# Why: Scout's onboard pass writes a new file per run:
#   ~/.chump/external/<owner>/<repo>/scans/onboard-scan-YYYYMMDDTHHMMSSZ.json
# With N tracked repos × M scans/repo this grows unbounded. At 100 repos and
# 10 scans/repo that's 1000 files; at 10,000 repos (operator's stated target)
# it becomes a real fs-listing cost.
#
# Strategy: keep the latest N (default 5) per repo, by lexicographic sort of
# the YYYYMMDDTHHMMSSZ-suffixed filenames (which is also chronological order).
# Reap the rest.
#
# Safety: per-repo independent (one repo's full reap can't touch another's),
# pure delete (no archive), --dry-run default, --execute opt-in.
#
# Usage:
#   ./scripts/ops/external-scan-reaper.sh                 # dry-run
#   ./scripts/ops/external-scan-reaper.sh --execute       # actually reap
#   ./scripts/ops/external-scan-reaper.sh --execute --keep 10
#
# Install daily via launchd:
#   cp scripts/setup/com.chump.external-scan-reaper.plist ~/Library/LaunchAgents/
#   launchctl load -w ~/Library/LaunchAgents/com.chump.external-scan-reaper.plist
#
# Tunable env: CHUMP_EXTERNAL_SCAN_KEEP_N (default 5)

set -euo pipefail

DRY_RUN=1
KEEP_N="${CHUMP_EXTERNAL_SCAN_KEEP_N:-5}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --execute) DRY_RUN=0; shift ;;
        --keep) KEEP_N="$2"; shift 2 ;;
        --keep=*) KEEP_N="${1#--keep=}"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
        *) echo "[external-scan-reaper] unknown flag: $1" >&2; exit 2 ;;
    esac
done

EXTERNAL_ROOT="${CHUMP_EXTERNAL_ROOT:-$HOME/.chump/external}"
AMBIENT="${CHUMP_AMBIENT_PATH:-$HOME/Projects/Chump/.chump-locks/ambient.jsonl}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[external-scan-reaper] %s %s\n' "$(_ts)" "$*"; }

# Emit an ambient event (best-effort; no failure if path absent).
# scanner-anchor: "kind":"external_scan_reaped"
_emit() {
    local kind="$1" payload="$2"
    if [[ -f "$AMBIENT" ]] || [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' \
            "$(_ts)" "$kind" "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi
}

[[ ! -d "$EXTERNAL_ROOT" ]] && {
    _log "no $EXTERNAL_ROOT — nothing to rotate"
    exit 0
}

[[ "$KEEP_N" =~ ^[0-9]+$ ]] || { _log "--keep must be a non-negative integer (got: $KEEP_N)"; exit 2; }
[[ "$KEEP_N" -ge 1 ]] || { _log "--keep must be >= 1 (safety: never reap all scans)"; exit 2; }

_log "starting (keep_n=$KEEP_N, dry_run=$DRY_RUN, root=$EXTERNAL_ROOT)"

total_repos=0
total_reaped=0
total_kept=0

# Iterate ~/.chump/external/<owner>/<repo>/scans/
while IFS= read -r -d '' scans_dir; do
    total_repos=$((total_repos + 1))
    # Lexicographic sort of onboard-scan-*.json IS chronological because of
    # the YYYYMMDDTHHMMSSZ filename convention. Avoid mapfile (bash 4+,
    # macOS ships 3.2) — use a portable while-read pattern.
    files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(
        find "$scans_dir" -maxdepth 1 -type f -name 'onboard-scan-*.json' 2>/dev/null \
            | sort
    )
    count="${#files[@]}"
    [[ "$count" -le "$KEEP_N" ]] && { total_kept=$((total_kept + count)); continue; }

    # Repo identity for logging: strip $EXTERNAL_ROOT/ and /scans tail.
    rel="${scans_dir#"$EXTERNAL_ROOT"/}"
    repo="${rel%/scans}"

    reap_count=$((count - KEEP_N))
    _log "repo=$repo count=$count keep=$KEEP_N reap=$reap_count"
    total_kept=$((total_kept + KEEP_N))

    # Reap the OLDEST (first count-KEEP_N entries of sorted list).
    for ((i = 0; i < reap_count; i++)); do
        f="${files[$i]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            _log "DRY: would reap $f"
        else
            if rm -f -- "$f"; then
                _log "reaped $f"
            else
                _log "WARN: failed to remove $f"
            fi
        fi
        total_reaped=$((total_reaped + 1))
    done
done < <(find "$EXTERNAL_ROOT" -mindepth 3 -maxdepth 3 -type d -name scans -print0 2>/dev/null)

_log "done — repos=$total_repos reaped=$total_reaped kept=$total_kept (dry_run=$DRY_RUN)"

_emit "external_scan_reaped" \
    "\"repos\":$total_repos,\"reaped\":$total_reaped,\"kept\":$total_kept,\"keep_n\":$KEEP_N,\"dry_run\":$DRY_RUN"

exit 0
