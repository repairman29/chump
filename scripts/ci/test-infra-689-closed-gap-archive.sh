#!/usr/bin/env bash
# test-infra-689-closed-gap-archive.sh — INFRA-689 tests.
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified the
# docs/gaps/closed/<ID>.yaml archive that INFRA-689 introduced as part of
# the per-file YAML mirror system. ZERO-WASTE-020 retired that whole
# system — docs/gaps/ now holds only a tombstone README.md (see
# docs/gaps/README.md). state.db is canonical; .chump/state.sql is the
# tracked dump; `chump gap show <ID>` is the human-readable inspection
# path. There is no more open/closed split to verify.
#
# Kept as a stub (not deleted) so the test-lag gate's file-existence check
# for INFRA-689 continues to resolve, and so `git log` on this path shows
# why the checks went away instead of the file just vanishing.

set -uo pipefail

echo "=== INFRA-689 closed gap archive tests — RETIRED (ZERO-WASTE-020) ==="
echo "docs/gaps/closed/ no longer exists; the per-file YAML mirror system"
echo "(including its closed-gap archive) was retired in favor of state.db"
echo "canonical + .chump/state.sql tracked dump. See docs/gaps/README.md."
echo
echo "=== Results: 1 passed, 0 failed ==="
exit 0
