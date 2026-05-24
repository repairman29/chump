#!/usr/bin/env bash
# scripts/coord/capability-publish.sh — INFRA-1825
#
# Publishes the current session's CapabilityManifest (INFRA-1760 schema,
# chump-capability-v1) to .chump-locks/capabilities/<session>.jsonl.
# File-backed v0; INFRA-1120 slice 2/4 swaps the backend to NATS KV
# chump_capabilities bucket while preserving this CLI surface.
#
# Modes:
#   capability-publish.sh once             — single emit + exit
#   capability-publish.sh daemon [--ttl N] — loop, emit every N seconds (default 30s)
#                                            persists until SIGTERM
#
# Reads:
#   CHUMP_SESSION_ID         — required (session identifier)
#   CHUMP_AGENT_HARNESS      — claude | opencode | codex | manual (default: manual)
#   FLEET_MODEL              — opus | sonnet | haiku | local | unknown
#   CHUMP_PUBLISH_HARDWARE=1 — opt-in to publishing gpu/ip fields
#   CHUMP_MACHINE_LABEL      — operator-set machine name (else hostname)
#   CHUMP_GPU_LABEL          — only used when CHUMP_PUBLISH_HARDWARE=1
#   CHUMP_IP_LABEL           — only used when CHUMP_PUBLISH_HARDWARE=1
#
# Writes:
#   .chump-locks/capabilities/<session>.jsonl  — one JSONL line per emit (append)
#   ambient.jsonl                               — kind=capability_published per emit
#
# Bypass: CHUMP_AUTO_CAPABILITY=0 silently skips publishing (audit emit).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
CAP_DIR="${CHUMP_CAPABILITY_DIR:-$LOCK_DIR/capabilities}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
mkdir -p "$CAP_DIR" 2>/dev/null || true

_session() {
    echo "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-$(hostname)-$$}}}"
}

_machine() {
    if [[ -n "${CHUMP_MACHINE_LABEL:-}" ]]; then
        echo "$CHUMP_MACHINE_LABEL"
    elif [[ -r /etc/hostname ]]; then
        tr -d '[:space:]' </etc/hostname
    else
        hostname 2>/dev/null | tr -d '[:space:]' || echo "unknown"
    fi
}

# Build the v1 manifest as compact JSON. Mirrors the
# CapabilityManifest struct from crates/chump-coord/src/capability.rs.
build_manifest() {
    local session="$1" ts="$2"
    local harness="${CHUMP_AGENT_HARNESS:-manual}"
    local model="${FLEET_MODEL:-unknown}"
    local machine
    machine="$(_machine)"
    local skills_csv="${CHUMP_SKILLS:-}"
    local gpu="null"
    local ip="null"
    if [[ "${CHUMP_PUBLISH_HARDWARE:-0}" == "1" ]]; then
        if [[ -n "${CHUMP_GPU_LABEL:-}" ]]; then
            gpu="\"$CHUMP_GPU_LABEL\""
        fi
        if [[ -n "${CHUMP_IP_LABEL:-}" ]]; then
            ip="\"$CHUMP_IP_LABEL\""
        fi
    fi
    # Skills as JSON array.
    local skills_json="[]"
    if [[ -n "$skills_csv" ]]; then
        # Convert CSV → JSON array of strings (no jq dep — python3 is universal).
        skills_json="$(
            python3 -c "
import json, sys
csv = sys.argv[1]
skills = [s.strip() for s in csv.split(',') if s.strip()]
print(json.dumps(skills, separators=(',', ':')))
" "$skills_csv"
        )"
    fi
    cat <<JSON
{"schema_version":"chump-capability-v1","session_id":"$session","harness":"$harness","model_tier":"$model","skills":$skills_json,"machine":"$machine","gpu":$gpu,"ip":$ip,"started_at":"$ts","heartbeat_at":"$ts","ttl_seconds":300}
JSON
}

emit_once() {
    local session ts inbox
    session="$(_session)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    inbox="$CAP_DIR/${session//[\/:]/_}.jsonl"
    if [[ "${CHUMP_AUTO_CAPABILITY:-1}" == "0" ]]; then
        printf '{"ts":"%s","kind":"auto_capability_bypassed","session":"%s","reason":"CHUMP_AUTO_CAPABILITY=0"}\n' \
            "$ts" "$session" >> "$AMBIENT_LOG" 2>/dev/null || true
        return 0
    fi
    local manifest
    manifest="$(build_manifest "$session" "$ts")"
    printf '%s\n' "$manifest" >> "$inbox" 2>/dev/null || return 1
    printf '{"ts":"%s","kind":"capability_published","session":"%s","ttl_seconds":300}\n' \
        "$ts" "$session" >> "$AMBIENT_LOG" 2>/dev/null || true
}

usage() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    once|"")
        emit_once
        ;;
    daemon)
        shift
        TTL=30
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --ttl) TTL="$2"; shift 2 ;;
                *) echo "capability-publish daemon: unknown flag '$1'" >&2; exit 2 ;;
            esac
        done
        # Run once immediately, then loop on TTL.
        while true; do
            emit_once || true
            sleep "$TTL"
        done
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "capability-publish.sh: unknown command '$1' (want once|daemon)" >&2
        exit 2
        ;;
esac
