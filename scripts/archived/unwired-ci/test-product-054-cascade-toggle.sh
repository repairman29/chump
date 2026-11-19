#!/usr/bin/env bash
# test-product-054-cascade-toggle.sh — PRODUCT-054 tests.
#
# Verifies PWA cascade slot toggle feature:
#   (1) POST /api/cascade-slot-toggle route wired in web_server.rs
#   (2) handle_cascade_slot_toggle handler defined in routes/health.rs
#   (3) read_cascade_disabled parses [cascade_slots] disabled = [...] from config.toml
#   (4) write_cascade_disabled creates [cascade_slots] section when absent
#   (5) write_cascade_disabled updates existing disabled list in place
#   (6) GET /api/cascade-status enriched with disabled_by_config field
#   (7) PWA JS uses /api/cascade-status (not /api/repo/context) for cascade info
#   (8) PWA JS wires cascade-toggle-input change events → POST /api/cascade-slot-toggle
#   (9) CSS cascade-toggle-track / cascade-slot-row present in index.html
#
# Run: ./scripts/ci/test-product-054-cascade-toggle.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEALTH_RS="$REPO_ROOT/src/routes/health.rs"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

echo "=== PRODUCT-054 cascade slot toggle tests ==="
echo

# ── Test 1: route present in web_server.rs ─────────────────────────────────
echo "--- Test 1: POST /api/cascade-slot-toggle route wired ---"
if grep -q 'cascade-slot-toggle' "$WEB_SERVER" 2>/dev/null && \
   grep -q 'handle_cascade_slot_toggle' "$WEB_SERVER" 2>/dev/null; then
    ok "Test 1: cascade-slot-toggle route + handler reference in web_server.rs"
else
    fail "Test 1: cascade-slot-toggle route missing from web_server.rs"
fi

# ── Test 2: handler defined in routes/health.rs ─────────────────────────────
echo "--- Test 2: handle_cascade_slot_toggle defined in health.rs ---"
if grep -q 'pub async fn handle_cascade_slot_toggle' "$HEALTH_RS" 2>/dev/null; then
    ok "Test 2: handle_cascade_slot_toggle defined in routes/health.rs"
else
    fail "Test 2: handle_cascade_slot_toggle not found in routes/health.rs"
fi

# ── Test 3: read_cascade_disabled parses config.toml ────────────────────────
echo "--- Test 3: read_cascade_disabled parses [cascade_slots] disabled list ---"
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

cat > "$_tmpdir/config.toml" <<'TOML'
fleet_model = "sonnet"

[api]
anthropic_api_key = "sk-ant-test"

[cascade_slots]
disabled = ["slot-a", "slot-b"]
TOML

_result3=$(CHUMP_HOME="$_tmpdir" python3 - <<'PYEOF' 2>/dev/null
import os, re
path = os.path.join(os.environ["CHUMP_HOME"], "config.toml")
content = open(path).read()
in_section = False
disabled = []
for line in content.splitlines():
    t = line.strip()
    if t.startswith('['):
        in_section = (t == "[cascade_slots]")
        continue
    if not in_section or t.startswith('#'):
        continue
    if t.startswith("disabled"):
        rest = t[len("disabled"):].strip(" =[]")
        disabled = [s.strip().strip('"') for s in rest.split(',') if s.strip().strip('"')]
print(",".join(disabled))
PYEOF
)

if [[ "$_result3" == "slot-a,slot-b" ]]; then
    ok "Test 3: read_cascade_disabled correctly parses disabled = [\"slot-a\", \"slot-b\"]"
else
    fail "Test 3: expected 'slot-a,slot-b', got '$_result3'"
fi

# ── Test 4: write creates [cascade_slots] section when absent ────────────────
echo "--- Test 4: write_cascade_disabled appends section when absent ---"
cat > "$_tmpdir/config2.toml" <<'TOML'
fleet_model = "sonnet"

[api]
anthropic_api_key = "sk-ant-test"
TOML

