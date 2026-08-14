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
#   kind=oauth_token_refreshed       — successful extraction + atomic write (token CHANGED)
#   kind=oauth_token_refresh_failed  — keychain miss / JSON parse fail / write fail
#   kind=oauth_token_invalid         — extracted token failed API validation; old file kept
#   kind=oauth_refresh_unsupported_platform — non-macOS host (INFRA-1865, see AC5)
#
# INFRA-1865 additions on top of the original INFRA-2124 daemon:
#   - hash-compare: skip the rewrite (and the ambient emit) when the extracted
#     token is identical to what's already on disk, so a 5-min cron doesn't
#     spam oauth_token_refreshed every cycle when nothing changed.
#   - validate-before-write: the freshly extracted token is smoke-tested
#     against the real Claude Code API path (`claude -p ... PONG`) before it
#     replaces the existing file, so a corrupt/expired keychain blob never
#     clobbers a still-good token.
#   - platform gate: this daemon is macOS-only (keychain-backed). Linux hosts
#     get a clear, loud error rather than a silent no-op — the operator
#     decision on a Linux-native keystore/env-fallback is still open.
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

# sha256 of a token string — used to skip no-op rewrites (AC3).
_token_hash() {
    printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1 \
        || printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1
}

# Current token stored in TOKEN_FILE, or empty if missing/unparseable.
_current_token() {
    [[ -f "$TOKEN_FILE" ]] || return 0
    python3 -c "
import json,sys
try:
    print(json.load(open('$TOKEN_FILE')).get('token',''))
except Exception:
    pass
" 2>/dev/null
}

# AC4: smoke-test the freshly-extracted token against the real Claude Code
# API path before it's allowed to replace whatever is currently on disk.
# Tests stub the `claude` binary on PATH rather than bypassing this function,
# so the real validation code path is what's under test.
_validate_token() {
    local token="$1"
    command -v claude >/dev/null 2>&1 || return 0   # can't validate without the CLI; don't block
    (cd /tmp && CLAUDE_CODE_OAUTH_TOKEN="$token" ANTHROPIC_API_KEY= \
        timeout "${CHUMP_OAUTH_VALIDATE_TIMEOUT_S:-60}" claude -p "Reply with exactly: PONG" \
        --model haiku 2>/dev/null | grep -q PONG)
}

