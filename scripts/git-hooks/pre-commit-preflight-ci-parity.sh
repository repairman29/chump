#!/usr/bin/env bash
# pre-commit-preflight-ci-parity.sh — INFRA-2120
#
# Fast-mode wrapper around scripts/ci/test-preflight-ci-parity.sh.
# Fires ONLY when .github/workflows/ci.yml is part of the staged diff;
# otherwise exits 0 immediately (typical commit cost: ~2ms).
#
# When ci.yml IS staged, runs the full parity smoke (~50ms wall-clock)
# and blocks the commit on drift. This is the local pre-commit mirror
# of the same gate that runs at CI time (`preflight-vs-CI parity smoke
# (INFRA-1867)` in .github/workflows/ci.yml fast-checks job).
#
# Promoted to pre-commit by INFRA-2120 because allowlist drift at
# PR-time is the rank-2 CI-rot class (~15% of recent CI failures per
# docs/strategy/CI_REVIEW_2026-05-29.md Lever 4).
#
# Bypass: CHUMP_PREFLIGHT_PARITY_CHECK=0 (silent) OR
#         CHUMP_SKIP_PARITY_CHECK=1 (inherited by the underlying script).

set -e

# Operator escape hatch — silent.
if [ "${CHUMP_PREFLIGHT_PARITY_CHECK:-1}" = "0" ]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Fast-mode gate: only fire when ci.yml is staged.
if ! git diff --cached --name-only | grep -qE '^\.github/workflows/ci\.yml$'; then
    exit 0
fi

PARITY_SCRIPT="$REPO_ROOT/scripts/ci/test-preflight-ci-parity.sh"
# Existence check only — we invoke via `bash $PARITY_SCRIPT`, which works
# regardless of the executable bit. (The script ships without +x in some
# checkouts; the CI step also calls it via `bash scripts/ci/...sh`.)
if [ ! -f "$PARITY_SCRIPT" ]; then
    # Script missing — soft-skip rather than block. The CI step is the backstop.
    exit 0
fi

# Run the full parity smoke. Output goes to stderr so it doesn't pollute
# any stdout-consuming caller. The script writes [ci-parity] PASS/FAIL
# lines + a Summary block of its own.
export CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

if bash "$PARITY_SCRIPT" >&2; then
    exit 0
fi

# Drift detected — give the operator a tight remediation path.
echo "[pre-commit] preflight-vs-CI parity drift detected (INFRA-2120 / INFRA-1867)" >&2
echo "[pre-commit] Your staged ci.yml has a gate that lacks a preflight mirror" >&2
echo "[pre-commit] AND is not on the Tier-D inventory AND is not allowlisted." >&2
echo "[pre-commit] Fix one of:" >&2
echo "[pre-commit]   (a) add a mirror in src/preflight.rs," >&2
echo "[pre-commit]   (b) classify as Tier-D in docs/process/CI_GATES_INVENTORY.md," >&2
echo "[pre-commit]   (c) add an entry to scripts/ci/preflight-ci-parity-exceptions.txt" >&2
echo "[pre-commit] See CLAUDE.md 'preflight-vs-CI parity allowlist' for details." >&2
echo "[pre-commit] Bypass: CHUMP_PREFLIGHT_PARITY_CHECK=0 git commit ..." >&2
exit 1
