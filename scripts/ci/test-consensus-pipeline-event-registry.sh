#!/usr/bin/env bash
# test-consensus-pipeline-event-registry.sh — INFRA-2162 (META-125/C3)
# smoke test (AC4): verifies the 9 consensus-pipeline ambient event kinds
# named in the META-125 umbrella's C3 sub-gap are all registered in
# EVENT_REGISTRY.yaml with an effect_metric, AND each has a scanner-anchor
# (or an already-emitting production call site) so the event-registry
# verify rule's register-without-emit check (src/verify/rules/event_registry.rs)
# never flags this block.
#
# Run:
#   bash scripts/ci/test-consensus-pipeline-event-registry.sh
#
# Exits non-zero on any check failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2162 consensus-pipeline event-registry smoke test ==="
echo

if [ ! -f "$REGISTRY" ]; then
    echo "FATAL: $REGISTRY not found"
    exit 2
fi

KINDS=(
    consensus_ask_started
    consensus_routed_to_curator
    consensus_vote_cast
    consensus_quorum_reached
    consensus_timeout
    consensus_resolved
    consensus_decision_emitted
    roadmap_rerank_proposed
    roadmap_rerank_applied
)

# Production paths the event-registry verify rule scans for scanner-anchor /
# emit-literal call sites (mirrors PROD_PATHS in src/verify/rules/event_registry.rs).
PROD_PATHS=(
    src
    crates
    scripts/coord
    scripts/dispatch
    scripts/ops
    scripts/dev
    scripts/setup
    scripts/content-bots
    scripts/arsenal
)

for kind in "${KINDS[@]}"; do
    # 1. Registered in EVENT_REGISTRY.yaml.
    if grep -q "^  - kind: ${kind}\$" "$REGISTRY"; then
        ok "registered: ${kind}"
    else
        fail "NOT registered in EVENT_REGISTRY.yaml: ${kind}"
        continue
    fi

    # 2. effect_metric present for this entry (grab the block up to the next
    #    "- kind:" line and check it contains effect_metric).
    block="$(awk -v k="  - kind: ${kind}" '
        $0 == k { grab=1; print; next }
        grab && /^  - kind:/ { grab=0 }
        grab { print }
    ' "$REGISTRY")"
    if grep -q "effect_metric:" <<<"$block"; then
        ok "effect_metric present: ${kind}"
    else
        fail "missing effect_metric: ${kind}"
    fi

    # 3. Paired with a scanner-anchor or emit literal somewhere in a
    #    production path (register-without-emit guard).
    needle="\"kind\":\"${kind}\""
    found=0
    for p in "${PROD_PATHS[@]}"; do
        dir="$REPO_ROOT/$p"
        [ -d "$dir" ] || continue
        if grep -rq -- "$needle" "$dir" 2>/dev/null; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 1 ]; then
        ok "scanner-anchor/emit site found: ${kind}"
    else
        fail "no scanner-anchor or emit site in any PROD_PATHS dir: ${kind}"
    fi
done

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
