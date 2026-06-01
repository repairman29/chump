#!/usr/bin/env bash
# INFRA-2350 (META-269 sub-1): integration test that verifies the three
# CI gates added by this slice are reachable from `chump preflight`.
#
# Catches silent regression — if someone removes a gate from preflight.rs
# without removing it from the audit doc, this test fails fast.
#
# Strategy: grep preflight.rs source for the expected gate step names AND
# their bypass env vars. We do not invoke `chump preflight` itself because
# the gates depend on a built binary which may not exist in CI's cold path
# (parity smoke runs before cargo).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PREFLIGHT_RS="$REPO_ROOT/src/preflight.rs"

if [ ! -f "$PREFLIGHT_RS" ]; then
  echo "FAIL: $PREFLIGHT_RS not found" >&2
  exit 1
fi

# Expected gates added by INFRA-2350.
# format: gate_name|bypass_env_var|underlying_script
EXPECTED_GATES=(
  "pipefail-race-sweep|CHUMP_PREFLIGHT_SKIP_PIPEFAIL|scripts/ci/test-pipefail-race-sweep.sh"
  "path-filter-coverage|CHUMP_PREFLIGHT_SKIP_PATHFILTER|scripts/ci/check-path-filter-coverage.sh"
  "install-manifest|CHUMP_PREFLIGHT_SKIP_INSTALLMAP|scripts/ci/test-install-script-manifest.sh"
)

errors=0
for entry in "${EXPECTED_GATES[@]}"; do
  IFS='|' read -r gate_name bypass_env script <<<"$entry"
  # 1. Gate name appears as a step() name.
  if ! grep -qE "\"$gate_name\"," "$PREFLIGHT_RS"; then
    echo "FAIL: gate name '$gate_name' not found in $PREFLIGHT_RS" >&2
    errors=$((errors + 1))
  fi
  # 2. Bypass env var is referenced.
  if ! grep -qE "$bypass_env" "$PREFLIGHT_RS"; then
    echo "FAIL: bypass env '$bypass_env' not found in $PREFLIGHT_RS" >&2
    errors=$((errors + 1))
  fi
  # 3. Underlying script path is referenced.
  if ! grep -qE "$script" "$PREFLIGHT_RS"; then
    echo "FAIL: script path '$script' not found in $PREFLIGHT_RS" >&2
    errors=$((errors + 1))
  fi
  # 4. Underlying script actually exists.
  if [ ! -f "$REPO_ROOT/$script" ]; then
    echo "FAIL: underlying script '$script' does not exist" >&2
    errors=$((errors + 1))
  fi
done

# 5. Audit doc is present and references each new gate.
AUDIT_DOC="$REPO_ROOT/docs/process/PREFLIGHT_COVERAGE_AUDIT.md"
if [ ! -f "$AUDIT_DOC" ]; then
  echo "FAIL: $AUDIT_DOC not found" >&2
  errors=$((errors + 1))
else
  for entry in "${EXPECTED_GATES[@]}"; do
    IFS='|' read -r gate_name bypass_env script <<<"$entry"
    if ! grep -qE "$gate_name" "$AUDIT_DOC"; then
      echo "FAIL: gate '$gate_name' not documented in audit doc" >&2
      errors=$((errors + 1))
    fi
  done
fi

if [ "$errors" -gt 0 ]; then
  echo "test-preflight-coverage: $errors check(s) failed" >&2
  exit 1
fi

echo "test-preflight-coverage: PASS — 3 INFRA-2350 gates wired correctly"
