#!/usr/bin/env bash
# Asserts that every env var read by Chump's Rust source is either:
#   (a) mentioned in .env.example, OR
#   (b) listed in scripts/ci/env-vars-internal.txt
#
# Run: bash scripts/ci/test-env-var-coverage.sh
# Exit 0 = pass.  Exit 1 = gaps found (prints offenders to stderr).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INTERNAL_LIST="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

if [[ ! -f "$INTERNAL_LIST" ]]; then
  echo "ERROR: $INTERNAL_LIST not found" >&2
  exit 1
fi
if [[ ! -f "$ENV_EXAMPLE" ]]; then
  echo "ERROR: $ENV_EXAMPLE not found" >&2
  exit 1
fi

# Extract all var names from src/ (std::env::var and env::var calls)
src_vars=$(grep -rn 'std::env::var\b\|env::var(' "$REPO_ROOT/src/" \
  | grep -oE '"[A-Z][A-Z0-9_]+"' | tr -d '"' | sort -u)

# Build lookup sets
env_example_vars=$(grep -oE '[A-Z][A-Z0-9_]{3,}' "$ENV_EXAMPLE" | sort -u)
internal_vars=$(grep -v '^#' "$INTERNAL_LIST" | grep -v '^$' | sort -u)

fail=0
missing=()

while IFS= read -r var; do
  in_example=$(echo "$env_example_vars" | grep -Fx "$var" || true)
  in_internal=$(echo "$internal_vars" | grep -Fx "$var" || true)
  if [[ -z "$in_example" && -z "$in_internal" ]]; then
    missing+=("$var")
    fail=1
  fi
done <<< "$src_vars"

if [[ $fail -eq 0 ]]; then
  total=$(echo "$src_vars" | wc -l | tr -d ' ')
  echo "PASS: all $total env vars are documented or allowlisted."
  exit 0
fi

echo "FAIL: ${#missing[@]} env var(s) are neither in .env.example nor in scripts/ci/env-vars-internal.txt:" >&2
for v in "${missing[@]}"; do
  echo "  $v" >&2
done
echo "" >&2
echo "Fix by either:" >&2
echo "  1. Adding to .env.example (Tier 1 — operator-tunable)" >&2
echo "  2. Adding to scripts/ci/env-vars-internal.txt (Tier 2/3 — debug/runtime/test)" >&2
exit 1
