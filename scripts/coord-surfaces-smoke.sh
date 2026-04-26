#!/usr/bin/env bash
# INFRA-032: verify gap coordination + chump --briefing from repo root without API keys.
# Uses an isolated CHUMP_LOCK_DIR so we do not touch the real .chump-locks/.

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Default to a stable open gap. Pass another open GAP-ID if needed.
# RESEARCH-018 closed 2026-04-23; switched to RESEARCH-020 (P1, ecological-fixture work, long-running).
GAP_ID="${1:-RESEARCH-020}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_LOCK_DIR="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_SESSION_ID="coord-surfaces-smoke-$$"

if [[ ! -x "$ROOT/target/debug/chump" ]]; then
  echo "coord-surfaces-smoke: building target/debug/chump …" >&2
  cargo build -q --bin chump
fi

echo "[coord-surfaces-smoke] gap-preflight $GAP_ID …" >&2
bash scripts/gap-preflight.sh "$GAP_ID"

echo "[coord-surfaces-smoke] gap-claim $GAP_ID …" >&2
bash scripts/gap-claim.sh "$GAP_ID" --paths docs/process/CURSOR_CLAUDE_COORDINATION.md

echo "[coord-surfaces-smoke] musher --status (first lines) …" >&2
bash scripts/musher.sh --status 2>/dev/null | head -25 || true

echo "[coord-surfaces-smoke] chump --briefing $GAP_ID …" >&2
"$ROOT/target/debug/chump" --briefing "$GAP_ID" >/dev/null

echo "ok: coord-surfaces-smoke passed for $GAP_ID"
