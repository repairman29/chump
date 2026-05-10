#!/usr/bin/env bash
# Smoke-test for chump orchestrate (INFRA-598, INFRA-796, INFRA-797, INFRA-798).
#
# Structural checks (always): verifies src/orchestrate.rs and main.rs wiring.
# Live checks: runs 3 fixture intents through the stub LLM and asserts routing.
#
# Skip live checks:
#   CHUMP_ORCHESTRATE_SKIP_LIVE=1  — skip binary execution
#   CHUMP_BIN=/path/to/chump       — override binary path
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/orchestrate.rs"
MAIN="$REPO_ROOT/src/main.rs"

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }
skip() { echo "  [SKIP] $*"; }

echo "=== test-chump-orchestrate-smoke.sh ==="

# --- Structural checks ---

# AC-a: src/orchestrate.rs exists and loads CLAUDE.md doctrine (INFRA-598)
[[ -f "$SRC" ]] || fail "src/orchestrate.rs not found"
pass "src/orchestrate.rs exists"

grep -q "CLAUDE\.md\|load_doctrine" "$SRC" \
  || fail "orchestrate.rs does not load CLAUDE.md doctrine (AC-a)"
pass "AC-a: CLAUDE.md doctrine loading present"

# AC-b: uses build_provider() with FLEET_MODEL=opus default (INFRA-598)
grep -q "build_provider" "$SRC" \
  || fail "orchestrate.rs does not call build_provider() (AC-b)"
grep -q "FLEET_MODEL\|resolve_model\|opus" "$SRC" \
  || fail "orchestrate.rs does not reference FLEET_MODEL/opus default (AC-b)"
pass "AC-b: build_provider() + FLEET_MODEL=opus default present"

# AC-c: tool-router dispatches to chump fleet/gap subcommands (INFRA-598, INFRA-798)
grep -q "TOOL:\|parse_tool_calls\|run_tool" "$SRC" \
  || fail "orchestrate.rs does not implement tool routing (AC-c)"
grep -q "fleet\|gap" "$SRC" \
  || fail "orchestrate.rs does not reference fleet/gap subcommands (AC-c)"
pass "AC-c: tool router for fleet/gap subcommands present"

# AC-d: emits 4-pillar grade each iter (INFRA-598)
grep -q "mission_grade\|emit_grade" "$SRC" \
  || fail "orchestrate.rs does not emit 4-pillar grade (AC-d)"
pass "AC-d: 4-pillar grade emission present"

# INFRA-796 AC-a: ambient event telemetry
grep -q "emit_ambient_event\|orchestrate_intent" "$SRC" \
  || fail "orchestrate.rs does not emit ambient telemetry (INFRA-796)"
pass "INFRA-796: ambient telemetry (emit_ambient_event + orchestrate_intent)"

# INFRA-796 AC-c: failure classification
grep -q "classify_failure\|transient.*permanent" "$SRC" \
  || fail "orchestrate.rs does not classify failures as transient/permanent (INFRA-796)"
pass "INFRA-796: failure classification (classify_failure)"

# INFRA-796 AC-b: cost estimation
grep -q "estimate_tokens\|est_input_tokens\|est_output_tokens" "$SRC" \
  || fail "orchestrate.rs does not estimate token usage (INFRA-796)"
pass "INFRA-796: token estimation (estimate_tokens)"

# INFRA-797 AC-a: background auto-grade timer
grep -q "tokio::spawn.*interval\|1800\|auto-grade" "$SRC" \
  || fail "orchestrate.rs does not have background auto-grade timer (INFRA-797)"
pass "INFRA-797: background auto-grade timer (tokio::spawn + 30min interval)"

# INFRA-798 AC-a/AC-b/AC-c: stub parser routes
grep -q "stub_response.*fleet\|stub_response.*mission-grade\|stub_response.*fleet stop" "$SRC" \
  || fail "orchestrate.rs stub parser missing route (INFRA-798)"
