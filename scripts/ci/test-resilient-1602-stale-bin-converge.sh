#!/usr/bin/env bash
# RESILIENT-1602: node-refresh converge must repoint stale PATH copies or emit a
# routed node_binary_converge_blocked signal; scoreboard must prefer the managed binary.
set -uo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd -P)"
S="$R/scripts/ops/node-refresh-chump.sh"
fail() { echo "FAIL $*"; exit 1; }
bash -n "$S" || fail "syntax"
grep -q '^_repoint_stale_bin()' "$S" || fail "helper missing"
[ "$(grep -c '_repoint_stale_bin "\$c" "\$canon"' "$S")" -eq 2 ] || fail "both converge loops must use helper"
grep -q 'node_binary_converge_blocked' "$S" || fail "no routed blocked signal"
grep -q 'sudo -n' "$S" || fail "no privileged retry"
grep -q 'HOME/.cargo/bin/chump' "$R/scripts/dev/mission-scoreboard.sh" || fail "scoreboard ignores managed binary"

# Functional: unwritable dir -> helper returns non-zero and emits blocked signal.
T="$(mktemp -d)"; trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
mkdir "$T/ro"; : > "$T/ro/chump"; : > "$T/canon"; chmod a-w "$T/ro"
eval "$(sed -n '/^_repoint_stale_bin()/,/^}/p' "$S")"
log() { :; }; emit() { echo "$1" >> "$T/emitted"; }
if [ "$(id -u)" -ne 0 ]; then
  sudo() { return 1; }
  _repoint_stale_bin "$T/ro/chump" "$T/canon" && fail "expected failure on unwritable dir"
  grep -q node_binary_converge_blocked "$T/emitted" || fail "blocked signal not emitted"
fi
mkdir "$T/rw"; : > "$T/rw/chump"
_repoint_stale_bin "$T/rw/chump" "$T/canon" || fail "writable repoint failed"
[ "$(readlink "$T/rw/chump")" = "$T/canon" ] || fail "not repointed"
echo "PASS"
