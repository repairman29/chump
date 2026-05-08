#!/usr/bin/env bash
# INFRA-032: verify gap coordination + chump --briefing from repo root without API keys.
# Uses an isolated CHUMP_LOCK_DIR so we do not touch the real .chump-locks/.

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# INFRA-499: post-INFRA-498 the per-file YAMLs are gone, so CI's
# state.db starts empty (no docs/gaps/* to seed it). Pre-INFRA-499
# this test used a hardcoded RESEARCH-020 fixture; that gap doesn't
# exist in CI's empty state.db so preflight fails. Reserve a fresh
# gap on-the-fly to make the test self-contained.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_LOCK_DIR="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_SESSION_ID="coord-surfaces-smoke-$$"
# Smoke test creates an ephemeral gap — skip guards that check for real remote
# branches (INFRA-573) or open PRs (INFRA-273) to avoid collisions with live work.
export CHUMP_ALLOW_REUSE_BRANCH=1
export CHUMP_PREFLIGHT_PR_CHECK=0

if [[ ! -x "$ROOT/target/debug/chump" ]]; then
  echo "coord-surfaces-smoke: building target/debug/chump …" >&2
  cargo build -q --bin chump
fi

# INFRA-499: caller may still pass an explicit ID for back-compat.
# When none given, reserve one and use it (self-contained fixture).
if [[ -n "${1:-}" ]]; then
    GAP_ID="$1"
else
    echo "[coord-surfaces-smoke] reserving fresh gap for self-contained test …" >&2
    GAP_ID=$("$ROOT/target/debug/chump" gap reserve --domain SMOKE --priority P3 --effort xs \
        --title "coord-surfaces-smoke fixture (auto-clean)" 2>&1 | tail -1)
    echo "[coord-surfaces-smoke] reserved $GAP_ID" >&2
fi

echo "[coord-surfaces-smoke] gap-preflight $GAP_ID …" >&2
bash scripts/coord/gap-preflight.sh "$GAP_ID"

echo "[coord-surfaces-smoke] gap-claim $GAP_ID …" >&2
bash scripts/coord/gap-claim.sh "$GAP_ID" --paths docs/process/CURSOR_CLAUDE_COORDINATION.md

echo "[coord-surfaces-smoke] musher --status (first lines) …" >&2
bash scripts/coord/musher.sh --status 2>/dev/null | head -25 || true

echo "[coord-surfaces-smoke] chump --briefing $GAP_ID …" >&2
"$ROOT/target/debug/chump" --briefing "$GAP_ID" >/dev/null

echo "ok: coord-surfaces-smoke passed for $GAP_ID"
