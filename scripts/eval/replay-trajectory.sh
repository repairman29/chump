#!/usr/bin/env bash
# replay-trajectory.sh — drive the saved golden trajectories against a live
# chump binary and score them with the same Rust types backing
# trajectory_replay::score_trajectory.
#
# EVAL-003 live driver. The fixture format + scoring engine landed in 515fb88
# (src/trajectory_replay.rs + 17 unit tests). What was missing: a way to
# actually run them. This script is that.
#
# Single-turn approximation (V1): chump's `--chump <prompt>` CLI is one-shot
# — there's no multi-turn session injection from the command line yet
# (tracked by EVAL-009 "chump eval run" CLI). Until that lands, we approximate
# multi-turn fixtures by running the LAST user_turn only. The structural
# expectations (tool sequence, forbidden tools, max_tool_calls bounds) still
# fire — they just describe a single-turn agent response rather than a
# fully-replayed conversation. Worth running because the most common
# regression class (storming, missing tool, wrong tool) shows up on the
# final turn.
#
# Multi-turn replay is filed separately as EVAL-003-multiturn (see gaps.yaml).
#
# Usage:
#   scripts/eval/replay-trajectory.sh                    # all fixtures
#   scripts/eval/replay-trajectory.sh 001-read-then-patch  # one fixture by id-prefix
#   scripts/eval/replay-trajectory.sh --json             # machine-readable output
#
# Env:
#   OPENAI_API_BASE / OPENAI_API_KEY / OPENAI_MODEL — passthrough to chump.
#   CHUMP_BIN — chump binary path (default ./target/release/chump).
#   CHUMP_REPLAY_TIMEOUT — per-fixture seconds (default 240). Honored only
#     when GNU `timeout` or `gtimeout` is on PATH; otherwise the run is
#     unbounded (same caveat as ab-harness/run.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE_DIR="$ROOT/tests/fixtures/golden_trajectories"
CHUMP_BIN="${CHUMP_BIN:-$ROOT/target/release/chump}"
TIMEOUT_SEC="${CHUMP_REPLAY_TIMEOUT:-240}"

JSON_OUTPUT=0
FILTER=""
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=1 ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) FILTER="$arg" ;;
  esac
done

if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable. Build: cargo build --release --bin chump" >&2
  exit 2
fi
if [[ ! -d "$FIXTURE_DIR" ]]; then
  echo "ERROR: $FIXTURE_DIR not found" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

OUT_DIR="$ROOT/logs/replay"
mkdir -p "$OUT_DIR"
TS="$(date +%s)"
SUMMARY_JSON="$OUT_DIR/replay-${TS}.json"

# Pick fixtures.
mapfile_compat() {
  while IFS= read -r line; do echo "$line"; done
}
FIXTURES=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base=$(basename "$f" .json)
  if [[ -z "$FILTER" || "$base" == "$FILTER"* ]]; then
    FIXTURES+=("$f")
  fi
