#!/usr/bin/env bash
# discover-flock.sh — find flock binary, set $FLOCK_BIN. INFRA-1600 follow-up.
#
# brew util-linux is keg-only on macOS, so flock lives at
# /opt/homebrew/opt/util-linux/bin/flock (Apple Silicon) or
# /usr/local/opt/util-linux/bin/flock (Intel) — neither is on default PATH.
# Self-hosted CI runners spawn jobs with launchd's restricted PATH, so
# `command -v flock` fails even when brew has installed it.
#
# Usage:
#   # shellcheck source=scripts/lib/discover-flock.sh
#   source "$(dirname "$0")/../lib/discover-flock.sh"
#   "$FLOCK_BIN" -x 9
#
# Honors an existing $FLOCK_BIN env var if it points at an executable.

if [[ -n "${FLOCK_BIN:-}" ]] && [[ -x "$FLOCK_BIN" ]]; then
    :  # caller-provided override
elif command -v flock >/dev/null 2>&1; then
    FLOCK_BIN="$(command -v flock)"
elif [[ -x /opt/homebrew/opt/util-linux/bin/flock ]]; then
    FLOCK_BIN="/opt/homebrew/opt/util-linux/bin/flock"
elif [[ -x /usr/local/opt/util-linux/bin/flock ]]; then
    FLOCK_BIN="/usr/local/opt/util-linux/bin/flock"
elif [[ -x /usr/bin/flock ]]; then
    FLOCK_BIN="/usr/bin/flock"
else
    echo "[discover-flock] ERROR: flock not found." >&2
    echo "  Tried: PATH, /opt/homebrew/opt/util-linux/bin/flock," >&2
    echo "         /usr/local/opt/util-linux/bin/flock, /usr/bin/flock" >&2
    echo "  Install: brew install util-linux  (macOS)" >&2
    return 1 2>/dev/null || exit 1
fi
export FLOCK_BIN
