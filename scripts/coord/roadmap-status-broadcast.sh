#!/usr/bin/env bash
# scripts/coord/roadmap-status-broadcast.sh — INFRA-1150
#
# Wraps `chump roadmap-status --exit-on-drift --json` and broadcasts a
# WARN to all active sessions when drift is detected (starved outcomes or
# untraced P0/P1 gaps). Designed for cron/CI use to surface drift to peer
# agents without requiring each one to poll roadmap-status independently.
#
# Companion to INFRA-1145 (the underlying drift detector) and INFRA-1146
# (the SessionStart inject). INFRA-1150 adds the broadcast → inbox path
# so an active session sees drift as a pending message at next refresh.
#
# Usage:
#   scripts/coord/roadmap-status-broadcast.sh                    # broadcast on drift
#   scripts/coord/roadmap-status-broadcast.sh --dry-run          # print, don't broadcast
#   scripts/coord/roadmap-status-broadcast.sh --top-starved 5    # broadcast top N starved
#
# Bypass: CHUMP_ROADMAP_BROADCAST=0
# Master switch: CHUMP_A2A_COORD_DISABLE=1

set -uo pipefail

if [[ "${CHUMP_ROADMAP_BROADCAST:-1}" == "0" ]]; then
    echo "[roadmap-status-broadcast] CHUMP_ROADMAP_BROADCAST=0 — skipping" >&2
    exit 0
fi
if [[ "${CHUMP_A2A_COORD_DISABLE:-0}" == "1" ]]; then
    echo "[roadmap-status-broadcast] CHUMP_A2A_COORD_DISABLE=1 — a2a disabled" >&2
    exit 0
fi

DRY_RUN=0
TOP_STARVED=3
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --top-starved) shift; TOP_STARVED="${1:-3}" ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
[[ -x "$BROADCAST" ]] || { echo "[roadmap-status-broadcast] broadcast.sh not found" >&2; exit 0; }

# Resolve chump binary
CHUMP="${CHUMP_BIN:-$(command -v chump 2>/dev/null)}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "[roadmap-status-broadcast] chump binary not found" >&2
    exit 0
fi

# Run roadmap-status with --exit-on-drift; capture JSON regardless of exit code.
JSON="$("$CHUMP" roadmap-status --json --top-starved "$TOP_STARVED" 2>/dev/null || echo "")"
if [[ -z "$JSON" ]]; then
    echo "[roadmap-status-broadcast] roadmap-status produced no output" >&2
    exit 0
fi

# Extract starved/untraced via python for safe JSON handling.
parsed="$(printf '%s' "$JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('', '')
    sys.exit(0)
s = d.get('starved_outcomes', [])
u = d.get('untraced_p0', [])
print(','.join(str(x) for x in s[:int('$TOP_STARVED')]))
print(','.join(str(x) for x in u[:5]))
")" 2>/dev/null

STARVED="$(echo "$parsed" | sed -n '1p')"
UNTRACED="$(echo "$parsed" | sed -n '2p')"

if [[ -z "$STARVED" && -z "$UNTRACED" ]]; then
    echo "[roadmap-status-broadcast] no drift detected"
    exit 0
fi

# Compose a single broadcast — WARN to --to all.
MSG=""
[[ -n "$STARVED" ]] && MSG="$MSG starved_outcomes=$STARVED"
[[ -n "$UNTRACED" ]] && MSG="$MSG untraced_p0=$UNTRACED"
MSG="${MSG# }"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[roadmap-status-broadcast] (dry-run) would broadcast: WARN to all: '$MSG'"
    exit 0
fi

# Use --to all to fanout to every active session inbox.
if "$BROADCAST" --to all WARN "roadmap drift: $MSG" >/dev/null 2>&1; then
    echo "[roadmap-status-broadcast] broadcast sent: $MSG"
    # Emit telemetry
    AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"a2a_coord_broadcast_sent","source":"roadmap-status-broadcast","starved":"%s","untraced_p0":"%s"}\n' \
        "$TS" "$STARVED" "$UNTRACED" >> "$AMBIENT" 2>/dev/null || true
else
    echo "[roadmap-status-broadcast] FAIL: broadcast.sh returned non-zero" >&2
    exit 1
fi
