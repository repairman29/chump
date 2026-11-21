#!/usr/bin/env bash
# INFRA-8057: gpu-embed/embed nodes must not carry the shipping organ stack.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
fail(){ echo "FAIL $*"; exit 1; }
for r in embed gpu-embed; do
  u=" $(organ_role_units_for "$r") "
  for bad in chump-cj-worker.service chump-farmer.timer chump-merge-serializer.timer chump-armed-rebaser.timer chump-armed-pr-rebaser.timer chump-integrator.timer chump-pr-approval.timer chump-nba-dispatch.timer chump-duty-officer.timer chump-digest.timer chump-gap-drain.timer; do
    [[ "$u" == *" $bad "* ]] && fail "$r roster contains shipping organ $bad"
  done
  [[ "$u" == *" chump-disk-monitor.service "* ]] || fail "$r roster lost disk-monitor"
  [[ -n "$(organ_role_filter_for "$r")" ]] || fail "$r has empty role filter"
done
# worker exemption must be off on embed nodes, on elsewhere
src="$(sed -n '/^organ_is_node_local()/,/^}/p' "$REPO_ROOT/scripts/ops/organ-reconcile.sh")"
eval "NODE_LOCAL_ORGAN_BASES=(); $src"
CHUMP_NODE_ROLE=gpu-embed organ_is_node_local chump-cj-worker.service && fail "worker still exempt on gpu-embed"
CHUMP_NODE_ROLE=muscle organ_is_node_local chump-cj-worker.service || fail "worker exemption lost on muscle"
echo "PASS INFRA-8057 embed role scope"