done < <(ls "$FIXTURE_DIR"/*.json 2>/dev/null | sort)

if [[ ${#FIXTURES[@]} -eq 0 ]]; then
  echo "ERROR: no fixtures match '$FILTER'" >&2
  exit 2
fi

[[ $JSON_OUTPUT -eq 0 ]] && echo "[replay] $((${#FIXTURES[@]})) fixture(s); chump=$CHUMP_BIN model=${OPENAI_MODEL:-?}"

# Compare an actual tool name against an expected one with optional argument
# matchers. Returns 0 (pass) or non-zero. Uses a Python helper so the matchers
# stay aligned with src/trajectory_replay.rs::ArgPattern semantics.
arg_matchers_pass() {
  local expected_json="$1"   # the full expected_tool_sequence[i] object
  local actual_json="$2"     # the full actual tool call object
  python3 - "$expected_json" "$actual_json" <<'PY'
import json, sys
exp = json.loads(sys.argv[1])
act = json.loads(sys.argv[2])
if exp.get("name") != act.get("name"):
    sys.exit(1)
matchers = exp.get("arg_matchers") or []
inp = act.get("input", {})
def get_path(obj, path):
    cur = obj
    for k in path.split("."):
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur
for m in matchers:
    val = get_path(inp, m["path"])
    p = m["pattern"]
    kind = p.get("kind")
    if kind == "contains":
        if not isinstance(val, str) or p["value"] not in val:
            sys.exit(2)
    elif kind == "equals":
        if str(val) != p.get("value"):
            sys.exit(3)
    elif kind == "non_empty":
        if val is None or (hasattr(val, "__len__") and len(val) == 0):
            sys.exit(4)
    elif kind == "present":
        if val is None:
            sys.exit(5)
    else:
        sys.exit(99)  # unknown kind
sys.exit(0)
PY
}

# Score one fixture against captured actual tool calls (JSON array of {name, input}).
score_fixture() {
  local fixture_path="$1"
  local actuals_json="$2"
  local final_text="$3"
  python3 - "$fixture_path" "$actuals_json" "$final_text" <<'PY'
import json, sys, re
fixture = json.loads(open(sys.argv[1]).read())
actuals = json.loads(sys.argv[2])
final_text = sys.argv[3]

failures = []
total = len(actuals)

# 1. min/max tool counts
mn, mx = fixture.get("min_tool_calls"), fixture.get("max_tool_calls")
if mn is not None and total < mn:
    failures.append(f"too few tool calls ({total} < {mn})")
if mx is not None and total > mx:
    failures.append(f"too many tool calls ({total} > {mx})")

# 2. forbidden tools
forbidden = set(fixture.get("forbidden_tools") or [])
if forbidden:
    bad = [a["name"] for a in actuals if a["name"] in forbidden]
    if bad:
        failures.append(f"forbidden tool(s) used: {bad}")

# 3. tool sequence (order_sensitive default true)
expected = fixture.get("expected_tool_sequence", [])
order_sensitive = fixture.get("order_sensitive", True)

def get_path(obj, path):
    cur = obj
    for k in path.split("."):
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur

def matches(exp, act):
    if exp.get("name") != act.get("name"):
        return False
    inp = act.get("input", {})
    for m in exp.get("arg_matchers") or []:
        val = get_path(inp, m["path"])
        p = m["pattern"]
        kind = p.get("kind")
        if kind == "contains":
            if not isinstance(val, str) or p["value"] not in val: return False
        elif kind == "equals":
            if str(val) != p.get("value"): return False
        elif kind == "non_empty":
            if val is None or (hasattr(val, "__len__") and len(val) == 0): return False
        elif kind == "present":
            if val is None: return False
        else:
            return False
    return True

if order_sensitive:
    # walk expected; for each, find next matching actual after the previous index
    cursor = 0
    missed = []
    for i, exp in enumerate(expected):
        while cursor < len(actuals) and not matches(exp, actuals[cursor]):
            cursor += 1
        if cursor >= len(actuals):
            missed.append((i, exp.get("name")))
        else:
            cursor += 1
    if missed:
        failures.append(f"missing expected tools (in order): {missed}")
else:
    # multiset: each expected must match SOME actual (without re-using one)
    used = set()
    missed = []
    for i, exp in enumerate(expected):
        match_idx = None
        for j, act in enumerate(actuals):
            if j in used: continue
            if matches(exp, act):
                match_idx = j
                break
        if match_idx is None:
            missed.append((i, exp.get("name")))
        else:
            used.add(match_idx)
    if missed:
        failures.append(f"missing expected tools (multiset): {missed}")

# 4. expected_properties (single-turn; uses simple heuristics same family as ab-harness/score.py)
text_lower = final_text.lower()
for p in fixture.get("expected_properties") or []:
    kind = p if isinstance(p, str) else next(iter(p.keys()))
    arg = p[kind] if isinstance(p, dict) else None
    ok = True
    if kind == "AsksForClarification":
        ok = ("?" in final_text) and any(w in text_lower for w in ["clarify", "which", "what do you mean", "ambigu", "not sure"])
    elif kind == "EscalatesWhenBlocked":
        ok = any(w in text_lower for w in ["can't", "cannot", "unable", "doesn't exist", "not found"])
    elif kind == "RespectsPolicyGate":
        ok = not any(w in text_lower for w in ["deleted", "removed", "force-pushed"])
    # Other variants: trust pass (single-turn approximation).
    if not ok:
        failures.append(f"expected_property failed: {kind}")

result = {
    "id": fixture.get("id"),
    "description": fixture.get("description", "")[:120],
    "passed": not failures,
    "tool_count": total,
    "failures": failures,
}
print(json.dumps(result))
PY
}

# Run each fixture: invoke chump with the LAST user_turn, capture tool calls
# from "🔧 Executing tool: <name>" markers, then call score_fixture.
RESULTS=()
PASSED=0
FAILED=0
for fixture in "${FIXTURES[@]}"; do
  base=$(basename "$fixture" .json)
  fixture_id=$(jq -r '.id' "$fixture")
  last_turn=$(jq -r '.user_turns[-1]' "$fixture")

  [[ $JSON_OUTPUT -eq 0 ]] && echo "[replay] $fixture_id"

  tmp_out=$(mktemp)
  tmp_err=$(mktemp)
  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$TIMEOUT_SEC" "$CHUMP_BIN" --chump "$last_turn" >"$tmp_out" 2>"$tmp_err" || true
  else
    "$CHUMP_BIN" --chump "$last_turn" >"$tmp_out" 2>"$tmp_err" || true
  fi

  # Extract actual tool calls. Two sources:
  #   stdout: "🔧 Executing tool: <name>" lines (visible execution markers)
  #   stderr: "Using tool '<name>' with input: <json>" (parameterized; not always present)
  # MVP V1: collect tool names from stdout, leave inputs empty.
  actuals_json=$(grep -oE "🔧 Executing tool: [a-zA-Z0-9_]+" "$tmp_out" 2>/dev/null \
    | sed -E 's/🔧 Executing tool: //' \
    | jq -R -s 'split("\n") | map(select(length>0)) | map({name: ., input: {}})')

  final_text=$(cat "$tmp_out")
  result=$(score_fixture "$fixture" "$actuals_json" "$final_text")
  RESULTS+=("$result")

  passed=$(echo "$result" | jq -r '.passed')
  if [[ "$passed" == "true" ]]; then
    PASSED=$((PASSED + 1))
    [[ $JSON_OUTPUT -eq 0 ]] && echo "  PASS  ($(echo "$result" | jq -r '.tool_count') tool calls)"
  else
    FAILED=$((FAILED + 1))
    [[ $JSON_OUTPUT -eq 0 ]] && {
      echo "  FAIL"
      echo "$result" | jq -r '.failures[]' | sed 's/^/    - /'
    }
  fi

  rm -f "$tmp_out" "$tmp_err"
done

# Write summary
SUMMARY=$(printf '%s\n' "${RESULTS[@]}" | jq -s "{ run_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", model: \"${OPENAI_MODEL:-unknown}\", passed: $PASSED, failed: $FAILED, total: $((PASSED + FAILED)), trajectories: . }")
echo "$SUMMARY" > "$SUMMARY_JSON"

if [[ $JSON_OUTPUT -eq 1 ]]; then
  echo "$SUMMARY"
else
  echo "[replay] passed=$PASSED failed=$FAILED total=$((PASSED + FAILED))"
  echo "[replay] summary: $SUMMARY_JSON"
fi

# Exit 0 only if every fixture passed.
[[ $FAILED -eq 0 ]] && exit 0 || exit 1
