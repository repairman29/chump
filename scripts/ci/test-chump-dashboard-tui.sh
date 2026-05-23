#!/usr/bin/env bash
# test-chump-dashboard-tui.sh — INFRA-1894 smoke test
#
# Network-free. Stubs chump + gh on PATH. Creates a synthetic
# .chump-locks/ambient.jsonl with at least one ALERT event.
# Asserts all 5 section headers are present in one-shot output.
# Asserts --json mode produces a valid envelope with all 5 top-level fields.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/chump-dashboard-tui.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found or not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Environment overrides ─────────────────────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/locks/inbox"
export PATH="$TMP/bin:$PATH"
export CHUMP_LOCK_DIR="$TMP/locks"
export CHUMP_AMBIENT_LOG="$TMP/locks/ambient.jsonl"
export CHUMP_SESSION_ID="test-dashboard-session"
export CHUMP_BIN="$TMP/bin/chump"

# ── Synthetic ambient.jsonl with one ALERT event ──────────────────────────────
cat > "$CHUMP_AMBIENT_LOG" <<'AMBIENT'
{"ts":"2026-05-23T01:00:00Z","event":"ALERT","reason":"synthetic alert for smoke test"}
{"ts":"2026-05-23T01:01:00Z","event":"WARN","reason":"synthetic warn one"}
{"ts":"2026-05-23T01:02:00Z","kind":"graphql_exhausted"}
AMBIENT

# ── Synthetic lease files ─────────────────────────────────────────────────────
python3 -c "
import json, os
# Write one claim file so section (b) is exercised
claim = {
    'session_id': 'claim-smoke-test-001',
    'gap_id': 'SMOKE-001',
    'taken_at': '2026-05-23T00:58:00Z',
    'expires_at': '2026-05-23T04:58:00Z',
    'paths': ['scripts/dev/chump-dashboard-tui.sh']
}
with open(os.environ['CHUMP_LOCK_DIR'] + '/claim-smoke-test-001.json', 'w') as f:
    json.dump(claim, f)
"

# ── Stub: chump binary ────────────────────────────────────────────────────────
# Returns gap list output with pillar tags so section (d) can count them.
cat > "$TMP/bin/chump" <<'CHUMP_STUB'
#!/usr/bin/env bash
case "${1:-}" in
    gap)
        case "${2:-}" in
            list)
                # Minimal rows with pillar tags for section (d) counting
                printf '[open] EFFECTIVE-001 — EFFECTIVE: stub gap one (P1/s)\n'
                printf '[open] EFFECTIVE-002 — EFFECTIVE: stub gap two (P1/xs)\n'
                printf '[open] CREDIBLE-001 — CREDIBLE: stub gap three (P1/s)\n'
                printf '[open] RESILIENT-001 — RESILIENT: stub gap four (P1/s)\n'
                printf '[open] RESILIENT-002 — RESILIENT: stub gap five (P1/xs)\n'
                printf '[open] RESILIENT-003 — RESILIENT: stub gap six (P1/s)\n'
                printf '[open] ZERO-WASTE-001 — ZERO-WASTE: stub gap seven (P1/xs)\n'
                printf '[open] MISSION-001 — MISSION: stub gap eight (P1/s)\n'
                exit 0
                ;;
            audit-priorities)
                # Legacy / fallback path — not used by dashboard but keep valid JSON
                printf '{"p0_count":0,"vague_pickable":0}\n'
                exit 0
                ;;
        esac
        ;;
esac
# All other subcommands: silent no-op
exit 0
CHUMP_STUB
chmod +x "$TMP/bin/chump"

# ── Stub: gh (not called by dashboard, but guard just in case) ────────────────
cat > "$TMP/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
echo "[]"
GH_STUB
chmod +x "$TMP/bin/gh"

echo "=== chump-dashboard-tui smoke tests ==="
echo ""

# ── Test 1: one-shot render contains all 5 section headers ───────────────────
echo "Test 1: one-shot render — all 5 section headers present"
out="$(bash "$SCRIPT" 2>&1 || true)"
fail=0
for header in \
    "(a) TODAY'S SHIPPING" \
    "(b) ACTIVE LEASES" \
    "(c) INBOX UNREAD" \
    "(d) PILLAR PICKABLE" \
    "(e) RECENT ALERTS"
do
    if printf '%s' "$out" | grep -q "$header"; then
        printf '  PASS  header: %s\n' "$header"
    else
        printf '  FAIL  header missing: %s\n' "$header"
        fail=1
    fi
done
if [[ "$fail" -eq 1 ]]; then
    echo ""
    echo "--- dashboard output ---"
    printf '%s\n' "$out"
    exit 1
fi

# ── Test 2: output fits in 40 lines ──────────────────────────────────────────
echo "Test 2: output fits in ≤40 lines (80x40 terminal)"
line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
if [[ "$line_count" -le 40 ]]; then
    printf '  PASS  %d lines\n' "$line_count"
else
    printf '  FAIL  %d lines exceeds 40-line terminal budget\n' "$line_count"
    exit 1
fi

# ── Test 3: --json mode emits valid JSON with all 5 top-level fields ──────────
echo "Test 3: --json mode — valid JSON with all 5 required fields"
json_out="$(bash "$SCRIPT" --json 2>&1 || true)"
parse_fail=0
python3 - <<PYEOF || { echo "  FAIL  --json output is not valid JSON"; exit 1; }
import json, sys
raw = """$json_out"""
try:
    d = json.loads(raw)
except Exception as e:
    print(f"  FAIL  json.loads: {e}")
    sys.exit(1)
required = ['ts', 'shipping', 'leases', 'inbox_unread', 'pillar_pickable', 'recent_alerts']
missing = [k for k in required if k not in d]
if missing:
    print(f"  FAIL  missing fields: {missing}")
    sys.exit(1)
# Assert pillar_pickable has the 5 pillars
pp = d.get('pillar_pickable', {})
for pillar in ['EFFECTIVE', 'CREDIBLE', 'RESILIENT', 'ZERO_WASTE', 'MISSION']:
    if pillar not in pp:
        print(f"  FAIL  pillar_pickable missing {pillar}")
        sys.exit(1)
print("  PASS  all 6 top-level fields present; pillar_pickable has 5 pillars")
PYEOF

# ── Test 4: ALERT event from synthetic ambient is surfaced ────────────────────
echo "Test 4: synthetic ALERT event surfaces in section (e)"
if printf '%s' "$out" | grep -q "synthetic alert for smoke test"; then
    echo "  PASS  ALERT event text found in output"
else
    echo "  FAIL  synthetic ALERT event not found in section (e)"
    printf '%s\n' "$out" | grep -A 6 "RECENT ALERTS" || true
    exit 1
fi

# ── Test 5: lease from claim file surfaces in section (b) ─────────────────────
echo "Test 5: synthetic lease (SMOKE-001) surfaces in section (b)"
if printf '%s' "$out" | grep -q "SMOKE-001"; then
    echo "  PASS  SMOKE-001 lease visible"
else
    echo "  FAIL  SMOKE-001 not found in section (b)"
    printf '%s\n' "$out" | grep -A 5 "ACTIVE LEASES" || true
    exit 1
fi

echo ""
echo "All 5 chump-dashboard-tui smoke tests PASSED."
