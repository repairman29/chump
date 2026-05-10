#!/usr/bin/env bash
# test-path-filter-allowlist.sh — INFRA-682 CI gate.
#
# Verifies that check-path-filter-coverage.sh exits non-zero and emits the
# right diagnostic when a new top-level directory is not in the 'code:'
# paths-filter allowlist, and that it passes once the dir is added.
#
# Does NOT require a live repo or GitHub — uses a synthetic ci.yml.

set -euo pipefail

REPO_ROOT_REAL="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$REPO_ROOT_REAL/scripts/ci/check-path-filter-coverage.sh"

[[ -f "$CHECK" ]] || { echo "FAIL: check-path-filter-coverage.sh not found at $CHECK"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.github/workflows"

# Minimal ci.yml with a 'code:' section that covers only 'src' and 'scripts'.
# 'new-feature-dir' is intentionally absent.
# Note: .github/workflows/** is always included because the test creates that
# dir to hold this ci.yml — the structural check would otherwise flag it.
write_ci_yml_without_new_dir() {
    cat >"$TMP/.github/workflows/ci.yml" <<'YAML'
jobs:
  changes:
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - 'src/**'
              - 'scripts/**'
              - '.github/workflows/**'
            e2e:
              - 'src/**'
YAML
}

write_ci_yml_with_new_dir() {
    cat >"$TMP/.github/workflows/ci.yml" <<'YAML'
jobs:
  changes:
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - 'src/**'
              - 'scripts/**'
              - '.github/workflows/**'
              - 'new-feature-dir/**'
            e2e:
              - 'src/**'
YAML
}

# ── Test 1: new top-level dir NOT in allowlist → must exit non-zero + diagnose ─
write_ci_yml_without_new_dir
mkdir -p "$TMP/new-feature-dir"

output=$(REPO_ROOT="$TMP" bash "$CHECK" 2>&1 || true)
if REPO_ROOT="$TMP" bash "$CHECK" >/dev/null 2>&1; then
    echo "FAIL test-1: check-path-filter-coverage.sh should exit non-zero for uncovered 'new-feature-dir'"
    exit 1
fi
if ! echo "$output" | grep -q "new-feature-dir"; then
    echo "FAIL test-1: diagnostic output does not mention 'new-feature-dir'"
    echo "  Got: $output"
    exit 1
fi
echo "[OK] test-1: script exits non-zero and names 'new-feature-dir' in output"

# ── Test 2: after adding to allowlist → must pass ──────────────────────────
write_ci_yml_with_new_dir

if ! REPO_ROOT="$TMP" bash "$CHECK" >/dev/null 2>&1; then
    echo "FAIL test-2: script should pass once 'new-feature-dir/**' is in allowlist"
    REPO_ROOT="$TMP" bash "$CHECK" >&2 || true
    exit 1
fi
echo "[OK] test-2: script passes after 'new-feature-dir/**' added to allowlist"

# ── Test 3: missing ci.yml → must exit 2 (not 1) ──────────────────────────
rm "$TMP/.github/workflows/ci.yml"
exit_code=0
REPO_ROOT="$TMP" bash "$CHECK" >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -ne 2 ]]; then
    echo "FAIL test-3: expected exit 2 when ci.yml missing, got $exit_code"
    exit 1
fi
echo "[OK] test-3: exit code 2 when ci.yml is absent"

# ── Test 4: top-level file (Cargo.toml) not in allowlist → must fail ───────
write_ci_yml_without_new_dir
rm -rf "$TMP/new-feature-dir"
touch "$TMP/Cargo.toml"
if REPO_ROOT="$TMP" bash "$CHECK" >/dev/null 2>&1; then
    echo "FAIL test-4: script should fail when Cargo.toml not in code: allowlist"
    exit 1
fi
output=$(REPO_ROOT="$TMP" bash "$CHECK" 2>&1 || true)
if ! echo "$output" | grep -q "Cargo.toml"; then
    echo "FAIL test-4: diagnostic does not mention 'Cargo.toml'"
    exit 1
fi
echo "[OK] test-4: script detects Cargo.toml missing from allowlist"

echo ""
echo "PASS: test-path-filter-allowlist (4/4 cases verified)"
