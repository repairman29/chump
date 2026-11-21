#!/usr/bin/env bash
# ZERO-WASTE-153: pre-commit must scope/defer cargo check on small nodes.
set -euo pipefail
H="$(git rev-parse --show-toplevel)/scripts/git-hooks/pre-commit"
grep -q 'CHUMP_NODE_SIZE' "$H"
grep -q 'deferring cargo check to CI' "$H"
grep -q 'chump_admission_wait_cargo' "$H"
bash -n "$H"
echo "PASS test-precommit-small-node-check"
