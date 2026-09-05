#!/usr/bin/env bash
# show-sccache-config.sh — INFRA-4653 (INFRA-2249 slice): print the resolved
# sccache backend URLs (BuildBuddy primary, R2 secondary) for CI
# observability. Non-blocking — this is a diagnostic step, not a gate.
#
# sccache itself has no `--show-config` subcommand; this prints the env vars
# that determine which backend(s) sccache will use, plus `--show-stats` for
# the running-server view.
set -uo pipefail

if [[ -n "${SCCACHE_BUILDBUDDY_URL:-}" ]]; then
    echo "[show-sccache-config] SCCACHE_BUILDBUDDY_URL: <set> (grpc.buildbuddy.io, key redacted)"
else
    echo "[show-sccache-config] SCCACHE_BUILDBUDDY_URL: <unset>"
fi
echo "[show-sccache-config] SCCACHE_ENDPOINT (R2, secondary): ${SCCACHE_ENDPOINT:-<unset>}"
echo "[show-sccache-config] SCCACHE_BUCKET: ${SCCACHE_BUCKET:-<unset>}"

if command -v sccache >/dev/null 2>&1; then
    sccache --show-stats || true
else
    echo "[show-sccache-config] sccache binary not on PATH — nothing running to inspect"
fi
