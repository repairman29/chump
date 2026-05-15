#!/usr/bin/env bash
# ambient-write.sh — INFRA-1241: flock-safe ambient.jsonl append with stderr fallback
#
# Source this file, then call:
#   _ambient_write "$AMBIENT_LOG" "$json_line"
#
# On failure: emits "[WARN] ambient write failed: <reason>" to stderr instead
# of silently discarding the event.
#
# flock(1) is used when available (Linux; macOS Homebrew util-linux).
# Falls back to a plain append on systems that don't have it.

_ambient_write() {
    local log_path="$1"
    local json_line="$2"
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 200; printf '%s\n' "$json_line" >> "$log_path" ) \
            200>"${log_path}.lock" 2>&1 \
            || printf '[WARN] %s ambient write failed (disk-full or perm?): kind=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$(printf '%s' "$json_line" | grep -o '"kind":"[^"]*"' | head -1)" >&2
    else
        printf '%s\n' "$json_line" >> "$log_path" \
            || printf '[WARN] %s ambient write failed: kind=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$(printf '%s' "$json_line" | grep -o '"kind":"[^"]*"' | head -1)" >&2
    fi
}
