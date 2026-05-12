#!/usr/bin/env bash
# test-operational-runbooks.sh — INFRA-850
#
# Validates operational runbooks for fleet management:
#  - docs/runbooks/fleet-wedge.md exists with required sections
#  - docs/runbooks/pr-stuck.md exists with required sections
#  - docs/runbooks/silent-agent.md exists with required sections
#  - Event kinds referenced in each runbook are registered in EVENT_REGISTRY.yaml

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNBOOKS="$REPO_ROOT/docs/runbooks"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-850 operational runbooks test ==="
echo

# --- fleet-wedge.md ---
echo "[fleet-wedge.md]"

WEDGE="$RUNBOOKS/fleet-wedge.md"
if [[ -f "$WEDGE" ]]; then
    ok "fleet-wedge.md exists"
else
    fail "fleet-wedge.md missing from docs/runbooks/"
fi

for section in "## Symptoms" "## Steps" "## Verify"; do
    if grep -qF "$section" "$WEDGE" 2>/dev/null; then
        ok "fleet-wedge.md has '$section' section"
    else
        fail "fleet-wedge.md missing '$section' section"
    fi
done

for kind in fleet_wedge fleet_wedge_storm silent_agent; do
    if grep -qF "$kind" "$WEDGE" 2>/dev/null; then
        if grep -qF "$kind" "$REGISTRY" 2>/dev/null; then
            ok "fleet-wedge.md references $kind (registered in EVENT_REGISTRY)"
        else
            fail "$kind referenced in fleet-wedge.md but not in EVENT_REGISTRY.yaml"
        fi
    else
        fail "fleet-wedge.md does not reference event kind '$kind'"
    fi
done

# --- pr-stuck.md ---
echo
echo "[pr-stuck.md]"

STUCK="$RUNBOOKS/pr-stuck.md"
if [[ -f "$STUCK" ]]; then
    ok "pr-stuck.md exists"
else
    fail "pr-stuck.md missing from docs/runbooks/"
fi

for section in "## Symptoms" "## Steps" "## Verify"; do
    if grep -qF "$section" "$STUCK" 2>/dev/null; then
        ok "pr-stuck.md has '$section' section"
    else
        fail "pr-stuck.md missing '$section' section"
    fi
done

for kind in pr_stuck pr_rescue_triggered pr_rescue_completed pr_rescue_failed; do
    if grep -qF "$kind" "$STUCK" 2>/dev/null; then
        if grep -qF "$kind" "$REGISTRY" 2>/dev/null; then
            ok "pr-stuck.md references $kind (registered in EVENT_REGISTRY)"
        else
            fail "$kind referenced in pr-stuck.md but not in EVENT_REGISTRY.yaml"
        fi
    else
        fail "pr-stuck.md does not reference event kind '$kind'"
    fi
done

# --- silent-agent.md ---
echo
echo "[silent-agent.md]"

SILENT="$RUNBOOKS/silent-agent.md"
if [[ -f "$SILENT" ]]; then
    ok "silent-agent.md exists"
else
    fail "silent-agent.md missing from docs/runbooks/"
fi

for section in "## Symptoms" "## Steps" "## Verify"; do
    if grep -qF "$section" "$SILENT" 2>/dev/null; then
        ok "silent-agent.md has '$section' section"
    else
        fail "silent-agent.md missing '$section' section"
    fi
done

for kind in fleet_worker_silent silent_agent lease_overlap; do
    if grep -qF "$kind" "$SILENT" 2>/dev/null; then
        if grep -qF "$kind" "$REGISTRY" 2>/dev/null; then
            ok "silent-agent.md references $kind (registered in EVENT_REGISTRY)"
        else
            fail "$kind referenced in silent-agent.md but not in EVENT_REGISTRY.yaml"
        fi
    else
        fail "silent-agent.md does not reference event kind '$kind'"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
