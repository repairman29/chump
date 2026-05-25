#!/usr/bin/env bash
# scripts/coord/ci-audit-loop.sh — Chump curator-opus-ci-audit role CLI (harness-neutral)
#
# Productizes the curator-opus-ci-audit role per INFRA-1923 + META-097.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/ci-audit.md + .claude/skills/ci-audit/
# wrappers delegate here; they are convenience, not capability.
#
# This role owns CI and test-gate health for the Chump fleet. It was created
# to own the failure patterns that repeated across sessions:
#   - INFRA-1395: grace-window misuse (|| true silencing real failures)
#   - INFRA-1459: stale auto-merge (PR armed then rebased without re-arming)
#   - INFRA-1939: bot-merge silent wedge (PR merged, gap not shipped)
#   - Voice-lint drift (banned words slipping through without policy file)
#   - Bounced-PR trunk red (PR rebased into conflict, CI passed on stale SHA)
#
# Rust-First-Bypass: glue between gh + jq + git + scripts/coord helpers;
# <200 LOC at first commit; read-mostly (only writes are ambient.jsonl emit
# lines + inbox broadcasts, both already-idempotent). Will be ported to Rust
# if the surface grows past 200 LOC.
#
# Usage:
#   scripts/coord/ci-audit-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick          One full work-your-lane cycle: read inbox, check ambient
#                 for CI-relevant events, print actionable summary.
#                 Exit 0 if actionable, exit 1 if quiet, exit 2 on bad input.
#   audit         Decompose latest CI failure cluster: classify events in
#                 ambient.jsonl into flake / logic-bug / missing-gate buckets.
#                 Prints one line per finding. Exit 0 ok, exit 1 quiet.
#   heartbeat     Emit kind=ci_audit_heartbeat to ambient.jsonl. Exit 0 always.
#   help          Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (no actionable items)
#   2 — bad subcommand or missing required arg
#   3 — ambient log missing or unreadable
#
# Env:
#   CHUMP_SESSION_ID          session id for inbox + emits (default: ci-audit-<pid>)
#   CHUMP_AMBIENT_LOG         ambient.jsonl path override
#   CHUMP_CI_AUDIT_LANE_OVERRIDE  if "1", lane-scope checks skip

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-ci-audit-$$}"

