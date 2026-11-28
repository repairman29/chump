#!/usr/bin/env bash
# scripts/ci/test-product-378-mission-studio.sh — PRODUCT-378
#
# Structural & parse verification for the Dream -> Mission Architect ->
# 1-Click Autonomous Factory pipeline (/api/missions + /v2/ Mission Studio).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MISSIONS_RS="${REPO_ROOT}/src/routes/missions.rs"
WEB_SERVER="${REPO_ROOT}/src/web_server.rs"
COCKPIT_JS="${REPO_ROOT}/web/v2/cockpit.js"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-product-378-mission-studio] PRODUCT-378 — Mission Architect & Autonomous Factory"

[[ -f "$MISSIONS_RS" ]] || fail "missing src/routes/missions.rs"
[[ -f "$WEB_SERVER" ]]  || fail "missing src/web_server.rs"
[[ -f "$COCKPIT_JS" ]]  || fail "missing web/v2/cockpit.js"

grep -q "FileBackedMissionStore" "$MISSIONS_RS" || fail "missions.rs must reuse chump_coord::mission::FileBackedMissionStore"
grep -q "check_l1_missions" "$MISSIONS_RS"      || fail "missions.rs must reuse standard_missions::check_l1_missions"
grep -q "build_provider" "$MISSIONS_RS"         || fail "missions.rs must route LLM calls through provider_cascade::build_provider"
grep -q "ensure_greenfield_repo_initialized" "$MISSIONS_RS" || fail "missions.rs missing greenfield repo init"
ok "missions.rs reuses FileBackedMissionStore, check_l1_missions, and ProviderCascade"

grep -q '"/api/missions"' "$WEB_SERVER"           || fail "missing /api/missions route"
grep -q '"/api/missions/architect"' "$WEB_SERVER" || fail "missing /api/missions/architect route"
grep -q '"/api/missions/{id}/launch"' "$WEB_SERVER"  || fail "missing /api/missions/{id}/launch route"
grep -q '"/api/missions/{id}/control"' "$WEB_SERVER" || fail "missing /api/missions/{id}/control route"
ok "all /api/missions routes registered in web_server.rs"

grep -q "Architect Mission Plan" "$COCKPIT_JS" || fail "cockpit.js missing Architect Mission Plan CTA"
grep -q "Scout &amp; Revive Repo" "$COCKPIT_JS" || fail "cockpit.js missing 0->1 Scout & Revive button"
grep -q "Approve &amp; Launch Autonomous Factory" "$COCKPIT_JS" || fail "cockpit.js missing 1-click Approve & Launch CTA"
grep -q 'data-repo-mode="new"' "$COCKPIT_JS" || fail "cockpit.js missing greenfield new-repo mode tab"
ok "cockpit.js wires Dream intake, 0->1 Scout, 1-click Plan Approval, and Greenfield mode"

node --check "$COCKPIT_JS"
ok "cockpit.js passes node --check"

echo "[test-product-378-mission-studio] All checks passed."
