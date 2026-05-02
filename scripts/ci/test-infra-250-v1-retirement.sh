#!/usr/bin/env bash
# CI acceptance test for INFRA-250: PWA v1 retirement.
# Asserts: (a) v1 assets deleted, (b) tauri.conf.json points at web/v2, (c) v2 wizard exists.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok()  { echo "[PASS] $*"; PASS=$((PASS + 1)); }
err() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

# (a) v1 assets must NOT exist
for f in \
  web/index.html \
  web/desktop-bridge.js \
  web/ootb-wizard.js \
  web/sse-event-parser.js \
  web/sw.js \
  web/ui-selftests.js
do
  if [ -f "$REPO_ROOT/$f" ]; then
    err "v1 file still present: $f"
  else
    ok "v1 file absent: $f"
  fi
done

# (b) tauri.conf.json frontendDist must be ../../web/v2
TAURI_CONF="$REPO_ROOT/desktop/src-tauri/tauri.conf.json"
if [ ! -f "$TAURI_CONF" ]; then
  err "tauri.conf.json not found at $TAURI_CONF"
else
  FRONTEND_DIST=$(python3 -c "import json,sys; d=json.load(open('$TAURI_CONF')); print(d['build']['frontendDist'])" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$FRONTEND_DIST" = "../../web/v2" ]; then
    ok "tauri.conf.json frontendDist = ../../web/v2"
  else
    err "tauri.conf.json frontendDist = '$FRONTEND_DIST' (expected ../../web/v2)"
  fi
fi

# (c) v2 wizard must exist and contain isTauriHost
WIZARD="$REPO_ROOT/web/v2/ootb-wizard.js"
if [ ! -f "$WIZARD" ]; then
  err "web/v2/ootb-wizard.js does not exist"
else
  ok "web/v2/ootb-wizard.js exists"
  if grep -q "isTauriHost" "$WIZARD"; then
    ok "web/v2/ootb-wizard.js contains isTauriHost reference"
  else
    err "web/v2/ootb-wizard.js missing isTauriHost reference"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
