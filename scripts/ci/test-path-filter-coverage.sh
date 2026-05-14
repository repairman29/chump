#!/usr/bin/env bash
# INFRA-507 / INFRA-272 / INFRA-1142: Verify every top-level directory and key
# path category is covered by the path filters in ci.yml.
# INFRA-1142: also verify per-job narrower filters (rust/scripts/acp/docs) exist
# and that clippy/cargo-test/coverage if-conditions use 'rust' (not 'code').
#
# WHY: The 'code:' filter is an ALLOWLIST for required status checks.
# If a PR's sole diff touches a path not in the list, required checks get
# "skipped" (not "passing") and branch protection blocks the merge forever.
# This test catches regressions before they kill real PRs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

pass=0
fail=0
declare -a errors=()

# ── Extract patterns from a named filter section inside 'filters: |' ──────
# Anchors to the 'filters: |' line to skip the 'outputs:' block above it,
# which has identically named keys (code:, e2e:, tauri:) that would confuse
# a naive grep/awk.
extract_section() {
  local section="$1"
  awk "
    /filters: \|/ { start=NR }
    start && NR>start && /^[[:space:]]+${section}:/ { found=1; next }
    found && /^[[:space:]]+-[[:space:]]/ {
      line=\$0
      gsub(/[[:space:]]*-[[:space:]]+|'/, \"\", line)
      print line; next
    }
    found && /^[[:space:]]+[a-z]/ { exit }
  " "$CI_YML"
}

code_patterns=$(extract_section "code")
docs_patterns=$(extract_section "docs-only")   # may be empty
all_patterns="$code_patterns
$docs_patterns"

# ── Is a top-level name covered by any pattern? ───────────────────────────
is_covered() {
  local name="$1"
  # Match "name/**", "name/*", "name/anything", or exact "name"
  echo "$all_patterns" | grep -qE "^${name}(/|$)" && return 0
  # Match glob patterns like "Cargo.toml", ".release-plz.toml"
  echo "$all_patterns" | grep -qF "$name" && return 0
  return 1
}

check() {
  local label="$1"
  if is_covered "$label"; then
    echo "  [PASS] $label"
    ((pass++)) || true
  else
    echo "  [FAIL] $label — not in code: or docs-only: filter"
    errors+=("$label")
    ((fail++)) || true
  fi
}

echo "=== Path-filter coverage check ($CI_YML) ==="
echo ""

# ── 1. Every non-hidden top-level directory ───────────────────────────────
echo "--- Top-level directories ---"
while IFS= read -r -d '' dir; do
  name=$(basename "$dir")
  [[ "$name" == .* ]] && continue
  check "$name"
done < <(find "$REPO_ROOT" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

# ── 2. Required top-level files ───────────────────────────────────────────
echo ""
echo "--- Top-level files ---"
for f in Cargo.toml Cargo.lock .release-plz.toml; do
  [[ -e "$REPO_ROOT/$f" ]] || continue
  check "$f"
done

# ── 3. .github/workflows must be covered ─────────────────────────────────
echo ""
echo "--- .github/workflows ---"
check ".github/workflows"

# ── 4. Regression guard: required code: entries must still be present ─────
echo ""
echo "--- Regression guard (required code: entries) ---"
required=(
  'src/**'
  'crates/**'
  'desktop/**'
  'Cargo.toml'
  'Cargo.lock'
  '.github/workflows/**'
  '.release-plz.toml'
  'scripts/**'
  'docs/**'
)
for pattern in "${required[@]}"; do
  # Strip glob suffix for matching against extracted patterns
  bare="${pattern%%\**}"
  bare="${bare%/}"
  if echo "$code_patterns" | grep -qF "$bare"; then
    echo "  [PASS] code: contains pattern for '$pattern'"
    ((pass++)) || true
  else
    echo "  [FAIL] code: MISSING '$pattern' — regression detected"
    errors+=("regression: code: missing $pattern")
    ((fail++)) || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [[ ${#errors[@]} -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for e in "${errors[@]}"; do
    echo "  - $e"
  done
  echo ""
  echo "Fix: add unclassified paths to 'code:' (or 'docs-only:') in"
  echo "     .github/workflows/ci.yml — see INFRA-272 / INFRA-507."
  exit 1
fi

echo "All paths classified. Path-filter trap cannot recur for current repo layout."

# ── INFRA-1142: per-job filter validation ─────────────────────────────────────
echo ""
echo "=== INFRA-1142: per-job filter checks ==="
infra1142_fails=0

check_infra1142() {
  local label="$1" result="$2"
  if [[ "$result" == "pass" ]]; then
    echo "  [PASS] $label"
    ((pass++)) || true
  else
    echo "  [FAIL] $label"
    ((infra1142_fails++)) || true
    ((fail++)) || true
  fi
}

# Per-job outputs exist
for output in rust scripts acp docs; do
  if grep -q "steps.filter.outputs.${output}" "$CI_YML"; then
    check_infra1142 "changes.outputs.${output} declared" "pass"
  else
    check_infra1142 "changes.outputs.${output} declared" "fail"
  fi
done

# rust filter covers core Rust paths
rust_section=$(extract_section "rust")
for pattern in 'src/**' 'crates/**' 'Cargo.toml'; do
  bare="${pattern%%\**}"; bare="${bare%/}"
  if echo "$rust_section" | grep -qF "$bare"; then
    check_infra1142 "rust filter includes $pattern" "pass"
  else
    check_infra1142 "rust filter includes $pattern" "fail"
  fi
done

# docs filter does NOT include src/**
docs_section=$(extract_section "docs")
if echo "$docs_section" | grep -q "src/"; then
  check_infra1142 "docs filter excludes src/** (docs-only skips rust CI)" "fail"
else
  check_infra1142 "docs filter excludes src/** (docs-only skips rust CI)" "pass"
fi

# clippy/cargo-test/coverage use 'rust' filter
for job in clippy cargo-test coverage; do
  if_line="$(grep -A3 "^\s*${job}:" "$CI_YML" | grep "if:" | head -1 || true)"
  if echo "$if_line" | grep -q "outputs.rust"; then
    check_infra1142 "${job} if-condition uses 'rust' output" "pass"
  else
    check_infra1142 "${job} if-condition uses 'rust' output" "fail"
  fi
done

# fast-checks uses rust OR scripts — match the job key at 2-space indent level
fast_if="$(awk '/^  fast-checks:/{f=1} f && /^    if:/{print; exit}' "$CI_YML" || true)"
if echo "$fast_if" | grep -q "outputs.rust" && echo "$fast_if" | grep -q "outputs.scripts"; then
  check_infra1142 "fast-checks if-condition uses rust || scripts" "pass"
else
  check_infra1142 "fast-checks if-condition uses rust || scripts" "fail"
fi

if [[ "$infra1142_fails" -gt 0 ]]; then
  echo ""
  echo "INFRA-1142 validation: $infra1142_fails check(s) failed. See ci.yml changes guide."
  exit 1
fi
echo "INFRA-1142: per-job filter split validated."
