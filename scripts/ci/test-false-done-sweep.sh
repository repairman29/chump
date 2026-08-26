#!/usr/bin/env bash
# scripts/ci/test-false-done-sweep.sh — CREDIBLE-336
#
# Regression test for scripts/ops/false-done-sweep.py's BOOKKEEPING tier: a
# closing PR whose diff contains zero implementation files cannot have shipped
# the work it is credited with (see the module docstring for the full case).
#
# Fixture-based: constructs a docs-only file list and a file list containing
# a .rs implementation file, then asserts the classification each produces
# against the exact function main() uses (is_implementation), not a re-
# implementation of the logic.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/ops/false-done-sweep.py"

echo "=== CREDIBLE-336 false-done-sweep.py tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "script is executable" || fail "script is not executable"

RESULT="$(
  cd "$REPO_ROOT" && python3 - "$TARGET" <<'PYEOF'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("false_done_sweep", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Fixture PR touching only docs/gaps/*.yaml — must classify as BOOKKEEPING
# (no file in the diff is an implementation file).
docs_only = ["docs/gaps/CREDIBLE-999.yaml", "docs/gaps/CREDIBLE-1000.yaml"]
is_bookkeeping_docs_only = not any(mod.is_implementation(f) for f in docs_only)

# Fixture PR containing a .rs implementation file — must NOT classify as
# BOOKKEEPING (the diff shipped at least one implementation file).
with_rs = ["docs/gaps/CREDIBLE-999.yaml", "src/foo.rs"]
is_bookkeeping_with_rs = not any(mod.is_implementation(f) for f in with_rs)

print("docs_only_bookkeeping=%s" % is_bookkeeping_docs_only)
print("with_rs_bookkeeping=%s" % is_bookkeeping_with_rs)
PYEOF
)"

echo "$RESULT" | grep -q "^docs_only_bookkeeping=True$" \
  && ok "docs/gaps/*.yaml-only fixture classified BOOKKEEPING" \
  || fail "docs/gaps/*.yaml-only fixture NOT classified BOOKKEEPING"

echo "$RESULT" | grep -q "^with_rs_bookkeeping=False$" \
  && ok "fixture with a .rs file NOT classified BOOKKEEPING" \
  || fail "fixture with a .rs file wrongly classified BOOKKEEPING"

python3 -m py_compile "$TARGET" \
  && ok "script compiles" \
  || fail "script fails to compile"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
