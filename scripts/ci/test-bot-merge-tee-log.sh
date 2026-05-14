#!/usr/bin/env bash
# scripts/ci/test-bot-merge-tee-log.sh — INFRA-1034
#
# Verifies bot-merge.sh always tees its output to a per-PID log file so
# operators can `tail -f` regardless of how the caller redirects.
#
# We don't run bot-merge end-to-end (cargo dependencies). Instead:
#   1. Static-grep: the tee block exists with the right env-var opt-out.
#   2. Functional: source the relevant snippet in isolation, redirect through
#      tail -15, verify the log file contains output even though tail's
#      buffering would have suppressed it on a naked pipe.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Test 1: static-grep ──────────────────────────────────────────────────────
grep -q 'INFRA-1034' "$BM" || fail "INFRA-1034 banner missing"
grep -q '_BM_LOG_FILE=' "$BM" || fail "_BM_LOG_FILE assignment missing"
grep -q 'exec > >(tee -a "\$_BM_LOG_FILE")' "$BM" \
    || fail "exec tee redirect missing"
grep -q 'CHUMP_BOT_MERGE_NO_TEE' "$BM" \
    || fail "CHUMP_BOT_MERGE_NO_TEE opt-out missing"
ok "tee block present with log path + opt-out"

# ── Test 2: tee survives a tail -15 caller pipe ──────────────────────────────
# Simulate: a script that prints 100 lines then exits. Without tee, piping
# through tail -15 + background only shows the last 15 once tail flushes.
# With tee to a log file, the file has ALL 100 lines regardless of pipe.
LOG="$TMP/sim.log"
SCRIPT="$TMP/sim.sh"
cat >"$SCRIPT" <<EOF
#!/usr/bin/env bash
# Mimic the bot-merge tee setup.
LOG="$LOG"
exec > >(tee -a "\$LOG") 2>&1
for i in \$(seq 1 100); do
    echo "line-\$i"
    [ \$((i % 20)) -eq 0 ] && sleep 0.05
done
EOF
chmod +x "$SCRIPT"

# Run with tail -15 piping in background, just like today's bug case.
bash "$SCRIPT" 2>&1 | tail -15 >"$TMP/tail_out.txt" &
PID=$!
wait "$PID"

# The log file must contain all 100 lines.
log_count=$(wc -l <"$LOG" | tr -d ' ')
[[ "$log_count" -eq 100 ]] \
    || fail "log file should have 100 lines, got $log_count"
# The tail output must contain only the last 15 (normal tail behavior).
tail_count=$(wc -l <"$TMP/tail_out.txt" | tr -d ' ')
[[ "$tail_count" -eq 15 ]] \
    || fail "tail output should have 15 lines, got $tail_count"
ok "tee log captures all 100 lines while caller's tail -15 pipe only sees 15"

# ── Test 3: opt-out env var skips the tee ───────────────────────────────────
# We can't easily exercise the inside-bot-merge opt-out without running
# the whole script, so use a small fixture mirroring the same conditional.
LOG2="$TMP/optout.log"
SCRIPT2="$TMP/sim_optout.sh"
cat >"$SCRIPT2" <<'EOF'
#!/usr/bin/env bash
LOG="$1"
if [[ "${CHUMP_BOT_MERGE_NO_TEE:-0}" != "1" ]]; then
    exec > >(tee -a "$LOG") 2>&1
fi
echo "should-not-be-in-log-when-optout-set"
EOF
chmod +x "$SCRIPT2"

CHUMP_BOT_MERGE_NO_TEE=1 bash "$SCRIPT2" "$LOG2" >/dev/null
[[ ! -s "$LOG2" ]] || fail "opt-out=1 should NOT write to log file: $(cat "$LOG2")"
ok "CHUMP_BOT_MERGE_NO_TEE=1 suppresses tee"

# ── Test 4: opt-in (default) DOES write ─────────────────────────────────────
LOG3="$TMP/optin.log"
bash "$SCRIPT2" "$LOG3" >/dev/null
# Wait briefly for tee subprocess to flush + file to materialize. The
# process substitution shell's tee runs detached; under load the kernel
# write may lag the calling shell's return.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$LOG3" ]] && break
    sleep 0.1
done
[[ -s "$LOG3" ]] || fail "default (no opt-out) should write to log"
grep -q "should-not-be-in-log-when-optout-set" "$LOG3" \
    || fail "default log should contain the test marker"
ok "default behavior: tee writes to log"

echo
echo "All INFRA-1034 tee-log tests passed."
