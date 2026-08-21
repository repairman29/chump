#!/usr/bin/env bash
# scripts/coord/definition-of-ready-gate.sh — CREDIBLE-270 (SHIP-INFRA 2/7)
#
# Definition-of-ready gate: run BEFORE `gh pr create`. Refuses to open a new
# PR unless `chump preflight` is green locally — the same fmt/clippy/check
# gates CI runs, but caught in seconds instead of a ~15-min CI round-trip.
#
# Rationale (CREDIBLE-270 evidence): PRs routinely failed CI on fmt drift,
# clippy lints, or `cargo check` errors that a local `chump preflight` run
# would have caught in <60s. Shifting that check left of `gh pr create` turns
# CI from "first line of defense" into a rubber-stamp on already-verified work.
#
# Usage:
#   scripts/coord/definition-of-ready-gate.sh [<GAP-ID>]
#   scripts/coord/definition-of-ready-gate.sh [<GAP-ID>] --skip-reason "<text>"  # with bypass
#
# Exit codes:
#   0   preflight green (or gate disabled/bypassed) — OK to open PR
#   21  preflight failed — PR creation refused
#   22  bypass requested (CHUMP_DOR_SKIP=1) without --skip-reason
#   2   usage error
#
# Bypass: CHUMP_DOR_SKIP=1 + --skip-reason "<reason>" (audit-logged)
# Disable entirely (CI/test mode): CHUMP_DOR_DISABLE=1
#
# If the `chump` binary isn't on PATH (e.g. cold worktree, no cargo build
# yet), the gate falls back to running `cargo fmt --check` + `cargo clippy`
# + `cargo check` directly — the same three gates `chump preflight` runs.
# If `cargo` is also unavailable, the gate no-ops (exit 0) — nothing local to
# verify; CI remains the gate in that environment.

set -uo pipefail

if [[ "${CHUMP_DOR_DISABLE:-0}" == "1" ]]; then
    exit 0
fi

GAP_ID="${1:-}"
if [[ -n "$GAP_ID" && "$GAP_ID" != --* ]]; then
    shift
else
    GAP_ID=""
fi

SKIP_REASON=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-reason) SKIP_REASON="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"

emit() {
    local kind="$1"; shift
    local extra="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","source":"definition-of-ready-gate","gap":"%s"%s}\n' \
        "$ts" "$kind" "$GAP_ID" \
        "${extra:+,$extra}" >> "$AMBIENT" 2>/dev/null || true
}

# Bypass path: requires explicit --skip-reason + env var.
if [[ "${CHUMP_DOR_SKIP:-0}" == "1" ]]; then
    if [[ -z "$SKIP_REASON" ]]; then
        echo "definition-of-ready-gate: CHUMP_DOR_SKIP=1 but no --skip-reason provided" >&2
        echo "definition-of-ready-gate: bypass requires --skip-reason '<reason>' (audit-logged)" >&2
        # scanner-anchor: "kind":"definition_of_ready_bypass_rejected"
        emit definition_of_ready_bypass_rejected "\"reason\":\"no_skip_reason\""
        exit 22
    fi
    reason_esc=$(printf '%s' "$SKIP_REASON" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || echo "$SKIP_REASON")
    # scanner-anchor: "kind":"definition_of_ready_bypassed"
    emit definition_of_ready_bypassed "\"skip_reason\":\"$reason_esc\""
    echo "definition-of-ready-gate: BYPASS — proceeding without a green local preflight" >&2
    echo "definition-of-ready-gate: reason: $SKIP_REASON" >&2
    exit 0
fi

run_preflight() {
    # INFRA-1042 extended to the DoR gate (RESILIENT-356 barnacle): a shell/doc-only
    # diff has NO Rust to verify — fmt/clippy/check are all N/A. Running them anyway
    # made this gate wedge on the chump-shim clippy timeout (INFRA-469, unhealable on
    # Linux) and REFUSE to open PRs for pure shell fixes — the merge pipeline blocking
    # its own repair. Skip the local Rust preflight for doc/shell-only diffs; CI still
    # runs the authoritative full gate.
    local _changed
    _changed="$(git -C "$REPO_ROOT" diff --name-only origin/main...HEAD 2>/dev/null || true)"
    [[ -z "$_changed" ]] && _changed="$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)"
    if [[ -n "$_changed" ]] && ! grep -qE '"'"'\.rs$|(^|/)Cargo\.(toml|lock)$'"'"' <<<"$_changed"; then
        echo "definition-of-ready-gate: doc/shell-only diff — Rust preflight (fmt/clippy/check) N/A locally; CI remains authoritative"
        return 0
    fi
    if command -v chump >/dev/null 2>&1; then
        chump preflight --scope all
        return $?
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        # Nothing local to verify with; CI remains the gate.
        return 0
    fi
    (
        cd "$REPO_ROOT" || exit 1
        cargo fmt --all -- --check \
            && cargo clippy --workspace --all-targets -- -D warnings \
            && cargo check --workspace
    )
}

if run_preflight; then
    # scanner-anchor: "kind":"definition_of_ready_gate_passed"
    emit definition_of_ready_gate_passed
    exit 0
fi

echo "definition-of-ready-gate: chump preflight is NOT green — refusing to open PR." >&2
echo "definition-of-ready-gate: fix the failing gate(s) above, or bypass with:" >&2
echo "definition-of-ready-gate:   CHUMP_DOR_SKIP=1 $0 $GAP_ID --skip-reason '<why>'" >&2
# scanner-anchor: "kind":"definition_of_ready_gate_blocked"
emit definition_of_ready_gate_blocked
exit 21
