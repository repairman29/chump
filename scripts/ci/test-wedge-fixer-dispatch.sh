#!/usr/bin/env bash
# test-wedge-fixer-dispatch.sh — INFRA-2069
#
# Smoke test for the wedge-fixer template library and manual dispatcher.
# Assertions:
#   1. YAML template file loads cleanly (no parse errors)
#   2. Each template renders without {{PLACEHOLDER}} residuals
#   3. Dispatcher --dry-run prints expected sections for each template
#   4. Unknown template name exits non-zero
#   5. Missing required placeholder exits non-zero
#
# CI gate: runs on every PR (fast-checks tier)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

TEMPLATE_FILE="${REPO_ROOT}/scripts/coord/wedge-fixer-templates.yaml"
DISPATCHER="${REPO_ROOT}/scripts/coord/wedge-fixer-dispatch.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# ── 1. YAML loads cleanly ─────────────────────────────────────────────────────
echo "--- 1. YAML parse ---"
if python3 -c "import yaml; yaml.safe_load(open('$TEMPLATE_FILE'))" 2>&1; then
  pass "YAML parses without error"
else
  fail "YAML parse failed"
fi

# ── 2. All three templates exist ──────────────────────────────────────────────
echo "--- 2. Template presence ---"
TEMPLATES_FOUND="$(python3 - "$TEMPLATE_FILE" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
for t in data.get("templates", []):
    print(t.get("template_name", ""))
PYEOF
)"

for tpl in fmt-drift orphan-event printf-grep; do
  if echo "$TEMPLATES_FOUND" | grep -qxF "$tpl"; then
    pass "template '$tpl' found in YAML"
  else
    fail "template '$tpl' MISSING from YAML"
  fi
done

# ── 3. Dispatcher is executable and bash-syntax-clean ────────────────────────
echo "--- 3. Dispatcher syntax ---"
if bash -n "$DISPATCHER" 2>&1; then
  pass "wedge-fixer-dispatch.sh passes bash -n"
else
  fail "wedge-fixer-dispatch.sh has syntax errors"
fi

# ── 4. fmt-drift renders without residual placeholders ───────────────────────
echo "--- 4. fmt-drift render ---"
OUTPUT="$(bash "$DISPATCHER" \
  --gap INFRA-TEST \
  --template fmt-drift \
  --worktree /tmp/test-worktree \
  --dry-run 2>&1)"
if echo "$OUTPUT" | grep -qE '\{\{[A-Z_]+\}\}'; then
  fail "fmt-drift render has unresolved placeholders: $(echo "$OUTPUT" | grep -oE '\{\{[A-Z_]+\}\}')"
else
  pass "fmt-drift renders without residual placeholders"
fi
if echo "$OUTPUT" | grep -q "cargo fmt --all"; then
  pass "fmt-drift output contains expected instruction"
else
  fail "fmt-drift output missing 'cargo fmt --all'"
fi

# ── 5. orphan-event renders without residual placeholders ────────────────────
echo "--- 5. orphan-event render ---"
OUTPUT="$(bash "$DISPATCHER" \
  --gap INFRA-TEST \
  --template orphan-event \
  --event-kind test_kind_fired \
  --worktree /tmp/test-worktree \
  --dry-run 2>&1)"
if echo "$OUTPUT" | grep -qE '\{\{[A-Z_]+\}\}'; then
  fail "orphan-event render has unresolved placeholders: $(echo "$OUTPUT" | grep -oE '\{\{[A-Z_]+\}\}')"
else
  pass "orphan-event renders without residual placeholders"
fi
if echo "$OUTPUT" | grep -q "test_kind_fired"; then
  pass "orphan-event output contains substituted event kind"
else
  fail "orphan-event output missing substituted event kind"
fi

# ── 6. printf-grep renders without residual placeholders ─────────────────────
echo "--- 6. printf-grep render ---"
OUTPUT="$(bash "$DISPATCHER" \
  --gap INFRA-TEST \
  --template printf-grep \
  --violation-file scripts/coord/some-script.sh \
  --worktree /tmp/test-worktree \
  --dry-run 2>&1)"
if echo "$OUTPUT" | grep -qE '\{\{[A-Z_]+\}\}'; then
  fail "printf-grep render has unresolved placeholders: $(echo "$OUTPUT" | grep -oE '\{\{[A-Z_]+\}\}')"
else
  pass "printf-grep renders without residual placeholders"
fi
if echo "$OUTPUT" | grep -q "case statement"; then
  pass "printf-grep output contains case statement instruction"
else
  fail "printf-grep output missing case statement instruction"
fi

# ── 7. Unknown template exits non-zero ───────────────────────────────────────
echo "--- 7. Unknown template error ---"
if bash "$DISPATCHER" --gap INFRA-TEST --template nonexistent-template --dry-run 2>/dev/null; then
  fail "dispatcher accepted unknown template name (should have exited non-zero)"
else
  pass "dispatcher correctly rejects unknown template name"
fi

# ── 8. orphan-event without --event-kind exits non-zero ──────────────────────
echo "--- 8. Missing placeholder guard ---"
if bash "$DISPATCHER" \
  --gap INFRA-TEST \
  --template orphan-event \
  --worktree /tmp/test-worktree \
  --dry-run 2>/dev/null; then
  fail "dispatcher accepted orphan-event without --event-kind (should have exited non-zero)"
else
  pass "dispatcher correctly rejects orphan-event with missing --event-kind"
fi

# ── 9. printf-grep without --violation-file exits non-zero ───────────────────
echo "--- 9. Missing violation-file guard ---"
if bash "$DISPATCHER" \
  --gap INFRA-TEST \
  --template printf-grep \
  --worktree /tmp/test-worktree \
  --dry-run 2>/dev/null; then
  fail "dispatcher accepted printf-grep without --violation-file (should have exited non-zero)"
else
  pass "dispatcher correctly rejects printf-grep with missing --violation-file"
fi

# ── 10. max_loc field present for all templates ───────────────────────────────
echo "--- 10. max_loc fields ---"
MISSING_MAX_LOC="$(python3 - "$TEMPLATE_FILE" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
missing = [t["template_name"] for t in data.get("templates", []) if "max_loc" not in t]
for m in missing:
    print(m)
PYEOF
)"
if [[ -z "$MISSING_MAX_LOC" ]]; then
  pass "all templates have max_loc field"
else
  fail "templates missing max_loc: $MISSING_MAX_LOC"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
