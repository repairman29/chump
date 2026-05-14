#!/usr/bin/env bash
# fleet-status.sh — INFRA-1218 — backwards-compat shim
#
# This file used to be a 94-line standalone snapshot script. As of
# INFRA-1218 the canonical implementation lives in
# scripts/dispatch/fleet-status.sh and supports `--once` for the same
# single-pane single-shot output.
#
# This shim forwards every invocation to the canonical script so existing
# callers (docs, CI tests, unattended fleet loops) keep working without
# behavior change. New callers should prefer the dispatch path directly:
#
#   bash scripts/dispatch/fleet-status.sh --once
#
# This shim will be removed once all callers are migrated.
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec bash "$REPO_ROOT/scripts/dispatch/fleet-status.sh" --once "$@"
