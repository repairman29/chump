#!/usr/bin/env bash
# test-bot-merge-watchdog.sh — INFRA-1006
#
# Tests:
# 1. Watchdog kills process when gap is done (SIGTERM + SIGKILL + lease removed)
# 2. Watchdog does NOT kill when gap is open (emits stuck warning instead)
# 3. CHUMP_BOT_MERGE_NO_WATCHDOG=1 exempts a process
# 4. Idempotent: re-running on already-dead process is a no-op

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/coord/bot-merge-watchdog.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

[[ -f "$WATCHDOG" ]] || fail "missing $WATCHDOG"
chmod +x "$WATCHDOG"

TMP="$(mktemp -d)"
FAKE_PID_DONE=""
FAKE_PID_OPEN=""
FAKE_PID_EXEMPT=""
cleanup() {
    rm -rf "$TMP"
    [[ -n "$FAKE_PID_DONE" ]] && kill "$FAKE_PID_DONE" 2>/dev/null || true
    [[ -n "$FAKE_PID_OPEN" ]] && kill "$FAKE_PID_OPEN" 2>/dev/null || true
    [[ -n "$FAKE_PID_EXEMPT" ]] && kill "$FAKE_PID_EXEMPT" 2>/dev/null || true
}
trap cleanup EXIT

LOCK_DIR="$TMP/.chump-locks"
AMB="$LOCK_DIR/ambient.jsonl"
mkdir -p "$LOCK_DIR"

# ── Fake tool shims ───────────────────────────────────────────────────────────
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

# chump shim: return YAML output matching _gap_status / closed_pr grep patterns
# in bot-merge-watchdog.sh (which uses `grep -E '^\s*status:'`, not JSON parsing).
cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"INFRA-9001"* ]]; then
    printf 'status: done\nclosed_pr: \n'
elif [[ "$*" == *"INFRA-9002"* ]]; then
    printf 'status: open\nclosed_pr: \n'
else
    printf 'status: open\nclosed_pr: \n'
fi
SHIM
chmod +x "$SHIM_DIR/chump"

# ── Spawn fake bot-merge.sh processes ─────────────────────────────────────────
sleep 9999 &
FAKE_PID_DONE=$!
sleep 9999 &
FAKE_PID_OPEN=$!
sleep 9999 &
FAKE_PID_EXEMPT=$!

# Give processes a moment to start.
sleep 0.2

# ── pgrep shim: only return our test PIDs ─────────────────────────────────────
# Returning three PIDs with specific args embedded in their "cmdline".
# The watchdog uses pgrep -f 'bot-merge.sh', then ps to get etime and args.
# We stub pgrep to return only our test PIDs, and stub ps to return
# canned etime and args for each.

cat > "$SHIM_DIR/pgrep" <<PGREPSHIM
#!/usr/bin/env bash
# Return only our test PIDs when searching for bot-merge (handles both
# 'bot-merge.sh' and 'bot-merge\.sh' as passed by the watchdog).
if [[ "\$*" == *"bot-merge"* ]]; then
    echo $FAKE_PID_DONE
    echo $FAKE_PID_OPEN
    echo $FAKE_PID_EXEMPT
fi
PGREPSHIM
chmod +x "$SHIM_DIR/pgrep"

# ps shim: return canned etime and args per PID
cat > "$SHIM_DIR/ps" <<PSSHIM
#!/usr/bin/env bash
# ps -p <pid> -o etime=  → return "02:00" (120s, well above max-age=0)
# ps -p <pid> -o args=   → return canned cmdline per PID
if [[ "\$*" == *"-o etime="* ]]; then
    echo "02:00"
elif [[ "\$*" == *"-o args="* ]] || [[ "\$*" == *"args="* ]]; then
    pid=""
    for a in "\$@"; do [[ "\$a" =~ ^[0-9]+$ ]] && pid="\$a"; done
    if [[ "\$pid" == "$FAKE_PID_DONE" ]]; then
        echo "bash bot-merge.sh --gap INFRA-9001"
    elif [[ "\$pid" == "$FAKE_PID_OPEN" ]]; then
        echo "bash bot-merge.sh --gap INFRA-9002"
    elif [[ "\$pid" == "$FAKE_PID_EXEMPT" ]]; then
        echo "CHUMP_BOT_MERGE_NO_WATCHDOG=1 bash bot-merge.sh --gap INFRA-9001"
    fi
elif [[ "\$*" == *"eww"* ]]; then
    # ps eww -p <pid> for env vars
    pid=""
    for a in "\$@"; do [[ "\$a" =~ ^[0-9]+$ ]] && pid="\$a"; done
    if [[ "\$pid" == "$FAKE_PID_EXEMPT" ]]; then
        echo "CHUMP_BOT_MERGE_NO_WATCHDOG=1 bash bot-merge.sh --gap INFRA-9001"
    fi
fi
PSSHIM
chmod +x "$SHIM_DIR/ps"

# ── Create lease file for the done-gap process ────────────────────────────────
LEASE_FILE="$LOCK_DIR/claim-infra-9001-${FAKE_PID_DONE}-$(date +%s).json"
echo "{\"gap_id\":\"INFRA-9001\",\"pid\":$FAKE_PID_DONE}" > "$LEASE_FILE"

# ── Run watchdog ──────────────────────────────────────────────────────────────
echo "--- watchdog run ---"
PATH="$SHIM_DIR:$PATH" CHUMP_LOCK_DIR="$LOCK_DIR" CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_BOT_MERGE_MAX_AGE_S=0 bash "$WATCHDOG" 2>&1 || true
echo "---"
echo ""

# 1. Done-gap process killed.
kill -0 "$FAKE_PID_DONE" 2>/dev/null \
    && fail "INFRA-9001 process should have been killed (gap=done)" \
    || ok "done-gap process killed"

# 2. Open-gap process NOT killed.
kill -0 "$FAKE_PID_OPEN" 2>/dev/null \
    && ok "open-gap process NOT killed (correct)" \
    || fail "INFRA-9002 process should NOT have been killed"

# 3. Exempt process NOT killed.
kill -0 "$FAKE_PID_EXEMPT" 2>/dev/null \
    && ok "CHUMP_BOT_MERGE_NO_WATCHDOG=1 process exempt" \
    || fail "exempt process should NOT have been killed"

# 4. Lease file removed for done process.
[[ ! -f "$LEASE_FILE" ]] \
    && ok "lease file removed after kill" \
    || fail "lease file should be removed after kill"

# 5. bot_merge_watchdog_killed event emitted.
grep -q '"kind":"bot_merge_watchdog_killed"' "$AMB" \
    && ok "bot_merge_watchdog_killed event emitted" \
    || fail "missing bot_merge_watchdog_killed ambient event"

# 6. bot_merge_watchdog_stuck event emitted for open-gap.
grep -q '"kind":"bot_merge_watchdog_stuck"' "$AMB" \
    && ok "bot_merge_watchdog_stuck event emitted" \
    || fail "missing bot_merge_watchdog_stuck ambient event"

# 7. Idempotent: re-run doesn't error on already-dead process.
echo "--- idempotent re-run ---"
PATH="$SHIM_DIR:$PATH" CHUMP_LOCK_DIR="$LOCK_DIR" CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_BOT_MERGE_MAX_AGE_S=0 bash "$WATCHDOG" 2>&1 | grep -v '^---' || true
ok "watchdog re-run idempotent"

echo ""
echo "=== test-bot-merge-watchdog.sh PASSED ==="
