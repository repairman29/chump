#!/usr/bin/env bash
# test-drift-flag-triage.sh — CREDIBLE-222
#
# Validates drift-flag-triage.py against the exact NOISE/REAL examples cited
# in the gap's own acceptance criteria: the noise-collapse rules (extended
# unset sentinels, mock placeholders, $VAR-path shape, dominance threshold)
# must classify each cited example the way the gap says it should.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SCRIPT="scripts/dev/drift-flag-triage.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

FIXTURE="$WORK/findings.json"
cat > "$FIXTURE" <<'JSON'
[
  {"kind": "drift", "context": {"flag": "ANTHROPIC_API_KEY", "reads": 78,
    "defaults": ["", "<unset>", "sk-ant-mock-key-for-tests"]}},
  {"kind": "drift", "context": {"flag": "CARGO_MANIFEST_DIR", "reads": 6,
    "defaults": ["", "unknown"]}},
  {"kind": "drift", "context": {"flag": "CHUMP_AMBIENT_LOG", "reads": 307,
    "defaults": ["", "$CB_REPO_ROOT/.chump-locks/ambient.jsonl",
      "$FLEET_LOCKS_DIR/.chump-locks/ambient.jsonl",
      "$MAIN_REPO/.chump-locks/ambient.jsonl",
      "$REPO/.chump-locks/ambient.jsonl",
      "$REPO_ROOT/.chump-locks/ambient.jsonl",
      "$ROOT/.chump-locks/ambient.jsonl",
      "$STATE_DIR/.chump-locks/ambient.jsonl",
      "$WORK/ambient.jsonl", "$LOCK_DIR/ambient.jsonl",
      ".chump-locks/ambient.jsonl", "/dev/null", "<dynamic>"]}},
  {"kind": "drift", "context": {"flag": "CARGO_TARGET_DIR", "reads": 171,
    "defaults": ["", "$REPO_ROOT/target", "$ROOT/target", "$repo_root/target",
      "./target", "<dynamic>", "<unset>", "MISSING", "target"]}},
  {"kind": "drift", "context": {"flag": "BEAST_MODE_API", "reads": 270,
    "defaults": ["http://localhost:3000", "https://beast-mode.com"]}},
  {"kind": "drift", "context": {"flag": "BEAST_MODE_API_URL", "reads": 40,
    "defaults": ["https://beast-mode.dev", "https://beastmode.dev",
      "https://beast-mode.com", "http://localhost:3000", "<dynamic>"]}},
  {"kind": "drift", "context": {"flag": "BASE_URL", "reads": 12,
    "defaults": ["3000", "7777"]}},
  {"kind": "drift", "context": {"flag": "BEAST_MODE_CLOUD_MODEL", "reads": 8,
    "defaults": ["llama-3.3-70b", "gpt-4o-mini"]}},
  {"kind": "drift", "context": {"flag": "CHUMPBAR_SSH_TIMEOUT", "reads": 3,
    "defaults": ["15", "6"]}},
  {"kind": "bypass", "context": {"flag": "NOT_A_DRIFT_FINDING", "reads": 1, "defaults": ["a", "b"]}}
]
JSON

OUT="$(python3 "$SCRIPT" --in "$FIXTURE" --json)"

expect_noise() {
    local flag="$1"
    echo "$OUT" | python3 -c "
import json,sys
rows = json.load(sys.stdin)['rows']
row = next(r for r in rows if r['flag'] == '$flag')
assert row['verdict'] == 'NOISE', row
" && pass "$flag classified NOISE" || fail "$flag expected NOISE"
}

expect_real() {
    local flag="$1"
    echo "$OUT" | python3 -c "
import json,sys
rows = json.load(sys.stdin)['rows']
row = next(r for r in rows if r['flag'] == '$flag')
assert row['verdict'] == 'REAL', row
" && pass "$flag classified REAL" || fail "$flag expected REAL"
}

# --- NOISE examples from the gap's acceptance criteria ---
expect_noise "ANTHROPIC_API_KEY"
expect_noise "CARGO_MANIFEST_DIR"
expect_noise "CHUMP_AMBIENT_LOG"
expect_noise "CARGO_TARGET_DIR"

# --- REAL examples that must survive triage ---
expect_real "BEAST_MODE_API"
expect_real "BEAST_MODE_API_URL"
expect_real "BASE_URL"
expect_real "BEAST_MODE_CLOUD_MODEL"
expect_real "CHUMPBAR_SSH_TIMEOUT"

# --- only "drift"-kind findings are triaged ---
echo "$OUT" | python3 -c "
import json,sys
rows = json.load(sys.stdin)['rows']
assert not any(r['flag'] == 'NOT_A_DRIFT_FINDING' for r in rows)
assert len(rows) == 9
" && pass "non-drift findings excluded, 9 drift rows triaged" \
    || fail "expected exactly 9 drift-kind rows, non-drift findings excluded"

echo "ALL PASS: test-drift-flag-triage.sh"