# scanner-anchor: "kind":"oauth_token_refreshed"
# scanner-anchor: "kind":"oauth_token_refresh_failed"
# scanner-anchor: "kind":"oauth_refresh_not_applicable"
# scanner-anchor: "kind":"oauth_token_invalid"
# scanner-anchor: "kind":"oauth_refresh_unsupported_platform"
cmd_refresh_once() {
    local prev_age
    prev_age="$(_age_seconds "$TOKEN_FILE")"

    # AC5: macOS-only (keychain-backed). Fail loudly + clearly on Linux
    # rather than silently no-op'ing — the operator decision on a
    # Linux-native keystore/env-fallback substrate is still open (INFRA-1865).
    local _plat
    _plat="${CHUMP_OAUTH_PLATFORM_OVERRIDE:-$(uname -s)}"
    if [[ "$_plat" != "Darwin" ]]; then
        _emit_ambient "oauth_refresh_unsupported_platform" \
            ",\"platform\":\"${_plat}\",\"reason\":\"macos_keychain_only\""
        echo "[oauth-refresh] SKIP: this daemon is macOS-only (keychain-backed)." >&2
        echo "[oauth-refresh]      platform=${_plat} has no supported keystore path yet (INFRA-1865)." >&2
        echo "[oauth-refresh]      set CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY directly, or write" >&2
        echo "[oauth-refresh]      ${TOKEN_FILE} by hand until a Linux keystore path lands." >&2
        return 1
    fi

    # RESILIENT-115 (2026-06-05): if operator is on api-key auth, OAuth refresh
    # is irrelevant — skip cleanly with an informational event, NOT a
    # failure event. Pre-fix, this daemon spammed oauth_token_refresh_failed
    # every 5 min for 17h+ on operators using ANTHROPIC_API_KEY, which
    # farmer.sh tripped on as AUTH_DEAD (~1.1 false-positive pages/min).
    # Two short-circuit conditions:
    #   (1) CHUMP_AUTH_MODE explicitly api-key
    #   (2) auto-mode + ANTHROPIC_API_KEY non-empty (the auto-mode preference)
    # In either case the OAuth path is dormant by design; this daemon should
    # honor that. Operator can force-run via CHUMP_OAUTH_FORCE_REFRESH=1.
    #
    # Launchd plists use `bash -lc` which sources login rc, but operator's
    # `.env` isn't guaranteed to be auto-sourced. Read ANTHROPIC_API_KEY
    # explicitly from $REPO_ROOT/.env if it's not already in env. Safe parse:
    # match the exact key, strip quotes, do NOT eval arbitrary content.
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
        local _api_key
        _api_key="$(grep -E '^ANTHROPIC_API_KEY=' "$REPO_ROOT/.env" 2>/dev/null \
                  | head -1 | cut -d= -f2- \
                  | sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')"
        [[ -n "$_api_key" ]] && export ANTHROPIC_API_KEY="$_api_key"
    fi
    local auth_mode="${CHUMP_AUTH_MODE:-auto}"
    if [[ "${CHUMP_OAUTH_FORCE_REFRESH:-0}" != "1" ]]; then
        if [[ "$auth_mode" == "api-key" ]]; then
            _emit_ambient "oauth_refresh_not_applicable" \
                ",\"reason\":\"auth_mode_api_key\",\"prev_age_seconds\":${prev_age}"
            return 0
        fi
        if [[ "$auth_mode" == "auto" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
            _emit_ambient "oauth_refresh_not_applicable" \
                ",\"reason\":\"auto_mode_with_api_key_present\",\"prev_age_seconds\":${prev_age}"
            return 0
        fi
    fi

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

    # 2. Parse JSON, pull claudeAiOauth.accessToken + claudeAiOauth.expiresAt
    # (RESILIENT-056: expires_at is captured alongside the token so downstream
    # watchdogs can flag a token as stale from its own claimed expiry, not
    # just from file mtime.)
    local parsed token expires_at
    parsed="$(printf '%s' "$blob" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    oauth = d.get("claudeAiOauth", {})
    t = oauth.get("accessToken", "")
    exp = oauth.get("expiresAt", "")
    if t:
        print(f"{t}\t{exp}")
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
    token="${parsed%%$'\t'*}"
    expires_at="${parsed#*$'\t'}"

    if [[ -z "$token" ]]; then
        _emit_ambient "oauth_token_refresh_failed" \
            ",\"reason\":\"empty_access_token\",\"prev_age_seconds\":${prev_age}"
        echo "[oauth-refresh] FAIL: claudeAiOauth.accessToken empty" >&2
        return 1
    fi

    # 3. Rotation-safe hash compare (AC3): skip the rewrite + ambient emit
    # entirely when the extracted token is identical to what's already on
    # disk. Avoids a kind=oauth_token_refreshed line every 5 min forever.
    local _new_hash _cur_hash
    _new_hash="$(_token_hash "$token")"
    _cur_hash="$(_token_hash "$(_current_token)")"
    if [[ -n "$_cur_hash" && "$_new_hash" == "$_cur_hash" ]]; then
        echo "[oauth-refresh] SKIP: token unchanged (prev_age=${prev_age}s)"
        return 0
    fi

    # 4. Validate before write (AC4): a corrupt/expired keychain blob must
    # never clobber a still-good token file. On failure, leave the old file
    # in place and emit a distinct warning event.
    if ! _validate_token "$token"; then
        _emit_ambient "oauth_token_invalid" \
            ",\"reason\":\"validation_failed\",\"prev_age_seconds\":${prev_age}"
        echo "[oauth-refresh] WARN: freshly-extracted token failed validation; keeping existing $TOKEN_FILE (prev_age=${prev_age}s)" >&2
        return 1
    fi

    # 5. Atomic write to TOKEN_FILE
    mkdir -p "$(dirname "$TOKEN_FILE")"
    chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    local tmp="${TOKEN_FILE}.tmp.$$"
    printf '{"token":"%s","written_at":"%s","source":"launchd-refresher","expires_at":"%s"}\n' \
        "$token" "$(_ts)" "$expires_at" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$TOKEN_FILE"

    _emit_ambient "oauth_token_refreshed" \
        ",\"source\":\"launchd-refresher\",\"prev_age_seconds\":${prev_age},\"new_age_seconds\":0,\"token_len\":${#token}"
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
