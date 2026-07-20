#!/usr/bin/env bash
# test-external-repo-worker-loop.sh — INFRA-2276 smoke test
#
# Verifies `chump onboard --iter-once <repo-path>` picks a safe pickable gap
# from a fixture onboard scan, ships it via `chump improve --apply`, and
# emits the expected ambient events.
#
# We stub `chump improve` via CHUMP_ONBOARD_IMPROVE_BIN-equivalent: since
# onboard.rs spawns std::env::current_exe() directly (not overridable), this
# test instead exercises the no-pickable-gap no-op path (no fixture scan) and
# the auto-pause path (pre-seeded consecutive_failures) — both fully
# deterministic, no network, no agent spawn required.
#
# Runtime target: <90s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/scrub-git-env.sh
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

export CHUMP_REPO_ROOT="$REPO_ROOT"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump"; do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP_BIN" ]] && command -v chump &>/dev/null; then
    CHUMP_BIN="$(command -v chump)"
fi
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[test-external-repo-worker-loop] SKIP: chump binary not found (run cargo build first)" >&2
    exit 0
fi

echo "[test-external-repo-worker-loop] using binary: $CHUMP_BIN"

TMP_REPO="$(mktemp -d /tmp/chump-worker-loop-test-XXXXXX)"
TMP_HOME="$(mktemp -d /tmp/chump-worker-loop-home-XXXXXX)"
HOME_ORIG="$HOME"

cleanup() {
    local exit_code=$?
    export HOME="$HOME_ORIG"
    rm -rf "$TMP_REPO" "$TMP_HOME" 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
        echo "[test-external-repo-worker-loop] FAIL (exit=$exit_code)"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" commit --allow-empty -m "init" -q

export HOME="$TMP_HOME"
# ambient_emit's local_repo_root() checks $CHUMP_REPO before falling back to
# `git rev-parse --show-toplevel` in cwd — point it at the fixture repo so
# emitted events land in a sandbox, not this repo's real ambient.jsonl.
export CHUMP_REPO="$TMP_REPO"
TMP_AMBIENT="$TMP_REPO/.chump-locks/ambient.jsonl"
# operator-recall.sh (invoked by page_operator on auto-pause) honors
# CHUMP_AMBIENT_LOG directly — sandbox it too so its cooldown-file writes and
# its own recall event don't touch this repo's real ambient.jsonl.
export CHUMP_AMBIENT_LOG="$TMP_AMBIENT"

# ── Assertion 1: no scan on disk → no-op iter, exits 0, no crash ──────────
echo "[test-external-repo-worker-loop] [1/3] --iter-once with no scan (no-op path) ..."
"$CHUMP_BIN" onboard --iter-once "$TMP_REPO"
echo "[test-external-repo-worker-loop] [1/3] PASS: --iter-once exited 0 with no scan present"

# ── Assertion 2: loop-state.json created with iter_count_total=1 ─────────
SANITIZED="$(echo "$TMP_REPO" | tr '/' '-' | sed 's/^-//')"
STATE_FILE="$TMP_HOME/.chump/external-repos/$SANITIZED/loop-state.json"
echo "[test-external-repo-worker-loop] [2/3] checking loop-state.json ..."
if [[ ! -f "$STATE_FILE" ]]; then
    echo "[test-external-repo-worker-loop] [2/3] FAIL: $STATE_FILE not written" >&2
    exit 1
fi
if ! grep -q '"iter_count_total": 1' "$STATE_FILE"; then
    echo "[test-external-repo-worker-loop] [2/3] FAIL: iter_count_total not incremented" >&2
    cat "$STATE_FILE" >&2
    exit 1
fi
echo "[test-external-repo-worker-loop] [2/3] PASS: loop-state.json tracks iter_count_total"

# ── Assertion 3: auto-pause fires + emits external_repo_paused when ───────
# consecutive_failures is pre-seeded at the threshold.
echo "[test-external-repo-worker-loop] [3/3] pre-seeding consecutive_failures=3, checking auto-pause ..."
cat > "$STATE_FILE" <<EOF
{"last_iter_ts": null, "consecutive_failures": 3, "iter_count_total": 1, "ship_count_total": 0}
EOF
CHUMP_EXTERNAL_LOOP_MAX_FAILURES=3 "$CHUMP_BIN" onboard --iter-once "$TMP_REPO"
if ! grep -q '"event":"external_repo_paused"' "$TMP_AMBIENT" 2>/dev/null; then
    echo "[test-external-repo-worker-loop] [3/3] FAIL: external_repo_paused not emitted to ambient log" >&2
    cat "$TMP_AMBIENT" >&2 2>/dev/null || true
    exit 1
fi
echo "[test-external-repo-worker-loop] [3/3] PASS: auto-pause emitted external_repo_paused"

echo ""
echo "[test-external-repo-worker-loop] ALL 3 assertions PASSED"
