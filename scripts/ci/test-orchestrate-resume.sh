#!/usr/bin/env bash
# test-orchestrate-resume.sh — CI gate for INFRA-1366
#
# Verifies chump orchestrate --resume <session-id>:
#   1. Emits orchestrate_session_resumed when session is not clean-exited
#   2. events_replayed matches the number of seeded events
#   3. resume_attempts increments correctly on repeated calls
#   4. Refuses (exit non-zero) on the (max_resumes + 1)th attempt
#   5. Refuses (exit non-zero) when exit_reason=clean
#
# All checks: 13 total

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

# ── Locate chump binary ────────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  _meta="$(cd "$REPO_ROOT" && cargo metadata --no-deps --format-version 1 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' \
      2>/dev/null || echo "")"
  if [[ -n "$_meta" && -x "$_meta/debug/chump" ]]; then
    CHUMP_BIN="$_meta/debug/chump"
  fi
fi
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
  echo "[SKIP] chump binary not found — skipping test-orchestrate-resume.sh"
  exit 0
fi

# ── Setup ──────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
AMBIENT="$TMPDIR_TEST/ambient.jsonl"
SESSION_ID="test-resume-session-$$"

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# Seed 5 ambient events for SESSION_ID:
# 3 orchestrate_intent events + 1 orchestrate_session_summary (exit_reason=timeout)
# + 1 extra orchestrate_intent after summary (to confirm last_intent detection)
seed_events() {
  local reason="${1:-timeout}"
  : > "$AMBIENT"
  for i in 1 2 3; do
    printf '{"ts":"2026-05-15T10:0%d:00Z","kind":"orchestrate_intent","session_id":"%s","intent":"intent number %d","status":"success"}\n' \
      "$i" "$SESSION_ID" "$i" >> "$AMBIENT"
  done
  # session_summary with desired exit_reason
  printf '{"ts":"2026-05-15T10:04:00Z","kind":"orchestrate_session_summary","session_id":"%s","exit_reason":"%s","intents_routed":3}\n' \
    "$SESSION_ID" "$reason" >> "$AMBIENT"
  # one more intent after summary (represents the last unanswered intent)
  printf '{"ts":"2026-05-15T10:05:00Z","kind":"orchestrate_intent","session_id":"%s","intent":"final intent before crash","status":"failure"}\n' \
    "$SESSION_ID" >> "$AMBIENT"
}

# ── Test 1: basic resume on a crashed session ──────────────────────────────────
seed_events "timeout"
RESUME_OUT="$(echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  CHUMP_ORCHESTRATE_MAX_RESUMES=3 \
  "$CHUMP_BIN" orchestrate --resume "$SESSION_ID" 2>&1 || true)"

# AC-4: orchestrate_session_resumed event emitted
RESUMED_COUNT="$(grep "orchestrate_session_resumed" "$AMBIENT" | wc -l | tr -d ' ')"
if [[ "$RESUMED_COUNT" -ge 1 ]]; then
  ok "orchestrate_session_resumed event emitted"
else
  fail "orchestrate_session_resumed event NOT found in ambient"
fi

# AC-4: events_replayed = 5 (3 intent + 1 summary + 1 intent)
EVENTS_REPLAYED="$(grep "orchestrate_session_resumed" "$AMBIENT" | head -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["events_replayed"])' 2>/dev/null || echo "")"
if [[ "$EVENTS_REPLAYED" == "5" ]]; then
  ok "events_replayed=5 matches 5 seeded events"
else
  fail "events_replayed expected 5, got '$EVENTS_REPLAYED'"
fi

# AC-4: resume_attempts=1 on first call
RESUME_ATTEMPTS="$(grep "orchestrate_session_resumed" "$AMBIENT" | head -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["resume_attempts"])' 2>/dev/null || echo "")"
if [[ "$RESUME_ATTEMPTS" == "1" ]]; then
  ok "resume_attempts=1 on first resume"
else
  fail "resume_attempts expected 1, got '$RESUME_ATTEMPTS'"
fi

# AC-4: session_id matches
RESUMED_SESSION="$(grep "orchestrate_session_resumed" "$AMBIENT" | head -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["session_id"])' 2>/dev/null || echo "")"
if [[ "$RESUMED_SESSION" == "$SESSION_ID" ]]; then
  ok "session_id matches in resumed event"
else
  fail "session_id expected '$SESSION_ID', got '$RESUMED_SESSION'"
fi

# AC-3: output mentions the last intent
if echo "$RESUME_OUT" | grep -q "final intent before crash"; then
  ok "last intent echoed back to operator"
else
  fail "last intent not echoed in output: $RESUME_OUT"
fi

# ── Test 2: resume_attempts increments on 2nd call ────────────────────────────
echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  CHUMP_ORCHESTRATE_MAX_RESUMES=3 \
  "$CHUMP_BIN" orchestrate --resume "$SESSION_ID" >/dev/null 2>&1 || true

SECOND_RESUMED="$(grep "orchestrate_session_resumed" "$AMBIENT" | tail -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["resume_attempts"])' 2>/dev/null || echo "")"
if [[ "$SECOND_RESUMED" == "2" ]]; then
  ok "resume_attempts=2 on second resume"
