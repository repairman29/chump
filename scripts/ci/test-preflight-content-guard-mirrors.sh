#!/usr/bin/env bash
# INFRA-3377 (META-070): integration test that verifies the 14 staged-diff
# commit-content-guards (scripts/git-hooks/pre-commit-*.sh) mirrored into
# `chump preflight --pre-commit` stay reachable from preflight.rs.
#
# Catches silent regression — if someone removes a gate mirror from
# preflight.rs (or the underlying pre-commit hook script) without updating
# the audit doc, this test fails fast. Mirrors the strategy used by
# scripts/ci/test-preflight-coverage.sh (INFRA-2350): grep preflight.rs
# source rather than invoking a built `chump` binary, so this test has no
# cold-build dependency.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PREFLIGHT_RS="$REPO_ROOT/src/preflight.rs"

if [ ! -f "$PREFLIGHT_RS" ]; then
  echo "FAIL: $PREFLIGHT_RS not found" >&2
  exit 1
fi

# The 22 commit-content-guards named in INFRA-3377's AC point at a
# docs/process/AUDIT_JOB_DECOMPOSITION.md#commit-content-guards-infra-3377
# section that does not exist on origin/main (verified via `git ls-tree
# origin/main` at implementation time). This test instead asserts against
# the concrete, currently-invoked inventory: every scripts/git-hooks/
# pre-commit-*.sh script is a staged-diff commit-content-guard by
# definition (each greps `git diff --cached`), and this INFRA-3377 slice
# mirrors all of them into preflight.rs. If the inventory grows, add the
# new script's basename to EXPECTED_GATES below.
#
# format: gate_name|underlying_script
EXPECTED_GATES=(
  "ac-completeness|scripts/git-hooks/pre-commit-ac-completeness.sh"
  "css-token-discipline|scripts/git-hooks/pre-commit-css-token-discipline.sh"
  "default-flip|scripts/git-hooks/pre-commit-default-flip.sh"
  "effect-metric|scripts/git-hooks/pre-commit-effect-metric.sh"
  "event-registry-staged|scripts/git-hooks/pre-commit-event-registry.sh"
  "gap-divergence|scripts/git-hooks/pre-commit-gap-divergence.sh"
  "git-identity|scripts/git-hooks/pre-commit-git-identity.sh"
  "hardcoded-dates|scripts/git-hooks/pre-commit-hardcoded-dates.sh"
  "main-worktree-config|scripts/git-hooks/pre-commit-main-worktree-config.sh"
  "obs-budget|scripts/git-hooks/pre-commit-obs-budget.sh"
  "preflight-ci-parity|scripts/git-hooks/pre-commit-preflight-ci-parity.sh"
  "pwa-index-uniq|scripts/git-hooks/pre-commit-pwa-index-uniq.sh"
  "redundancy|scripts/git-hooks/pre-commit-redundancy.sh"
  "rust-first|scripts/git-hooks/pre-commit-rust-first.sh"
)

errors=0

# 1. Every scripts/git-hooks/pre-commit-*.sh script on disk is accounted
#    for in EXPECTED_GATES — catches a new hook script landing without a
#    preflight mirror.
while IFS= read -r hook_script; do
  rel="scripts/git-hooks/$(basename "$hook_script")"
  found=0
  for entry in "${EXPECTED_GATES[@]}"; do
    IFS='|' read -r _ script <<<"$entry"
    if [ "$script" = "$rel" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -ne 1 ]; then
    echo "FAIL: $rel exists on disk but is not in EXPECTED_GATES — add a preflight.rs mirror (or update this test's inventory)" >&2
    errors=$((errors + 1))
  fi
done < <(find "$REPO_ROOT/scripts/git-hooks" -maxdepth 1 -name 'pre-commit-*.sh' | sort)

for entry in "${EXPECTED_GATES[@]}"; do
  IFS='|' read -r gate_name script <<<"$entry"

  # 2. Gate name appears in the CONTENT_GUARD_MIRRORS table in preflight.rs.
  if ! grep -qE "\"$gate_name\"," "$PREFLIGHT_RS"; then
    echo "FAIL: gate name '$gate_name' not found in $PREFLIGHT_RS" >&2
    errors=$((errors + 1))
  fi

  # 3. Underlying script path is referenced alongside it.
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

# 5. preflight.rs gates the whole mirror block behind --pre-commit (these
#    are staged-diff checks; running them outside a real commit path would
#    just recheck an empty stage).
if ! grep -qE 'CONTENT_GUARD_MIRRORS' "$PREFLIGHT_RS"; then
  echo "FAIL: CONTENT_GUARD_MIRRORS table not found in $PREFLIGHT_RS" >&2
  errors=$((errors + 1))
fi

# 6. Audit doc references the new mirrors.
AUDIT_DOC="$REPO_ROOT/docs/process/PREFLIGHT_COVERAGE_AUDIT.md"
if [ ! -f "$AUDIT_DOC" ]; then
  echo "FAIL: $AUDIT_DOC not found" >&2
  errors=$((errors + 1))
elif ! grep -q "INFRA-3377" "$AUDIT_DOC"; then
  echo "FAIL: $AUDIT_DOC does not mention INFRA-3377" >&2
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors error(s) — see above" >&2
  exit 1
fi

echo "OK: all ${#EXPECTED_GATES[@]} commit-content-guard mirrors are reachable from preflight.rs (INFRA-3377)"
exit 0
