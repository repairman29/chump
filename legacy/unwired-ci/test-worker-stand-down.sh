#!/usr/bin/env bash
# test-worker-stand-down.sh — INFRA-613 regression test.
#
# Verifies that worker.sh exits cleanly via worker_stand_down when
# consecutive empty picks exceed CHUMP_STAND_DOWN_THRESHOLD.
#
# AC: worker exits cleanly (rc=0) within 6 cycles when forced into
# starvation. Emits ambient event kind=worker_stand_down with reasoning
# about which filter tier is exhausted.
#
# Strategy: invoke worker.sh with `chump` stubbed on PATH to always
# return "no pickable gap", short IDLE_SLEEP_S so cycles run quickly,
# low CHUMP_STAND_DOWN_THRESHOLD=2 so stand-down triggers by cycle 2-3.
# Assert rc=0 and the ambient event.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -x "$WORKER" ]] || { echo "[FAIL] worker.sh not executable"; exit 1; }

# macOS ships with `gtimeout` (brew coreutils); ubuntu-latest has `timeout`.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v gtimeout)"
else
    echo "[SKIP] neither timeout nor gtimeout found — install brew coreutils on macOS"
    exit 0
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Stub `chump` to return an empty gap list (forces starvation).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json") echo "[]" ;;
    "gap preflight"*) exit 1 ;;  # Not reached in this test, but fail safely
    "session-track"*) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/chump"

# Stub git so git fetch doesn't hit a remote.
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "fetch" ]]; then exit 0; fi
exec /usr/bin/git "$@"
STUB
chmod +x "$TMP/bin/git"

# Use a fake REPO_ROOT.
FAKE_ROOT="$TMP/fake-repo"
mkdir -p "$FAKE_ROOT/scripts/dev" "$FAKE_ROOT/scripts/dispatch" "$FAKE_ROOT/.chump-locks"
cat > "$FAKE_ROOT/scripts/dev/chump-binary-unwedge.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_ROOT/scripts/dev/chump-binary-unwedge.sh"

# Stub the picker to always return empty.
cat > "$FAKE_ROOT/scripts/dispatch/_pick_and_claim_gap.py" <<'STUB'
#!/usr/bin/env python3
import sys
sys.exit(0)
STUB
chmod +x "$FAKE_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

# Pre-init git.
( cd "$FAKE_ROOT" && /usr/bin/git init -q && /usr/bin/git config user.email t@t \
  && /usr/bin/git config user.name t && touch x && /usr/bin/git add x \
  && /usr/bin/git commit -qm "v0" )

echo "Test: INFRA-613 worker stand-down on starvation"

# Run the worker with low stand-down threshold.
# CHUMP_STAND_DOWN_THRESHOLD=2 means it should exit after 2 consecutive empty cycles.
# Timeout set to 15s gives plenty of buffer (2 cycles × 1s sleep = ~2s + overhead).
out_file="$TMP/worker-out.log"
amb_file="$FAKE_ROOT/.chump-locks/ambient.jsonl"
: > "$amb_file"
: > "$out_file"

set +e
env PATH="$TMP/bin:/usr/bin:/bin" \
    AGENT_ID="1" \
    REPO_ROOT="$FAKE_ROOT" \
    FLEET_LOG_DIR="$TMP/fleet-logs" \
    IDLE_SLEEP_S="1" \
    CHUMP_POLL_JITTER="0" \
    CHUMP_STARVE_THRESHOLD="1" \
    CHUMP_STAND_DOWN_THRESHOLD="2" \
    CHUMP_AMBIENT_LOG="$amb_file" \
    "$TIMEOUT_BIN" 15 bash "$WORKER" >"$out_file" 2>&1
rc=$?
set -e

# Worker should exit cleanly (rc=0) from stand-down, not timeout.
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected rc=0 (clean stand-down exit), got rc=$rc"
    echo "--- output ---"
    cat "$out_file"
    echo "--- ambient ---"
    cat "$amb_file" 2>/dev/null || echo "(no ambient log)"
    exit 1
fi

# Check for stand-down log line.
if ! grep -q "INFRA-613: worker_stand_down" "$out_file"; then
    echo "[FAIL] no INFRA-613 stand-down log line"
    cat "$out_file"
    exit 1
fi

# Check ambient event.
if ! grep -q '"event":"worker_stand_down"' "$amb_file"; then
    echo "[FAIL] ambient event missing kind=worker_stand_down"
    cat "$amb_file"
    exit 1
fi

if ! grep -q '"kind":"worker_stand_down"' "$amb_file"; then
    echo "[FAIL] ambient event missing kind field"
    cat "$amb_file"
    exit 1
fi

if ! grep -q '"reason":' "$amb_file"; then
    echo "[FAIL] ambient event missing reason field"
    cat "$amb_file"
    exit 1
fi

# Verify starve counter hit the threshold.
if ! grep -q "consecutive_empty" "$amb_file"; then
    echo "[FAIL] ambient event missing consecutive_empty"
    cat "$amb_file"
    exit 1
fi

echo "[PASS] worker exited cleanly via stand-down with proper ambient event"
