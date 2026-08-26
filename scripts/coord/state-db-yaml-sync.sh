#!/usr/bin/env bash
# state-db-yaml-sync.sh — INFRA-1495
#
# state.db is canonical (ZERO-WASTE-020); docs/gaps/<ID>.yaml mirrors are
# optional post-INFRA-760 but drift silently when nothing backfills a
# missing mirror (ambient alert 2026-05-16: gap_drift_orphan, 70 OPEN gaps
# with no YAML). This sweep restores the missing mirrors for OPEN gaps
# only — per CREDIBLE-012, done/superseded gaps must never get a YAML
# written back (their lifecycle is over; a resurrected YAML mirror reads
# as live work to anything that scans docs/gaps/*.yaml).
#
# Usage:
#   scripts/coord/state-db-yaml-sync.sh --dry-run   # default; report only
#   scripts/coord/state-db-yaml-sync.sh --apply     # write + commit
#
# Env overrides (used by scripts/ci/test-state-db-yaml-sync.sh):
#   CHUMP_BIN                        path to the chump binary
#   CHUMP_STATE_DB                   state.db path (read by `chump` itself)
#   STATE_DB_YAML_SYNC_GAPS_DIR       docs/gaps dir override
#   STATE_DB_YAML_SYNC_SKIP_COMMIT    "1" skips the chump-commit.sh call
#   CHUMP_AMBIENT_DISABLE             "1" suppresses ambient.jsonl writes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

CHUMP_BIN="${CHUMP_BIN:-chump}"
GAPS_DIR="${STATE_DB_YAML_SYNC_GAPS_DIR:-$REPO_ROOT/docs/gaps}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

MODE="dry-run"
for arg in "$@"; do
    case "$arg" in
        --apply) MODE="apply" ;;
        --dry-run) MODE="dry-run" ;;
        *)
            echo "Usage: $0 [--dry-run|--apply]" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$GAPS_DIR"

mapfile -t OPEN_IDS < <("$CHUMP_BIN" gap list --status open --json | jq -r '.[].id')

orphans=()
for id in "${OPEN_IDS[@]}"; do
    [[ -z "$id" ]] && continue
    [[ -f "$GAPS_DIR/$id.yaml" ]] && continue
    orphans+=("$id")
    if [[ "${CHUMP_AMBIENT_DISABLE:-}" != "1" ]]; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _ambient_write "$AMBIENT_LOG" \
            "$(printf '{"ts":"%s","kind":"state_db_yaml_orphan","gap_id":"%s"}' "$ts" "$id")"
    fi
done

echo "state-db-yaml-sync: ${#orphans[@]} orphan(s) (open gap in state.db, no docs/gaps YAML mirror)"
if [[ "${#orphans[@]}" -gt 0 ]]; then
    printf '  %s\n' "${orphans[@]}"
fi

if [[ "$MODE" == "dry-run" ]]; then
    exit 0
fi

if [[ "${#orphans[@]}" -eq 0 ]]; then
    echo "state-db-yaml-sync: nothing to backfill"
    exit 0
fi

written=()
for id in "${orphans[@]}"; do
    "$CHUMP_BIN" gap show "$id" > "$GAPS_DIR/$id.yaml"
    written+=("$GAPS_DIR/$id.yaml")
done

n=${#written[@]}
if [[ "${STATE_DB_YAML_SYNC_SKIP_COMMIT:-}" == "1" ]]; then
    echo "state-db-yaml-sync: wrote $n YAML mirror(s) (commit skipped)"
    exit 0
fi

"$SCRIPT_DIR/chump-commit.sh" "${written[@]}" \
    -m "chore(state-db-yaml-sync): backfill $n YAML mirrors per CREDIBLE-012"
