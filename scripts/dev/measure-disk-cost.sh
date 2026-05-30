#!/usr/bin/env bash
# scripts/dev/measure-disk-cost.sh — measure actual GB consumed by a chump action
#
# Usage:
#   measure-disk-cost.sh <action-class> -- <command> [args...]
#
# Runs <command>, measures the df delta on the filesystem hosting $TMPDIR (or /),
# and appends one JSON record to ~/.chump/disk-cost-observed.jsonl.
#
# Examples:
#   measure-disk-cost.sh cargo_build_debug -- cargo build --workspace
#   measure-disk-cost.sh chump_claim_worktree -- chump claim INFRA-9999
#   measure-disk-cost.sh preflight_full -- chump preflight
#
# Output (appended to rolling log):
#   {"ts":"...","action_class":"cargo_build_debug","delta_gb":1.82,"exit_code":0,"node_id":"macbook-m4"}
#
# The observability curator reads this log to auto-tune DISK_COST_MODEL.yaml.
# See docs/strategy/DISK_AWARE_FLEET_2026-05-29.md §Layer 2 for design context.
#
# Requirements: df (macOS or Linux), awk, date, hostname — all standard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLING_LOG="${HOME}/.chump/disk-cost-observed.jsonl"
NODE_ID_FILE="${HOME}/.chump/node-id.txt"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

if [[ $# -lt 3 || "$2" != "--" ]]; then
    echo "Usage: $(basename "$0") <action-class> -- <command> [args...]" >&2
    echo "" >&2
    echo "  action-class  must match a key in docs/process/DISK_COST_MODEL.yaml" >&2
    echo "  --            separator between action-class and the command to run" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $(basename "$0") cargo_build_debug -- cargo build --workspace" >&2
    exit 1
fi

ACTION_CLASS="$1"
shift 2   # drop action-class and --
CMD=("$@")

# ---------------------------------------------------------------------------
# Determine node identity
# ---------------------------------------------------------------------------

if [[ -f "$NODE_ID_FILE" ]]; then
    NODE_ID="$(cat "$NODE_ID_FILE")"
else
    NODE_ID="$(hostname -s 2>/dev/null || hostname)"
fi

# ---------------------------------------------------------------------------
# Measure filesystem free space before and after
# Probe the filesystem that contains the working directory (or / as fallback).
# ---------------------------------------------------------------------------

_free_kb() {
    # Returns available kilobytes on the filesystem hosting $PWD.
    # macOS df: column 4 is "Available"; Linux df: column 4 is "Available".
    # Both have the same column layout with -k.
    df -k . 2>/dev/null | awk 'NR==2{print $4}'
}

TS_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FREE_KB_BEFORE="$(_free_kb)"

# ---------------------------------------------------------------------------
# Run the action
# ---------------------------------------------------------------------------

EXIT_CODE=0
"${CMD[@]}" || EXIT_CODE=$?

FREE_KB_AFTER="$(_free_kb)"
TS_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Calculate delta (positive = disk consumed, negative = disk freed)
# ---------------------------------------------------------------------------

# delta_kb = free_before - free_after  (positive means space was consumed)
DELTA_KB=$(( FREE_KB_BEFORE - FREE_KB_AFTER ))

# Convert to GB with 3 decimal places using awk (avoids bc dependency)
DELTA_GB="$(awk "BEGIN { printf \"%.3f\", ${DELTA_KB} / 1048576 }")"

# ---------------------------------------------------------------------------
# Ensure rolling log directory exists
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$ROLLING_LOG")"

# ---------------------------------------------------------------------------
# Append JSON record to rolling log
# ---------------------------------------------------------------------------

RECORD=$(printf '{"ts":"%s","action_class":"%s","delta_gb":%s,"exit_code":%d,"node_id":"%s","ts_start":"%s","ts_end":"%s","command":"%s"}' \
    "$TS_END" \
    "$ACTION_CLASS" \
    "$DELTA_GB" \
    "$EXIT_CODE" \
    "$NODE_ID" \
    "$TS_START" \
    "$TS_END" \
    "${CMD[*]}")

echo "$RECORD" >> "$ROLLING_LOG"

# ---------------------------------------------------------------------------
# Summary to stdout
# ---------------------------------------------------------------------------

echo ""
echo "=== disk-cost measurement ==="
echo "  action_class : ${ACTION_CLASS}"
echo "  delta_gb     : ${DELTA_GB} GB"
echo "  exit_code    : ${EXIT_CODE}"
echo "  node_id      : ${NODE_ID}"
echo "  logged to    : ${ROLLING_LOG}"
echo ""

# Propagate the command's exit code so callers can detect failures.
exit "$EXIT_CODE"
