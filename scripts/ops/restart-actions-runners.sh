#!/usr/bin/env bash
# restart-actions-runners.sh — META-100: restart self-hosted GitHub Actions runners
# that may be in a ghost-online state (status=online, busy=false, but not picking jobs).
#
# Cycles launchctl unload/load for all four runner plists:
#   com.chump.actions-runner.plist
#   com.chump.actions-runner-2.plist
#   com.chump.actions-runner-3.plist
#   com.chump.actions-runner-4.plist
#
# Emits kind=actions_runners_restarted to ambient.jsonl.
#
# Usage:
#   restart-actions-runners.sh [--dry-run]
#
# Env:
#   CHUMP_AMBIENT_LOG   path to ambient.jsonl (default: REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GH_REPO       GitHub repo slug for queued-run count (default: repairman29/chump)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"
_dry_run=0
_gh_repo="${CHUMP_GH_REPO:-repairman29/chump}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) _dry_run=1; shift ;;
        *) echo "Usage: $0 [--dry-run]" >&2; exit 1 ;;
    esac
done

# ── Snapshot queued run count before restart ──────────────────────────────────
_prior_queued=0
_queued_json=$(gh api "repos/${_gh_repo}/actions/runs?status=queued&per_page=100" 2>/dev/null || echo "")
if [[ -n "$_queued_json" ]]; then
    _prior_queued=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(d.get('total_count', 0))
except Exception:
    print(0)
" "$_queued_json" 2>/dev/null || echo 0)
fi
_prior_queued="${_prior_queued//[[:space:]]/}"

# ── Cycle each runner plist ───────────────────────────────────────────────────
_restarted_count=0
for label in "" "-2" "-3" "-4"; do
    plist="$HOME/Library/LaunchAgents/com.chump.actions-runner${label}.plist"
    if [[ ! -f "$plist" ]]; then
        echo "[restart-runners] skipping ${plist} (not found)"
        continue
    fi
    if (( _dry_run )); then
        echo "[restart-runners] DRY-RUN: would unload/load ${plist}"
        (( _restarted_count++ )) || true
        continue
    fi
    echo "[restart-runners] unloading ${plist}"
    launchctl unload "$plist" 2>/dev/null || true
    echo "[restart-runners] loading ${plist}"
    launchctl load  "$plist" 2>/dev/null || true
    (( _restarted_count++ )) || true
done

echo "[restart-runners] restarted ${_restarted_count} runner(s) (prior_queued=${_prior_queued})"

# ── Emit ambient event ────────────────────────────────────────────────────────
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$_lock_dir" 2>/dev/null || true

_dry_note=""
if (( _dry_run )); then
    _dry_note=",\"dry_run\":true"
fi

_body="$(printf '{"ts":"%s","kind":"actions_runners_restarted","runners_restarted_count":%d,"prior_queued_count":%d%s}' \
    "$_ts" "$_restarted_count" "$_prior_queued" "$_dry_note")"
printf '%s\n' "$_body" >> "$_amb" 2>/dev/null || true
