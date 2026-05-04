#!/usr/bin/env bash
# test-spike-isolation.sh — INFRA-430 regression test.
#
# Every script under scripts/spike/ that invokes the chump CLI MUST
# isolate writes to a tempdir via CHUMP_REPO (and ideally CHUMP_HOME).
# Pre-fix: scripts/spike/measure-sqlite-contention.sh used
# CHUMP_REPO_ROOT (a no-op env var the chump binary doesn't honor),
# silently leaking 302 SPIKE-* fixture rows into production state.db
# on 2026-05-03 (cleanup gap: INFRA-428).
#
# Static-grep CI guard:
#   For each scripts/spike/*.sh that calls chump:
#     - MUST set CHUMP_REPO to a non-production path
#     - MUST NOT use CHUMP_REPO_ROOT as the only isolation env (which is a no-op)
#     - SHOULD include the INFRA-430 hard-guard (refuse if effective repo == prod)
#
# Bypass: CHUMP_SKIP_SPIKE_ISOLATION_CHECK=1 (for legitimate scripts that
# don't write to the gap store, e.g. read-only measurement)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPIKE_DIR="$REPO_ROOT/scripts/spike"

if [[ ! -d "$SPIKE_DIR" ]]; then
    echo "[SKIP] no scripts/spike/ directory yet"
    exit 0
fi

shopt -s nullglob
spike_scripts=("$SPIKE_DIR"/*.sh)
if [[ ${#spike_scripts[@]} -eq 0 ]]; then
    echo "[SKIP] scripts/spike/ has no .sh files"
    exit 0
fi

failures=0

for script in "${spike_scripts[@]}"; do
    name=$(basename "$script")

    # Skip scripts that don't invoke chump at all (read-only measurement).
    if ! grep -qE 'chump[ _]gap|"\$CHUMP_BIN"|chump --' "$script"; then
        echo "[skip] $name: doesn't invoke chump"
        continue
    fi

    # Skip if explicitly opted out.
    if grep -q 'CHUMP_SKIP_SPIKE_ISOLATION_CHECK' "$script"; then
        echo "[skip] $name: declares CHUMP_SKIP_SPIKE_ISOLATION_CHECK opt-out"
        continue
    fi

    echo "Checking $name..."

    # Rule 1: must export CHUMP_REPO somewhere
    if ! grep -qE 'export CHUMP_REPO=|CHUMP_REPO=.*[a-zA-Z_-]+ "?\$CHUMP_BIN"?' "$script"; then
        echo "  [FAIL] $name: doesn't set CHUMP_REPO before invoking chump"
        echo "         (chump only honors CHUMP_REPO and CHUMP_HOME — see src/repo_path.rs)"
        failures=$((failures + 1))
        continue
    fi

    # Rule 2: warn (not fail) if CHUMP_REPO_ROOT is the ONLY isolation env
    if grep -q 'CHUMP_REPO_ROOT' "$script" && ! grep -qE 'export CHUMP_REPO=' "$script"; then
        echo "  [FAIL] $name: only sets CHUMP_REPO_ROOT (NOT honored by chump binary)"
        echo "         This was the INFRA-428 root cause — silent fixture leak."
        failures=$((failures + 1))
        continue
    fi

    # Rule 3: should include the INFRA-430 hard-guard (defense in depth)
    if ! grep -q 'INFRA-430' "$script"; then
        echo "  [WARN] $name: missing INFRA-430 hard-guard reference"
        echo "         Recommended: refuse to run if chump config repo_root resolves under \$REPO_ROOT"
        # Warn only, don't fail — the env-var fix above is sufficient.
    fi

    echo "  [PASS] $name"
done

echo ""
if [[ $failures -gt 0 ]]; then
    echo "[FAIL] $failures spike script(s) lack proper isolation"
    exit 1
fi
echo "[OK] all spike scripts properly isolated"
