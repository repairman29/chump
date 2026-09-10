#!/usr/bin/env bash
# test-worker-policy-env.sh — config-under-management regression test.
#
# Guards the tracked worker self-heal policy (scripts/setup/worker-policy.env)
# and its wiring into scripts/dispatch/worker.sh. The failure this exists to
# prevent: the worker's self-heal toggles lived only in a node's hand-deployed,
# git-untracked ~/node1-worker-run.sh, an unset CHUMP_STARVE_AUTO_RELAX let a
# narrow filter stand the fleet down 138x (2026-09-08), and nothing in git
# could review, reproduce, or heal that policy.
#
# Asserts:
#   1. worker-policy.env exists and, sourced with the toggle UNSET (the drift
#      state that froze the fleet), sets CHUMP_STARVE_AUTO_RELAX=1.
#   2. It pins CHUMP_STARVE_AUTO_SHUTDOWN=0 when unset.
#   3. ":=" semantics: an explicit CHUMP_STARVE_AUTO_RELAX=0 is PRESERVED, so a
#      node can still opt out (the policy provides defaults, not an override).
#   4. worker.sh actually sources the policy file (wiring can't silently drift).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
POLICY="$REPO_ROOT/scripts/setup/worker-policy.env"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

fail() { echo "[FAIL] $*"; exit 1; }

[[ -f "$POLICY" ]] || fail "policy file missing: $POLICY"
[[ -f "$WORKER" ]] || fail "worker.sh missing: $WORKER"

# ── Test 1: unset toggle gets the default-on self-heal ───────────────────────
( unset CHUMP_STARVE_AUTO_RELAX CHUMP_STARVE_AUTO_SHUTDOWN
  # shellcheck disable=SC1090
  source "$POLICY"
  [[ "${CHUMP_STARVE_AUTO_RELAX:-}" == "1" ]] \
    || { echo "[FAIL] unset CHUMP_STARVE_AUTO_RELAX did not default to 1 (got '${CHUMP_STARVE_AUTO_RELAX:-<unset>}')"; exit 1; }
) || exit 1
echo "[PASS] unset CHUMP_STARVE_AUTO_RELAX defaults to 1"

# ── Test 2: auto-shutdown pinned off when unset ──────────────────────────────
( unset CHUMP_STARVE_AUTO_RELAX CHUMP_STARVE_AUTO_SHUTDOWN
  # shellcheck disable=SC1090
  source "$POLICY"
  [[ "${CHUMP_STARVE_AUTO_SHUTDOWN:-}" == "0" ]] \
    || { echo "[FAIL] unset CHUMP_STARVE_AUTO_SHUTDOWN did not default to 0 (got '${CHUMP_STARVE_AUTO_SHUTDOWN:-<unset>}')"; exit 1; }
) || exit 1
echo "[PASS] unset CHUMP_STARVE_AUTO_SHUTDOWN defaults to 0"

# ── Test 3: explicit value is preserved (opt-out still works) ────────────────
( export CHUMP_STARVE_AUTO_RELAX=0
  # shellcheck disable=SC1090
  source "$POLICY"
  [[ "${CHUMP_STARVE_AUTO_RELAX:-}" == "0" ]] \
    || { echo "[FAIL] explicit CHUMP_STARVE_AUTO_RELAX=0 was clobbered (got '${CHUMP_STARVE_AUTO_RELAX:-<unset>}')"; exit 1; }
) || exit 1
echo "[PASS] explicit CHUMP_STARVE_AUTO_RELAX=0 is preserved (opt-out honored)"

# ── Test 4: worker.sh sources the policy file ────────────────────────────────
grep -q 'worker-policy.env' "$WORKER" \
  || fail "worker.sh does not reference worker-policy.env — wiring drifted"
grep -Eq 'source[[:space:]]+"\$CHUMP_WORKER_POLICY_ENV"' "$WORKER" \
  || fail "worker.sh does not source \$CHUMP_WORKER_POLICY_ENV — wiring drifted"
echo "[PASS] worker.sh sources the tracked worker-policy.env"

echo ""
echo "[OK] worker self-heal policy is under management and wired"
