#!/usr/bin/env bash
# test-chump-bench.sh — EFFECTIVE-327/328 / DOC-072
# Structural: the module + the full first-heat of tracks exist and parse to the schema,
# spanning all 5 modes; the runner's graders are present.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
echo "=== chump bench + track-suite smoke ==="
[ -f "$ROOT/src/bench.rs" ] && ok "src/bench.rs present" || fail "src/bench.rs missing"
grep -q 'fn grade_check_conclusions' "$ROOT/src/bench.rs" && ok "ci-green grader present" || fail "ci-green grader missing"
grep -q 'fn grade_command' "$ROOT/src/bench.rs" && ok "command grader present" || fail "command grader missing"

# All 5 modes covered by a track.
for mode in RESCUE IMPROVE FINISH COMPREHEND CREATE; do
  if grep -rslq "mode: $mode" "$ROOT/e2e/chumpbench/"*.yaml; then ok "track for mode $mode present"; else fail "no track for mode $mode"; fi
done

# Every track parses + declares task + acceptance kind.
if command -v python3 >/dev/null 2>&1; then
  bad=0
  for f in "$ROOT/e2e/chumpbench/"*.yaml; do
    python3 -c "import yaml,sys; d=yaml.safe_load(open('$f')); sys.exit(0 if d.get('acceptance',{}).get('kind') and d.get('task') and d.get('id') and d.get('mode') else 1)" || { fail "invalid track: $(basename "$f")"; bad=1; }
  done
  [ "$bad" = 0 ] && ok "all track YAMLs parse + have id/mode/task/acceptance"
fi
echo "=== chump bench smoke: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
