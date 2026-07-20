#!/usr/bin/env bash
# test-infra-247-worktree-yaml.sh — INFRA-247
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified that
# `chump gap reserve` wrote its per-file docs/gaps/<ID>.yaml mirror to the
# LINKED WORKTREE's docs/gaps/ rather than the main checkout's (INFRA-247 /
# INFRA-1428 worktree-routing fix). ZERO-WASTE-020 removed the YAML-write
# path entirely — `gap reserve` no longer writes any per-file mirror, in
# the main checkout or a linked worktree, so there is no routing behavior
# left to verify. state.db is canonical; .chump/state.sql is the tracked
# dump. See docs/gaps/README.md and scripts/ci/test-zero-waste-020.sh.
#
# Kept as a stub (not deleted) so path-based lookups and `git log` history
# stay intact.

set -uo pipefail

echo "=== INFRA-247 worktree-local YAML write test — RETIRED (ZERO-WASTE-020) ==="
echo "chump gap reserve no longer writes any docs/gaps/<ID>.yaml mirror, in"
echo "the main checkout or a linked worktree — there is no routing behavior"
echo "left to test. See scripts/ci/test-zero-waste-020.sh for current coverage."
exit 0
