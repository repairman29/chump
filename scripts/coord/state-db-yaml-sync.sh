#!/usr/bin/env bash
# state-db-yaml-sync.sh — INFRA-1495
#
# Backfills missing docs/gaps/<ID>.yaml mirrors for OPEN gaps in state.db.
# YAML mirrors are optional post-INFRA-760, but the drift accumulates
# silently with no daemon backfilling it (alert 2026-05-16: 70 OPEN gaps
# with no YAML mirror, kind=gap_drift_orphan). Per CREDIBLE-012, this sweep
# only ever restores YAML for `status:open` gaps — it must NEVER write a
# YAML mirror for a done/superseded/terminal gap (that resurrection risk is
# exactly what INFRA-3606 already had to fix once for `chump gap sync`).
#
# Usage:
#   scripts/coord/state-db-yaml-sync.sh --dry-run [--gaps-dir PATH]
#   scripts/coord/state-db-yaml-sync.sh --apply   [--gaps-dir PATH]
#
# --dry-run  report orphan count only; no files written, no commit. Still
#            emits kind=state_db_yaml_orphan per missing YAML so fleet-brief
#            can trend the drift even before anyone applies the fix.
# --apply    writes docs/gaps/<ID>.yaml for every orphan (via
#            `chump gap show <ID>`, which renders the same per-gap YAML
#            shape as the historical per-file mirror) and, if any files were
#            written, commits the batch via scripts/coord/chump-commit.sh.
#
# Env overrides (test fixtures): CHUMP_REPO_ROOT, CHUMP_LOCK_DIR,
# CHUMP_STATE_DB (passed through to the `chump` binary unmodified).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
LOCKS_DIR="${CHUMP_LOCK_DIR:-${REPO_ROOT}/.chump-locks}"
AMBIENT_LOG="${LOCKS_DIR}/ambient.jsonl"
mkdir -p "${LOCKS_DIR}" 2>/dev/null || true

# shellcheck source=scripts/coord/lib/ambient-write.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ambient-write.sh"

MODE=""
GAPS_DIR="${REPO_ROOT}/docs/gaps"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE="dry-run"; shift ;;
        --apply) MODE="apply"; shift ;;
        --gaps-dir) GAPS_DIR="$2"; shift 2 ;;
        --gaps-dir=*) GAPS_DIR="${1#--gaps-dir=}"; shift ;;
        *)
            echo "state-db-yaml-sync.sh: unknown arg '$1'" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Usage: state-db-yaml-sync.sh (--dry-run | --apply) [--gaps-dir PATH]" >&2
    exit 2
fi

if ! command -v chump >/dev/null 2>&1; then
    echo "state-db-yaml-sync.sh: 'chump' binary not on PATH" >&2
    exit 1
fi

mkdir -p "${GAPS_DIR}"

# scanner-anchor: "kind":"state_db_yaml_orphan"
emit_ambient() {
    local kind="$1" gap_id="$2" mode="$3"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "${AMBIENT_LOG}" \
        "$(printf '{"ts":"%s","kind":"%s","gap_id":"%s","mode":"%s"}' \
            "${ts}" "${kind}" "${gap_id}" "${mode}")"
}

# CREDIBLE-012: only OPEN gaps are eligible for backfill. Never touch
# done/superseded/terminal statuses.
OPEN_IDS="$(chump gap list --status open --json 2>/dev/null | jq -r '.[].id')"

ORPHAN_COUNT=0
WRITTEN_IDS=()

for gap_id in ${OPEN_IDS}; do
    [[ -z "$gap_id" ]] && continue
    yaml_path="${GAPS_DIR}/${gap_id}.yaml"
    if [[ -f "$yaml_path" ]]; then
        continue
    fi
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    emit_ambient "state_db_yaml_orphan" "$gap_id" "$MODE"
    if [[ "$MODE" == "apply" ]]; then
        if chump gap show "$gap_id" > "$yaml_path" 2>/dev/null; then
            WRITTEN_IDS+=("$gap_id")
        else
            echo "state-db-yaml-sync.sh: WARN: failed to render YAML for $gap_id" >&2
            rm -f "$yaml_path"
            ORPHAN_COUNT=$((ORPHAN_COUNT - 1))
        fi
    fi
done

if [[ "$MODE" == "dry-run" ]]; then
    echo "[dry-run] state-db-yaml-sync: ${ORPHAN_COUNT} orphan(s) — no files written"
    exit 0
fi

echo "state-db-yaml-sync: backfilled ${#WRITTEN_IDS[@]} YAML mirror(s)"

if [[ ${#WRITTEN_IDS[@]} -gt 0 ]]; then
    COMMIT_SCRIPT="${SCRIPT_DIR}/chump-commit.sh"
    FILES=()
    for id in "${WRITTEN_IDS[@]}"; do
        FILES+=("docs/gaps/${id}.yaml")
    done
    if [[ -x "$COMMIT_SCRIPT" ]]; then
        (cd "$REPO_ROOT" && "$COMMIT_SCRIPT" "${FILES[@]}" \
            -m "chore(state-db-yaml-sync): backfill ${#WRITTEN_IDS[@]} YAML mirrors per CREDIBLE-012")
    else
        echo "state-db-yaml-sync.sh: WARN: ${COMMIT_SCRIPT} not found/executable — files written but not committed" >&2
    fi
fi
