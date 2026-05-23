#!/usr/bin/env bash
# scripts/coord/lib/chump-strict-mode.sh — INFRA-1836 phase 1
#
# Shared helper for CHUMP_NO_BYPASS=1 strict mode. Disables ALL bypass
# paths globally during active-ship sprint windows. Per-bypass call sites
# are wired into this helper in follow-up gaps (see INFRA-1836 AC list).
#
# Usage in a script that honors a bypass env (e.g. CHUMP_FMT_CHECK):
#
#   source "$REPO_ROOT/scripts/coord/lib/chump-strict-mode.sh"
#
#   if [[ "${CHUMP_FMT_CHECK:-1}" == "0" ]]; then
#       _chump_check_no_bypass "CHUMP_FMT_CHECK" "cargo fmt --all check"
#       # ... existing skip logic ...
#   fi
#
# When CHUMP_NO_BYPASS=1 is active:
#   1. Emits ambient kind=no_bypass_violation {bypass_kind, would_have_skipped, session}.
#   2. Prints diagnostic to stderr.
#   3. exit 1.
#
# When CHUMP_NO_BYPASS != 1: returns 0 silently — caller continues its
# normal bypass-skip path.
#
# Operator-facing activation:
#   CHUMP_NO_BYPASS=1 bash scripts/coord/chump-commit.sh ...
#   CHUMP_NO_BYPASS=1 bash scripts/coord/bot-merge.sh --gap INFRA-XXX --auto-merge
#
# Or future: `chump fleet-mode --strict` (deferred to follow-up).
#
# Bypass-the-bypass: there isn't one. That's the point.

_chump_check_no_bypass() {
    local bypass_env="${1:-unknown}"
    local would_have_skipped="${2:-(unspecified)}"

    if [[ "${CHUMP_NO_BYPASS:-0}" != "1" ]]; then
        return 0
    fi

    local ts session ambient_log
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    session="${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}"

    # Resolve ambient log path: env > repo .chump-locks > /tmp fallback.
    if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
        ambient_log="$CHUMP_AMBIENT_LOG"
    else
        local rr
        rr="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
        if [[ -n "$rr" && -d "$rr/.chump-locks" ]]; then
            ambient_log="$rr/.chump-locks/ambient.jsonl"
        else
            ambient_log="/tmp/chump-strict-mode-ambient.jsonl"
        fi
    fi

    # Emit ambient (compact JSON — pairs with event-registry convention).
    printf '{"ts":"%s","kind":"no_bypass_violation","bypass_kind":"%s","would_have_skipped":"%s","session":"%s"}\n' \
        "$ts" "$bypass_env" "$would_have_skipped" "$session" \
        >> "$ambient_log" 2>/dev/null || true

    # Diagnostic.
    cat <<EOM >&2
✖  CHUMP_NO_BYPASS=1 strict mode is active.

   Bypass attempted: ${bypass_env}=0
   Would have skipped: ${would_have_skipped}

   Strict mode disables ALL CHUMP_*_SKIP + --no-verify paths during
   active-ship sprint windows (INFRA-1836). To proceed, either:
     - unset CHUMP_NO_BYPASS (and accept the consequences), or
     - fix the underlying issue so the bypass isn't needed.

   Audit emitted: kind=no_bypass_violation session=${session}
EOM
    exit 1
}

# Convenience for callers that want a quick yes/no without the exit:
#   if _chump_strict_mode_active; then ...; fi
_chump_strict_mode_active() {
    [[ "${CHUMP_NO_BYPASS:-0}" == "1" ]]
}

# Mark the file as sourced so callers don't re-source it.
export _CHUMP_STRICT_MODE_LIB_LOADED=1
