#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-fleet-brief-ship-count-unavailable.sh — CREDIBLE-129
#
# Regression test for the false fleet-dead signal: when `git log ...
# origin/main` fails (unresolvable ref — the transient failure mode
# documented in docs/investigations/CREDIBLE-1107-fleet-brief-subshell-audit.md),
# `chump fleet brief` must report "unavailable", never a bare 0 that reads
# as "the fleet shipped nothing and is healthy."
#
# Verifies:
#   1. Text output shows "Ships: unavailable" (not "Ships: 0") when
#      origin/main can't be resolved.
#   2. --json emits ships_24h=null, ships_1h=null, ships_measurement_failed=true.
#   3. Suggestions/actions surface the measurement-failure warning instead
#      of (or ahead of) "fleet looks healthy".
#   4. fleet_stalled is NOT fired purely from the failed measurement.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN"
    echo "  Run: cargo build --bin chump"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/.chump-locks"
mkdir -p "$TMP/repo/.chump"

# ── Init a real git repo with NO origin/main ref at all ───────────────────
# `git log ... origin/main` then fails to resolve the revision (exit 128),
# reproducing the CREDIBLE-1107-documented failure mode without needing a
# real network fetch or a timing race against pack-refs/gc.
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email ci@chump.test
git -C "$TMP/repo" config user.name CI
git -C "$TMP/repo" -c commit.gpgsign=false commit -q --allow-empty -m "local-only commit, no origin/main ref"

# ── Test 1: text output shows "unavailable", never a bare 0 ───────────────
echo "Test 1: Ships line reads 'unavailable' when origin/main is unresolvable"
OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -q "Ships: unavailable"; then
    echo "  PASS"
else
    echo "  FAIL: expected 'Ships: unavailable', got:"
    echo "$OUT" | sed 's/^/  /'
    exit 1
fi
if echo "$OUT" | grep -qE "Ships: 0 "; then
    echo "  FAIL: banner printed a bare 'Ships: 0' — indistinguishable from a real zero-ship state"
    exit 1
fi

# ── Test 2: --json emits null counts + explicit failure flag ──────────────
echo "Test 2: --json emits ships_24h=null, ships_1h=null, ships_measurement_failed=true"
JSON_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief --json 2>/dev/null)"
if echo "$JSON_OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ships_24h') is None, f\"ships_24h={d.get('ships_24h')!r}, want null\"
assert d.get('ships_1h') is None, f\"ships_1h={d.get('ships_1h')!r}, want null\"
assert d.get('ships_measurement_failed') is True, f\"ships_measurement_failed={d.get('ships_measurement_failed')!r}, want true\"
"; then
    echo "  PASS"
else
    echo "  FAIL: JSON did not report the measurement failure correctly"
    echo "$JSON_OUT" | sed 's/^/  /'
    exit 1
fi

# ── Test 3: suggestions surface the measurement-failure warning, not "healthy" ──
echo "Test 3: suggestions/actions warn about unavailable measurement, not false-healthy"
if echo "$JSON_OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sugg = d.get('suggestions', [])
assert any('unavailable' in s for s in sugg), f\"no unavailable warning in suggestions: {sugg!r}\"
assert not (len(sugg) == 1 and 'looks healthy' in sugg[0]), f\"suggestions collapsed to false-healthy: {sugg!r}\"
"; then
    echo "  PASS"
else
    echo "  FAIL"
    echo "$JSON_OUT" | sed 's/^/  /'
    exit 1
fi

# ── Test 4: fleet_stalled is NOT fired purely from the failed measurement ─
echo "Test 4: fleet_stalled stays false when the failure is measurement-only (no real pr_stuck signal)"
if echo "$JSON_OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('fleet_stalled') is False, f\"fleet_stalled={d.get('fleet_stalled')!r}, want false (no real pr_stuck evidence)\"
"; then
    echo "  PASS"
else
    echo "  FAIL"
    echo "$JSON_OUT" | sed 's/^/  /'
    exit 1
fi

echo ""
echo "All fleet-brief ship-count-unavailable tests passed (4/4)."
