#!/usr/bin/env bash
# test-cargo-target-isolation.sh — INFRA-2118
#
# Verifies that .github/workflows/ci.yml ships per-run CARGO_TARGET_DIR and
# PR-scoped cache prefix-key for each Rust job (cargo-test/fmt/clippy/audit).
#
# Why this is a CI test: DOC-063 (14d CI-rot post-mortem) showed cross-PR
# cargo target corruption (.cargo-test-target, /tmp/chump-coord-linux-build*)
# was a top-3 failure class. Per-PR isolation breaks the corruption chain.
#
# Exit 0 — every Rust job has CARGO_TARGET_DIR + prefix-key isolation (pass).
# Exit 1 — one or more Rust jobs is missing isolation (fail).
# Exit 2 — bad environment (missing file).
#
# Bypass: none — this is a structural lint, not a flake-prone runtime check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"

if [[ ! -f "$CI_YML" ]]; then
  echo "FAIL: $CI_YML not found" >&2
  exit 2
fi

fails=0

# ── AC #1: per-run CARGO_TARGET_DIR ──────────────────────────────────────────
# Each of fast-checks, clippy, cargo-test, audit must declare
# CARGO_TARGET_DIR with both github.run_id AND github.run_attempt so reruns
# of the same run also get a fresh dir.
expected_env_pattern='CARGO_TARGET_DIR: \${{ runner\.temp }}/cargo-target-\${{ github\.run_id }}-\${{ github\.run_attempt }}'
env_count=$(grep -cE "$expected_env_pattern" "$CI_YML" || true)

# We expect at minimum 4 hits (one per Rust job — fast-checks, clippy,
# cargo-test, audit). Extras are fine (coverage etc. may opt-in later).
if [[ "$env_count" -lt 4 ]]; then
  echo "FAIL: AC#1 — expected >= 4 per-run CARGO_TARGET_DIR env declarations, found $env_count" >&2
  echo "      Pattern: $expected_env_pattern" >&2
  echo "      Required jobs: fast-checks, clippy, cargo-test, audit" >&2
  fails=$((fails + 1))
fi

# ── AC #2: PR-scoped cache prefix-key ────────────────────────────────────────
# Every Swatinem/rust-cache@v2 block for a Rust *build* job must have a
# prefix-key including the PR number (with a ref_name fallback for push/merge).
expected_prefix_pattern='prefix-key: "v1-pr-\${{ github\.event\.pull_request\.number \|\| github\.ref_name }}"'
prefix_count=$(grep -cE "$expected_prefix_pattern" "$CI_YML" || true)

if [[ "$prefix_count" -lt 4 ]]; then
  echo "FAIL: AC#2 — expected >= 4 PR-scoped cache prefix-key declarations, found $prefix_count" >&2
  echo "      Pattern: $expected_prefix_pattern" >&2
  echo "      Required: fast-checks, clippy, cargo-test, audit Cache cargo steps" >&2
  fails=$((fails + 1))
fi

# ── AC #1 sanity: no stale literal target paths in CI ────────────────────────
# Catches accidental hand-typed /tmp/chump-coord-linux-build* or
# .cargo-test-target literals that would defeat the isolation. We exclude
# YAML comment lines (leading whitespace then `#`) so historical references
# in comments don't trip the lint.
stale_literals=$(grep -nE '\.cargo-test-target|/tmp/chump-coord-linux-build' "$CI_YML" \
  | grep -vE '^\s*[0-9]+:\s*#' || true)
if [[ -n "$stale_literals" ]]; then
  echo "FAIL: AC#1 — stale literal cargo target paths found in $CI_YML:" >&2
  echo "$stale_literals" >&2
  fails=$((fails + 1))
fi

if [[ "$fails" -gt 0 ]]; then
  echo "" >&2
  echo "INFRA-2118 isolation lint failed ($fails issue(s))." >&2
  echo "See docs/process/CI_ARCHITECTURE.md §Per-PR target isolation." >&2
  exit 1
fi

echo "OK: INFRA-2118 — per-run CARGO_TARGET_DIR ($env_count blocks) + PR-scoped cache prefix-key ($prefix_count blocks) confirmed."
exit 0
