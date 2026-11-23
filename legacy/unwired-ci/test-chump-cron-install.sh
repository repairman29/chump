#!/usr/bin/env bash
# test-chump-cron-install.sh — smoke test for `chump cron install|uninstall|status`
# (INFRA-2057).
#
# macOS: installs a synthetic --interval-based launchd plist, asserts it's on
# disk + launchctl loads it, waits one fire window, asserts the exec ran
# (stdout-log presence), then uninstalls and asserts cleanup.
#
# Linux: same flow against systemd --user units. Skipped (not failed) on
# runners without a user systemd instance (e.g. some containers).
#
# Usage:
#   ./scripts/ci/test-chump-cron-install.sh
#   CHUMP_BIN=./target/release/chump ./scripts/ci/test-chump-cron-install.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -n "$CHUMP_BIN" ]] && [[ ! -x "$CHUMP_BIN" ]] && [[ ! -x "$ROOT/$CHUMP_BIN" ]]; then
  echo "WARN: \$CHUMP_BIN='$CHUMP_BIN' not executable; falling through to discovery" >&2
  CHUMP_BIN=""
fi
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
  elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
  elif [[ -x "$ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$ROOT/target/release/chump"
  elif [[ -x "$ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$ROOT/target/debug/chump"
  else
    echo "ERROR: no chump binary found; run 'cargo build --bin chump' first" >&2
    exit 1
  fi
fi
echo "[cron-smoke] using CHUMP_BIN=$CHUMP_BIN" >&2

PASS=0
FAIL=0

check() {
  local label="$1" cond="$2"
  if [[ "$cond" == "0" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label" >&2
    FAIL=$((FAIL + 1))
  fi
}

NAME="ci-smoke-$$"
LABEL="com.chump.$NAME"
STDOUT_LOG="$(mktemp -d)/cron-smoke-stdout.log"

if [[ "$(uname)" == "Linux" ]] && ! systemctl --user status >/dev/null 2>&1; then
  echo "SKIP: no user systemd instance available on this runner (Linux, no session bus)"
  exit 0
fi

cleanup() {
  "$CHUMP_BIN" cron uninstall --name "$NAME" >/dev/null 2>&1 || true
  rm -f "$STDOUT_LOG"
}
trap cleanup EXIT

echo "[cron-smoke] installing $LABEL (interval=2s)"
"$CHUMP_BIN" cron install --name "$NAME" --interval 2s \
  --exec "/bin/sh -c 'echo cron-smoke-fired'" \
  --stdout-log "$STDOUT_LOG" --description "INFRA-2057 smoke test"
check "install exit 0" "$?"

if [[ "$(uname)" == "Darwin" ]]; then
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  [[ -f "$PLIST" ]]
  check "plist exists on disk" "$?"

  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  check "launchctl shows it loaded" "$?"

  echo "[cron-smoke] waiting one fire window (5s)..."
  sleep 5
  [[ -s "$STDOUT_LOG" ]]
  check "exec ran (stdout-log has content)" "$?"

  "$CHUMP_BIN" cron uninstall --name "$NAME" >/dev/null 2>&1
  check "uninstall exit 0" "$?"

  [[ ! -f "$PLIST" ]]
  check "plist removed" "$?"

  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  RC=$?
  [[ "$RC" != "0" ]]
  check "launchctl no longer lists it" "$?"
elif [[ "$(uname)" == "Linux" ]]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  TIMER="$UNIT_DIR/chump-$NAME.timer"
  [[ -f "$TIMER" ]]
  check "timer unit exists on disk" "$?"

  systemctl --user is-active "chump-$NAME.timer" >/dev/null 2>&1
  check "systemd shows timer active" "$?"

  echo "[cron-smoke] waiting one fire window (5s)..."
  sleep 5
  [[ -s "$STDOUT_LOG" ]]
  check "exec ran (stdout-log has content)" "$?"

  "$CHUMP_BIN" cron uninstall --name "$NAME" >/dev/null 2>&1
  check "uninstall exit 0" "$?"

  [[ ! -f "$TIMER" ]]
  check "timer unit removed" "$?"
fi

echo
echo "[cron-smoke] $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
