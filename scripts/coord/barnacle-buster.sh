#!/usr/bin/env bash
# scripts/coord/barnacle-buster.sh — RESILIENT-359
#
# Preventive-maintenance twin of the Roll Call (RESILIENT-358): where the
# Roll Call is periodic self-assessment, the barnacle buster is the drain.
# A barnacle forms wherever a gradient has no drain (stale worktrees, index
# drift, dup gaps, disk fill, bypass-debt, binary rot) — buildup that is
# invisible cycle-to-cycle until it crosses a threshold and cascades.
# Evidence 2026-08-20: worktree-reaper was OFF -> 182 stale /tmp worktrees
# -> ship path failed on disk-quota.
#
# This script is the ONE composer: it reads a registry of accumulating
# surfaces (docs/process/BARNACLE_SURFACES.yaml), runs each surface's cheap
# `check` command, and for any surface whose current value crosses its
# threshold, emits an ambient alert and auto-files a debounced gap so the
# fleet fixes it before it breaks something. Surfaces below threshold are
# healthy — no action, no noise.
#
# Usage:
#   scripts/coord/barnacle-buster.sh                 # full run: check + file gaps
#   scripts/coord/barnacle-buster.sh --dry-run        # check + report only, no gap reserve
#   scripts/coord/barnacle-buster.sh --registry PATH  # override registry (tests)
#   scripts/coord/barnacle-buster.sh --json            # machine-readable summary line
#
# Emits to ambient.jsonl:
#   scanner-anchor: "kind":"barnacle_threshold_crossed" — one per surface that
#     breached this run
#   scanner-anchor: "kind":"barnacle_buster_tick" — one per full run
#     (Roll-Call visibility: the busters are themselves Roll-Called)
#
# Env:
#   CHUMP_BARNACLE_REGISTRY   — override registry path (default docs/process/BARNACLE_SURFACES.yaml)
#   CHUMP_BARNACLE_AMBIENT    — override ambient.jsonl path (tests)
#   CHUMP_BARNACLE_STATE_DIR  — override debounce state dir (tests)
#   CHUMP_BARNACLE_CHUMP_CMD  — override chump binary (tests)
#   CHUMP_BARNACLE_DEBOUNCE_HOURS — hours between re-filing the same surface (default 24)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

REGISTRY="${CHUMP_BARNACLE_REGISTRY:-$REPO_ROOT/docs/process/BARNACLE_SURFACES.yaml}"
AMBIENT="${CHUMP_BARNACLE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DIR="${CHUMP_BARNACLE_STATE_DIR:-$REPO_ROOT/.chump/barnacle-buster}"
CHUMP="${CHUMP_BARNACLE_CHUMP_CMD:-chump}"
SKIP_RESERVE=0
DEBOUNCE_HOURS="${CHUMP_BARNACLE_DEBOUNCE_HOURS:-24}"
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  SKIP_RESERVE=1; shift ;;
        --registry) REGISTRY="${2:?--registry needs a path}"; shift 2 ;;
        --json)     JSON=1; shift ;;
        -h|--help)  sed -n '2,32p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT")" "$STATE_DIR"

if [[ ! -f "$REGISTRY" ]]; then
    echo "[barnacle-buster] ERROR: registry not found: $REGISTRY" >&2
    exit 1
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# debounce_ok SURFACE_ID — 0 (ok to file) if no state file or state file is
# older than DEBOUNCE_HOURS.
debounce_ok() {
    local id="$1"
    local f="$STATE_DIR/${id}.last"
    [[ ! -f "$f" ]] && return 0
    local last_epoch now
    last_epoch="$(cat "$f" 2>/dev/null || echo 0)"
    now="$(date -u +%s)"
    (( (now - last_epoch) / 3600 >= DEBOUNCE_HOURS ))
}

write_debounce() {
    local id="$1"
    date -u +%s > "$STATE_DIR/${id}.last"
}

# Parse the registry into tab-separated rows: id\tdescription\tcheck\tthreshold\tdomain\tpriority\teffort
ROWS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE"' EXIT

python3 - "$REGISTRY" > "$ROWS_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
for s in data.get("surfaces", []) or []:
    row = [
        str(s.get("id", "")),
        str(s.get("description", "")),
        str(s.get("check", "")),
        str(s.get("threshold", "")),
        str(s.get("domain", "RESILIENT")),
        str(s.get("priority", "P2")),
        str(s.get("effort", "s")),
    ]
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in row))
PYEOF

TOTAL=0
BREACHED=0
declare -a BREACH_IDS=()

while IFS=$'\t' read -r id desc check threshold domain priority effort; do
    [[ -z "$id" ]] && continue
    TOTAL=$((TOTAL + 1))

    value="$(cd "$REPO_ROOT" && eval "$check" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [[ -z "$value" ]]; then
        echo "[barnacle-buster] WARN: check for '$id' produced no numeric output — skipping" >&2
        continue
    fi

    echo "[barnacle-buster] $id: value=$value threshold=$threshold"

    if (( value > threshold )); then
        BREACHED=$((BREACHED + 1))
        BREACH_IDS+=("$id")

        # scanner-anchor: "kind":"barnacle_threshold_crossed"
        emit "barnacle_threshold_crossed" \
            "\"surface\":\"$id\",\"value\":$value,\"threshold\":$threshold,\"domain\":\"$domain\""

        if ! debounce_ok "$id"; then
            echo "[barnacle-buster] SKIP gap-file for '$id' — debounced (< ${DEBOUNCE_HOURS}h since last)"
            continue
        fi

        if (( SKIP_RESERVE )); then
            echo "[barnacle-buster] DRY-RUN: would file gap for '$id' (domain=$domain priority=$priority)"
        else
            GAP_TITLE="RESILIENT: barnacle — ${id} at ${value} (threshold ${threshold})"
            AC="Surface '${id}' (${desc}) crossed its threshold: value=${value} > threshold=${threshold}. Drain it: run the surface's remediation (see docs/process/BARNACLE_SURFACES.yaml check command context) and confirm the value drops back at/under threshold on the next barnacle-buster run (scripts/coord/barnacle-buster.sh --dry-run)."
            out="$(CHUMP_GAP_RESERVE_NO_SIMILARITY=1 "$CHUMP" gap reserve \
                --domain "$domain" \
                --priority "$priority" \
                --effort "$effort" \
                --title "$GAP_TITLE" \
                --acceptance-criteria "$AC" \
                2>&1)"
            if [[ $? -eq 0 ]]; then
                echo "[barnacle-buster] filed gap for '$id': $out"
            else
                echo "[barnacle-buster] WARN: gap reserve failed for '$id': $out" >&2
            fi
        fi
        write_debounce "$id"
    fi
done < "$ROWS_FILE"

# scanner-anchor: "kind":"barnacle_buster_tick"
emit "barnacle_buster_tick" "\"surfaces_checked\":$TOTAL,\"surfaces_breached\":$BREACHED"

if (( JSON )); then
    printf '{"surfaces_checked":%d,"surfaces_breached":%d}\n' "$TOTAL" "$BREACHED"
else
    echo "[barnacle-buster] done — checked $TOTAL surface(s), $BREACHED breached"
fi

exit 0