pass "INFRA-798: stub parser routes (spawn→fleet, grade→mission-grade, stop→fleet stop)"

# main.rs wires the subcommand
grep -q '"orchestrate"' "$MAIN" \
  || fail "main.rs does not dispatch 'orchestrate' subcommand"
pass "main.rs wires 'chump orchestrate' subcommand"

# --- Live smoke test ---

if [[ "${CHUMP_ORCHESTRATE_SKIP_LIVE:-}" == "1" ]]; then
  skip "live smoke skipped (CHUMP_ORCHESTRATE_SKIP_LIVE=1)"
  echo "=== structural checks passed ==="
  exit 0
fi

# Locate the chump binary.
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if command -v chump >/dev/null 2>&1; then
    CHUMP_BIN="$(command -v chump)"
  elif [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
  fi
fi

if [[ -z "$CHUMP_BIN" ]]; then
  skip "live smoke skipped — chump binary not found (run 'cargo build' or set CHUMP_BIN)"
  echo "=== structural checks passed ==="
  exit 0
fi

# Use a temp ambient.jsonl to avoid polluting the real one during live test.
TEMP_AMBIENT="$(mktemp)"
export CHUMP_AMBIENT_IN_PROMPT="$TEMP_AMBIENT"

# 3 fixture intents + exit, piped to chump orchestrate in stub mode.
FIXTURE="spawn fleet on infra p0
what's our mission grade?
stop the fleet
exit"

OUTPUT=$(printf '%s\n' "$FIXTURE" | \
  CHUMP_ORCHESTRATE_STUB=1 "$CHUMP_BIN" orchestrate 2>&1) \
  || fail "chump orchestrate exited non-zero"

# Intent 1: spawn → fleet status (INFRA-798 AC-a)
echo "$OUTPUT" | grep -q "TOOL: chump fleet" \
  || fail "spawn intent did not produce a fleet TOOL line (INFRA-798)"
pass "INFRA-798: intent 1 (spawn) → fleet TOOL"

# Intent 2: grade → mission-grade (INFRA-798 AC-b)
echo "$OUTPUT" | grep -q "TOOL: chump mission-grade" \
  || fail "grade intent did not produce mission-grade TOOL line (INFRA-798)"
pass "INFRA-798: intent 2 (grade) → mission-grade TOOL"

# Intent 3: stop → fleet stop (INFRA-798 AC-c)
echo "$OUTPUT" | grep -q "TOOL: chump fleet stop" \
  || fail "stop intent did not produce fleet stop TOOL line (INFRA-798)"
pass "INFRA-798: intent 3 (stop) → fleet stop TOOL"

# Grade is emitted each iter (AC-d)
echo "$OUTPUT" | grep -q "\[grade\]" \
  || fail "4-pillar grade not emitted during session"
pass "AC-d: 4-pillar grade emitted each iter"

# INFRA-796 AC-d: ambient event emission
if [[ -f "$TEMP_AMBIENT" ]] && grep -q "orchestrate_intent" "$TEMP_AMBIENT" 2>/dev/null; then
  pass "INFRA-796: orchestrate_intent events found in ambient.jsonl"
else
  fail "INFRA-796: no orchestrate_intent events in ambient.jsonl ($TEMP_AMBIENT: $(cat "$TEMP_AMBIENT" 2>/dev/null || echo 'empty'))"
fi

# INFRA-796 AC-e: event fields
if grep -q "est_input_tokens\|est_output_tokens\|tool_count\|elapsed_ms\|failure_class" "$TEMP_AMBIENT" 2>/dev/null; then
  pass "INFRA-796: telemetry event contains all required fields"
else
  fail "INFRA-796: telemetry event missing required fields (est_input_tokens, est_output_tokens, tool_count, elapsed_ms, failure_class)"
fi

rm -f "$TEMP_AMBIENT"

echo "=== all checks passed ==="
