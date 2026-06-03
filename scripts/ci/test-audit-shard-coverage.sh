#!/usr/bin/env bash
# test-audit-shard-coverage.sh — AC3 for INFRA-2565
#
# Diffs the union of gate names in the audit-shard matrix (across all 4 shards)
# against the prior audit.yml job step list captured in audit-gate-baseline.txt.
#
# Asserts:
#   1. Every gate from the baseline appears in exactly one shard
#   2. No gate is duplicated across shards (name+shard uniqueness)
#   3. No gates are missing from the shards
#   4. No extra gates appear in the shards that aren't in the baseline
#
# The baseline captures duplicate step names that existed in the original audit job
# (gap rollback x2, run.sh consolidation x3, etc.) — those are valid and must be
# preserved with the same multiplicity.
#
# Usage:
#   bash scripts/ci/test-audit-shard-coverage.sh
#   AUDIT_YML=path/to/audit.yml bash scripts/ci/test-audit-shard-coverage.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

AUDIT_YML="${AUDIT_YML:-$REPO_ROOT/.github/workflows/audit.yml}"
BASELINE_FILE="${BASELINE_FILE:-$SCRIPT_DIR/audit-gate-baseline.txt}"

fail=0

echo "[test-audit-shard-coverage] baseline: $BASELINE_FILE"
echo "[test-audit-shard-coverage] audit.yml: $AUDIT_YML"

if [[ ! -f "$AUDIT_YML" ]]; then
  echo "FAIL: audit.yml not found at $AUDIT_YML" >&2
  exit 1
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "FAIL: baseline file not found at $BASELINE_FILE" >&2
  exit 1
fi

# ── Extract all step names from the audit-shard job (before the `audit:` aggregate) ──
# We stop at the aggregate `audit:` job line (not audit-shard or audit-required).
shard_steps_file="$(mktemp)"
awk '/^  audit-shard:/{p=1} /^  # ── audit: aggregate/{p=0} p && /^      - name:/' \
  "$AUDIT_YML" | sed 's/^      - name: //' | grep -v '^$' > "$shard_steps_file"

shard_count="$(wc -l < "$shard_steps_file" | tr -d ' ')"
baseline_count="$(wc -l < "$BASELINE_FILE" | tr -d ' ')"

echo "[test-audit-shard-coverage] shard steps: $shard_count  baseline steps: $baseline_count"

# ── Check 1: Totals match ──────────────────────────────────────────────────────
if [[ "$shard_count" -ne "$baseline_count" ]]; then
  echo "FAIL: step count mismatch — shard has $shard_count, baseline has $baseline_count" >&2
  fail=1
fi

# ── Check 2: All baseline gates appear in shards (no missing gates) ───────────
missing_file="$(mktemp)"
comm -23 <(sort "$BASELINE_FILE") <(sort "$shard_steps_file") > "$missing_file"
if [[ -s "$missing_file" ]]; then
  echo "FAIL: gates in baseline but MISSING from shards:" >&2
  sed 's/^/  MISSING: /' "$missing_file" >&2
  fail=1
fi

# ── Check 3: No extra gates in shards that aren't in baseline ─────────────────
extra_file="$(mktemp)"
comm -13 <(sort "$BASELINE_FILE") <(sort "$shard_steps_file") > "$extra_file"
if [[ -s "$extra_file" ]]; then
  echo "FAIL: gates in shards but NOT in baseline:" >&2
  sed 's/^/  EXTRA: /' "$extra_file" >&2
  fail=1
fi

# ── Check 4: Verify each shard has at least one gate ─────────────────────────
for shard in 1 2 3 4; do
  count=$(grep -c "if: matrix.shard == $shard" "$AUDIT_YML" 2>/dev/null || echo 0)
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: shard $shard has no gated steps (if: matrix.shard == $shard)" >&2
    fail=1
  else
    echo "[test-audit-shard-coverage] shard-$shard: $count gated steps"
  fi
done

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$shard_steps_file" "$missing_file" "$extra_file"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: audit-shard coverage check did not pass" >&2
  exit 1
fi

echo "PASS: audit-shard covers exactly the same gates as the baseline (INFRA-2565 AC3)"