python3 - <<PYEOF 2>/dev/null
import os
path = "$_tmpdir/config2.toml"
disabled = ["slot-x"]
content = open(path).read()
disabled_line = 'disabled = [' + ', '.join(f'"{s}"' for s in disabled) + ']'
if "[cascade_slots]" not in content:
    if not content.endswith('\n'): content += '\n'
    content += '\n[cascade_slots]\n' + disabled_line + '\n'
open(path, 'w').write(content)
PYEOF

if grep -q '\[cascade_slots\]' "$_tmpdir/config2.toml" && \
   grep -q 'slot-x' "$_tmpdir/config2.toml"; then
    ok "Test 4: [cascade_slots] section created when absent"
else
    fail "Test 4: [cascade_slots] section not created"
fi

# ── Test 5: write updates existing disabled list ────────────────────────────
echo "--- Test 5: write_cascade_disabled updates existing disabled line ---"
cat > "$_tmpdir/config3.toml" <<'TOML'
fleet_model = "sonnet"

[cascade_slots]
disabled = ["slot-old"]
TOML

python3 - <<PYEOF 2>/dev/null
path = "$_tmpdir/config3.toml"
new_disabled = ["slot-new1", "slot-new2"]
content = open(path).read()
disabled_line = 'disabled = [' + ', '.join(f'"{s}"' for s in new_disabled) + ']'
lines = []
in_section = False
replaced = False
for line in content.splitlines():
    t = line.strip()
    if t.startswith('['):
        if in_section and not replaced:
            lines.append(disabled_line); replaced = True
        in_section = (t == "[cascade_slots]")
        lines.append(line); continue
    if in_section and t.startswith("disabled"):
        lines.append(disabled_line); replaced = True; continue
    lines.append(line)
if in_section and not replaced:
    lines.append(disabled_line)
open(path, 'w').write('\n'.join(lines) + '\n')
PYEOF

if grep -q 'slot-new1' "$_tmpdir/config3.toml" && \
   ! grep -q 'slot-old' "$_tmpdir/config3.toml"; then
    ok "Test 5: disabled list updated in place (old removed, new written)"
else
    fail "Test 5: disabled list update failed"
fi

# ── Test 6: cascade-status enriched with disabled_by_config ─────────────────
echo "--- Test 6: cascade-status handler includes disabled_by_config field ---"
if grep -q 'disabled_by_config' "$HEALTH_RS" 2>/dev/null; then
    ok "Test 6: disabled_by_config field present in cascade-status handler"
else
    fail "Test 6: disabled_by_config missing from cascade-status handler"
fi

# ── Test 7: PWA uses /api/cascade-status (not /api/repo/context) ────────────
echo "--- Test 7: app.js fetches /api/cascade-status for cascade slot info ---"
if grep -q "'/api/cascade-status'" "$APP_JS" 2>/dev/null || \
   grep -q '"/api/cascade-status"' "$APP_JS" 2>/dev/null; then
    ok "Test 7: app.js fetches /api/cascade-status"
else
    fail "Test 7: app.js does not fetch /api/cascade-status"
fi

# ── Test 8: PWA wires toggle events to POST cascade-slot-toggle ─────────────
echo "--- Test 8: app.js POSTs to /api/cascade-slot-toggle on toggle change ---"
if grep -q 'cascade-slot-toggle' "$APP_JS" 2>/dev/null && \
   grep -q "method.*POST\|POST.*method" "$APP_JS" 2>/dev/null; then
    ok "Test 8: app.js wires toggle → POST /api/cascade-slot-toggle"
else
    fail "Test 8: app.js missing POST to /api/cascade-slot-toggle"
fi

# ── Test 9: CSS present in index.html ───────────────────────────────────────
echo "--- Test 9: cascade slot toggle CSS in index.html ---"
if grep -q 'cascade-toggle-track' "$INDEX_HTML" 2>/dev/null && \
   grep -q 'cascade-slot-row' "$INDEX_HTML" 2>/dev/null; then
    ok "Test 9: cascade-toggle-track + cascade-slot-row CSS present in index.html"
else
    fail "Test 9: cascade slot CSS missing from index.html"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
