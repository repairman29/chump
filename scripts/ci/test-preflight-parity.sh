#!/usr/bin/env bash
# test-preflight-parity.sh — INFRA-5432 (INFRA-1861 slice)
#
# Nightly local-vs-CI parity smoke: (a) actually RUNS `chump preflight`
# end-to-end to confirm the binary itself still executes cleanly, then
# (b) delegates to scripts/ci/test-preflight-ci-parity.sh — the existing
# gate-by-gate diff engine (INFRA-1867) that parses every .github/workflows/
# *.yml `run:` step and asserts each one has a chump-preflight mirror, a
# Tier-D entry in docs/process/CI_GATES_INVENTORY.md, or an allowlist entry
# in scripts/ci/preflight-ci-parity-exceptions.txt.
#
# This script does not reimplement the diff engine — it wraps it, so the
# gate inventory has exactly one source of truth. What it adds on top is
# step (a): proof that `chump preflight` is a real, runnable command, not
# just a source file the diff engine can parse.
#
# Exit 0 — chump preflight ran AND gate parity holds.
# Exit 1 — either chump preflight failed to run, or gate parity drifted
#          (diff report printed by the delegated script).
# Exit 2 — bad environment (missing binary/build, missing files).
#
# Bypass: CHUMP_SKIP_PARITY_CHECK=1 (same escape hatch as the delegated
# script — see scripts/ci/test-preflight-ci-parity.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if [[ "${CHUMP_SKIP_PARITY_CHECK:-0}" == "1" ]]; then
    echo "[preflight-parity] WARN: CHUMP_SKIP_PARITY_CHECK=1 — skipping parity check" >&2
    exit 0
fi

# ── Step 1: resolve a runnable `chump` binary ─────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    else
        echo "[preflight-parity] FAIL: no chump binary on PATH and no target/{debug,release}/chump built — run 'cargo build --bin chump' first" >&2
        exit 2
    fi
fi

# ── Step 2: actually run chump preflight (AC1) ────────────────────────────
echo "[preflight-parity] INFO: running \`$CHUMP_BIN preflight --scope all\`"
if ! "$CHUMP_BIN" preflight --scope all; then
    echo "[preflight-parity] FAIL: chump preflight exited non-zero — local gate set is red" >&2
    exit 1
fi
echo "[preflight-parity] PASS: chump preflight ran clean"

# ── Step 3: delegate gate-by-gate diff (AC2/AC3) ──────────────────────────
DIFF_SCRIPT="$SCRIPT_DIR/test-preflight-ci-parity.sh"
if [[ ! -x "$DIFF_SCRIPT" && ! -f "$DIFF_SCRIPT" ]]; then
    echo "[preflight-parity] FAIL: missing delegate script $DIFF_SCRIPT" >&2
    exit 2
fi

if bash "$DIFF_SCRIPT"; then
    echo "[preflight-parity] PASS: every required CI check has a preflight mirror or an explicit exemption"
    exit 0
else
    rc=$?
    echo "[preflight-parity] FAIL: gate parity drift detected (diff report above)" >&2
    exit "$rc"
fi
