#!/usr/bin/env bash
# One ship round targeting chassis (top portfolio product); asserts chassis repo and log were updated.
# Use for dogfooding: run this to verify Chump can ship updates to the chassis repo.
#
# Prereqs: Run from Chump repo root; .env sourced (script sources it if present); CHUMP_GITHUB_REPOS
# includes repairman29/chump-chassis; target/release/chump built.
#
# Usage: ./scripts/test-ship-chassis-round.sh

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

CHASSIS_REPO="$ROOT/repos/repairman29_chump-chassis"
CHASSIS_LOG="$ROOT/chump-brain/projects/chump-chassis/log.md"
SHIP_LOG="$ROOT/logs/heartbeat-ship.log"
CHUMP_LOG="$ROOT/logs/chump.log"
TIMEOUT_SEC="${SHIP_CHASSIS_TIMEOUT:-300}"
mkdir -p "$ROOT/logs"

# Ensure chassis repo dir exists so the ship round can set_working_repo and do Step 1 (cargo init).
if [[ ! -d "$CHASSIS_REPO" ]]; then
  echo "Setup: creating $CHASSIS_REPO (git init + remote) for empty-remote case."
  mkdir -p "$CHASSIS_REPO"
  (cd "$CHASSIS_REPO" && git init && git remote add origin https://github.com/repairman29/chump-chassis.git)
elif [[ ! -f "$CHASSIS_REPO/.git/HEAD" ]]; then
  echo "Setup: $CHASSIS_REPO exists but is not a git repo; initializing."
  (cd "$CHASSIS_REPO" && git init && git remote add origin https://github.com/repairman29/chump-chassis.git 2>/dev/null || true)
fi

# Run one ship round forced to chassis so the test reliably asserts chassis updates.
RUN_START=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
  timeout "${TIMEOUT_SEC}s" env HEARTBEAT_ONE_ROUND=1 CHUMP_HOME="$ROOT" CHUMP_SHIP_TARGET=chump-chassis ./scripts/heartbeat-ship.sh >> "$SHIP_LOG" 2>&1 || true
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "${TIMEOUT_SEC}s" env HEARTBEAT_ONE_ROUND=1 CHUMP_HOME="$ROOT" CHUMP_SHIP_TARGET=chump-chassis ./scripts/heartbeat-ship.sh >> "$SHIP_LOG" 2>&1 || true
else
  env HEARTBEAT_ONE_ROUND=1 CHUMP_HOME="$ROOT" CHUMP_SHIP_TARGET=chump-chassis ./scripts/heartbeat-ship.sh >> "$SHIP_LOG" 2>&1 || true
fi
RUN_END=$(date +%s)
echo "Ship round finished in $(( RUN_END - RUN_START ))s."

# Assertions: chassis repo has Cargo.toml (Step 1 success) and log.md has a new session/step.
FAIL=""
if [[ ! -f "$CHASSIS_REPO/Cargo.toml" ]]; then
  FAIL="${FAIL}${FAIL:+; }repos/repairman29_chump-chassis/Cargo.toml missing"
fi
if [[ ! -f "$CHASSIS_LOG" ]]; then
  FAIL="${FAIL}${FAIL:+; }chump-brain/projects/chump-chassis/log.md missing"
else
  if ! grep -qE "## Session [1-9]|Step 1:" "$CHASSIS_LOG" 2>/dev/null; then
    FAIL="${FAIL}${FAIL:+; }log.md has no Session 1 or Step 1 (not updated)"
  fi
fi

# Optional: fail if agent attempted rm -rf repos/ (guardrail should block).
if [[ -n "${CHECK_NO_RM_REPOS:-}" ]] && [[ "$CHECK_NO_RM_REPOS" == "1" ]]; then
  if [[ -f "$CHUMP_LOG" ]] && tail -500 "$CHUMP_LOG" | grep -q "rm -rf repos"; then
    FAIL="${FAIL}${FAIL:+; }chump.log shows rm -rf repos/ (guardrail should block)"
  fi
fi

if [[ -n "$FAIL" ]]; then
  echo "FAIL: $FAIL"
  echo "Ship log tail:"
  tail -20 "$SHIP_LOG"
  exit 1
fi

echo "PASS: Chassis Step 1 — Cargo.toml present, log.md updated."
exit 0
