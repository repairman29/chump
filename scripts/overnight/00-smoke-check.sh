#!/usr/bin/env bash
# 00-smoke-check.sh — sanity job. Confirms the overnight harness fires and
# the repo is still present. Always runs first; cheap.
set -euo pipefail
echo "[$(date -u +%FT%TZ)] overnight smoke-check OK; cwd=$(pwd); branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
