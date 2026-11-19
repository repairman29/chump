#!/usr/bin/env bash
# test-chump-bench.sh — EFFECTIVE-327/328 / DOC-072
# Structural: the module + the full first-heat of tracks exist and parse to the schema,
# spanning all 5 modes; the runner's graders are present.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$ROOT"
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-grep.sh"
PASS=0; FAIL=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
echo "=== chump bench + track-suite smoke ==="
# EFFECTIVE-405: bench.rs moved to crates/chump-bench/; locate it layout-agnostically.
BENCH_RS="$(find_rust_module "bench")"
[ -n "$BENCH_RS" ] && [ -f "$BENCH_RS" ] && ok "bench.rs present ($BENCH_RS)" || fail "bench.rs missing"
grep -q 'fn grade_check_conclusions' "$BENCH_RS" && ok "ci-green grader present" || fail "ci-green grader missing"
grep -q 'fn grade_command' "$BENCH_RS" && ok "command grader present" || fail "command grader missing"

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
