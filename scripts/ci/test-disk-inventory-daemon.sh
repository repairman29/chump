#!/usr/bin/env bash
# scripts/ci/test-disk-inventory-daemon.sh — INFRA-2359
#
# Smoke test for chump-disk-inventory-daemon's observability contract:
#   1. A successful poll cycle writes ~/.chump/disk-inventory.json and emits
#      event=disk_inventory_updated to ambient.jsonl.
#   2. A poll cycle that can't spawn df/du emits event=disk_inventory_poll_failed
#      with failure_class=transient_io, and does NOT write a snapshot.
#
# CHUMP_REPO/CHUMP_HOME are both pointed at an isolated tempdir so this test
# never touches the real .chump-locks/ambient.jsonl (chump_ambient_cli::emit
# resolves the ambient path from CHUMP_REPO > CHUMP_HOME > `git
# rev-parse`, and default_chump_dir() resolves the snapshot dir from
# CHUMP_HOME directly — CHUMP_AMBIENT_LOG is a CLI-only override and is NOT
# honored by the library emit() this daemon calls).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

PATH=$HOME/.cargo/bin:$PATH cargo build -p chump-disk-inventory --bin chump-disk-inventory-daemon -q
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump-disk-inventory-daemon"
[[ -x "$BIN" ]] || fail "binary not built at $BIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Test 1: healthy poll cycle ───────────────────────────────────────────────
ISOLATED_REPO="$TMP/healthy"
mkdir -p "$ISOLATED_REPO"
AMBIENT="$ISOLATED_REPO/.chump-locks/ambient.jsonl"

timeout 5 env \
  CHUMP_REPO="$ISOLATED_REPO" CHUMP_HOME="$ISOLATED_REPO/.chump" CHUMP_DISK_POLL_S=1 \
  "$BIN" >"$TMP/healthy.log" 2>&1 || true

[[ -f "$ISOLATED_REPO/.chump/disk-inventory.json" ]] \
  || fail "snapshot not written: $(cat "$TMP/healthy.log")"
ok "disk-inventory.json snapshot written on healthy poll"

grep -q '"event":"disk_inventory_updated"' "$AMBIENT" \
  || fail "disk_inventory_updated not emitted: $(cat "$AMBIENT" 2>/dev/null || echo '(no ambient log)')"
ok "disk_inventory_updated emitted on healthy poll"

# ── Test 2: df/du unavailable → poll failure, no snapshot ──────────────────
FAIL_REPO="$TMP/failing"
mkdir -p "$FAIL_REPO"
FAIL_AMBIENT="$FAIL_REPO/.chump-locks/ambient.jsonl"
EMPTY_BIN_DIR="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN_DIR"

# `timeout` runs env(1) via the real PATH; env(1) then execs $BIN (absolute
# path) with an empty PATH, so only the daemon's internal df/du spawns fail —
# not the harness commands driving this test.
timeout 5 env \
  CHUMP_REPO="$FAIL_REPO" CHUMP_HOME="$FAIL_REPO/.chump" CHUMP_DISK_POLL_S=1 \
  PATH="$EMPTY_BIN_DIR" \
  "$BIN" >"$TMP/failing.log" 2>&1 || true

[[ -f "$FAIL_REPO/.chump/disk-inventory.json" ]] \
  && fail "snapshot should not exist when df/du are unavailable"
ok "no snapshot written when df/du are unavailable"

grep -q '"event":"disk_inventory_poll_failed"' "$FAIL_AMBIENT" \
  || fail "disk_inventory_poll_failed not emitted: $(cat "$FAIL_AMBIENT" 2>/dev/null || echo '(no ambient log)')"
ok "disk_inventory_poll_failed emitted when df/du are unavailable"

grep '"event":"disk_inventory_poll_failed"' "$FAIL_AMBIENT" | grep -q '"failure_class":"transient_io"' \
  || fail "failure_class not transient_io: $(grep '"event":"disk_inventory_poll_failed"' "$FAIL_AMBIENT")"
ok "failure_class=transient_io on df/du spawn failure"

echo "All disk-inventory-daemon observability checks passed."
