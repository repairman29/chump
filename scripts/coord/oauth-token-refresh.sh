#!/usr/bin/env bash
# scripts/coord/oauth-token-refresh.sh — INFRA-2124
#
# Standalone OAuth refresh daemon: extracts the current Claude Code OAuth
# access token from macOS Keychain ("Claude Code-credentials") and writes
# it atomically to ~/.chump/oauth-token.json every 5 min (per CLAUDE.md
# INFRA-622 spec). Independent of run-fleet.sh — works whether the fleet is
# up or not, so headless `claude -p` subprocesses (Oracle, JIT scheduler,
# dispatch_flatline) always have a fresh token to inherit.
#
# Background: the original token refresher (scripts/dispatch/run-fleet.sh
# lines 574–614) only runs while a subscription-mode fleet is alive. When
# the fleet stops, the refresher dies and ~/.chump/oauth-token.json goes
# stale; downstream subprocesses that read CLAUDE_CODE_OAUTH_TOKEN from
# this file silently return "Not logged in". Symptom cascade: Oracle silent
# fail (INFRA-2122), JIT stale priorities, dispatch_flatline. This daemon
# decouples token freshness from fleet liveness.
#
# Subcommands:
#   refresh-once   — one extraction + write cycle (idempotent)
#   loop           — refresh-once every CHUMP_OAUTH_REFRESH_INTERVAL_S (default 300)
#
# Emits to ambient.jsonl:
#   kind=oauth_token_refreshed       — successful extraction + atomic write
#   kind=oauth_token_refresh_failed  — keychain miss / JSON parse fail / write fail
#
# Rust-First-Bypass: bash-glue over `security` (macOS-only keychain CLI), `python3 -c`
# for JSON parsing, and atomic mv. Same shape as fleet-restart.sh path-2 keychain
# probe; no state mutation outside the well-known token file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
TOKEN_FILE="${CHUMP_OAUTH_TOKEN_FILE:-${HOME}/.chump/oauth-token.json}"
KEYCHAIN_SERVICE="${CHUMP_OAUTH_KEYCHAIN_SERVICE:-Claude Code-credentials}"
INTERVAL_S="${CHUMP_OAUTH_REFRESH_INTERVAL_S:-300}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_age_seconds() {
    local path="$1"
    [[ -f "$path" ]] || { echo "-1"; return; }
    local now mtime
    now="$(date +%s)"
    if stat -f %m "$path" >/dev/null 2>&1; then
        mtime="$(stat -f %m "$path")"
    else
        mtime="$(stat -c %Y "$path")"
    fi
    echo "$((now - mtime))"
}

_emit_ambient() {
    local kind="$1"
    local extra="$2"   # already-formatted JSON snippet, e.g. ',"prev_age_seconds":1234'
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' "$(_ts)" "$kind" "$extra" >> "$AMBIENT_LOG"
}

# scanner-anchor: "kind":"oauth_token_refreshed"
# scanner-anchor: "kind":"oauth_token_refresh_failed"
cmd_refresh_once() {
    local prev_age
    prev_age="$(_age_seconds "$TOKEN_FILE")"

    # 1. Extract the credential blob from keychain
    local blob
    if ! blob="$(security find-generic-password -w -a "$(whoami)" -s "$KEYCHAIN_SERVICE" 2>&1)"; then
        # Try without -a fallback (some installs don't scope by account)
        if ! blob="$(security find-generic-password -w -s "$KEYCHAIN_SERVICE" 2>&1)"; then
            _emit_ambient "oauth_token_refresh_failed" \
                ",\"reason\":\"keychain_miss\",\"service\":\"${KEYCHAIN_SERVICE}\",\"prev_age_seconds\":${prev_age}"
            echo "[oauth-refresh] FAIL: keychain entry '$KEYCHAIN_SERVICE' not found" >&2
            return 1
        fi
    fi

    # 2. Parse JSON, pull claudeAiOauth.accessToken
    local token
    token="$(printf '%s' "$blob" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    t = d.get("claudeAiOauth", {}).get("accessToken", "")
    if t:
        print(t)
        sys.exit(0)
    sys.exit(2)
except Exception:
    sys.exit(3)
' 2>/dev/null)" || {
        _emit_ambient "oauth_token_refresh_failed" \
            ",\"reason\":\"json_parse_or_missing_field\",\"prev_age_seconds\":${prev_age}"
        echo "[oauth-refresh] FAIL: keychain blob missing claudeAiOauth.accessToken" >&2
        return 1
    }

    if [[ -z "$token" ]]; then
        _emit_ambient "oauth_token_refresh_failed" \
            ",\"reason\":\"empty_access_token\",\"prev_age_seconds\":${prev_age}"
        echo "[oauth-refresh] FAIL: claudeAiOauth.accessToken empty" >&2
        return 1
    fi

    # 3. Atomic write to TOKEN_FILE
    mkdir -p "$(dirname "$TOKEN_FILE")"
    chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    local tmp="${TOKEN_FILE}.tmp.$$"
    printf '{"token":"%s","written_at":"%s","source":"keychain"}\n' \
        "$token" "$(_ts)" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$TOKEN_FILE"

    _emit_ambient "oauth_token_refreshed" \
        ",\"source\":\"keychain\",\"prev_age_seconds\":${prev_age},\"new_age_seconds\":0,\"token_len\":${#token}"
    echo "[oauth-refresh] OK: wrote $TOKEN_FILE (prev_age=${prev_age}s, token_len=${#token})"
}

cmd_loop() {
    echo "[oauth-refresh] starting loop interval=${INTERVAL_S}s token_file=$TOKEN_FILE keychain=$KEYCHAIN_SERVICE"
    while true; do
        cmd_refresh_once || true   # never exit on a single failure; daemon stays alive
        sleep "$INTERVAL_S"
    done
}

CMD="${1:-refresh-once}"
shift || true
case "$CMD" in
    refresh-once) cmd_refresh_once "$@" ;;
    loop)         cmd_loop "$@" ;;
    *)
        echo "Usage: $(basename "$0") {refresh-once|loop}" >&2
        echo "  Env: CHUMP_OAUTH_REFRESH_INTERVAL_S=300  CHUMP_OAUTH_TOKEN_FILE=~/.chump/oauth-token.json" >&2
        echo "       CHUMP_OAUTH_KEYCHAIN_SERVICE='Claude Code-credentials'  CHUMP_AMBIENT_LOG=...ambient.jsonl" >&2
        exit 1
        ;;
esac
