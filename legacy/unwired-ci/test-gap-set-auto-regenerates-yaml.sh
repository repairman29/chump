#!/usr/bin/env bash
# test-gap-set-auto-regenerates-yaml.sh — INFRA-470
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified that
# `chump gap set <ID> --field VAL` auto-regenerated the per-file YAML at
# docs/gaps/<ID>.yaml and stamped the .chump/.last-yaml-op freshness
# marker. ZERO-WASTE-020 removed that write path entirely — `gap set` now
# mutates state.db only and writes no YAML mirror or freshness marker, so
# the drift class this test guarded against (state.db updated, YAML stale)
# cannot occur because there is no second representation to drift from.
# state.db is canonical; .chump/state.sql is the tracked dump. See
# docs/gaps/README.md and scripts/ci/test-zero-waste-020.sh (Test 3) for
# the replacement coverage of the no-YAML-write invariant.
#
# Kept as a stub (not deleted) so path-based lookups and `git log` history
# stay intact.

set -uo pipefail

echo "=== INFRA-470 chump gap set auto-regenerates YAML — RETIRED (ZERO-WASTE-020) ==="
echo "chump gap set no longer writes docs/gaps/<ID>.yaml or stamps"
echo ".chump/.last-yaml-op — it mutates state.db only. See"
echo "scripts/ci/test-zero-waste-020.sh for current coverage."
exit 0
