#!/usr/bin/env bash
# scripts/dev/integration-bisect-step.sh — INFRA-2168
#
# Git bisect oracle for integration-cycle regression hunts.
#
# Exit codes (git bisect semantics):
#   0   good  — preflight passed; this commit is not the regression
#   1   bad   — preflight failed with a novel (non-flake) signature
#   125 skip  — preflight failed but the failure matches a known flake class;
#               git bisect will skip this commit as untestable
#
# Usage:
#   git bisect start
#   git bisect bad HEAD
#   git bisect good <last-known-good-sha>
#   git bisect run scripts/dev/integration-bisect-step.sh
#
# Environment:
#   CHUMP_BISECT_REGISTRY   path to INTEGRATION_FLAKE_CLASSES.yaml
#                           (default: docs/process/INTEGRATION_FLAKE_CLASSES.yaml
#                            relative to repo root)
#   CHUMP_BISECT_WORKTREE   path to integration worktree for preflight
#                           (default: current directory)
#   CHUMP_AMBIENT_DISABLE   set to 1 to suppress ambient emit (useful in tests)
#   CHUMP_PREFLIGHT_SKIP    set to 1 to skip preflight entirely (testing only)
#
# Ambient event emitted: kind=bisect_step_evaluated
#   Fields: commit, outcome (good|bad|skip), duration_s, matched_class
#
# Depends on:
#   - chump CLI (for preflight + ambient emit)
#   - grep, date, awk — standard POSIX tools
#   - docs/process/INTEGRATION_FLAKE_CLASSES.yaml (INFRA-2168 registry)

set -euo pipefail

# ── locate repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── configuration ─────────────────────────────────────────────────────────────
REGISTRY="${CHUMP_BISECT_REGISTRY:-$REPO_ROOT/docs/process/INTEGRATION_FLAKE_CLASSES.yaml}"
WORKTREE="${CHUMP_BISECT_WORKTREE:-$REPO_ROOT}"
AMBIENT_DISABLE="${CHUMP_AMBIENT_DISABLE:-0}"

# ── helpers ───────────────────────────────────────────────────────────────────
log() { printf '[bisect-step] %s\n' "$*" >&2; }

emit_ambient() {
    local outcome="$1" matched_class="$2" duration_s="$3"
    [[ "$AMBIENT_DISABLE" == "1" ]] && return 0
    local commit
    commit="$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    chump ambient emit bisect_step_evaluated \
        --field "commit=$commit" \
        --field "outcome=$outcome" \
        --field "duration_s=$duration_s" \
        --field "matched_class=$matched_class" 2>/dev/null || true
}

# ── runtime clock ─────────────────────────────────────────────────────────────
start_ns="$(date +%s%N 2>/dev/null || date +%s)000000000"
start_ns="${start_ns:0:19}"   # trim to nanoseconds if %N not supported

elapsed_s() {
    local now_ns
    now_ns="$(date +%s%N 2>/dev/null || date +%s)000000000"
    now_ns="${now_ns:0:19}"
    awk "BEGIN { printf \"%.1f\", ($now_ns - $start_ns) / 1000000000 }"
}

# ── validate registry ─────────────────────────────────────────────────────────
if [[ ! -f "$REGISTRY" ]]; then
    log "ERROR: flake class registry not found: $REGISTRY"
    log "Cannot safely determine flake vs. bad; returning 125 (skip) to avoid false quarantine."
    emit_ambient "skip" "registry-missing" "$(elapsed_s)"
    exit 125
fi

# ── run preflight ─────────────────────────────────────────────────────────────
PREFLIGHT_LOG="$(mktemp /tmp/bisect-preflight-XXXXXX.log)"
trap 'rm -f "$PREFLIGHT_LOG"' EXIT

log "Running chump preflight in $WORKTREE ..."
preflight_exit=0

if [[ "${CHUMP_PREFLIGHT_SKIP:-0}" == "1" ]]; then
    log "CHUMP_PREFLIGHT_SKIP=1 — treating as good (testing mode only)"
    emit_ambient "good" "none" "$(elapsed_s)"
    exit 0
fi

(cd "$WORKTREE" && chump preflight) >"$PREFLIGHT_LOG" 2>&1 || preflight_exit=$?

if [[ "$preflight_exit" -eq 0 ]]; then
    log "preflight PASSED — commit is good"
    emit_ambient "good" "none" "$(elapsed_s)"
    exit 0
fi

log "preflight FAILED (exit $preflight_exit) — checking flake class registry ..."

# ── check each flake class ────────────────────────────────────────────────────
# Parse the YAML manually (no yq dependency) — extract id + failure_signature_regex pairs.
# Registry format: entries separated by "- id:" lines; regex is next field after signature key.
#
# We iterate by scanning for "failure_signature_regex:" lines, pairing with the preceding id.

matched_class="none"
current_id=""

while IFS= read -r line; do
    # Track current id
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+id:[[:space:]]+(.+)$ ]]; then
        current_id="${BASH_REMATCH[1]}"
        # Strip leading/trailing whitespace and quotes
        current_id="${current_id//\"/}"
        current_id="${current_id// /}"
        continue
    fi

    # When we hit a failure_signature_regex line, extract and test it
    if [[ "$line" =~ ^[[:space:]]*failure_signature_regex:[[:space:]]+\"?(.+)\"?[[:space:]]*$ ]]; then
        regex="${BASH_REMATCH[1]}"
        # Strip surrounding quotes if present
        regex="${regex%\"}"
        regex="${regex#\"}"

        if [[ -z "$current_id" ]]; then
            continue
        fi

        # Skip retired entries by checking status in the block (simple heuristic:
        # if "status: retired" appears within 10 lines after this regex line, skip)
        # For correctness we use a two-pass: check class ids with status:retired first.
        if grep -A10 "id: ${current_id}" "$REGISTRY" 2>/dev/null | grep -q "status: retired"; then
            log "Skipping retired class: $current_id"
            continue
        fi

        # Test the regex against combined preflight output
        if grep -qE "$regex" "$PREFLIGHT_LOG" 2>/dev/null; then
            matched_class="$current_id"
            log "Matched flake class: $current_id (regex: $regex)"
            break
        fi
    fi
done < "$REGISTRY"

# ── decide outcome ────────────────────────────────────────────────────────────
if [[ "$matched_class" != "none" ]]; then
    log "Flake class '$matched_class' matched — returning 125 (skip, not bad)"
    log "This commit is untestable due to infrastructure noise, not a regression."
    emit_ambient "skip" "$matched_class" "$(elapsed_s)"
    exit 125
else
    log "No known flake class matched — returning 1 (bad)"
    log "Preflight failure is likely a genuine regression in this commit."
    # Print last 30 lines of preflight output for bisect log readability
    log "--- preflight tail ---"
    tail -30 "$PREFLIGHT_LOG" >&2 || true
    log "--- end preflight tail ---"
    emit_ambient "bad" "none" "$(elapsed_s)"
    exit 1
fi
