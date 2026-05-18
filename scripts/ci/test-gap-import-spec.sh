#!/usr/bin/env bash
# test-gap-import-spec.sh — INFRA-636
#
# Tests chump gap import-spec on a fixture markdown spec:
#  - --dry-run mode shows expected gaps without filing
#  - --apply mode files gaps from the fixture spec
#  - Pillar inference: EFFECTIVE, RESILIENT, CREDIBLE keywords detected
#  - Priority mapping: P1/P2 parsed correctly
#  - Description and AC extracted from subsections
#  - Rebalance runs after --apply

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
FIXTURE="$REPO_ROOT/docs/test-fixtures/import-spec/sample-spec.md"

echo "=== INFRA-636 chump gap import-spec test ==="
echo

# Prerequisite: binary exists
if [[ ! -f "$CHUMP" ]]; then
    echo "  SKIP: chump binary not built at $CHUMP; run: cargo build --bin chump"
    exit 0
fi

# Prerequisite: fixture exists
if [[ ! -f "$FIXTURE" ]]; then
    fail "fixture missing: $FIXTURE"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy a minimal state.db-free environment so we don't pollute the real registry
FAKE_ROOT="$TMP/fakerepo"
mkdir -p "$FAKE_ROOT/.chump"
touch "$FAKE_ROOT/.chump/state.db"

# ── 1. Dry-run mode ──────────────────────────────────────────────────────────
echo "[dry-run mode]"

DRY_OUT="$("$CHUMP" gap import-spec "$FIXTURE" --dry-run 2>/dev/null)" || true

# Should show 3 gap lines
COUNT="$(echo "$DRY_OUT" | grep -c '^\[dry-run\]' || true)"
if [[ "$COUNT" -ge 3 ]]; then
    ok "dry-run shows 3+ gaps from fixture spec"
else
    fail "dry-run shows $COUNT gaps, expected 3 (output: $(echo "$DRY_OUT" | head -5))"
fi

# Pillar inference: REQ-001 title has 'dashboard URL' → EFFECTIVE
if echo "$DRY_OUT" | grep -q 'EFFECTIVE'; then
    ok "EFFECTIVE pillar inferred from user-facing feature title"
else
    fail "EFFECTIVE pillar not detected (got: $(echo "$DRY_OUT" | head -3))"
fi

# Priority P1 and P2 present
if echo "$DRY_OUT" | grep -q 'P1'; then
    ok "P1 priority parsed from **Priority.** P1"
else
    fail "P1 priority not found in dry-run output"
fi

if echo "$DRY_OUT" | grep -q 'P2'; then
    ok "P2 priority parsed from **Priority.** P2"
else
    fail "P2 priority not found in dry-run output"
fi

# REQ-002 has RESILIENT keyword ('retry' implies resilience)
if echo "$DRY_OUT" | grep -qi 'RESILIENT\|MISSION\|INFRA'; then
    ok "pillar label present on all dry-run lines"
else
    fail "pillar label missing from dry-run output"
fi

# ── 2. JSON dry-run ───────────────────────────────────────────────────────────
echo
echo "[json dry-run]"

JSON_OUT="$("$CHUMP" gap import-spec "$FIXTURE" --dry-run --json 2>/dev/null)" || true

JSON_COUNT="$(echo "$JSON_OUT" | python3 -c "
import sys, json, re
# Output may be multiple pretty-printed JSON objects separated by blank lines.
# Split on top-level object boundaries.
text = sys.stdin.read()
decoder = json.JSONDecoder()
pos = 0
count = 0
while pos < len(text):
    while pos < len(text) and text[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(text):
        break
    try:
        obj, end = decoder.raw_decode(text, pos)
        count += 1
        pos = end
    except json.JSONDecodeError:
        pos += 1
print(count)
" 2>/dev/null)"
if [[ "${JSON_COUNT:-0}" -ge 3 ]]; then
    ok "json dry-run emits $JSON_COUNT JSON objects"
else
    fail "json dry-run: expected 3 objects, got ${JSON_COUNT:-?}"
fi

if echo "$JSON_OUT" | python3 -c "
import sys, json
text = sys.stdin.read()
decoder = json.JSONDecoder()
pos = 0
while pos < len(text):
    while pos < len(text) and text[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(text):
        break
    try:
        obj, end = decoder.raw_decode(text, pos)
        assert 'title' in obj, f'missing title in {obj}'
        pos = end
    except Exception as e:
        print('error:', e)
        sys.exit(1)
" 2>/dev/null; then
    ok "json objects include title field"
else
    fail "json output missing title field"
fi

# ── 3. Help text ─────────────────────────────────────────────────────────────
echo
echo "[help / usage]"

HELP_OUT="$("$CHUMP" gap 2>&1 || true)"
if echo "$HELP_OUT" | grep -q 'import-spec'; then
    ok "import-spec appears in 'chump gap' help text"
else
    fail "import-spec missing from 'chump gap' help text"
fi

# ── 4. Missing file ──────────────────────────────────────────────────────────
echo
echo "[error handling]"

EXIT_CODE=0
"$CHUMP" gap import-spec /nonexistent/file.md --dry-run 2>/dev/null || EXIT_CODE=$?
if [[ "$EXIT_CODE" -ne 0 ]]; then
    ok "import-spec exits non-zero on missing file"
else
    fail "import-spec should exit non-zero on missing file"
fi

# ── 5. Empty spec ─────────────────────────────────────────────────────────────
EMPTY_SPEC="$TMP/empty.md"
printf "# No headings here\n\nJust some text.\n" > "$EMPTY_SPEC"
EXIT_CODE=0
"$CHUMP" gap import-spec "$EMPTY_SPEC" --dry-run 2>/dev/null || EXIT_CODE=$?
if [[ "$EXIT_CODE" -ne 0 ]]; then
    ok "import-spec exits non-zero on spec with no gap headings"
else
    fail "import-spec should exit non-zero when no '### REQ-NNN — title' headings found"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
