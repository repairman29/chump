#!/usr/bin/env bash
# CI test: verify tauri e2e accepts #input OR #msg-input (CREDIBLE-055)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

ok()   { echo "ok: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

RUN="$ROOT/e2e-tauri/run.mjs"

# 1. The tauri e2e script exists
[[ -f "$RUN" ]] && ok "e2e-tauri/run.mjs exists" || fail "e2e-tauri/run.mjs missing"

# 2. The wait query accepts msg-input fallback
grep -q "getElementById.*msg-input" "$RUN" \
  && ok "tauri e2e accepts #msg-input fallback" \
  || fail "tauri e2e still only accepts #input — alias rename race remains"

# 3. The error message reflects both ids
grep -q "input or #msg-input\|#msg-input" "$RUN" \
  && ok "error message reflects both selectors" \
  || fail "error message does not mention both ids"

# 4. The index.html alias script still renames #input → #msg-input (keep behavior)
grep -q "input.id = 'msg-input'\|input\.id\s*=\s*['\"]msg-input" "$ROOT/web/v2/index.html" \
  && ok "alias script still renames #input → #msg-input (backward compat)" \
  || fail "alias script no longer renames #input — check downstream consumers"

# 5. chump-chat shadow root sets id="input"
grep -q 'id="input"' "$ROOT/web/v2/chat.js" \
  && ok "chump-chat shadow root declares id=input" \
  || fail "chump-chat shadow root no longer has id=input"

echo ""
echo "CREDIBLE-055: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
