#!/usr/bin/env bash
# test-chump-bench.sh — EFFECTIVE-327 / DOC-072
# Structural smoke: the module + the first track exist and the track YAML parses to the schema.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
echo "=== EFFECTIVE-327 chump bench smoke ==="
[ -f "$ROOT/src/bench.rs" ] && ok "src/bench.rs present" || fail "src/bench.rs missing"
[ -f "$ROOT/e2e/chumpbench/rescue-beast-ci.yaml" ] && ok "first track present" || fail "track missing"
grep -q 'kind: ci-green' "$ROOT/e2e/chumpbench/rescue-beast-ci.yaml" && ok "track declares an acceptance check" || fail "track has no acceptance check"
grep -q 'fn grade_check_conclusions' "$ROOT/src/bench.rs" && ok "conservative CI grader present" || fail "grader missing"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import yaml,sys; d=yaml.safe_load(open('$ROOT/e2e/chumpbench/rescue-beast-ci.yaml')); sys.exit(0 if d.get('acceptance',{}).get('kind')=='ci-green' and 'task' in d else 1)" \
    && ok "track YAML parses + has task + ci-green acceptance" || fail "track YAML invalid"
fi
echo "=== chump bench smoke: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
