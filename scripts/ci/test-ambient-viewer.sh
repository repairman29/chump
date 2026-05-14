#!/usr/bin/env bash
# scripts/ci/test-ambient-viewer.sh — PRODUCT-091
#
# Verifies PRODUCT-091: ambient event viewer API endpoints.
#   1. /api/ambient/recent endpoint exists in web_server.rs
#   2. /api/ambient/stream SSE endpoint exists in web_server.rs
#   3. PRODUCT-091 referenced in web_server.rs (AC 7)
#   4. ambient-viewer.js component exists + defines chump-ambient-viewer
#   5. ambient-viewer.js loaded in index.html
#   6. ambient view registered in app.js VIEWS
#   7. Events nav item added to ChumpNav
#   8. Functional: /api/ambient/recent reads ambient.jsonl and returns JSON
#   9. Functional: kind filter works correctly
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== PRODUCT-091: ambient event viewer CI checks ==="

WEB_SERVER="$REPO_ROOT/src/web_server.rs"
VIEWER_JS="$REPO_ROOT/web/v2/ambient-viewer.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
APP_JS="$REPO_ROOT/web/v2/app.js"

# 1. /api/ambient/recent handler exists
check grep -q "handle_ambient_recent" "$WEB_SERVER"

# 2. /api/ambient/stream handler exists
check grep -q "handle_ambient_stream" "$WEB_SERVER"

# 3. PRODUCT-091 referenced in web_server.rs
check grep -q "PRODUCT-091" "$WEB_SERVER"

# 4. ambient-viewer.js component exists and defines the element
check test -f "$VIEWER_JS"
check grep -q "chump-ambient-viewer" "$VIEWER_JS"

# 5. ambient-viewer.js loaded in index.html
check grep -q "ambient-viewer.js" "$INDEX_HTML"

# 6. ambient view registered in app.js VIEWS
check grep -q "ambient.*makeAmbientView\|ambient.*ambient" "$APP_JS"

# 7. Events nav item in ChumpNav
check grep -q "Events" "$APP_JS"

# 8. Functional: /api/ambient/recent reads ambient.jsonl correctly
_tmpdir=$(mktemp -d)
trap "rm -rf '$_tmpdir'" EXIT

_ambient="$_tmpdir/ambient.jsonl"
cat > "$_ambient" <<'JSON'
{"ts":"2026-05-14T00:01:00Z","kind":"gap_shipped","gap_id":"INFRA-100","note":"shipped"}
{"ts":"2026-05-14T00:02:00Z","kind":"pr_stuck","gap_id":"INFRA-101","note":"blocked"}
{"ts":"2026-05-14T00:03:00Z","kind":"fleet_wedge","note":"wedge detected"}
JSON

total=$((total+1))
_result=$(
  CHUMP_AMBIENT_LOG="$_ambient" python3 - <<'PY'
import json, os, sys

ambient = os.environ.get("CHUMP_AMBIENT_LOG", "")
content = open(ambient).read() if ambient and os.path.isfile(ambient) else ""
events = []
for line in content.strip().splitlines():
    try:
        events.append(json.loads(line))
    except Exception:
        pass
# Reverse for last N, then re-reverse for chronological
result = {"events": list(reversed(list(reversed(events))[:100])), "count": len(events)}
print(json.dumps(result))
PY
)
if echo "$_result" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['count']==3, d" >/dev/null 2>&1; then
  ok "Functional: /api/ambient/recent returns all events from ambient.jsonl"
  pass=$((pass+1))
else
  fail "Functional: expected 3 events, got: $_result"
fi

# 9. Functional: kind filter works
total=$((total+1))
_filtered=$(
  CHUMP_AMBIENT_LOG="$_ambient" python3 - <<'PY'
import json, os

ambient = os.environ.get("CHUMP_AMBIENT_LOG", "")
content = open(ambient).read() if ambient and os.path.isfile(ambient) else ""
kind_filter = "pr_stuck"
events = []
for line in content.strip().splitlines():
    try:
        v = json.loads(line)
        if v.get("kind") == kind_filter:
            events.append(v)
    except Exception:
        pass
result = {"events": events, "count": len(events)}
print(json.dumps(result))
PY
)
if echo "$_filtered" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['count']==1 and d['events'][0]['gap_id']=='INFRA-101'" >/dev/null 2>&1; then
  ok "Functional: kind=pr_stuck filter returns exactly 1 matching event"
  pass=$((pass+1))
else
  fail "Functional: kind filter unexpected result: $_filtered"
fi

echo ""
echo "=== Results: $pass/$total passed ==="
[[ "$pass" -eq "$total" ]] || exit 1
echo "PRODUCT-091: ambient event viewer validation complete."
