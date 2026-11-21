#!/usr/bin/env bash
# test-audit-matrix-shape.sh — AC4 for INFRA-2565
#
# Parses audit.yml and asserts the structural invariants of the sharded audit workflow:
#
#   1. `audit-shard` job exists with strategy.matrix.shard containing [1, 2, 3, 4]
#   2. `audit` aggregate job has `needs: [audit-shard]`
#   3. `audit` aggregate job has `if: always()`
#   4. `audit` aggregate job has a step that exits 1 on shard failure
#   5. `audit-required` job still references `needs: [audit]`
#
# Usage:
#   bash scripts/ci/test-audit-matrix-shape.sh
#   AUDIT_YML=path/to/audit.yml bash scripts/ci/test-audit-matrix-shape.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

AUDIT_YML="${AUDIT_YML:-$REPO_ROOT/.github/workflows/audit.yml}"

fail=0

echo "[test-audit-matrix-shape] audit.yml: $AUDIT_YML"

if [[ ! -f "$AUDIT_YML" ]]; then
  echo "FAIL: audit.yml not found at $AUDIT_YML" >&2
  exit 1
fi

content="$(cat "$AUDIT_YML")"

# ── Check 1: audit-shard job exists with matrix.shard ────────────────────────
if echo "$content" | grep -q "^  audit-shard:"; then
  echo "PASS: audit-shard job exists"
else
  echo "FAIL: audit-shard job not found (expected '  audit-shard:' at column 2)" >&2
  fail=1
fi

# matrix.shard must list all 4 values
for shard_val in 1 2 3 4; do
  if echo "$content" | grep -qE "shard:.*\[.*$shard_val.*\]|shard:.*$shard_val"; then
    echo "PASS: matrix.shard includes value $shard_val"
  else
    # Also accept multi-line matrix form
    if awk '/matrix:/{p=1} /shard:/{if(p)print} /steps:/{p=0}' "$AUDIT_YML" | grep -q "$shard_val"; then
      echo "PASS: matrix.shard includes value $shard_val (multi-line form)"
    else
      echo "FAIL: matrix.shard does not include value $shard_val" >&2
      fail=1
    fi
  fi
done

# ── Check 2: audit aggregate job has needs: [audit-shard] ────────────────────
# Extract the `audit:` aggregate job block (stop before audit-required:)
audit_block="$(awk '/^  audit:$/{p=1} /^  audit-required:/{p=0} p' "$AUDIT_YML")"

if echo "$audit_block" | grep -qE "needs:.*audit-shard|\- audit-shard"; then
  echo "PASS: audit aggregate job has needs: [audit-shard]"
else
  echo "FAIL: audit aggregate job does not have needs: [audit-shard]" >&2
  echo "      Found in audit block:" >&2
  echo "$audit_block" | grep -E "needs:|if:" | head -5 | sed 's/^/        /' >&2
  fail=1
fi

# ── Check 3: audit aggregate job has if: always() ────────────────────────────
if echo "$audit_block" | grep -qE "if: always\(\)"; then
  echo "PASS: audit aggregate job has if: always()"
else
  echo "FAIL: audit aggregate job missing 'if: always()'" >&2
  fail=1
fi

# ── Check 4: audit aggregate job exits 1 on shard failure ────────────────────
# The step must check needs.audit-shard.result and exit 1 on failure
if echo "$audit_block" | grep -qE "exit 1|exit1"; then
  echo "PASS: audit aggregate job has exit 1 on failure"
else
  echo "FAIL: audit aggregate job has no exit 1 path (must fail when any shard fails)" >&2
  fail=1
fi

if echo "$audit_block" | grep -qE "audit-shard"; then
  echo "PASS: audit aggregate job references needs.audit-shard result"
else
  echo "FAIL: audit aggregate job does not check needs.audit-shard result" >&2
  fail=1
fi

# ── Check 5: audit-required references needs: [audit] ────────────────────────
# Extract from `audit-required:` job header to end of file (it's the last job).
audit_required_block="$(awk '/^  audit-required:/{p=1} p' "$AUDIT_YML")"

if echo "$audit_required_block" | grep -qE "needs:.*\[audit\]|needs:.*audit[^-]|^\s*- audit\s*$"; then
  echo "PASS: audit-required has needs: [audit]"
else
  echo "FAIL: audit-required does not reference needs: [audit]" >&2
  echo "      needs lines in audit-required block:" >&2
  echo "$audit_required_block" | grep -E "needs:" | head -5 | sed 's/^/        /' >&2
  fail=1
fi

# ── Check 6: audit job name must be literally `audit` (branch protection) ────
if echo "$content" | grep -qE "^  audit:$"; then
  echo "PASS: aggregate job is named exactly 'audit' (branch protection safe)"
else
  echo "FAIL: no job named exactly 'audit' found (branch protection requires this name)" >&2
  fail=1
fi

# ── Check 7: no bypass env vars introduced ────────────────────────────────────
if echo "$content" | grep -qE "CHUMP_AUDIT_SKIP|CHUMP_SHARD_SKIP|CHUMP_AUDIT_BYPASS"; then
  echo "FAIL: bypass env var found in audit.yml — prohibited by INFRA-2565 AC5" >&2
  fail=1
else
  echo "PASS: no bypass env vars introduced"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: audit matrix shape invariants not satisfied (INFRA-2565 AC4)" >&2
  exit 1
fi

echo "PASS: audit.yml matrix shape is correct (INFRA-2565 AC4)"
