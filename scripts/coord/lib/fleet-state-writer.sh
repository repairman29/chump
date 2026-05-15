#!/usr/bin/env bash
# fleet-state-writer.sh — INFRA-1068: batch fleet-state.json writes
#
# Sourced library providing queue+flush semantics for fleet-state.json.
# Instead of grabbing an exclusive flock for each individual field write,
# callers queue updates in a per-process temp file and flush them all in
# ONE flock acquisition at the end of a logical unit (e.g. curator loop iter).
#
# Usage (source this file, then call):
#   source "$REPO_ROOT/scripts/coord/lib/fleet-state-writer.sh"
#
#   fleet_state_queue_write "last_curator_run" "2026-05-14T10:00:00Z"
#   fleet_state_queue_write "health" "ok"
#   fleet_state_flush   # single flock grab, applies both updates
#
# Env:
#   FLEET_STATE_WRITE_QUEUE   path for the per-process queue file
#                             (default: /tmp/chump-fleet-state-queue-$$.tmp)
#   CHUMP_FLEET_STATE_BATCH_WRITES   1=batch (default), 0=fall through to immediate writes
#   REPO_ROOT                 repo root (resolved by calling script)
#   CHUMP_AMBIENT_LOG         ambient.jsonl path (for telemetry)

# Guard: idempotent source
[[ -n "${_FLEET_STATE_WRITER_LOADED:-}" ]] && return 0
_FLEET_STATE_WRITER_LOADED=1

# Default queue path: per-process ($$) so parallel workers don't share.
_fleet_state_default_queue() {
    printf '%s' "${FLEET_STATE_WRITE_QUEUE:-/tmp/chump-fleet-state-queue-$$.tmp}"
}

# fleet_state_queue_write KEY VALUE
#   Append a tab-delimited key/value pair to the in-memory queue file.
#   Does NOT acquire the flock — purely a local file append.
fleet_state_queue_write() {
    local key="$1" val="$2"
    local queue_file; queue_file="$(_fleet_state_default_queue)"
    printf '%s\t%s\n' "$key" "$val" >> "$queue_file"
}

# fleet_state_flush
#   Apply all queued writes to fleet-state.json in ONE flock acquisition.
#   Last-write-wins per key (awk deduplication before building jq filter).
#   Emits fleet_state_batch_flush to ambient.jsonl with fields_updated + wait_ms.
#   Idempotent: returns 0 and is a no-op when the queue is empty.
fleet_state_flush() {
    local queue_file; queue_file="$(_fleet_state_default_queue)"

    # No queue file — nothing pending.
    [[ -f "$queue_file" ]] || return 0

    # Empty queue file — clean up and return.
    if [[ ! -s "$queue_file" ]]; then
        rm -f "$queue_file"
        return 0
    fi

    # Build a jq filter that applies ALL queued updates in one pass.
    # awk: last write wins per key, then emits one `.["k"] = "v" |` per key.
    # We join with newlines then strip the trailing " | " before the final ".".
    local jq_filter update_count
    update_count=$(awk 'END{print NR}' "$queue_file")
    jq_filter=$(awk -F'\t' '
        { keys[$1] = $2 }
        END {
            out = ""
            for (k in keys) {
                v = keys[k]
                # Escape backslashes then double-quotes so jq receives valid JSON.
                gsub(/\\/, "\\\\", v)
                gsub(/"/, "\\\"", v)
                gsub(/\\/, "\\\\", k)
                gsub(/"/, "\\\"", k)
                out = out ".[\""k"\"] = \""v"\" | "
            }
            # Trim trailing " | " and append terminal "."
            if (length(out) > 3)
                out = substr(out, 1, length(out) - 3)
            else
                out = "."
            print out
        }
    ' "$queue_file")

    # Determine the fast-path script location.
    local _fast_path
    _fast_path="${REPO_ROOT:-.}/scripts/coord/emergency-fast-path.sh"

    local before_ms after_ms wait_ms
    before_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null \
        || date +%s 2>/dev/null | awk '{print $1*1000}' || echo 0)

    CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}" \
    REPO_ROOT="${REPO_ROOT:-.}" \
    bash "$_fast_path" update-jq "$jq_filter" 2>/dev/null || true

    after_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null \
        || date +%s 2>/dev/null | awk '{print $1*1000}' || echo 0)
    wait_ms=$(( after_ms - before_ms ))

    # Emit telemetry.
    local _amb ts
    _amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","kind":"fleet_state_batch_flush","fields_updated":%d,"wait_ms":%d}\n' \
        "$ts" "$update_count" "$wait_ms" \
        >> "$_amb" 2>/dev/null || true

    rm -f "$queue_file"
}
