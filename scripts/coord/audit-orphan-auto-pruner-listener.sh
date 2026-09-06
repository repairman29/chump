#!/usr/bin/env bash
# audit-orphan-auto-pruner-listener.sh — INFRA-5121 (INFRA-1861 slice: audit-allowlist auto-pruner)
#
# One-shot tick: tails .chump-locks/ambient.jsonl (byte-offset bookmark, same
# pattern as post-merge-bell.sh) for `kind=audit_orphan_landed` events not
# yet processed. For each one:
#   1. Records the orphan into .chump-locks/audit-orphan-pruner-log.jsonl
#      (append-only; survives across ticks) and emits
#      kind=audit_orphan_recorded.
#   2. Triggers scripts/coord/pr-failure-auto-rescue.sh (one-shot) so a
#      batch-allowlist PR gets opened. Since this listener runs
#      synchronously and invokes the daemon immediately on the same tick,
#      the INFRA-1861 "within 5 minutes" AC is satisfied by cadence alone
#      (session-bound loop / cron tick interval, see SCHEDULING_LAYERS.md)
#      — this script does not itself sleep or poll.
#
# `kind=audit_orphan_landed` is emitted when a new register-without-emit
# entry lands in scripts/ci/event-registry-reserved.txt on main (the
# emitter is a separate INFRA-1861 slice; this listener consumes the event
# independent of which script produces it).
#
# Usage: scripts/coord/audit-orphan-auto-pruner-listener.sh [--dry-run]
#
# Env:
#   CHUMP_AMBIENT_LOG                override ambient.jsonl path
#   CHUMP_AUDIT_ORPHAN_PRUNER_STATE  override bookmark file
#   CHUMP_AUDIT_ORPHAN_PRUNER_LOG    override recorded-orphan log path
#   CHUMP_AUDIT_ORPHAN_RESCUE_BIN    override auto-rescue daemon path (tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
BOOKMARK_FILE="${CHUMP_AUDIT_ORPHAN_PRUNER_STATE:-$REPO_ROOT/.chump-locks/audit-orphan-pruner-state.txt}"
ORPHAN_LOG="${CHUMP_AUDIT_ORPHAN_PRUNER_LOG:-$REPO_ROOT/.chump-locks/audit-orphan-pruner-log.jsonl}"
RESCUE_BIN="${CHUMP_AUDIT_ORPHAN_RESCUE_BIN:-$SCRIPT_DIR/pr-failure-auto-rescue.sh}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "$AMBIENT_LOG" ]] || exit 0
mkdir -p "$(dirname "$BOOKMARK_FILE")" "$(dirname "$ORPHAN_LOG")"

LAST_OFFSET=0
[[ -f "$BOOKMARK_FILE" ]] && LAST_OFFSET="$(cat "$BOOKMARK_FILE" 2>/dev/null || echo 0)"
[[ "$LAST_OFFSET" =~ ^[0-9]+$ ]] || LAST_OFFSET=0

CURRENT_SIZE="$(wc -c < "$AMBIENT_LOG" | xargs)"
if [[ "$CURRENT_SIZE" -lt "$LAST_OFFSET" ]]; then
    # File rotated/truncated since last tick — restart from top.
    LAST_OFFSET=0
fi
if [[ "$CURRENT_SIZE" -le "$LAST_OFFSET" ]]; then
    [[ "$DRY_RUN" == 1 ]] || printf '%s\n' "$CURRENT_SIZE" > "$BOOKMARK_FILE"
    exit 0
fi

NEW_LINES="$(tail -c "+$((LAST_OFFSET + 1))" "$AMBIENT_LOG")"

extract_field() {
    # extract_field <line> <field-name>
    echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

FOUND=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | grep -q '"kind":"audit_orphan_landed"' || continue
    FOUND=1

    ENTRY="$(extract_field "$line" entry)"
    FILE="$(extract_field "$line" file)"
    [[ -z "$ENTRY" ]] && ENTRY="unknown"
    [[ -z "$FILE" ]] && FILE="scripts/ci/event-registry-reserved.txt"

    RECORD_JSON="$(printf '{"ts":"%s","entry":"%s","file":"%s","source_event":%s}' \
        "$(now_ts)" "$ENTRY" "$FILE" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')")"

    if [[ "$DRY_RUN" == 1 ]]; then
        echo "DRY-RUN: would record orphan entry=$ENTRY file=$FILE"
        echo "DRY-RUN: would trigger $RESCUE_BIN"
        continue
    fi

    printf '%s\n' "$RECORD_JSON" >> "$ORPHAN_LOG"

    RECORDED_EVENT="$(printf '{"ts":"%s","kind":"audit_orphan_recorded","entry":"%s","file":"%s"}' \
        "$(now_ts)" "$ENTRY" "$FILE")"
    # scanner-anchor: "kind":"audit_orphan_recorded"
    _ambient_write "$AMBIENT_LOG" "$RECORDED_EVENT"

    if [[ -x "$RESCUE_BIN" ]]; then
        TRIGGER_EVENT="$(printf '{"ts":"%s","kind":"audit_orphan_rescue_triggered","entry":"%s"}' \
            "$(now_ts)" "$ENTRY")"
        # scanner-anchor: "kind":"audit_orphan_rescue_triggered"
        _ambient_write "$AMBIENT_LOG" "$TRIGGER_EVENT"
        "$RESCUE_BIN" >/dev/null 2>&1 &
        disown || true
    else
        echo "[audit-orphan-auto-pruner-listener] rescue daemon not found/executable: $RESCUE_BIN" >&2
    fi
done <<< "$NEW_LINES"

[[ "$DRY_RUN" == 1 ]] || printf '%s\n' "$CURRENT_SIZE" > "$BOOKMARK_FILE"

if [[ "$FOUND" == 1 ]]; then
    echo "audit-orphan-auto-pruner-listener: processed audit_orphan_landed event(s)"
fi
exit 0
