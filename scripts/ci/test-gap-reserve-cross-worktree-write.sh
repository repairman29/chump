#!/usr/bin/env bash
# test-gap-reserve-cross-worktree-write.sh — CI smoke test for INFRA-1428
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified that
# `chump gap reserve`, run from a linked worktree, wrote its per-file
# docs/gaps/<ID>.yaml mirror to the MAIN repo (not the linked worktree) so
# origin/main and every other worktree could see it (INFRA-1428). ZERO-
# WASTE-020 removed the YAML-write path entirely — `gap reserve` no
# longer writes any per-file mirror anywhere, so there is no cross-
# worktree routing behavior left to verify. state.db is canonical;
# .chump/state.sql is the tracked dump. See docs/gaps/README.md and
# scripts/ci/test-zero-waste-020.sh.
#
# Kept as a stub (not deleted) so path-based lookups and `git log` history
# stay intact.

set -uo pipefail

echo "=== INFRA-1428 cross-worktree YAML write test — RETIRED (ZERO-WASTE-020) ==="
echo "chump gap reserve no longer writes any docs/gaps/<ID>.yaml mirror, so"
echo "there is no cross-worktree routing left to test. See"
echo "scripts/ci/test-zero-waste-020.sh for current coverage."
exit 0
