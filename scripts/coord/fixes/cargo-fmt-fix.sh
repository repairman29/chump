#!/usr/bin/env bash
# scripts/coord/fixes/cargo-fmt-fix.sh — INFRA-2355 (META-269 sub-6)
#
# Fix-script for the cargo_fmt_drift known-failure-pattern. Re-applies
# `cargo fmt --all` in the repo root. Called by
# scripts/coord/pattern-fix-dispatcher.sh with no arguments; leaves working
# tree changes uncommitted for the dispatcher to commit + PR.
#
# Exit codes:
#   0 — cargo fmt ran (working tree may or may not have changed)
#   1 — cargo not on PATH
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
  CARGO_BIN="cargo"
fi
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
  echo "cargo-fmt-fix: cargo not on PATH" >&2
  exit 1
fi

"$CARGO_BIN" fmt --all
