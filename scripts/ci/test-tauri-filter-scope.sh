#!/usr/bin/env bash
# scripts/ci/test-tauri-filter-scope.sh — INFRA-1432 regression guard
#
# Asserts the tauri paths-filter in .github/workflows/ci.yml stays narrow.
# Catches the regression that surfaced 2026-05-15/16: src/** was matching
# all Rust code, triggering tauri-cowork-e2e on every PR. The Selenium test
# is brittle (INFRA-1425/1433), so over-broad triggering blocks unrelated PRs.

set -euo pipefail

CI_YML="${CI_YML:-.github/workflows/ci.yml}"

if [ ! -f "$CI_YML" ]; then
  echo "FAIL: $CI_YML not found"
  exit 1
fi

# Extract just the tauri filter block (lines between 'tauri:' and the next sibling filter key)
tauri_block=$(awk '
  /^[[:space:]]+tauri:[[:space:]]*$/ {in_block=1; print; next}
  in_block && /^[[:space:]]+[a-z][a-z_-]*:[[:space:]]*$/ {in_block=0; exit}
  in_block {print}
' "$CI_YML")

# Rule A: must NOT contain bare 'src/**'
if echo "$tauri_block" | grep -qE "^[[:space:]]+- 'src/\*\*'$"; then
  echo "FAIL: tauri filter contains bare 'src/**' — too broad; narrow to specific tauri files only"
  echo "Observed block:"
  echo "$tauri_block"
  exit 1
fi

# Rule B: must contain at least the canonical narrow entries
required_entries=(
  "src/desktop_launcher.rs"
  "desktop/"
  "e2e-tauri/"
)
for entry in "${required_entries[@]}"; do
  if ! echo "$tauri_block" | grep -qF "$entry"; then
    echo "FAIL: tauri filter missing required entry: $entry"
    echo "Observed block:"
    echo "$tauri_block"
    exit 1
  fi
done

echo "PASS: tauri paths-filter is appropriately narrow (no bare src/**)"
echo "PASS: required entries present: ${required_entries[*]}"
