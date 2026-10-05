#!/usr/bin/env bash
# subprocess-auth-smoke.sh — INFRA-2354 (META-269 sub-5): subprocess-auth smoke.
#
# WHY THIS EXISTS: fix-trunk-dispatcher.sh's subprocess mode (INFRA-2340/2341)
# spawns a headless `claude -p` sub-agent when trunk is RED. If the credential
# that subprocess would use is broken (401/expired/absent), the Sonnet dies in
# seconds and the trunk-red incident burns its dispatch slot on a doomed
# process instead of falling back cleanly. This script runs a cheap
# hello-world `claude -p` call BEFORE that dispatch, so the caller can gate on
# a real verdict instead of finding out after the subprocess is already dead.
#
# Distinct from scripts/coord/auth-status.sh: auth-status.sh probes oauth AND
# api-key credential *validity* independently and reports a precedence
# verdict. This script probes the *actual subprocess invocation path*
# (`claude -p ... --dangerously-skip-permissions`-shaped call, matching what
# fix-trunk-dispatcher.sh really spawns) with a hard timeout, and is meant to
# be cheap enough to run as a pre-check on every dispatch tick.
#
# Exit 0 = subprocess auth path works (claude_p_exit_code=0, PONG observed).
# Exit 1 = subprocess auth path is dead (timeout, non-zero exit, no PONG, or
#          `claude` missing from PATH) — degrades gracefully, never crashes.
#
# Usage: subprocess-auth-smoke.sh [--quiet]
#
# Env overrides:
#   CHUMP_SUBPROC_SMOKE_TIMEOUT_S   hard timeout for the claude -p call (default: 30)
#   CHUMP_SUBPROC_SMOKE_MODEL       model to probe with (default: haiku — cheapest)
#   CHUMP_SUBPROC_SMOKE_AMBIENT     override ambient.jsonl path (used in tests)
#
# Emits:
#   kind=subprocess_auth_ok    claude -p subprocess auth path works
#   kind=subprocess_auth_dead  claude -p subprocess auth path is broken/absent

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
  MAIN_REPO="$REPO_ROOT"
else
  MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

TIMEOUT_S="${CHUMP_SUBPROC_SMOKE_TIMEOUT_S:-30}"
MODEL="${CHUMP_SUBPROC_SMOKE_MODEL:-haiku}"
AMBIENT="${CHUMP_SUBPROC_SMOKE_AMBIENT:-$LOCK_DIR/ambient.jsonl}"
QUIET=0
for a in "$@"; do case "$a" in --quiet|-q) QUIET=1 ;; esac; done

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { [[ "$QUIET" -eq 1 ]] || printf '[subprocess-auth-smoke %s] %s\n' "$TS" "$*" >&2; }

# scanner-anchor: "kind":"subprocess_auth_ok"
# scanner-anchor: "kind":"subprocess_auth_dead"
emit_ambient() {
  local kind="$1" extra="$2"
  printf '{"ts":"%s","kind":"%s",%s}\n' "$TS" "$kind" "$extra" >> "$AMBIENT" 2>/dev/null || true
}

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH; subprocess auth path is dead"
  emit_ambient "subprocess_auth_dead" "\"reason\":\"claude_not_on_path\",\"claude_p_exit_code\":127"
  echo "SUBPROCESS-AUTH ✗ DEAD — claude CLI not found on PATH."
  exit 1
fi

_out="$(cd /tmp && timeout "$TIMEOUT_S" claude -p "Reply with exactly: PONG" --model "$MODEL" 2>&1)"
_rc=$?

if [[ $_rc -eq 0 ]] && grep -q "PONG" <<<"$_out"; then
  log "claude -p subprocess auth OK (exit=$_rc)"
  emit_ambient "subprocess_auth_ok" "\"claude_p_exit_code\":$_rc,\"model\":\"$MODEL\""
  echo "SUBPROCESS-AUTH ✓ OK — claude -p subprocess auth path works (model=$MODEL)."
  exit 0
fi

log "claude -p subprocess auth DEAD (exit=$_rc, output=${_out:0:200})"
emit_ambient "subprocess_auth_dead" "\"claude_p_exit_code\":$_rc,\"model\":\"$MODEL\""
echo "SUBPROCESS-AUTH ✗ DEAD — claude -p subprocess exited $_rc without PONG. FIX: check auth-status.sh for the credential precedence trap."
exit 1
