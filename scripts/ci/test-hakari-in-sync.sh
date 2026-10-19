#!/usr/bin/env bash
# scripts/ci/test-hakari-in-sync.sh — RESILIENT-1645 (PHASE-R R4)
#
# The workspace-hack consistency check that `chump gap ship` used to run in the
# node checkout (RESILIENT-469 `cargo hakari generate`) moves HERE — a PR gate.
# ship() must run no cargo command in the checkout; keeping workspace-hack in
# sync is the PR author's job, enforced on the PR instead of silently rewritten
# at ship time.
#
# Fails when workspace-hack/Cargo.toml is out of sync with the dependency graph.
# `cargo hakari generate --diff` is the verify form: it prints the needed diff
# and exits non-zero when regeneration is required, without writing anything.
#
# Runs in CI (cargo-hakari installed via taiki-e/install-action) and in
# `chump preflight`. When cargo-hakari is not installed locally, SKIP rather
# than fail — the hard gate is CI, which always installs it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"
export PATH="$HOME/.cargo/bin:$PATH"

if ! cargo hakari --version >/dev/null 2>&1; then
    echo "SKIP: cargo-hakari not installed (install: cargo install cargo-hakari --locked)."
    echo "      CI installs it and runs the hard workspace-hack sync gate."
    exit 0
fi

if cargo hakari generate --diff; then
    echo "PASS: workspace-hack is in sync with the dependency graph"
    exit 0
else
    echo "FAIL: workspace-hack/Cargo.toml is out of sync with the dependency graph." >&2
    echo "      Run 'cargo hakari generate' and commit the result." >&2
    exit 1
fi
