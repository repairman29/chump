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
# CREDIBLE-239: pre-existing, untriaged debt surfaced by widening this gate to crates/.
# Vars here are NOT considered "documented" -- they're tracked separately so the gate
# doesn't silently regress to green via a bulk env-vars-internal.txt dump (AC 6). See
# INFRA-3840 for the triage follow-up. This file must only shrink, never grow.
BACKLOG_LIST="$REPO_ROOT/scripts/ci/env-vars-crates-backlog.txt"

if [[ ! -f "$INTERNAL_LIST" ]]; then
  echo "ERROR: $INTERNAL_LIST not found" >&2
  exit 1
fi
if [[ ! -f "$ENV_EXAMPLE" ]]; then
  echo "ERROR: $ENV_EXAMPLE not found" >&2
  exit 1
fi

# Extract all var names from src/ AND crates/**/src/ (std::env::var and env::var calls).
# CREDIBLE-239: the fleet has been extracting code OUT of src/ into crates/ (chump-verify,
# chump-atomic-claim, chump-gap-store, chump-orchestrator, ...) — a scan pinned to src/ only
# silently loses coverage of every var read exclusively from a workspace crate.
scan_dirs=("$REPO_ROOT/src/")
if [[ -d "$REPO_ROOT/crates" ]]; then
  scan_dirs+=("$REPO_ROOT/crates/")
fi
src_vars=$(grep -rn 'std::env::var\b\|env::var(' "${scan_dirs[@]}" \
  | grep -oE '"[A-Z][A-Z0-9_]+"' | tr -d '"' | sort -u)

# Build lookup sets
env_example_vars=$(grep -oE '[A-Z][A-Z0-9_]{3,}' "$ENV_EXAMPLE" | sort -u)
internal_vars=$(grep -v '^#' "$INTERNAL_LIST" | grep -v '^$' | sort -u)
backlog_vars=""
if [[ -f "$BACKLOG_LIST" ]]; then
  backlog_vars=$(grep -v '^#' "$BACKLOG_LIST" | grep -v '^$' | sort -u)
fi

fail=0
missing=()
backlogged=()

while IFS= read -r var; do
  in_example=$(echo "$env_example_vars" | grep -Fx "$var" || true)
  in_internal=$(echo "$internal_vars" | grep -Fx "$var" || true)
  if [[ -n "$in_example" || -n "$in_internal" ]]; then
    continue
  fi
  in_backlog=$(echo "$backlog_vars" | grep -Fx "$var" || true)
  if [[ -n "$in_backlog" ]]; then
    backlogged+=("$var")
    continue
  fi
  missing+=("$var")
  fail=1
done <<< "$src_vars"

if [[ $fail -eq 0 ]]; then
  total=$(echo "$src_vars" | wc -l | tr -d ' ')
  echo "PASS: all $total env vars are documented or allowlisted."
  if [[ ${#backlogged[@]} -gt 0 ]]; then
    echo "NOTE: ${#backlogged[@]} var(s) are untriaged debt tracked in scripts/ci/env-vars-crates-backlog.txt (see INFRA-3840) — not counted as a failure, but not documented either." >&2
  fi
  exit 0
fi

echo "FAIL: ${#missing[@]} env var(s) are neither in .env.example, scripts/ci/env-vars-internal.txt, nor scripts/ci/env-vars-crates-backlog.txt:" >&2
for v in "${missing[@]}"; do
  echo "  $v" >&2
done
echo "" >&2
echo "Fix by either:" >&2
echo "  1. Adding to .env.example (Tier 1 — operator-tunable)" >&2
echo "  2. Adding to scripts/ci/env-vars-internal.txt (Tier 2/3 — debug/runtime/test)" >&2
echo "  3. If this is pre-existing untriaged debt (not something you just added), add it to" >&2
echo "     scripts/ci/env-vars-crates-backlog.txt instead — do NOT bulk-add new debt there for" >&2
echo "     vars you just introduced; those must be classified into (1) or (2)." >&2
exit 1
