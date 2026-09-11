#!/usr/bin/env bash
# scripts/ci/test-preflight-cli-misc.sh — INFRA-4406 (INFRA-3373/META-070 slice)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/crates/chump-preflight/src/preflight.rs"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }

# AC 2: all 41 cli-observability-misc scripts run by default under the gate.
SCRIPTS=(
  test-acp-real-clients.sh
  test-api-chat-cost-kill.sh
  test-api-cost-leaderboard.sh
  test-cascade-rebase-observability.sh
  test-chump-fleet-cli.sh
  test-chump-skill-cli.sh
  test-cli-aliases.sh
  test-cli-arg-validation.sh
  test-cli-exit-codes.sh
  test-cli-fleet-coord.sh
  test-cli-help.sh
  test-cli-integration.sh
  test-cli-output-format.sh
  test-cli-product-surface.sh
  test-cog-043-action-telemetry.sh
  test-cost-enforcement.sh
  test-cost-per-model.sh
  test-cost-watch.sh
  test-coupling-cost.sh
  test-cursor-cli-integration.sh
  test-doc-only-clippy-skip.sh
  test-event-registry-guard.sh
  test-fleet-metrics-snapshot.sh
  test-gap-closed-pr-cli.sh
  test-gate-telemetry.sh
  test-gen-cost-summary.sh
  test-github-api-telemetry.sh
  test-github-api-telemetry-shim.sh
  test-harvester-cli.sh
  test-infra-1062-clippy-timeout-silent-exit.sh
  test-observability-coverage.sh
  test-observability-loop.sh
  test-pr-cost-telemetry.sh
  test-pr-fix-clippy.sh
  test-pr-stuck-cluster-observability.sh
  test-pr-unstick-observability.sh
  test-pwa-cost-ceiling.sh
  test-pwa-version-compat.sh
  test-pwa-workflow-observability.sh
  test-telemetry-cost.sh
  test-worker-preship-clippy.sh
)

if [[ ${#SCRIPTS[@]} -ne 41 ]]; then
  echo "FAIL: expected 41 cli-observability-misc scripts, have ${#SCRIPTS[@]}"
  failures=$((failures+1))
fi

for s in "${SCRIPTS[@]}"; do
  ag "$PREFLIGHT" "scripts/ci/$s" "preflight CLI_OBSERVABILITY_MISC_SCRIPTS mirrors $s"
done

# AC 1 (existence + executable) is enforced by CI itself (this script runs),
# but assert the bit is set so a non-executable regression is caught locally too.
if [[ ! -x "$0" ]]; then
  echo "FAIL: $0 is not executable"
  failures=$((failures+1))
fi

# AC 3: CHUMP_PREFLIGHT_SKIP_CLI_MISC=1 skips the gate and emits the
# skip audit-trail event.
ag "$PREFLIGHT" "CHUMP_PREFLIGHT_SKIP_CLI_MISC" "preflight honors CHUMP_PREFLIGHT_SKIP_CLI_MISC"
ag "$PREFLIGHT" '"preflight_climisc_bypassed"' "preflight emits preflight_climisc_bypassed"
ag "$RESERVED" "^preflight_climisc_bypassed" "reserved.txt allowlists preflight_climisc_bypassed"
ag "$PREFLIGHT" "INFRA-4406" "preflight has INFRA-4406 attribution"

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-4406: $failures"; exit 1; }
echo "OK INFRA-4406"
