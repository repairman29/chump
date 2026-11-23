#!/usr/bin/env bash
# scripts/ci/test-content-bot-fleet-routing.sh — INFRA-1697
#
# Regression guard for Content Bots fleet routing (META-066 phase 4).
# Verifies:
#   1. scripts/dispatch/run-fleet.sh sets WORKER_SKILLS=content-bot,...
#      for the content-bot-tagged worker pool (default 1 worker, after
#      the PWA pool)
#   2. CHUMP_CONTENT_BOT_WORKERS=N env honored (0 disables, N=K tags K workers)
#   3. PWA pool + content-bot pool don't overlap (PWA workers 1..N_pwa,
#      content-bot workers N_pwa+1 .. N_pwa+N_cb)
#   4. _pick_and_claim_gap.py reads WORKER_SKILLS (the affinity layer
#      that lets content-bot tags actually route — INFRA-314)
#
# This is a wiring-regression test (no live fleet spawn). Real end-to-end
# routing under load is INFRA-1622's territory (the PWA equivalent has the
# same test surface).

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

# ── 1. run-fleet.sh exists + has content-bot routing block ──────────────────
if [[ ! -f "$FLEET_SCRIPT" ]]; then
    echo "FAIL: $FLEET_SCRIPT not found"
    failures=$((failures + 1))
else
    assert_grep "$FLEET_SCRIPT" \
        'WORKER_SKILLS=content-bot,pmm,docubot,evangelist,copybot' \
        "run-fleet.sh sets WORKER_SKILLS for content-bot pool"

    assert_grep "$FLEET_SCRIPT" \
        'CHUMP_CONTENT_BOT_WORKERS' \
        "run-fleet.sh honors CHUMP_CONTENT_BOT_WORKERS override"

    assert_grep "$FLEET_SCRIPT" \
        'CONTENT_BOT_WORKER_COUNT.*\$\{CHUMP_CONTENT_BOT_WORKERS:-1\}' \
        "run-fleet.sh defaults content-bot worker count to 1"

    # The PWA + content-bot blocks must not overlap (PWA first N, content-bot next M)
    assert_grep "$FLEET_SCRIPT" \
        'CONTENT_BOT_FIRST=\$\(\(PWA_WORKER_COUNT \+ 1\)\)' \
        "content-bot pool starts after the PWA pool ends"
fi

# ── 2. picker reads WORKER_SKILLS for affinity ──────────────────────────────
if [[ ! -f "$PICKER_SCRIPT" ]]; then
    echo "FAIL: $PICKER_SCRIPT not found"
    failures=$((failures + 1))
else
    assert_grep "$PICKER_SCRIPT" \
        'WORKER_SKILLS' \
        "picker reads WORKER_SKILLS env (INFRA-314 affinity layer)"
fi

# ── 3. Simulated env: CHUMP_CONTENT_BOT_WORKERS=0 disables the block ────────
# We can't spawn the fleet, but we can grep the block's gate condition.
if grep -qE 'CONTENT_BOT_WORKER_COUNT.*-gt[[:space:]]*0' "$FLEET_SCRIPT" 2>/dev/null; then
    : # gate present
else
    echo "FAIL: run-fleet.sh missing 'CONTENT_BOT_WORKER_COUNT -gt 0' disable-when-zero gate"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1697: $failures wiring assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1697: content-bot fleet routing wiring intact"
echo "  run-fleet.sh tags CONTENT_BOT_WORKER_COUNT workers (default 1) immediately"
echo "  after the PWA pool with WORKER_SKILLS=content-bot,<bot_id>..."
