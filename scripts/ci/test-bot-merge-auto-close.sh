#!/usr/bin/env bash
# INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake
# that bot-merge.sh uses.
#
# ZERO-WASTE-020 (2026-07-19): RETIRED. This test verified that
# `chump gap ship --update-yaml` and `chump gap reserve` wrote/updated a
# per-file docs/gaps/<ID>.yaml mirror (INFRA-228/229). ZERO-WASTE-020
# removed that write path entirely — `--update-yaml` is now a documented
# no-op and `gap reserve` writes no mirror at all, so there is no
# per-file-mirror contract left to verify. The auto-close handshake
# bot-merge.sh actually depends on (status flips to done in state.db,
# closed_pr recorded) is covered by scripts/ci/test-gap-ship-integration.sh
# via `chump gap show`. state.db is canonical; .chump/state.sql is the
# tracked dump. See docs/gaps/README.md and scripts/ci/test-zero-waste-020.sh.
#
# Kept as a stub (not deleted) so path-based lookups and `git log` history
# stay intact.

set -uo pipefail

echo "=== INFRA-154/228/229 auto-close handshake — RETIRED (ZERO-WASTE-020) ==="
echo "chump gap ship --update-yaml is now a no-op and gap reserve writes no"
echo "docs/gaps/<ID>.yaml mirror. See scripts/ci/test-gap-ship-integration.sh"
echo "for status-flip + closed_pr coverage via state.db, and"
echo "scripts/ci/test-zero-waste-020.sh for the no-YAML-write invariant."
exit 0
