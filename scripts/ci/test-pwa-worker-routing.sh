#!/usr/bin/env bash
# scripts/ci/test-pwa-worker-routing.sh — INFRA-1622
#
# Verifies the PWA worker-skill affinity routing wiring:
#   1. scripts/dispatch/run-fleet.sh tags the first N workers (default 2)
#      with WORKER_SKILLS=pwa,frontend,javascript when launching fleet panes
#   2. scripts/dispatch/_pick_and_claim_gap.py reads WORKER_SKILLS env and
#      filters gaps by skills_required affinity (INFRA-314 + INFRA-1622)
#   3. The CHUMP_PWA_WORKERS env var overrides the default count
#
# This is a wiring-regression test: it asserts the integration points exist
# and behave as documented in docs/product/PWA_ROADMAP.md "Worker pool"
# section. Full end-to-end picker dry-run (with fixture state.db) is out
# of scope for this gap and tracked separately.
#
# Exit: 0 = wiring intact, 1 = at least one integration point missing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLEET_SCRIPT="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
PICKER_SCRIPT="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

failures=0

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       file: ${file#"$REPO_ROOT/"}"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
        return 1
    fi
    return 0
}

# ── 1. run-fleet.sh sets WORKER_SKILLS for first N workers ──────────────────
if [[ ! -f "$FLEET_SCRIPT" ]]; then
    echo "FAIL: $FLEET_SCRIPT not found"
    failures=$((failures + 1))
else
    assert_grep "$FLEET_SCRIPT" \
        'WORKER_SKILLS=pwa,frontend,javascript' \
        "run-fleet.sh sets WORKER_SKILLS for PWA-tagged workers"

    assert_grep "$FLEET_SCRIPT" \
        'CHUMP_PWA_WORKERS' \
        "run-fleet.sh respects CHUMP_PWA_WORKERS override"

    assert_grep "$FLEET_SCRIPT" \
        'PWA_WORKER_COUNT.*\$\{CHUMP_PWA_WORKERS:-2\}' \
        "run-fleet.sh defaults PWA worker count to 2"
fi

# ── 2. picker reads WORKER_SKILLS and uses it for affinity ───────────────────
if [[ ! -f "$PICKER_SCRIPT" ]]; then
    echo "FAIL: $PICKER_SCRIPT not found"
    failures=$((failures + 1))
else
    assert_grep "$PICKER_SCRIPT" \
        'WORKER_SKILLS' \
        "picker reads WORKER_SKILLS env (INFRA-314 affinity layer)"

    assert_grep "$PICKER_SCRIPT" \
        'skills_required|affinity_enabled|CHUMP_AFFINITY' \
        "picker filters gaps by skills_required affinity"
fi

# ── 3. canonical skills mapping documented in PWA_ROADMAP.md ────────────────
ROADMAP="$REPO_ROOT/docs/product/PWA_ROADMAP.md"
if [[ -f "$ROADMAP" ]]; then
    assert_grep "$ROADMAP" \
        'pwa,frontend,javascript' \
        "PWA_ROADMAP.md documents the WORKER_SKILLS tag"

    assert_grep "$ROADMAP" \
        'CHUMP_PWA_WORKERS' \
        "PWA_ROADMAP.md documents the CHUMP_PWA_WORKERS knob"

    assert_grep "$ROADMAP" \
        'PWA-FRONTEND.*pwa,frontend' \
        "PWA_ROADMAP.md documents skills_required → title-prefix mapping"
fi

# ── 4. real PWA gaps in registry have skills_required populated ─────────────
# This is a smoke check that the INFRA-1622 backfill happened. Optional —
# skipped if chump binary unavailable (CI minimal envs).
if command -v chump >/dev/null 2>&1; then
    pwa_total="$(chump gap list --status open --json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
n = sum(1 for g in data if 'pwa' in g.get('title','').lower() or g.get('title','').startswith('PWA'))
print(n)
" 2>/dev/null || echo "0")"
    pwa_tagged="$(chump gap list --status open --json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
n = sum(1 for g in data
        if ('pwa' in g.get('title','').lower() or g.get('title','').startswith('PWA'))
        and g.get('skills_required'))
print(n)
" 2>/dev/null || echo "0")"
    # Advisory: report tagged ratio but don't fail. The detection is best-effort
    # — title-substring matching catches false-positives (e.g. INFRA-1677's
    # "(homebrew-chump, PWA)" parenthetical) that aren't real PWA work. Real
    # backfill audits should be done with curator-aware gap selection, not
    # this regex. The wiring assertions above are the durable test surface.
    if [[ "${pwa_total:-0}" -gt 0 ]]; then
        echo "ADVISORY: $pwa_tagged of $pwa_total PWA-titled gaps have skills_required set"
    fi
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1622: $failures wiring assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1622: PWA worker-routing wiring intact"
