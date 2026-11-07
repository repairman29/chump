#!/usr/bin/env bash
# ZERO-WASTE-153 — node-class helper + hook/admission wiring.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
. "$R/scripts/lib/node-class.sh"
[ "$(CHUMP_NODE_CLASS=small chump_node_class)" = small ] || { echo FAIL small; exit 1; }
[ "$(CHUMP_NODE_CLASS=normal chump_node_class)" = normal ] || { echo FAIL normal; exit 1; }
[ "$(CHUMP_RUST_LANES=3 chump_rust_lanes)" = 3 ] || { echo FAIL lanes; exit 1; }
grep -q 'check_args' "$R/scripts/git-hooks/pre-commit" || { echo FAIL hook; exit 1; }
grep -q 'ZERO-WASTE-153' "$R/scripts/dispatch/run-fleet.sh" || { echo FAIL admission; exit 1; }
echo "PASS test-node-class"
