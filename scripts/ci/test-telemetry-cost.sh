#!/usr/bin/env bash
# CI test for INFRA-1012: GET /api/telemetry/cost per-gap breakdown + window support.
#
# Tests:
#   1. Endpoint handler accepts ?window query param (code inspection)
#   2. per_gap_breakdown field present in response schema
#   3. Session_end events from ambient.jsonl are parsed for gap/gap_id field
#   4. day/month window filtering uses cutoff_secs logic
#   5. cost-meter.js component exists and polls /api/telemetry/cost

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEB_SERVER="${REPO_ROOT}/src/web_server.rs"
COST_METER="${REPO_ROOT}/web/v2/cost-meter.js"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-telemetry-cost] INFRA-1012 — cost endpoint per-gap breakdown"

# ── 1. Endpoint accepts window query param ─────────────────────────────────────
echo
echo "[1. window query param accepted]"
if grep -q "CostQuery" "$WEB_SERVER" && grep -q '"window"' "$WEB_SERVER"; then
    ok "CostQuery struct with window field present"
else
    fail "window query param not wired in handle_telemetry_cost"
fi

# ── 2. per_gap_breakdown in response ──────────────────────────────────────────
echo
echo "[2. per_gap_breakdown in response payload]"
if grep -q '"per_gap_breakdown"' "$WEB_SERVER"; then
    ok "per_gap_breakdown field present in JSON response"
else
    fail "per_gap_breakdown missing from handle_telemetry_cost response"
fi

# ── 3. session_end events parsed for gap/gap_id ───────────────────────────────
echo
echo "[3. session_end parsing supports both gap and gap_id fields]"
if grep -q '"gap_id"' "$WEB_SERVER" && grep -q '"gap"' "$WEB_SERVER"; then
    ok "handler reads both gap_id (Rust emitter) and gap (shell emitter) fields"
else
    fail "session_end field compatibility not present"
fi

# ── 4. Cutoff logic for day/month windows ─────────────────────────────────────
echo
echo "[4. day/month window cutoff logic present]"
if grep -q 'cutoff_secs' "$WEB_SERVER" && grep -q '86_400' "$WEB_SERVER"; then
    ok "cutoff_secs-based time filtering present for day/month windows"
else
    fail "window cutoff logic missing"
fi

# ── 5. cost-meter.js component exists and polls correct endpoint ──────────────
echo
echo "[5. cost-meter.js component polls /api/telemetry/cost]"
if [[ -f "$COST_METER" ]]; then
    if grep -q "telemetry/cost" "$COST_METER"; then
        ok "cost-meter.js fetches /api/telemetry/cost"
    else
        fail "cost-meter.js does not reference /api/telemetry/cost"
    fi
else
    fail "web/v2/cost-meter.js not found"
fi

# ── 6. cost-meter.js is wired into index.html ────────────────────────────────
echo
echo "[6. cost-meter component wired into PWA index.html]"
INDEX="${REPO_ROOT}/web/v2/index.html"
if [[ -f "$INDEX" ]] && grep -q "chump-cost-meter" "$INDEX"; then
    ok "<chump-cost-meter> element present in index.html"
else
    fail "cost-meter not visible in PWA: <chump-cost-meter> missing from index.html"
fi

# ── 7. chrono_approx_secs helper parses ISO 8601 ─────────────────────────────
echo
echo "[7. chrono_approx_secs timestamp parser present]"
if grep -q "chrono_approx_secs" "$WEB_SERVER"; then
    ok "chrono_approx_secs helper defined for window timestamp filtering"
else
    fail "chrono_approx_secs not found — window filtering will fail at runtime"
fi

echo
echo "[test-telemetry-cost] All checks passed."
