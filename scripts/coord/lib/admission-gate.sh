#!/usr/bin/env bash
# admission-gate.sh — RESILIENT-1604: node-wide admission ceiling.
#
# Problem: multiple independent spawn sites (chump dispatch, worker.sh,
# curator organs) each think they own the node and spawn `claude -p` /
# cargo+rustc jobs with no shared view of what else is already running.
# Receipt: cuphead (4 cores) ran 5-8 concurrent `claude -p` + up to 9 cargo
# jobs at load 12-18 on 2026-10-16, budget-killing agents that had already
# finished their work.
#
# This library gives every spawn site a shared, process-table-grounded gate:
# before starting a `claude -p` or cargo/rustc job, block (bounded) until
# the live count on this node is under the ceiling. If the ceiling never
# clears within the bound, proceed anyway (fail-open — a stuck admission
# gate is worse than a temporarily-busy node) after emitting the deferral.
#
# Usage (source then call):
#   source "$(dirname "$0")/../coord/lib/admission-gate.sh"   # from scripts/dispatch/*
#   chump_admission_wait_claude
#   chump_admission_wait_cargo
#
# Ceiling (env, written into node.env by chump-node-install.sh):
#   CHUMP_MAX_CONCURRENT_CLAUDE       default max(1, nproc/2)
#   CHUMP_MAX_CONCURRENT_CARGO_JOBS   default max(1, nproc/2)
# Bound:
#   CHUMP_ADMISSION_WAIT_TIMEOUT_S    default 300 — total time to wait before
#                                     admitting anyway (fail-open)
#   CHUMP_ADMISSION_POLL_INTERVAL_S   default 5 — seconds between re-checks
#
# Test seam: CHUMP_ADMISSION_TEST_CLAUDE_COUNT / CHUMP_ADMISSION_TEST_CARGO_COUNT
# override the live pgrep count with a fixed fixture value, so CI can prove
# the deferral path without needing real background processes.
#
# Emits kind=admission_deferred (registered in EVENT_REGISTRY.yaml).

if [ -n "${_CHUMP_ADMISSION_GATE_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CHUMP_ADMISSION_GATE_LOADED=1

_chump_admission_lib_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}
# shellcheck source=scripts/coord/lib/ambient-write.sh
. "$(_chump_admission_lib_dir)/ambient-write.sh"

_chump_admission_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}
_chump_admission_ambient_log() {
    echo "${CHUMP_AMBIENT_LOG:-$(_chump_admission_repo_root)/.chump-locks/ambient.jsonl}"
}

_chump_admission_nproc() {
    nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1
}

# max(1, nproc/2), used as the default ceiling for BOTH resources.
_chump_admission_default_ceiling() {
    local cores half
    cores="$(_chump_admission_nproc)"
    [[ "$cores" =~ ^[0-9]+$ ]] || cores=1
    half=$(( cores / 2 ))
    (( half < 1 )) && half=1
    echo "$half"
}

chump_admission_ceiling_claude() {
    local v="${CHUMP_MAX_CONCURRENT_CLAUDE:-}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
        echo "$v"
    else
        _chump_admission_default_ceiling
    fi
}

chump_admission_ceiling_cargo() {
    local v="${CHUMP_MAX_CONCURRENT_CARGO_JOBS:-}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
        echo "$v"
    else
        _chump_admission_default_ceiling
    fi
}

# Live count of `claude -p` processes on this node (pgrep -f match, minus
# the pgrep invocation itself).
#
# Test seam: CHUMP_ADMISSION_TEST_CLAUDE_COUNT_FILE, if set, is re-read on
# every call — a fake process-count fixture a test can mutate mid-wait to
# simulate the live count changing over time. CHUMP_ADMISSION_TEST_CLAUDE_COUNT
# is a simpler static override, checked when the file seam isn't set.
chump_admission_count_claude() {
    if [[ -n "${CHUMP_ADMISSION_TEST_CLAUDE_COUNT_FILE:-}" ]]; then
        cat "$CHUMP_ADMISSION_TEST_CLAUDE_COUNT_FILE" 2>/dev/null || echo 0
        return 0
    fi
    if [[ -n "${CHUMP_ADMISSION_TEST_CLAUDE_COUNT:-}" ]]; then
        echo "$CHUMP_ADMISSION_TEST_CLAUDE_COUNT"
        return 0
    fi
    pgrep -fc 'claude -p' 2>/dev/null || echo 0
}

# Live count of cargo/rustc build processes on this node. Same test seams as
# chump_admission_count_claude, via the _CARGO_ variants.
chump_admission_count_cargo() {
    if [[ -n "${CHUMP_ADMISSION_TEST_CARGO_COUNT_FILE:-}" ]]; then
        cat "$CHUMP_ADMISSION_TEST_CARGO_COUNT_FILE" 2>/dev/null || echo 0
        return 0
    fi
    if [[ -n "${CHUMP_ADMISSION_TEST_CARGO_COUNT:-}" ]]; then
        echo "$CHUMP_ADMISSION_TEST_CARGO_COUNT"
        return 0
    fi
    pgrep -fc '(^|/)(cargo|rustc)( |$)' 2>/dev/null || echo 0
}

# scanner-anchor: "kind":"admission_deferred"
_chump_admission_emit_deferred() {
    local resource="$1" active="$2" ceiling="$3" waited_s="$4" outcome="$5"
    local amb ts
    amb="$(_chump_admission_ambient_log)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "$amb" "$(printf '{"ts":"%s","kind":"admission_deferred","resource":"%s","active":%d,"ceiling":%d,"waited_s":%d,"outcome":"%s","source":"admission-gate.sh"}' \
        "$ts" "$resource" "$active" "$ceiling" "$waited_s" "$outcome")"
}

# _chump_admission_wait <resource-label> <count-fn> <ceiling>
# Blocks (bounded) while count-fn's output is >= ceiling. Emits
# kind=admission_deferred on entering the wait and again if it exhausts the
# bound (fail-open: admits anyway rather than hanging forever).
_chump_admission_wait() {
    local resource="$1" count_fn="$2" ceiling="$3"
    local timeout_s="${CHUMP_ADMISSION_WAIT_TIMEOUT_S:-300}"
    local poll_s="${CHUMP_ADMISSION_POLL_INTERVAL_S:-5}"
    local waited=0
    local active
    active="$("$count_fn")"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0

    if (( active < ceiling )); then
        return 0
    fi

    _chump_admission_emit_deferred "$resource" "$active" "$ceiling" 0 "deferred"
    echo "[admission-gate] $resource: $active active >= ceiling $ceiling — waiting (bounded ${timeout_s}s)" >&2

    while (( active >= ceiling )) && (( waited < timeout_s )); do
        sleep "$poll_s"
        waited=$(( waited + poll_s ))
        active="$("$count_fn")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
    done

    if (( active >= ceiling )); then
        _chump_admission_emit_deferred "$resource" "$active" "$ceiling" "$waited" "fail_open_timeout"
        echo "[admission-gate] $resource: still $active active >= ceiling $ceiling after ${waited}s — admitting anyway (fail-open)" >&2
    fi
    return 0
}

# Call before spawning a `claude -p` subprocess.
chump_admission_wait_claude() {
    _chump_admission_wait "claude" chump_admission_count_claude "$(chump_admission_ceiling_claude)"
}

# Call before spawning a cargo/rustc build job.
chump_admission_wait_cargo() {
    _chump_admission_wait "cargo" chump_admission_count_cargo "$(chump_admission_ceiling_cargo)"
}
