#!/usr/bin/env bash
# CI gate for INFRA-691: canonical run.sh dispatcher + deprecation shims.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc"; (( FAIL++ )) || true
  fi
}
check_file() { check "file exists: $1" test -f "$REPO_ROOT/$1"; }
check_exec()  { check "file is executable: $1" test -x "$REPO_ROOT/$1"; }

echo "=== INFRA-691: run.sh consolidation ==="

# 1. run.sh must exist and be executable
check_file "run.sh"
check_exec "run.sh"

# 2. run.sh must handle each documented mode (grep for case arms)
for mode in local best web discord discord-full discord-ollama; do
  check "run.sh has mode: $mode" grep -q "$mode)" "$REPO_ROOT/run.sh"
done

# 3. All deprecated shims must print a deprecation warning
for script in run-local.sh run-best.sh run-web.sh run-discord.sh run-discord-full.sh run-discord-ollama.sh; do
  if [[ -f "$REPO_ROOT/$script" ]]; then
    check "$script emits DEPRECATED" grep -q 'DEPRECATED' "$REPO_ROOT/$script"
  fi
done

# 4. README must reference ./run.sh not the old scripts
check "README uses run.sh web"   grep -q 'run\.sh web'   "$REPO_ROOT/README.md"
check "README uses run.sh local" grep -q 'run\.sh local' "$REPO_ROOT/README.md"
check "README no bare run-web.sh call" bash -c \
  "! grep -E '^\s*\./run-web\.sh' '$REPO_ROOT/README.md'"
check "README no bare run-local.sh call" bash -c \
  "! grep -E '^\s*\./run-local\.sh' '$REPO_ROOT/README.md'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
