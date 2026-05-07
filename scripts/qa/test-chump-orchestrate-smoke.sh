#!/usr/bin/env bash
# Smoke-test for chump orchestrate (INFRA-598).
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

# --- Structural checks (AC-a through AC-d) ---

# AC-a: src/orchestrate.rs exists and loads CLAUDE.md doctrine
[[ -f "$SRC" ]] || fail "src/orchestrate.rs not found"
pass "src/orchestrate.rs exists"

grep -q "CLAUDE\.md\|load_doctrine" "$SRC" \
  || fail "orchestrate.rs does not load CLAUDE.md doctrine (AC-a)"
pass "AC-a: CLAUDE.md doctrine loading present"

# AC-b: uses build_provider() with FLEET_MODEL=opus default
grep -q "build_provider" "$SRC" \
  || fail "orchestrate.rs does not call build_provider() (AC-b)"
grep -q "FLEET_MODEL\|resolve_model\|opus" "$SRC" \
  || fail "orchestrate.rs does not reference FLEET_MODEL/opus default (AC-b)"
pass "AC-b: build_provider() + FLEET_MODEL=opus default present"

# AC-c: tool-router dispatches to chump fleet/gap subcommands
grep -q "TOOL:\|parse_tool_calls\|run_tool" "$SRC" \
  || fail "orchestrate.rs does not implement tool routing (AC-c)"
grep -q "fleet\|gap" "$SRC" \
  || fail "orchestrate.rs does not reference fleet/gap subcommands (AC-c)"
pass "AC-c: tool router for fleet/gap subcommands present"

# AC-d: emits 4-pillar grade each iter
grep -q "mission_grade\|emit_grade" "$SRC" \
  || fail "orchestrate.rs does not emit 4-pillar grade (AC-d)"
pass "AC-d: 4-pillar grade emission present"

# main.rs wires the subcommand
grep -q '"orchestrate"' "$MAIN" \
  || fail "main.rs does not dispatch 'orchestrate' subcommand"
pass "main.rs wires 'chump orchestrate' subcommand"

# --- Live smoke test (AC-e) ---

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

# 3 fixture intents + exit, piped to chump orchestrate in stub mode.
FIXTURE="spawn fleet on infra p0
what's our mission grade?
stop the fleet
exit"

OUTPUT=$(printf '%s\n' "$FIXTURE" | \
  CHUMP_ORCHESTRATE_STUB=1 "$CHUMP_BIN" orchestrate 2>&1) \
  || fail "chump orchestrate exited non-zero"

# Intent 1: spawn → fleet status
echo "$OUTPUT" | grep -q "TOOL: chump fleet" \
  || fail "spawn intent did not produce a fleet TOOL line"
pass "intent 1 (spawn) → fleet TOOL"

# Intent 2: grade → mission-grade
echo "$OUTPUT" | grep -q "TOOL: chump mission-grade" \
  || fail "grade intent did not produce mission-grade TOOL line"
pass "intent 2 (grade) → mission-grade TOOL"

# Intent 3: stop → fleet stop
echo "$OUTPUT" | grep -q "TOOL: chump fleet stop" \
  || fail "stop intent did not produce fleet stop TOOL line"
pass "intent 3 (stop) → fleet stop TOOL"

# Grade is emitted each iter
echo "$OUTPUT" | grep -q "\[grade\]" \
  || fail "4-pillar grade not emitted during session"
pass "4-pillar grade emitted each iter"

echo "=== all checks passed ==="