else
  fail "resume_attempts expected 2 on second call, got '$SECOND_RESUMED'"
fi

# ── Test 3: 3rd call (still within limit of 3) ────────────────────────────────
echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  CHUMP_ORCHESTRATE_MAX_RESUMES=3 \
  "$CHUMP_BIN" orchestrate --resume "$SESSION_ID" >/dev/null 2>&1 || true

THIRD_RESUMED="$(grep "orchestrate_session_resumed" "$AMBIENT" | tail -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["resume_attempts"])' 2>/dev/null || echo "")"
if [[ "$THIRD_RESUMED" == "3" ]]; then
  ok "resume_attempts=3 on third resume (at limit)"
else
  fail "resume_attempts expected 3 on third call, got '$THIRD_RESUMED'"
fi

# ── Test 4: 4th call is refused (exit non-zero) ───────────────────────────────
REFUSED_EXIT=0
echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  CHUMP_ORCHESTRATE_MAX_RESUMES=3 \
  "$CHUMP_BIN" orchestrate --resume "$SESSION_ID" >/dev/null 2>&1 || REFUSED_EXIT=$?

if [[ "$REFUSED_EXIT" -ne 0 ]]; then
  ok "4th resume refused with non-zero exit (limit enforced)"
else
  fail "4th resume should have exited non-zero (limit 3 exceeded)"
fi

# No new resumed event should have been emitted for the 4th call
FINAL_COUNT="$(grep "orchestrate_session_resumed" "$AMBIENT" | wc -l | tr -d ' ')"
if [[ "$FINAL_COUNT" -eq 3 ]]; then
  ok "no 4th orchestrate_session_resumed event emitted (refused before emit)"
else
  fail "expected 3 resumed events total, got $FINAL_COUNT"
fi

# ── Test 5: refuse when exit_reason=clean ─────────────────────────────────────
CLEAN_AMBIENT="$TMPDIR_TEST/ambient_clean.jsonl"
CLEAN_SESSION="clean-session-$$"
printf '{"ts":"2026-05-15T11:00:00Z","kind":"orchestrate_intent","session_id":"%s","intent":"list gaps","status":"success"}\n' \
  "$CLEAN_SESSION" > "$CLEAN_AMBIENT"
printf '{"ts":"2026-05-15T11:01:00Z","kind":"orchestrate_session_summary","session_id":"%s","exit_reason":"clean","intents_routed":1}\n' \
  "$CLEAN_SESSION" >> "$CLEAN_AMBIENT"

CLEAN_EXIT=0
CLEAN_STDERR="$(echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$CLEAN_AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  "$CHUMP_BIN" orchestrate --resume "$CLEAN_SESSION" 2>&1 >/dev/null || CLEAN_EXIT=$?; echo "$CLEAN_EXIT")"

# Rerun properly since the subshell above doesn't capture exit cleanly
CLEAN_EXIT=0
echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$CLEAN_AMBIENT" \
  CHUMP_ORCHESTRATE_STUB=1 \
  "$CHUMP_BIN" orchestrate --resume "$CLEAN_SESSION" >/dev/null 2>&1 || CLEAN_EXIT=$?

if [[ "$CLEAN_EXIT" -ne 0 ]]; then
  ok "clean-exited session refused with non-zero exit"
else
  fail "clean session should have exited non-zero but exited 0"
fi

# ── Test 6: prior_exit_reason field set correctly ─────────────────────────────
seed_events "user_quit"
NEW_SESSION="test-userquit-$$"
# Rewrite ambient with a user_quit session
: > "$TMPDIR_TEST/ambient_uq.jsonl"
printf '{"ts":"2026-05-15T12:00:00Z","kind":"orchestrate_session_summary","session_id":"%s","exit_reason":"user_quit"}\n' \
  "$NEW_SESSION" > "$TMPDIR_TEST/ambient_uq.jsonl"

echo 'exit' | \
  CHUMP_AMBIENT_IN_PROMPT="$TMPDIR_TEST/ambient_uq.jsonl" \
  CHUMP_ORCHESTRATE_STUB=1 \
  CHUMP_ORCHESTRATE_MAX_RESUMES=3 \
  "$CHUMP_BIN" orchestrate --resume "$NEW_SESSION" >/dev/null 2>&1 || true

PRIOR_REASON="$(grep "orchestrate_session_resumed" "$TMPDIR_TEST/ambient_uq.jsonl" | head -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["prior_exit_reason"])' 2>/dev/null || echo "")"
if [[ "$PRIOR_REASON" == "user_quit" ]]; then
  ok "prior_exit_reason=user_quit recorded correctly"
else
  fail "prior_exit_reason expected user_quit, got '$PRIOR_REASON'"
fi

# ── Missing session-id argument error ─────────────────────────────────────────
MISSING_EXIT=0
"$CHUMP_BIN" orchestrate --resume >/dev/null 2>&1 || MISSING_EXIT=$?
if [[ "$MISSING_EXIT" -ne 0 ]]; then
  ok "missing session-id arg exits non-zero"
else
  fail "missing session-id arg should exit non-zero"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All checks passed."
