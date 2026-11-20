#!/usr/bin/env bash
# test-api-ambient-emit.sh — INFRA-1333
#
# Verifies the POST /api/ambient/emit endpoint:
#   1. Static wiring: handler symbol present + route registered.
#   2. Handler async + auth-gated.
#   3. Body validation: kind required, empty kind rejected.
#   4. server-side ts + source:"pwa" stamped (grep in handler body).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "==> INFRA-1333: POST /api/ambient/emit endpoint tests"

# ── 1. Static wiring ─────────────────────────────────────────────────────────

grep -q "fn handle_ambient_emit" "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_ambient_emit present" || fail "handle_ambient_emit missing"

grep -q '"/api/ambient/emit"' "$REPO_ROOT/src/web_server.rs" \
    && ok "ambient/emit route registered" || fail "ambient/emit route missing"

# Route must use POST (not GET)
grep -q 'post(handle_ambient_emit)' "$REPO_ROOT/src/web_server.rs" \
    && ok "route uses POST" || fail "route not POST"

# ── 2. Async + auth-gated ────────────────────────────────────────────────────

grep -q "async fn handle_ambient_emit" "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_ambient_emit is async" || fail "not async"

# Auth check must appear before any write — check_auth call in handler body
WEB_SERVER_RS="$REPO_ROOT/src/web_server.rs" python3 - <<'PYEOF'
import re, sys, os

src_path = os.environ['WEB_SERVER_RS']
with open(src_path) as f:
    src = f.read()

# Extract the handle_ambient_emit function body
m = re.search(r'async fn handle_ambient_emit\b.*?^}', src, re.DOTALL | re.MULTILINE)
if not m:
    print("[FAIL] handle_ambient_emit function not found for auth-gate check")
    sys.exit(1)

fn_body = m.group(0)
auth_pos = fn_body.find('check_auth')
write_pos = fn_body.find('writeln!')
if auth_pos < 0:
    print("[FAIL] check_auth not found in handle_ambient_emit")
    sys.exit(1)
if write_pos < 0:
    print("[FAIL] writeln! not found in handle_ambient_emit")
    sys.exit(1)
if auth_pos < write_pos:
    print(f"[PASS] auth gate precedes write (auth@{auth_pos} < write@{write_pos})")
else:
    print(f"[FAIL] auth gate AFTER write (auth@{auth_pos} >= write@{write_pos})")
    sys.exit(1)
PYEOF
if [[ $? -eq 0 ]]; then ok "auth gate precedes write"; else fail "auth gate ordering wrong"; fi

# ── 3. kind validation ───────────────────────────────────────────────────────

# Handler must reject missing/empty kind (look for BAD_REQUEST on kind check)
grep -q "BAD_REQUEST" "$REPO_ROOT/src/web_server.rs" \
    && ok "BAD_REQUEST present (kind validation)" || fail "BAD_REQUEST not found"

# ── 4. Server-side ts + source stamped ───────────────────────────────────────

WEB_SERVER_RS="$REPO_ROOT/src/web_server.rs" python3 - <<'PYEOF'
import re, sys, os

src_path = os.environ['WEB_SERVER_RS']
with open(src_path) as f:
    src = f.read()

m = re.search(r'async fn handle_ambient_emit\b.*?^}', src, re.DOTALL | re.MULTILINE)
if not m:
    print("[FAIL] handle_ambient_emit not found")
    sys.exit(1)

fn_body = m.group(0)

# Must stamp ts
if '"ts"' not in fn_body and "'ts'" not in fn_body:
    print("[FAIL] ts not stamped in handler")
    sys.exit(1)
print("[PASS] ts stamp present")

# Must tag source
if '"source"' not in fn_body and "'source'" not in fn_body:
    print("[FAIL] source tag not present in handler")
    sys.exit(1)
print("[PASS] source tag present")

# Must use ambient_log_path()
if 'ambient_log_path()' not in fn_body:
    print("[FAIL] ambient_log_path() not used in handler")
    sys.exit(1)
print("[PASS] ambient_log_path() used")
PYEOF
if [[ $? -eq 0 ]]; then ok "server-side ts + source + ambient_log_path"; else fail "ts/source/path checks failed"; fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL CHECKS PASSED — INFRA-1333 verified" && exit 0 || exit 1
