#!/usr/bin/env bash
# fleet-restart.sh — INFRA-610/INFRA-623: fleet restart with optional credential refresh.
#
# Usage:
#   scripts/dispatch/fleet-restart.sh [OPTIONS]
#
# Options:
#   --refresh-auth          Probe for fresh credentials before relaunching.
#   --fleet-start-epoch N   Unix epoch when the fleet was launched (for oauth mtime check).
#   --dry-run               Print plan, do not restart.
#
# Credential probe order (--refresh-auth):
#   1. ~/.chump/oauth-token.json mtime > fleet-start-epoch  (INFRA-620 refreshes every 5 min)
#   2. ANTHROPIC_API_KEY env var (set in .env or via INFRA-622 multi-auth)
#   3. Neither → emit kind=fleet_auth_unrecoverable + halt (exit 4) with operator message:
#      "restart Claude Code app to refresh OAuth OR set ANTHROPIC_API_KEY"

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export PATH="$REPO_ROOT/bin:$PATH"

REFRESH_AUTH=0
FLEET_START_EPOCH="${FLEET_START_EPOCH:-0}"
DRY_RUN="${FLEET_DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh-auth)       REFRESH_AUTH=1; shift ;;
        --fleet-start-epoch)  FLEET_START_EPOCH="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=1; shift ;;
        *) printf '[fleet-restart] unknown arg: %s\n' "$1" >&2; exit 1 ;;
    esac
done

_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_log()  { printf '[fleet-restart] %s\n' "$*"; }
_emit() {
    local _kind="$1" _msg="$2"
    mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_kind" "$_msg" \
        >> "$_amb" 2>/dev/null || true
}

_resolved_cred=""

if [[ "$REFRESH_AUTH" -eq 1 ]]; then
    _token_file="${HOME}/.chump/oauth-token.json"

    # Path 1: fresh oauth-token.json written by the Claude Code app (INFRA-620)
    if [[ -f "$_token_file" ]]; then
        # Portable mtime: BSD stat (-f %m) then GNU stat (-c %Y)
        _mtime=$(stat -f %m "$_token_file" 2>/dev/null \
                 || stat -c %Y "$_token_file" 2>/dev/null || echo 0)
        if [[ "$_mtime" -gt "$FLEET_START_EPOCH" ]]; then
            _log "path-1: oauth-token.json mtime=$_mtime > fleet_start=$FLEET_START_EPOCH — using refreshed token"
            # Extract api_key from JSON using jq (fallback: python3)
            _api_key=""
            if command -v jq >/dev/null 2>&1; then
                _api_key="$(jq -r '.api_key // .ANTHROPIC_API_KEY // empty' "$_token_file" 2>/dev/null || true)"
            elif command -v python3 >/dev/null 2>&1; then
                _api_key="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('api_key') or d.get('ANTHROPIC_API_KEY') or '')
except Exception:
    print('')
" "$_token_file" 2>/dev/null || true)"
            fi
            if [[ -n "$_api_key" ]]; then
                export ANTHROPIC_API_KEY="$_api_key"
                _log "path-1: extracted ANTHROPIC_API_KEY from oauth-token.json"
            fi
            _resolved_cred="oauth"
            _emit "fleet_auth_refresh" "path=oauth mtime=${_mtime} fleet_start=${FLEET_START_EPOCH}"
        else
            _log "path-1: oauth-token.json mtime=$_mtime <= fleet_start=$FLEET_START_EPOCH — stale, skipping"
        fi
    else
        _log "path-1: ~/.chump/oauth-token.json not found — skipping"
    fi

    # Path 2: ANTHROPIC_API_KEY already in env (INFRA-622 multi-auth or .env)
    if [[ -z "$_resolved_cred" ]] && [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        _log "path-2: ANTHROPIC_API_KEY set in environment — using existing API key credential"
        _resolved_cred="api_key"
        _emit "fleet_auth_refresh" "path=api_key"
    fi

    # Path 3: no fresh credential — operator must act
    if [[ -z "$_resolved_cred" ]]; then
        _emit "fleet_auth_unrecoverable" \
            "no fresh oauth-token.json and no ANTHROPIC_API_KEY — operator action required"
        _log "ERROR: fleet_auth_unrecoverable — no valid credential found."
        _log "  ┌─ To recover, choose one of:"
        _log "  │  OPTION A: Restart the Claude Code app."
        _log "  │            It writes a fresh OAuth token to ~/.chump/oauth-token.json"
        _log "  │            every 5 min (INFRA-620). Then re-run run-fleet.sh."
        _log "  │  OPTION B: Set ANTHROPIC_API_KEY=<key> in .env or the environment,"
        _log "  │            then re-run scripts/dispatch/run-fleet.sh."
        _log "  └─────────────────────────────────────────────────────────────────"
        exit 4
    fi
fi

FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"

# Stop the current fleet if it is running
if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
    _log "stopping existing fleet session: $FLEET_SESSION"
    if [[ "$DRY_RUN" -ne 1 ]]; then
        FLEET_SIZE=0 "$REPO_ROOT/scripts/dispatch/run-fleet.sh"
        sleep 2
    else
        _log "(dry-run: would stop fleet session $FLEET_SESSION)"
    fi
fi

_log "relaunching fleet (cred=${_resolved_cred:-none} refresh_auth=$REFRESH_AUTH)"
_emit "fleet_restart" "auth_refresh=${REFRESH_AUTH} cred=${_resolved_cred:-none}"

if [[ "$DRY_RUN" -ne 1 ]]; then
    exec "$REPO_ROOT/scripts/dispatch/run-fleet.sh"
else
    _log "(dry-run: would exec run-fleet.sh)"
fi
