#!/usr/bin/env bash
# scripts/ci/test-auto-deploy-canary.sh — RESILIENT-211
#
# Verifies the canary-rollout gate added to scripts/ops/auto-deploy.sh:
#   the two-node fleet (Helsinki + closetjunky, docs/process/ADD_A_FLEET_NODE.md)
#   must receive a new binary SEQUENTIALLY, gated by a health check on the
#   first (canary) node before the second node is touched.
#
# Acceptance criteria verified (RESILIENT-211):
#   (1) Static: canary/second-node functions + doc/env-var wiring present.
#   (2) Static: canary_rollout_failed is scanner-anchored AND registered in
#       EVENT_REGISTRY.yaml (both directions of the register/emit guard).
#   (3) Functional: an UNHEALTHY canary (mission-scoreboard.sh exit != 0)
#       does NOT propagate to the second node, and emits
#       kind=canary_rollout_failed rather than failing silently.
#   (4) Functional: a HEALTHY canary DOES propagate, and does NOT emit
#       canary_rollout_failed.
#   (5) Functional: no second node configured (CHUMP_SECOND_NODE_SSH unset,
#       no override) degrades to a clean skip, not a failure — single-node
#       contexts (dev checkouts, a node mid-bringup) are legitimate.
#   (6) Functional: the fallback gate (`chump health --slo-check`, used when
#       mission-scoreboard.sh isn't present) also blocks propagation on an
#       SLO breach — the second acceptable gate named in the AC.
#
# We never build the real binary or hit the network: refresh-runner-binary.sh
# and the installed `chump` binary are both stubbed, and the "second node"
# ssh trigger is replaced with CHUMP_SECOND_NODE_DEPLOY_CMD (a local
# marker-file write) so propagation is observable without real ssh/network.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUTO_DEPLOY="$REPO_ROOT/scripts/ops/auto-deploy.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Static checks ───────────────────────────────────────────────────────────
[[ -x "$AUTO_DEPLOY" ]] || fail "auto-deploy.sh missing or not executable"
grep -q 'RESILIENT-211' "$AUTO_DEPLOY" || fail "RESILIENT-211 banner missing"
grep -q '^run_canary_health_check()' "$AUTO_DEPLOY" || fail "run_canary_health_check() missing"
grep -q '^deploy_second_node()' "$AUTO_DEPLOY" || fail "deploy_second_node() missing"
grep -q 'CHUMP_SECOND_NODE_SSH' "$AUTO_DEPLOY" || fail "CHUMP_SECOND_NODE_SSH wiring missing"
ok "canary + second-node functions present"

# Sequential, not backgrounded: the second-node call must not be forked with
# a trailing '&' (that would make the rollout concurrent, not sequential).
grep -E 'deploy_second_node[[:space:]]*&[[:space:]]*$' "$AUTO_DEPLOY" \
    && fail "deploy_second_node must run synchronously (found trailing '&')"
ok "second-node deploy runs synchronously (sequential rollout, not concurrent)"

grep -q 'scanner-anchor: "kind":"canary_rollout_failed"' "$AUTO_DEPLOY" \
    || fail "canary_rollout_failed missing its scanner-anchor comment"
grep -q 'kind: canary_rollout_failed' "$REG" \
    || fail "EVENT_REGISTRY.yaml missing kind: canary_rollout_failed"
ok "canary_rollout_failed is scanner-anchored and registered"

# ── Functional fixtures (shared) ────────────────────────────────────────────
FAKE_REFRESH="$TMP/fake-refresh.sh"
cat >"$FAKE_REFRESH" <<'EOF'
#!/usr/bin/env bash
# Stands in for scripts/setup/refresh-runner-binary.sh: pretend the
# canary node's own rebuild+install always succeeds instantly.
exit 0
EOF
chmod +x "$FAKE_REFRESH"

FAKE_BIN="$TMP/fake-chump"
cat >"$FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
# Stands in for the installed `chump` binary. Supports the two things
# auto-deploy.sh calls it for: `--version` (SHA extraction) and
# `health --slo-check` (the fallback health-check gate, exit code driven
# by FAKE_BIN_SLO_EXIT so tests can force pass/fail).
if [[ "${1:-}" == "health" && "${2:-}" == "--slo-check" ]]; then
    exit "${FAKE_BIN_SLO_EXIT:-0}"
fi
echo "chump 0.0.0 (deadbeef1234 built 2026-01-01)"
EOF
chmod +x "$FAKE_BIN"

# make_fake_repo <dir> — minimal git repo with one commit on main, and an
# origin/main ref so `git rev-parse origin/main` resolves without a real
# remote. origin points at a nonexistent local path so `git fetch` fails
# fast and is absorbed by auto-deploy.sh's existing non-fatal WARN path.
make_fake_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q
        git checkout -q -b main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo hello >f.txt
        git add f.txt
        git commit -q -m init
        git remote add origin "file:///nonexistent-$(basename "$dir")-origin"
        git update-ref refs/remotes/origin/main HEAD
    )
}

