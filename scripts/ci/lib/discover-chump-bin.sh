#!/usr/bin/env bash
# scripts/ci/lib/discover-chump-bin.sh — INFRA-1619
#
# Sourceable helper: locate the chump debug binary, honoring CARGO_TARGET_DIR.
# Exports CHUMP_BIN to the resolved path so downstream CI steps can use it
# without hard-coding the build output directory.
#
# Self-hosted runners share a workspace-level CARGO_TARGET_DIR that redirects
# build artefacts away from the checkout directory (INFRA-1600). Without this
# helper, steps that exec `target/debug/chump` directly break when the cache
# points elsewhere.
#
# Usage (source — do NOT execute directly):
#   source scripts/ci/lib/discover-chump-bin.sh
#   # Then use: "$CHUMP_BIN" <args>

_repo_root="${REPO_ROOT:-$(pwd)}"
_target_dir="${CARGO_TARGET_DIR:-${_repo_root}/target}"

CHUMP_BIN="${_target_dir}/debug/chump"

# Fallback: conventional location in case CARGO_TARGET_DIR not set by runner
if [[ ! -f "${CHUMP_BIN}" ]]; then
  CHUMP_BIN="${_repo_root}/target/debug/chump"
fi

export CHUMP_BIN
unset _repo_root _target_dir
