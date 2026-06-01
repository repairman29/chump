#!/usr/bin/env bash
# META-271 / INFRA-2367 — harness-neutral wrapper around `chump inventory rebuild`.
#
# Use case: cron job / ops dashboard that wants to refresh the inventory
# without dropping into a Rust call site. The current rebuild path
# refreshes PRs + artifacts + detectors in one pass; a finer-grained
# `--prs-only` switch can land later (filed as part of the INFRA-2372
# backfill follow-up).
#
# Exits 0 on successful rebuild, non-zero on error. Stdout is the
# rebuild log; stderr surfaces structured errors.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[collect-prs] chump binary not built at $CHUMP_BIN — building..." >&2
    PATH="$HOME/.cargo/bin:$PATH" cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

exec "$CHUMP_BIN" inventory rebuild "$@"
