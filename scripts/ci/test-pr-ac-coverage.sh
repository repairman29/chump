#!/usr/bin/env bash
# INFRA-1541: 3-line exec wrapper — logic lives in src/pr_ac_coverage.rs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${CARGO_TARGET_DIR:-$ROOT/target}/debug/chump" pr ac-coverage "$@"
