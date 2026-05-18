#!/usr/bin/env bash
# scripts/ci/test-pr-rescue-audit-handler.sh — INFRA-1618
#
# Verifies the new ACTIVE-FIX handler `audit_chump_bin_hardcoded` in
# scripts/coord/pr-failure-auto-rescue.sh correctly:
#   1. Recognizes the workflow-YAML-level CHUMP_BIN-hardcode failure log
#   2. Is wired into the dispatch list BEFORE the passive chump_bin_not_found
#   3. Emits the right ambient-event outcome string
#
# Strategy: source the daemon (its functions are bash functions), call the
# handler with a synthetic failure log, capture the rescue.log + ambient
# emissions, assert shape.
#
# Avoids real `gh pr update-branch` by setting DRY_RUN=1; that's an existing
# daemon convention.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1618 pr-rescue audit-handler tests ==="

DAEMON="$REPO_ROOT/scripts/coord/pr-failure-auto-rescue.sh"

# ── Source-level contract checks ──────────────────────────────────────────────
if grep -q "handle_audit_chump_bin_hardcoded" "$DAEMON" 2>/dev/null; then
    ok "daemon defines handle_audit_chump_bin_hardcoded"
else
    fail "daemon missing handle_audit_chump_bin_hardcoded"
fi

if grep -qE "for handler in audit_chump_bin_hardcoded" "$DAEMON" 2>/dev/null; then
    ok "audit_chump_bin_hardcoded is FIRST in dispatch list (active preempts passive)"
else
    fail "audit_chump_bin_hardcoded not first in dispatch (should preempt passive chump_bin_not_found)"
fi

# Pattern matches both debug + release variants
if grep -qE 'target/\(debug\|release\)/chump not found' "$DAEMON" 2>/dev/null; then
    ok "pattern matches target/{debug,release}/chump not found"
else
    fail "handler pattern doesn't match expected log shape"
fi

# Active rebase path
if grep -q "gh pr update-branch" "$DAEMON" 2>/dev/null; then
    ok "handler calls gh pr update-branch (active fix path)"
else
    fail "handler missing gh pr update-branch (no active rebase)"
fi

# Active outcome strings — distinct from passive awaiting_pr_2266_merge
for outcome in rebased_against_main rebase_failed waiting_for_main; do
    if grep -q "\"outcome\":\"$outcome\"" "$DAEMON" 2>/dev/null \
        || grep -q "outcome=$outcome\|outcome=\"$outcome\"" "$DAEMON" 2>/dev/null \
        || grep -q "$outcome" "$DAEMON" 2>/dev/null; then
        ok "emits outcome=$outcome"
    else
        fail "missing outcome=$outcome"
    fi
done

# Ensure the old passive marker "awaiting_pr_2266_merge" is NOT emitted by
# the new handler (it's only used by chump_bin_not_found legacy handler).
new_handler_section=$(awk '/^handle_audit_chump_bin_hardcoded/,/^}/' "$DAEMON")
if echo "$new_handler_section" | grep -q "awaiting_pr_2266_merge"; then
    fail "new handler still emits passive awaiting_pr_2266_merge"
else
    ok "new handler does NOT emit passive awaiting_pr_2266_merge"
fi

# ── Behavioural test: call handler in DRY_RUN with synthetic log ──────────────
# We source the daemon as a library by sourcing it with a sentinel that
# prevents `run_once` / loop from executing. The script structure has the
# `if [[ $LOOP -eq 1 ]]; then ... else run_once` at the bottom; we set
# LOOP=0 and override run_once before sourcing.

TMP="$(mktemp -d -t pr-rescue-audit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Stand up a dummy REPO_ROOT with .chump-locks so log_rescue + emit_event work
mkdir -p "$TMP/.chump-locks"

# Build a tiny harness that sources the daemon's functions WITHOUT triggering
# the trailing if/else. We grep up to "# ── MAIN LOOP" and source that prefix.
HARNESS="$TMP/daemon_prefix.sh"
awk '/^# ── MAIN LOOP/{exit} {print}' "$DAEMON" > "$HARNESS"

cat > "$TMP/run-handler.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export REPO_ROOT="$TMP"
export DRY_RUN=1
export LOG_FILE="$TMP/.chump-locks/pr-rescue.log"
export AMBIENT_FILE="$TMP/.chump-locks/ambient.jsonl"
# Shadow log_rescue + emit_event with simple appenders so we don't depend on
# the daemon's internal log paths.
log_rescue() { printf '{"pr":%s,"handler":"%s","outcome":"%s"}\n' "\$1" "\$2" "\$3" >> "\$LOG_FILE"; }
emit_event() { printf '{"kind":"%s",%s}\n' "\$1" "\$2" >> "\$AMBIENT_FILE"; }
say() { :; }  # mute chatter in the test
source "$HARNESS"

# Override the shadowed functions AGAIN (sourcing may redefine them).
log_rescue() { printf '{"pr":%s,"handler":"%s","outcome":"%s"}\n' "\$1" "\$2" "\$3" >> "\$LOG_FILE"; }
emit_event() { printf '{"kind":"%s",%s}\n' "\$1" "\$2" >> "\$AMBIENT_FILE"; }
say() { :; }

# Synthetic failure log matching the bug pattern
FAILURE_LOG="FATAL: /Users/jeffadkins/actions-runner-chump-4/_work/chump/chump/target/debug/chump not found"

handle_audit_chump_bin_hardcoded 9999 "\$FAILURE_LOG"
rc=\$?
echo "exit=\$rc"
EOF
chmod +x "$TMP/run-handler.sh"

OUT="$("$TMP/run-handler.sh" 2>&1)"
RC=$(echo "$OUT" | grep -oE 'exit=[0-9]+' | head -1 | cut -d= -f2)

if [[ "$RC" == "0" ]]; then
    ok "handler returns 0 (success) on matching log + DRY_RUN"
else
    fail "handler returned rc=$RC (output: $(echo "$OUT" | head -c 200))"
fi

# Rescue log got a line
if [[ -s "$TMP/.chump-locks/pr-rescue.log" ]]; then
    line=$(cat "$TMP/.chump-locks/pr-rescue.log")
    if echo "$line" | grep -q '"handler":"audit_chump_bin_hardcoded"'; then
        ok "log_rescue called with handler=audit_chump_bin_hardcoded"
    else
        fail "log_rescue line missing audit_chump_bin_hardcoded ($line)"
    fi
    if echo "$line" | grep -q '"outcome":"dry_run_skip"'; then
        ok "DRY_RUN path emits outcome=dry_run_skip (no real gh call attempted)"
    else
        fail "DRY_RUN path didn't emit dry_run_skip ($line)"
    fi
else
    fail "rescue log empty — handler didn't log_rescue"
fi

# ── Non-matching log → handler returns 99 (not-my-pattern) ────────────────────
cat > "$TMP/run-non-matching.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export REPO_ROOT="$TMP"; export DRY_RUN=1
log_rescue() { :; }; emit_event() { :; }; say() { :; }
source "$HARNESS"
log_rescue() { :; }; emit_event() { :; }; say() { :; }
handle_audit_chump_bin_hardcoded 9999 "some unrelated cargo clippy lint error"
echo "exit=\$?"
EOF
chmod +x "$TMP/run-non-matching.sh"
NM_RC=$("$TMP/run-non-matching.sh" 2>&1 | grep -oE 'exit=[0-9]+' | head -1 | cut -d= -f2)
if [[ "$NM_RC" == "99" ]]; then
    ok "non-matching log → return 99 (not-my-pattern)"
else
    fail "non-matching log returned $NM_RC (expected 99)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
