#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-auto-stages.sh — INFRA-1354
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified that
# `chump gap reserve` auto-wrote and auto-staged a per-file
# docs/gaps/<ID>.yaml mirror (INFRA-484/1354). ZERO-WASTE-020 removed that
# write path entirely — `gap reserve` no longer writes any YAML mirror,
# regardless of whether docs/gaps/ exists. state.db is canonical;
# .chump/state.sql is the tracked dump. See docs/gaps/README.md and
# scripts/ci/test-zero-waste-020.sh (Test 3) for the replacement coverage.
#
# Kept as a stub (not deleted) so path-based lookups and history stay
# intact; `git log -- scripts/ci/test-gap-reserve-auto-stages.sh` shows
# why the behavior it checked went away.

set -uo pipefail

echo "=== INFRA-1354 gap-reserve-auto-stages — RETIRED (ZERO-WASTE-020) ==="
echo "chump gap reserve no longer writes docs/gaps/<ID>.yaml at all (mirror"
echo "write path removed). See scripts/ci/test-zero-waste-020.sh for current"
echo "coverage of the no-YAML-write invariant."
exit 0
