#!/usr/bin/env bash
# test-resilient-1738-chumpd-version-no-takeover.sh — RESILIENT-1738
#
# `chumpd --version` (or any other non-worker argv probe) must NEVER reach
# takeover()'s pkill sweep. Regression for the deploy-lag watchdog incident:
# a plain --version probe used to fall through to the normal supervisor
# startup path, whose takeover() ran `pkill -f dispatch/worker.sh`
# host-wide, killing every live worker on the node every time the watchdog
# polled (every 5-10 min).
#
#  - chumpd --version exits 0, prints "chumpd <ver> (<sha>)"
#  - a concurrently running (fake) dispatch/worker.sh process SURVIVES the
#    --version call
#  - chumpd --help exits 0, no side effects
#  - an unrecognized argv refuses with exit 2 (never starts the supervisor)
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chumpd"
if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build -p chumpd..."
    (cd "$REPO_ROOT" && cargo build -p chumpd -q) || { echo "FAIL: build"; exit 1; }
fi
[[ -x "$BIN" ]] || BIN="$REPO_ROOT/target/debug/chumpd"

echo "=== RESILIENT-1738 chumpd --version / takeover-scoping test ==="

FIX="$(mktemp -d)"
mkdir -p "$FIX/repo/scripts/dispatch" "$FIX/repo/.chump-locks" "$FIX/repo/.chump" "$FIX/home/.chump"
cat > "$FIX/repo/scripts/dispatch/worker.sh" <<'MOCK'
#!/usr/bin/env bash
while true; do sleep 1; done
MOCK
chmod +x "$FIX/repo/scripts/dispatch/worker.sh"

# A fake live worker tick — same argv pattern a real worker.sh process has,
# so a host-wide `pkill -f dispatch/worker.sh` would catch it too.
/bin/bash "$FIX/repo/scripts/dispatch/worker.sh" &
FAKE_WORKER_PID=$!
sleep 1

# 1. --version exits 0 and prints version + sha, no takeover side effects.
OUT="$(HOME="$FIX/home" CHUMP_REPO="$FIX/repo" "$BIN" --version 2>&1)"
CODE=$?
if [[ "$CODE" -eq 0 ]]; then ok "--version exits 0"; else fail "--version exited $CODE"; fi
if echo "$OUT" | grep -qE '^chumpd [0-9.]+ \([0-9a-f]+\)$|^chumpd [0-9.]+ \(unknown\)$'; then
    ok "--version output has version + sha: $OUT"
else
    fail "--version output malformed: $OUT"
fi

# 2. the fake worker tick survives the --version call.
sleep 1
if kill -0 "$FAKE_WORKER_PID" 2>/dev/null; then
    ok "concurrent worker.sh tick survives chumpd --version"
else
    fail "chumpd --version killed the live worker.sh tick"
fi

# 3. no chumpd-owned-pids.json takeover sweep artifact was created/cleared
#    unexpectedly (no supervisor state touched by a --version probe).
if [[ ! -f /tmp/chumpd-status.json.tmp ]]; then
    ok "--version wrote no supervisor status artifacts"
else
    fail "--version touched supervisor status artifacts"
fi

# 4. --help exits 0, no side effects.
HELP_OUT="$(HOME="$FIX/home" CHUMP_REPO="$FIX/repo" "$BIN" --help 2>&1)"
HELP_CODE=$?
if [[ "$HELP_CODE" -eq 0 ]] && echo "$HELP_OUT" | grep -q "chumpd"; then
    ok "--help exits 0 with usage text"
else
    fail "--help exited $HELP_CODE: $HELP_OUT"
fi
if kill -0 "$FAKE_WORKER_PID" 2>/dev/null; then
    ok "concurrent worker.sh tick survives chumpd --help"
else
    fail "chumpd --help killed the live worker.sh tick"
fi

# 5. unrecognized argv refuses with exit 2, never starts the supervisor.
UNKNOWN_OUT="$(HOME="$FIX/home" CHUMP_REPO="$FIX/repo" timeout 5 "$BIN" --bogus-flag 2>&1)"
UNKNOWN_CODE=$?
if [[ "$UNKNOWN_CODE" -eq 2 ]]; then
    ok "unrecognized argv exits 2"
else
    fail "unrecognized argv exited $UNKNOWN_CODE (expected 2): $UNKNOWN_OUT"
fi
if kill -0 "$FAKE_WORKER_PID" 2>/dev/null; then
    ok "concurrent worker.sh tick survives an unrecognized chumpd argv"
else
    fail "unrecognized chumpd argv killed the live worker.sh tick"
fi

kill -9 "$FAKE_WORKER_PID" 2>/dev/null
wait "$FAKE_WORKER_PID" 2>/dev/null
rm -rf "$FIX"
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
