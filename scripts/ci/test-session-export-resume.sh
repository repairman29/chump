#!/usr/bin/env bash
# INFRA-616: CI test for `chump session-export` / `chump session-resume` round-trip.
# Covers: export writes ~/.chump/sessions/<session-id>.md, resume reads it back,
# and the Opus-orchestrator integration path (session-id from env var).
set -euo pipefail

CHUMP="${CHUMP_BIN:-chump}"
SESSION_ID="test-infra-616-$$"
export HOME
HOME="$(mktemp -d)"          # isolate ~/.chump writes for this test run
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export CHUMP_SESSION_ID="$SESSION_ID"

# Seed a minimal ambient.jsonl with one shipped and one abandoned event.
LOCKS="$REPO_ROOT/.chump-locks"
mkdir -p "$LOCKS"
AMBIENT="$LOCKS/ambient.jsonl"
TS="2026-05-06T10:00:00Z"
# shipped
printf '{"kind":"session_end","ts":"%s","session_id":"%s","gap_id":"INFRA-9901","outcome":"shipped","elapsed_seconds":420,"input_tokens":5000,"output_tokens":1000,"cache_read_tokens":2000}\n' \
  "$TS" "$SESSION_ID" >> "$AMBIENT"
# abandoned — must NOT appear in ships_landed
printf '{"kind":"session_end","ts":"%s","session_id":"%s","gap_id":"INFRA-9902","outcome":"abandoned","elapsed_seconds":60,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0}\n' \
  "$TS" "$SESSION_ID" >> "$AMBIENT"
# session_start for a gap filed this session
printf '{"kind":"session_start","ts":"%s","session_id":"%s","gap_id":"INFRA-9903"}\n' \
  "$TS" "$SESSION_ID" >> "$AMBIENT"
# notable finding
printf '{"kind":"notable_finding","ts":"%s","session_id":"%s","message":"cache hit rate below 40%%"}\n' \
  "$TS" "$SESSION_ID" >> "$AMBIENT"

# ── Test 1: session-export ────────────────────────────────────────────────────
echo "[INFRA-616] Test 1: session-export writes ~/.chump/sessions/<id>.md"
OUTPUT=$("$CHUMP" session-export --session-id "$SESSION_ID" 2>&1)
EXPORT_FILE="$HOME/.chump/sessions/${SESSION_ID}.md"

if [[ ! -f "$EXPORT_FILE" ]]; then
  echo "FAIL: export file not created at $EXPORT_FILE"
  echo "Output was: $OUTPUT"
  exit 1
fi
echo "  PASS: export file created"

# Verify ships landed section.
if ! grep -q "INFRA-9901" "$EXPORT_FILE"; then
  echo "FAIL: shipped gap INFRA-9901 not in export"
  cat "$EXPORT_FILE"
  exit 1
fi
echo "  PASS: shipped gap present"

# Verify abandoned gap NOT in ships_landed.
# The abandoned gap may appear in other sections (gaps filed) but must not be
# listed under ## Ships Landed.
SHIPS_SECTION=$(awk '/^## Ships Landed/,/^## /' "$EXPORT_FILE" | head -20)
if echo "$SHIPS_SECTION" | grep -q "INFRA-9902"; then
  echo "FAIL: abandoned gap INFRA-9902 incorrectly appears in Ships Landed"
  echo "$SHIPS_SECTION"
  exit 1
fi
echo "  PASS: abandoned gap absent from Ships Landed"

# Verify notable finding.
if ! grep -q "cache hit rate" "$EXPORT_FILE"; then
  echo "FAIL: notable finding not in export"
  cat "$EXPORT_FILE"
  exit 1
fi
echo "  PASS: notable finding present"

# Verify resume hint present.
if ! grep -q "chump session-resume $SESSION_ID" "$EXPORT_FILE"; then
  echo "FAIL: resume hint not in export"
  exit 1
fi
echo "  PASS: resume hint present"

# ── Test 2: session-resume round-trip ────────────────────────────────────────
echo "[INFRA-616] Test 2: session-resume reads back the export"
RESUMED=$("$CHUMP" session-resume "$SESSION_ID" 2>&1)
if ! echo "$RESUMED" | grep -q "INFRA-9901"; then
  echo "FAIL: resume did not return export content"
  echo "$RESUMED"
  exit 1
fi
echo "  PASS: session-resume round-trip succeeded"

# ── Test 3: env-var session-id (Opus-orchestrator integration path) ───────────
echo "[INFRA-616] Test 3: session-export reads session-id from CHUMP_SESSION_ID env"
ENV_SESSION_ID="opus-orch-test-$$"
export CHUMP_SESSION_ID="$ENV_SESSION_ID"
# Export without explicit --session-id flag.
"$CHUMP" session-export >/dev/null 2>&1 || true
ENV_FILE="$HOME/.chump/sessions/${ENV_SESSION_ID}.md"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: env-var export file not created at $ENV_FILE"
  exit 1
fi
if ! grep -q "$ENV_SESSION_ID" "$ENV_FILE"; then
  echo "FAIL: env-var session-id not in export file"
  cat "$ENV_FILE"
  exit 1
fi
echo "  PASS: env-var session-id path works"

# ── Test 4: session-resume unknown session exits non-zero ─────────────────────
echo "[INFRA-616] Test 4: session-resume unknown session exits non-zero"
if "$CHUMP" session-resume "does-not-exist-$$" >/dev/null 2>&1; then
  echo "FAIL: expected non-zero exit for missing session"
  exit 1
fi
echo "  PASS: missing session exits non-zero"

echo ""
echo "[INFRA-616] All tests passed."