# ── (3) Unhealthy canary blocks propagation ─────────────────────────────────
REPO_A="$TMP/repo-a"
make_fake_repo "$REPO_A"
mkdir -p "$REPO_A/scripts/dev"
cat >"$REPO_A/scripts/dev/mission-scoreboard.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$REPO_A/scripts/dev/mission-scoreboard.sh"
MARKER_A="$TMP/marker-a"
rm -f "$MARKER_A"
CHUMP_REPO_ROOT="$REPO_A" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$FAKE_BIN" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    CHUMP_SECOND_NODE_DEPLOY_CMD="touch $MARKER_A" \
    bash "$AUTO_DEPLOY" >"$TMP/out-a.log" 2>&1
RC=$?
[[ "$RC" -eq 0 ]] || fail "scenario A: script should still exit 0 (canary's own deploy succeeded), got $RC: $(cat "$TMP/out-a.log")"
[[ ! -e "$MARKER_A" ]] || fail "scenario A: second-node deploy MUST NOT fire when the canary health check fails"
grep -q '"kind":"canary_rollout_failed"' "$REPO_A/.chump-locks/ambient.jsonl" \
    || fail "scenario A: canary_rollout_failed not emitted to ambient.jsonl"
ok "unhealthy canary blocks propagation to the second node + emits canary_rollout_failed"

# ── (4) Healthy canary propagates, no false-alarm event ─────────────────────
REPO_B="$TMP/repo-b"
make_fake_repo "$REPO_B"
mkdir -p "$REPO_B/scripts/dev"
cat >"$REPO_B/scripts/dev/mission-scoreboard.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO_B/scripts/dev/mission-scoreboard.sh"
MARKER_B="$TMP/marker-b"
rm -f "$MARKER_B"
CHUMP_REPO_ROOT="$REPO_B" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$FAKE_BIN" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    CHUMP_SECOND_NODE_DEPLOY_CMD="touch $MARKER_B" \
    bash "$AUTO_DEPLOY" >"$TMP/out-b.log" 2>&1
RC=$?
[[ "$RC" -eq 0 ]] || fail "scenario B: script should exit 0, got $RC: $(cat "$TMP/out-b.log")"
[[ -e "$MARKER_B" ]] || fail "scenario B: second-node deploy MUST fire when the canary health check passes"
if [[ -f "$REPO_B/.chump-locks/ambient.jsonl" ]] && grep -q '"kind":"canary_rollout_failed"' "$REPO_B/.chump-locks/ambient.jsonl"; then
    fail "scenario B: canary_rollout_failed must NOT be emitted on a healthy canary"
fi
ok "healthy canary propagates to the second node, no canary_rollout_failed emitted"

# ── (5) No second node configured -> clean skip, not a failure ─────────────
REPO_C="$TMP/repo-c"
make_fake_repo "$REPO_C"
mkdir -p "$REPO_C/scripts/dev"
cat >"$REPO_C/scripts/dev/mission-scoreboard.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO_C/scripts/dev/mission-scoreboard.sh"
CHUMP_REPO_ROOT="$REPO_C" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$FAKE_BIN" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    bash "$AUTO_DEPLOY" >"$TMP/out-c.log" 2>&1
RC=$?
[[ "$RC" -eq 0 ]] || fail "scenario C: unset CHUMP_SECOND_NODE_SSH should still exit 0, got $RC: $(cat "$TMP/out-c.log")"
grep -q 'SKIP second-node deploy' "$TMP/out-c.log" \
    || fail "scenario C: expected a SKIP log line for the unconfigured second node"
ok "no second node configured degrades to a clean skip (single-node context is legitimate)"

# ── (6) Fallback gate (chump health --slo-check) also blocks on breach ─────
REPO_D="$TMP/repo-d"
make_fake_repo "$REPO_D"
# Deliberately no scripts/dev/mission-scoreboard.sh in this repo -> forces
# the fallback path onto `<TARGET_BIN> health --slo-check`.
MARKER_D="$TMP/marker-d"
rm -f "$MARKER_D"
CHUMP_REPO_ROOT="$REPO_D" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$FAKE_BIN" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    FAKE_BIN_SLO_EXIT=1 \
    CHUMP_SECOND_NODE_DEPLOY_CMD="touch $MARKER_D" \
    bash "$AUTO_DEPLOY" >"$TMP/out-d.log" 2>&1
grep -q 'falling back to' "$TMP/out-d.log" \
    || fail "scenario D: expected a fallback-to-slo-check log line"
[[ ! -e "$MARKER_D" ]] || fail "scenario D: fallback gate breach must still block the second node"
grep -q '"kind":"canary_rollout_failed"' "$REPO_D/.chump-locks/ambient.jsonl" \
    || fail "scenario D: canary_rollout_failed not emitted on a fallback-gate breach"
ok "fallback gate (chump health --slo-check) also blocks propagation on an SLO breach"

echo
echo "All RESILIENT-211 canary-rollout tests passed."
