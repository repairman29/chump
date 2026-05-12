#!/usr/bin/env bash
# emit-gap-timing.sh — INFRA-906
#
# Wraps a CI gate command, measures wall-clock duration, and emits
# kind=gap_perf_sample to ambient.jsonl.
#
# Usage:
#   emit-gap-timing.sh --gap GAP-ID --phase PHASE -- COMMAND [ARGS...]
#
# Example:
#   emit-gap-timing.sh --gap INFRA-906 --phase test -- bash scripts/ci/test-foo.sh
#
# Environment:
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   REPO_ROOT           Repo root (default: auto-detected)
#
# Output to ambient.jsonl:
#   {"ts":"...","kind":"gap_perf_sample","gap_id":"...","phase":"...","duration_ms":123,"exit_code":0,"host":"..."}

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GAP_ID=""
PHASE="test"
HOST="${HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}"

# ── Arg parsing ───────────────────────────────────────────────────────────────
CMD_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)      GAP_ID="$2"; shift 2 ;;
        --phase)    PHASE="$2";  shift 2 ;;
        --host)     HOST="$2";   shift 2 ;;
        --)         shift; CMD_ARGS=("$@"); break ;;
        -h|--help)
            echo "Usage: emit-gap-timing.sh --gap GAP-ID --phase PHASE -- CMD [ARGS]"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

if [[ -z "$GAP_ID" ]]; then
    echo "[emit-gap-timing] ERROR: --gap is required" >&2
    exit 1
fi

if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
    echo "[emit-gap-timing] ERROR: command required after '--'" >&2
    exit 1
fi

# ── Run command with timing ────────────────────────────────────────────────────
TS_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || \
           node -e "console.log(Date.now())" 2>/dev/null || \
           echo "0")

EXIT_CODE=0
"${CMD_ARGS[@]}" || EXIT_CODE=$?

END_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || \
         node -e "console.log(Date.now())" 2>/dev/null || \
         echo "0")

DURATION_MS=$(( END_MS - START_MS ))

# ── Emit ambient event ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$AMBIENT")"
printf '{"ts":"%s","kind":"gap_perf_sample","gap_id":"%s","phase":"%s","duration_ms":%d,"exit_code":%d,"host":"%s"}\n' \
    "$TS_START" \
    "$GAP_ID" \
    "$PHASE" \
    "$DURATION_MS" \
    "$EXIT_CODE" \
    "$HOST" \
    >> "$AMBIENT" 2>/dev/null || true

exit "$EXIT_CODE"
