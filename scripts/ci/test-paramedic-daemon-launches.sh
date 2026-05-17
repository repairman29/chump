#!/usr/bin/env bash
# test-paramedic-daemon-launches.sh — INFRA-1597
#
# Regression test: `chump paramedic triage --dry-run` (the one-shot rule-engine
# entrypoint) must:
#   1. exit 0 (no fall-through to chat-mode / LLM API call),
#   2. emit a JSON `ActionPlan` shape on stdout (not English prose),
#   3. NOT spam r2d2 `unable to open database file` errors on stderr.
#
# Symptom this guards against (INFRA-1597 root cause): when the launchd plist
# sets cwd=/, `db_pool::chump_memory_db_path()` resolved to
# `/sessions/chump_memory.db` (read-only) and r2d2 init looped forever; the
# binary also lacked the `paramedic` dispatch arm and fell through to the
# chat agent. Both must stay fixed.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
[[ -x "$CHUMP_BIN" ]] || CHUMP_BIN="$REPO_ROOT/target/release/chump"

echo "=== INFRA-1597 paramedic daemon launch test ==="

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found (run cargo build first)"
    exit 0
fi
ok "chump binary present at $CHUMP_BIN"

# 1. `chump paramedic --help` must succeed (CLI parser arm exists; not chat).
HELP_OUT="$("$CHUMP_BIN" paramedic --help 2>&1)"
HELP_RC=$?
if [[ "$HELP_RC" -eq 0 ]] && grep -q "Subcommands:" <<<"$HELP_OUT" && grep -q "daemon" <<<"$HELP_OUT"; then
    ok "paramedic --help dispatches to subcommand parser (no chat fall-through)"
else
    fail "paramedic --help did not show daemon subcommand (got rc=$HELP_RC)"
    echo "    --- output ---"
    sed 's/^/    /' <<<"$HELP_OUT" | head -20
fi

# 2. One-shot triage in dry-run with a scratch CHUMP_HOME must exit 0 +
#    emit JSON shape, not LLM prose, and not spam r2d2 errors.
SCRATCH="$(mktemp -d -t chump-paramedic-1597-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
git init -q "$SCRATCH" 2>/dev/null
mkdir -p "$SCRATCH/sessions"

STDOUT_FILE="$SCRATCH/stdout.txt"
STDERR_FILE="$SCRATCH/stderr.txt"
CHUMP_HOME="$SCRATCH" CHUMP_REPO="$SCRATCH" CHUMP_PARAMEDIC_DRY_RUN=1 \
    timeout 30 "$CHUMP_BIN" paramedic triage --dry-run \
    >"$STDOUT_FILE" 2>"$STDERR_FILE"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    ok "paramedic triage --dry-run exited 0"
else
    fail "paramedic triage --dry-run exited $RC"
    echo "    --- stderr (last 20) ---"
    tail -20 "$STDERR_FILE" | sed 's/^/    /'
fi

# 3. Stdout must be JSON ActionPlan, not English prose / LLM chat.
#    Sentinel keys from the ActionPlan struct: "items" and either "ts" or "cycle".
if grep -q '"items"' "$STDOUT_FILE"; then
    ok "stdout contains ActionPlan JSON (items[] key found)"
else
    fail "stdout is not JSON ActionPlan — likely LLM fall-through"
    echo "    --- stdout (first 10 lines) ---"
    head -10 "$STDOUT_FILE" | sed 's/^/    /'
fi

# 4. r2d2 path-resolution regression guard.
if grep -q 'unable to open database file: /sessions' "$STDERR_FILE"; then
    fail "r2d2 still resolving to /sessions/... — CHUMP_HOME not honored"
else
    ok "no /sessions/chump_memory.db r2d2 error (CHUMP_HOME honored)"
fi

# 5. Sanity: the LLM 400-error signature from the unfixed binary must NOT appear.
if grep -qi 'function_declarations\|Local API error 400' "$STDERR_FILE" "$STDOUT_FILE"; then
    fail "chat-mode API error detected — paramedic still falls through to agent"
else
    ok "no chat-mode LLM API errors (paramedic dispatch arm reached)"
fi

echo "==========================================="
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
