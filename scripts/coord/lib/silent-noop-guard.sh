#!/usr/bin/env bash
# scripts/coord/lib/silent-noop-guard.sh — INFRA-2009 (THE FLOOR Phase 2)
#
# Sourceable guard that generalizes the INFRA-1988 sentinel + EXIT trap
# pattern from scripts/git-hooks/pre-push to all 3 critical floor daemons
# (cluster-detector, wedge-state-machine, recovery-queue-service).
#
# The INFRA-1986 failure mode: a daemon exits rc=0 without doing its main
# work — silently sailing through. This guard converts that invisible
# failure into a visible ambient event (kind=daemon_silent_noop) so the
# fleet detects the regression in hours rather than days.
#
# Usage — three steps in the calling script:
#
#   # 1. Source this file (after REPO_ROOT + AMBIENT are set):
#   source "$(dirname "${BASH_SOURCE[0]}")/scripts/coord/lib/silent-noop-guard.sh"
#   # (or use the absolute path)
#
#   # 2. Declare the guard (after env vars are ready):
#   _sng_install_guard \
#       "cluster_detector"               # source tag (no spaces)
#       "$AMBIENT"                       # path to ambient.jsonl
#
#   # 3. At the END of the main work body (not the bypass / early-exit path):
#   _sng_mark_done
#
# The EXIT trap fires whenever the shell exits. If _sng_mark_done was
# never called and rc=0 and input was non-trivial, kind=daemon_silent_noop
# is emitted.
#
# "Non-trivial input" for each daemon:
#   cluster-detector      → DETECTED was non-empty (PRs to cluster)
#   wedge-state-machine   → DETECTIONS was non-empty (events to process)
#   recovery-queue-service → REQUESTS was non-empty (requests to service)
#
# The daemon sets _SNG_HAD_INPUT=1 just before its main work block if
# there was real input. This guards against false-positive alarms when the
# daemon legitimately has nothing to do.
#
# Variables written by this lib (all prefixed _SNG_):
#   _SNG_MAIN_WORK_DONE  set to 1 by _sng_mark_done
#   _SNG_HAD_INPUT       set to 1 by caller when there is real work to do
#   _SNG_SOURCE_TAG      caller-supplied daemon name (for event "source" field)
#   _SNG_AMBIENT         path to ambient.jsonl (for event write)

# ── Internal state ─────────────────────────────────────────────────────────────
_SNG_MAIN_WORK_DONE=0
_SNG_HAD_INPUT=0
_SNG_SOURCE_TAG=""
_SNG_AMBIENT=""

# ── Public API ─────────────────────────────────────────────────────────────────

# _sng_install_guard <source_tag> <ambient_path>
#
# Call once after REPO_ROOT + AMBIENT are resolved. Installs the EXIT trap.
_sng_install_guard() {
    _SNG_SOURCE_TAG="${1:-unknown_daemon}"
    _SNG_AMBIENT="${2:-}"
    trap _sng_check_on_exit EXIT
}

# _sng_mark_done
#
# Call at the END of the main work body (not in bypass paths).
_sng_mark_done() {
    _SNG_MAIN_WORK_DONE=1
}

# ── EXIT trap ──────────────────────────────────────────────────────────────────
_sng_check_on_exit() {
    local rc="$?"
    # Only alarm on rc=0 (loud non-zero exits already signal failure).
    [[ "$rc" -ne 0 ]] && return "$rc"
    # Only alarm if the daemon had real input to process but skipped the body.
    [[ "$_SNG_HAD_INPUT" -eq 0 ]] && return 0
    # If main work was done, no alarm.
    [[ "$_SNG_MAIN_WORK_DONE" -eq 1 ]] && return 0

    # Alarm: daemon silently exited without processing its input.
    local amb="${_SNG_AMBIENT:-}"
    if [[ -n "$amb" ]]; then
        mkdir -p "$(dirname "$amb")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"daemon_silent_noop","source":"%s","reason":"main_work_body_skipped_despite_input"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$_SNG_SOURCE_TAG" \
            >> "$amb" 2>/dev/null || true
    fi
    return 0
}