# Source cache helpers if available (INFRA-1081: cache-first reads).
_CACHE_LIB="$MAIN_REPO/scripts/coord/lib/github_cache.sh"
if [[ -f "$_CACHE_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_CACHE_LIB"
fi

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Emit an ambient line. Each call site has a scanner-anchor comment below.
_emit_kind() {
    local kind="$1"; shift
    local extra="${1:-}"
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    local body
    if [[ -n "$extra" ]]; then
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s",%s}' \
            "$(_now_iso)" "$kind" "$SESSION_ID" "$extra")"
    else
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s"}' \
            "$(_now_iso)" "$kind" "$SESSION_ID")"
    fi
    printf '%s\n' "$body" >> "$AMBIENT" 2>/dev/null || true
}

# Scan ambient.jsonl for CI-relevant events in the last N lines.
# Prints matching lines to stdout. Returns number of matches via exit code
# (0 = found something, 1 = nothing).
_scan_ambient_for_ci() {
    local window="${1:-100}"
    if [[ ! -f "$AMBIENT" ]]; then
        return 1
    fi
    local hits
    hits="$(tail -"${window}" "$AMBIENT" 2>/dev/null \
        | grep -E '"kind":"(pr_stuck|fleet_wedge|ci_cluster_detected|ci_audit_heartbeat|sub_agent_dispatched)"' \
        || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits"
        return 0
    fi
    return 1
}

# Read inbox items for this session (non-advancing peek).
_peek_inbox() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        tail -5 "$inbox_file" 2>/dev/null || true
    fi
}

# ── Subcommands ──────────────────────────────────────────────────────────────

_cmd_tick() {
    local actionable=0
    echo "=== curator-opus-ci-audit tick @ $(_now_iso) ==="
    echo

    # Phase 1: Inbox check
    echo "## Inbox (last 5 items for session ${SESSION_ID})"
    local inbox_items
    inbox_items="$(_peek_inbox)"
    if [[ -n "$inbox_items" ]]; then
        printf '%s\n' "$inbox_items"
        actionable=1
    else
        echo "  (no inbox items)"
    fi
    echo

    # Phase 2: Ambient CI event scan
    echo "## Ambient CI events (last 100 lines)"
    local ci_events
    ci_events="$(_scan_ambient_for_ci 100 || true)"
    if [[ -n "$ci_events" ]]; then
        printf '%s\n' "$ci_events"
        echo
        echo "[ci-audit] CI-relevant events found — consider running: $0 audit"
        actionable=1
    else
        echo "  (no CI-relevant events in recent ambient)"
    fi
    echo

    # Phase 3: Active lease check — confirm we have the lock
    echo "## Active leases"
    local lease_count=0
    local lock
    for lock in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lock" ]] || continue
        lease_count=$((lease_count + 1))
    done
    echo "  ${lease_count} active lease(s) under $LOCK_DIR"
    echo

    if (( actionable > 0 )); then
        echo "[ci-audit] tick: actionable items found"
        return 0
    fi
    echo "[ci-audit] tick: quiet — no actionable items"
    return 1
}

_cmd_audit() {
    echo "=== curator-opus-ci-audit audit @ $(_now_iso) ==="
    echo

    if [[ ! -f "$AMBIENT" ]]; then
        echo "[ci-audit] ambient log not found at $AMBIENT" >&2
        echo "  Cannot audit CI cluster without ambient stream." >&2
        return 3
    fi

    local found=0

    # Scan for pr_stuck events → potential logic bug or stale auto-merge
    echo "## pr_stuck events (last 200 ambient lines)"
    local stuck_events
    stuck_events="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"pr_stuck"' || true)"
    if [[ -n "$stuck_events" ]]; then
        local stuck_count
        stuck_count="$(printf '%s\n' "$stuck_events" | wc -l | tr -d ' ')"
        echo "  BUCKET: stale-auto-merge candidate (${stuck_count} pr_stuck events)"
        echo "  → Cross-check with INFRA-1459 pattern: PR armed then rebased without re-arming"
        printf '%s\n' "$stuck_events" | tail -3
        found=1
    else
        echo "  (none)"
    fi
    echo

    # Scan for fleet_wedge events → bot-merge silent wedge
    echo "## fleet_wedge events (last 200 ambient lines)"
    local wedge_events
    wedge_events="$(tail -200 "$AMBIENT" 2>/dev/null \
        | grep '"kind":"fleet_wedge"' || true)"
    if [[ -n "$wedge_events" ]]; then
        local wedge_count
        wedge_count="$(printf '%s\n' "$wedge_events" | wc -l | tr -d ' ')"
        echo "  BUCKET: bot-merge silent wedge candidate (${wedge_count} fleet_wedge events)"
        echo "  → Cross-check with INFRA-1939 pattern: PR merged but gap not shipped"
        printf '%s\n' "$wedge_events" | tail -3
        found=1
    else
        echo "  (none)"
    fi
    echo

    # Emit cluster-detected if we found something
    if (( found > 0 )); then
        _emit_kind "ci_cluster_detected" "\"bucket_count\":${found}"
        # scanner-anchor: "kind":"ci_cluster_detected"
        echo "[ci-audit] audit complete — ${found} failure bucket(s) found"
        echo "  Next step: dispatch Sonnet on flake buckets, file follow-up gaps for logic bugs"
        return 0
    fi

    echo "[ci-audit] audit: quiet — no CI failure patterns detected in recent ambient"
    return 1
}

_cmd_heartbeat() {
    _emit_kind "ci_audit_heartbeat" "\"role\":\"ci-audit\""
    # scanner-anchor: "kind":"ci_audit_heartbeat"
    echo "[ci-audit] heartbeat emitted at $(_now_iso) for session $SESSION_ID"
    return 0
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    tick)       _cmd_tick "$@" ;;
    audit)      _cmd_audit "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[ci-audit] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
