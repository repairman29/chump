#!/usr/bin/env bash
# CI: chump health shows last 5 non-noise ambient events (EFFECTIVE-022)
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Build binary if needed
BINARY="${CARGO_TARGET_DIR:-target}/debug/chump"
if [[ ! -x "$BINARY" ]]; then
  cargo build --quiet 2>&1
fi

# Create an isolated temp dir with a fake ambient.jsonl
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.chump-locks"
mkdir -p "$TMPDIR_TEST/.chump"
touch "$TMPDIR_TEST/.chump/state.db"

AMBIENT="$TMPDIR_TEST/.chump-locks/ambient.jsonl"

# Populate: 3 noise events + 4 signal events (only last 4 of signal shown, capped at 5)
cat > "$AMBIENT" <<'EOF'
{"ts":"2026-05-13T01:00:00Z","kind":"heartbeat","worker":"w1"}
{"ts":"2026-05-13T01:01:00Z","kind":"session_start","gap":"INFRA-001"}
{"ts":"2026-05-13T01:02:00Z","kind":"bash_call","cmd":"ls"}
{"ts":"2026-05-13T01:03:00Z","kind":"gap_claimed","gap":"INFRA-100","worker":"w2"}
{"ts":"2026-05-13T01:04:00Z","kind":"pr_stuck","pr":"42","phase":"merge","error":"conflict"}
{"ts":"2026-05-13T01:05:00Z","kind":"alert","slo":"waste_rate","detail":"exceeded","current":"35%"}
{"ts":"2026-05-13T01:06:00Z","kind":"session_end","outcome":"shipped","gap":"INFRA-100","elapsed_seconds":"120"}
EOF

# ── Test 1: text output contains "Recent activity" section ────────────────────
echo "Test 1: render_text includes Recent activity header"
OUT=$(CHUMP_REPO="$TMPDIR_TEST" "$BINARY" health 2>/dev/null || true)
if echo "$OUT" | grep -q "Recent activity"; then
  ok "Recent activity section present in text output"
else
  fail "Recent activity section missing from text output; got: $OUT"
fi

# ── Test 2: noise events excluded; signal events shown ────────────────────────
echo "Test 2: noise events (heartbeat/session_start/bash_call) excluded"
if echo "$OUT" | grep -q "heartbeat\|session_start\|bash_call"; then
  fail "Noise event leaked into Recent activity output"
else
  ok "Noise events correctly excluded"
fi

echo "Test 3: signal events shown with [ts] kind: summary format"
RECENT_SECTION=$(echo "$OUT" | sed -n '/Recent activity:/,/^  Generated:/p')
if echo "$RECENT_SECTION" | grep -q "gap_claimed\|pr_stuck\|alert\|session_end"; then
  ok "Signal event lines present in Recent activity section"
else
  fail "No signal events found in Recent activity section; section: $RECENT_SECTION"
fi

# ── Test 4: --json output includes ambient_recent array ───────────────────────
echo "Test 4: --json output includes ambient_recent array"
JSON=$(CHUMP_REPO="$TMPDIR_TEST" "$BINARY" health --json 2>/dev/null || true)
if echo "$JSON" | grep -q '"ambient_recent"'; then
  ok "ambient_recent key present in JSON output"
else
  fail "ambient_recent missing from JSON output; got: $JSON"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
