#!/usr/bin/env bash
# test-nextest-sharding.sh — AC6 for INFRA-2243
#
# Parses ci.yml and asserts the structural invariants of the sharded
# cargo-test workflow:
#
#   1. `cargo-test-shard` job exists with strategy.matrix.shard = [1, 2, 3, 4]
#   2. Each shard invokes `cargo nextest run` with `--partition count:${{ matrix.shard }}/4`
#   3. `cargo-test` aggregate job exists, named exactly `cargo-test`, with
#      `needs: [cargo-test-shard]` and `if: always()` (branch protection /
#      external tooling key off this exact check-run name — see audit.yml's
#      audit-shard/audit precedent, INFRA-2565)
#   4. `cargo-test` aggregate treats both success and skipped shard results as
#      PASS (doc-only PRs skip the whole matrix and must still go green)
#   5. `cargo-test-required` still references `needs: [cargo-test]`
#
# Usage:
#   bash scripts/ci/test-nextest-sharding.sh
#   CI_YML=path/to/ci.yml bash scripts/ci/test-nextest-sharding.sh
#
# NOTE: uses `grep -q pattern <<< "$var"` rather than `echo "$var" | grep -q`.
# On a file this large, grep -q's early-exit-on-match can close its stdin pipe
# before echo finishes writing, delivering SIGPIPE to echo; under `pipefail`
# that non-zero echo status wins even though grep itself matched — a false
# FAIL. Herestrings don't have this failure mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

CI_YML="${CI_YML:-$REPO_ROOT/.github/workflows/ci.yml}"

fail=0

echo "[test-nextest-sharding] ci.yml: $CI_YML"

if [[ ! -f "$CI_YML" ]]; then
  echo "FAIL: ci.yml not found at $CI_YML" >&2
  exit 1
fi

content="$(cat "$CI_YML")"

# ── Check 1: cargo-test-shard job exists with matrix.shard [1,2,3,4] ────────
if grep -q "^  cargo-test-shard:" <<< "$content"; then
  echo "PASS: cargo-test-shard job exists"
else
  echo "FAIL: cargo-test-shard job not found (expected '  cargo-test-shard:' at column 2)" >&2
  fail=1
fi

shard_block="$(awk '/^  cargo-test-shard:$/{p=1} /^  cargo-test:$/{p=0} p' "$CI_YML")"

for shard_val in 1 2 3 4; do
  if grep -qE "shard:.*\[.*$shard_val.*\]" <<< "$shard_block"; then
    echo "PASS: matrix.shard includes value $shard_val"
  else
    echo "FAIL: matrix.shard does not include value $shard_val" >&2
    fail=1
  fi
done

# ── Check 2: nextest run uses --partition count:i/4 ──────────────────────────
if grep -qE "nextest run --workspace --partition count:\\\$\{\{ *matrix\.shard *\}\}/4" <<< "$shard_block"; then
  echo "PASS: cargo-test-shard invokes nextest with --partition count:\${{ matrix.shard }}/4"
else
  echo "FAIL: cargo-test-shard does not invoke nextest with a partition flag keyed on matrix.shard" >&2
  fail=1
fi

# ── Check 3: cargo-test aggregate job exists, named exactly `cargo-test` ────
# Extract from `  cargo-test:` header to the next top-level job.
aggregate_block="$(awk '/^  cargo-test:$/{p=1; print; next} /^  [a-zA-Z0-9_-]+:$/{if(p) exit} p' "$CI_YML")"

if grep -qE "^  cargo-test:$" <<< "$content"; then
  echo "PASS: aggregate job is named exactly 'cargo-test' (branch protection / tooling safe)"
else
  echo "FAIL: no job named exactly 'cargo-test' found" >&2
  fail=1
fi

if grep -qE "needs:.*\[cargo-test-shard\]|- cargo-test-shard" <<< "$aggregate_block"; then
  echo "PASS: cargo-test aggregate has needs: [cargo-test-shard]"
else
  echo "FAIL: cargo-test aggregate does not have needs: [cargo-test-shard]" >&2
  fail=1
fi

if grep -qE "if: always\(\)" <<< "$aggregate_block"; then
  echo "PASS: cargo-test aggregate has if: always()"
else
  echo "FAIL: cargo-test aggregate missing 'if: always()'" >&2
  fail=1
fi

# ── Check 4: aggregate treats success AND skipped as PASS ───────────────────
if grep -qE '"success"\s*\]\s*\|\|.*"skipped"' <<< "$aggregate_block"; then
  echo "PASS: cargo-test aggregate accepts success or skipped as PASS"
else
  echo "FAIL: cargo-test aggregate does not explicitly pass on skipped (doc-only PRs would fail)" >&2
  fail=1
fi

if grep -qE "exit 1" <<< "$aggregate_block"; then
  echo "PASS: cargo-test aggregate has an exit 1 path on real failure"
else
  echo "FAIL: cargo-test aggregate has no exit 1 path (must fail when any shard fails)" >&2
  fail=1
fi

# ── Check 5: cargo-test-required still references needs: [cargo-test] ───────
required_block="$(awk '/^  cargo-test-required:$/{p=1} /^  [a-zA-Z0-9_-]+:$/{if(p && !/cargo-test-required/) exit} p' "$CI_YML")"

if grep -qE "needs:.*\[cargo-test\]" <<< "$required_block"; then
  echo "PASS: cargo-test-required has needs: [cargo-test]"
else
  echo "FAIL: cargo-test-required does not reference needs: [cargo-test]" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: nextest sharding invariants not satisfied (INFRA-2243 AC6)" >&2
  exit 1
fi

echo "PASS: ci.yml nextest sharding shape is correct (INFRA-2243 AC6)"
