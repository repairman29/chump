#!/usr/bin/env bash
# test-resilient-469.sh — RESILIENT-469 smoke test for the cargo-hakari
# workspace-hack wiring: workspace-hack crate exists, Cargo.toml declares
# [workspace.metadata.hakari], and ship() invokes `cargo hakari generate`.
#
# Run from repo root: bash scripts/ci/test-resilient-469.sh
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check "workspace-hack crate Cargo.toml exists" \
    test -f crates/workspace-hack/Cargo.toml

check "workspace-hack crate src/lib.rs exists" \
    test -f crates/workspace-hack/src/lib.rs

check "root Cargo.toml lists crates/workspace-hack as a member" \
    grep -q '"crates/workspace-hack"' Cargo.toml

check "root Cargo.toml declares [workspace.metadata.hakari]" \
    grep -q '\[workspace.metadata.hakari\]' Cargo.toml

check "ship() invokes cargo hakari generate" \
    grep -q '"hakari", "generate"' crates/chump-gap-store/src/lib.rs

echo "--- RESILIENT-469: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
