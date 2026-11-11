#!/usr/bin/env bash
# RESILIENT-322 AC2: place_tmpdir() routes TMPDIR to a data volume when /tmp is full.
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="$REPO_ROOT/scripts/ops/node-orchestrator.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/vol" "$T/bin"
export CHUMP_STATE_DIR="$T/state"

# shellcheck source=/dev/null
source "$ORCH" 2>/dev/null || true
declare -f place_tmpdir >/dev/null || { echo "FAIL: place_tmpdir missing"; exit 1; }

# stub df: report the probe path at $PCT% used
PCT=95
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\ntmpfs 100 %s 5 %s%% /tmp\n' "$PCT" "$PCT"; }

DISK_PLACE_PCT=90
BEST_VOL_MNT="$T/vol"; BEST_VOL_FREE_KB=$((50*1024*1024))

place_tmpdir >/dev/null
if grep -q "TMPDIR=.*chump-tmp" "$T/state/tmpdir.env" 2>/dev/null && [ -d "$T/vol/chump-tmp" ]; then
  ok "full /tmp routes TMPDIR to data volume"; else fail "tmpdir.env not written under pressure"; fi

PCT=50
place_tmpdir >/dev/null
[ ! -f "$T/state/tmpdir.env" ] && ok "recovered /tmp clears tmpdir.env" || fail "tmpdir.env not cleared"

PCT=95; BEST_VOL_MNT=none
place_tmpdir >/dev/null
[ ! -f "$T/state/tmpdir.env" ] && ok "no volume -> no routing" || fail "routed with no volume"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
