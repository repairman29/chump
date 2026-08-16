#!/usr/bin/env bash
# scripts/ci/sccache-or-rustc.sh — INFRA-2249
#
# rustc-wrapper shim for .cargo/config.toml. If the sccache binary is on
# PATH (CI after the sccache-action install step, or a dev machine that
# installed it manually), delegate to it — sccache itself picks whichever
# backend the env points at (SCCACHE_BUILDBUDDY_URL preferred, R2 fallback;
# see docs/process/BUILDBUDDY.md). Otherwise exec the wrapped compiler
# directly so builds aren't broken on machines without sccache installed.
set -euo pipefail

if command -v sccache >/dev/null 2>&1; then
    exec sccache "$@"
else
    exec "$@"
fi
