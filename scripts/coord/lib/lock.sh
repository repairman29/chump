#!/usr/bin/env bash
set -euo pipefail
# scripts/coord/lib/lock.sh — INFRA-7946 (INFRA-1966 slice): coord-lane
# entrypoint for the acquire_lock/release_lock primitive.
#
# Thin wrapper over scripts/lib/lock.sh — the primitive already exists
# (INFRA-6130) and coord/ orchestration scripts should source it from here
# without duplicating the mkdir-atomic-lockfile logic.
#
# Usage:
#   source scripts/coord/lib/lock.sh
#   if acquire_lock "my-lock-name" 30; then       # blocking, 30s timeout
#     ...critical section...
#     release_lock "my-lock-name"
#   fi
#   acquire_lock "my-lock-name" 0                  # non-blocking: one attempt, no wait
#
# Env (see scripts/lib/lock.sh for full docs):
#   CHUMP_LOCK_DIR              directory holding lock directories (default: .chump-locks)
#   CHUMP_LOCK_POLL_INTERVAL_S  poll interval while waiting (default: 0.2)

_LOCK_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck source=../../lib/lock.sh
source "$_LOCK_SH_DIR/lock.sh"
