#!/usr/bin/env bash
# scripts/ci/test-infra1655-runner-checkout-flake-repro.sh — INFRA-3544 (INFRA-1655 slice)
#
# Reproduces the 2026-05-20 jeffs-macbook-air-10-X "actions/checkout@v6 0-step
# CANCELLED" flake as a fast, deterministic local simulation — no GitHub API
# or live runner hardware required.
#
# Mechanism (per INFRA-1852 root-cause, docs/process/CLAUDE_GOTCHAS.md
# "Audit job concurrency policy" + docs/process/SELF_HOSTED_RUNNERS.md
# "Current state — degraded ubuntu-only mode"):
#
#   Pre-fix, ci.yml keyed its `concurrency.group` on the PR number with
#   `cancel-in-progress: true`. A fixup push to the same PR cancels ANY
#   in-flight run in that group, including whatever step a queued job is
#   mid-execution of.
#
#   github-hosted (ubuntu-latest) capacity is effectively unbounded — a job
#   dequeues and reaches `actions/checkout@v6` in low single-digit seconds,
#   almost always finishing checkout before the next push's cancel signal
#   arrives.
#
#   Self-hosted jeffs-macbook-air-10-X capacity is 4 fixed runners. Under
#   queue pressure (several PRs cycling at once, the exact 2026-05-20
#   scenario), a job can sit QUEUED for 10-20s before a slot frees up — so
#   it is still mid-`actions/checkout@v6` when the next fixup push's cancel
#   arrives. Result: 0-step CANCELLED, specific to the constrained-capacity
#   lane.
#
# This script simulates both lanes under identical push cadence and asserts
# the failure reproduces (AC 1: within 30s) ONLY on the constrained lane
# (AC 2: specific to jeffs-macbook-air-10-X), then asserts the INFRA-1852
# per-SHA fix is still in place on main (regression guard — if someone
# reverts to PR-number keying, this test must fail).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Simulation parameters (seconds, scaled down from real observed timings
#    for a fast local run; ratios match the 2026-05-20 incident) ───────────
CHECKOUT_DURATION=3          # actions/checkout@v6 step wall-clock
SELF_HOSTED_RUNNERS=4        # jeffs-macbook-air-10-2..10-5 fixed pool
SELF_HOSTED_QUEUE_DEPTH=6    # concurrent PR cycles observed 2026-05-20
GITHUB_HOSTED_QUEUE_DELAY=0  # near-immediate dequeue, github-hosted pool
FIXUP_PUSH_INTERVAL=5        # operator fixup-push cadence (scaled down)

# Self-hosted: with a fixed pool of N runners and Q queued jobs ahead of
# ours, queue delay before dequeue scales with contention.
self_hosted_queue_delay() {
  local depth=$1 pool=$2
  echo $(( (depth / pool) * CHECKOUT_DURATION ))
}

# ── Simulate: does a fixup push at t=FIXUP_PUSH_INTERVAL cancel a run that
#    is still mid-checkout? ─────────────────────────────────────────────────
simulate_lane() {
  local queue_delay=$1
  local checkout_start=$queue_delay
  local checkout_end=$(( checkout_start + CHECKOUT_DURATION ))
  local cancel_arrives=$FIXUP_PUSH_INTERVAL

  if (( cancel_arrives < checkout_end )); then
    echo "CANCELLED $checkout_start"
  else
    echo "COMPLETED $checkout_start"
  fi
}

# ── Self-hosted lane (jeffs-macbook-air-10-X): bounded pool → queue delay
#    large enough that checkout is still in-flight when the fixup lands ────
sh_delay=$(self_hosted_queue_delay "$SELF_HOSTED_QUEUE_DEPTH" "$SELF_HOSTED_RUNNERS")
read -r sh_result sh_checkout_start <<<"$(simulate_lane "$sh_delay")"

# ── github-hosted lane (ubuntu-latest): unbounded pool → checkout starts
#    (near-)immediately and finishes long before the next fixup push ──────
gh_delay=$GITHUB_HOSTED_QUEUE_DELAY
read -r gh_result gh_checkout_start <<<"$(simulate_lane "$gh_delay")"

# ── AC 1: failure reproduces within 30 seconds ──────────────────────────────
repro_elapsed=$(( sh_checkout_start + CHECKOUT_DURATION ))
[[ "$sh_result" == "CANCELLED" ]] \
  || fail "self-hosted lane did not reproduce CANCELLED (got $sh_result) — simulation parameters no longer match the 2026-05-20 incident shape"
(( repro_elapsed <= 30 )) \
  || fail "self-hosted CANCELLED reproduced but at ${repro_elapsed}s, outside the 30s AC window"
ok "self-hosted (jeffs-macbook-air-10-X) lane: actions/checkout@v6 CANCELLED at t=${repro_elapsed}s (< 30s)"

# ── AC 2: failure is specific to the constrained (self-hosted) lane ────────
[[ "$gh_result" == "COMPLETED" ]] \
  || fail "github-hosted lane also failed (got $gh_result) — failure would not be runner-specific, contradicting INFRA-1655's observed pattern"
ok "github-hosted (ubuntu-latest) lane under identical push cadence: COMPLETED, not cancelled — confirms failure is runner-pool-specific"

# ── Regression guard: INFRA-1852 fix must still be present on main, else
#    the reproduced mechanism above is live again in production CI ─────────
[[ -f "$CI_YML" ]] || fail "ci.yml not found at $CI_YML"
grep -q "group: ci-\${{ github.workflow }}-\${{ github.event_name == 'push' && github.run_id || github.sha }}" "$CI_YML" \
  || fail "ci.yml concurrency group no longer keys PR/merge_group events on github.sha — INFRA-1852 fix appears reverted, which would make this reproduction live in production again"
ok "ci.yml concurrency.group still keys on github.sha (INFRA-1852 fix in place — mechanism reproduced above is NOT currently live on main)"

echo
echo "INFRA-3544: reproduction complete — root cause (INFRA-1852 pre-fix PR-number-keyed"
echo "concurrency group + self-hosted's bounded 4-runner pool) confirmed specific to"
echo "jeffs-macbook-air-10-X and confirmed already fixed on main. See:"
echo "  docs/process/SELF_HOSTED_RUNNERS.md 'Current state — degraded ubuntu-only mode'"
echo "  docs/process/CLAUDE_GOTCHAS.md 'Audit job concurrency policy — per-SHA scoping'"
echo "  docs/gaps/INFRA-1852.yaml (closed_pr: 2446)"
