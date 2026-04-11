#!/usr/bin/env bash
# Vector 3: run one automated "battle" against tests/mock_projects/broken_rust_app, record baselines.
#
# Prerequisites: local OpenAI-compatible server (e.g. Ollama) per .env; Chump built (--release recommended).
# Usage:
#   ./scripts/run-battle-sim-suite.sh
#   CHUMP_BIN=/path/to/chump ./scripts/run-battle-sim-suite.sh
#   BATTLE_SIM_TIMEOUT_SECS=600 ./scripts/run-battle-sim-suite.sh
#
# Env (optional): CHUMP_AUTO_APPROVE_* already supported by Chump for non-interactive tool runs.
# Sets: CHUMP_BATTLE_BENCHMARK=1, CHUMP_BATTLE_PRINT_METRICS=1, CHUMP_REPO=temp copy of mock project.
# Appends one line per run to logs/battle_baselines.txt (JSON after ISO timestamp).

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chump_battle_XXXXXX")"
cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

MOCK_SRC="$ROOT/tests/mock_projects/broken_rust_app"
if [[ ! -d "$MOCK_SRC" ]]; then
  echo "error: missing $MOCK_SRC" >&2
  exit 1
fi
cp -R "$MOCK_SRC/"* "$WORKDIR/"
export CHUMP_REPO="$WORKDIR"

export CHUMP_BATTLE_BENCHMARK=1
export CHUMP_BATTLE_LABEL="${CHUMP_BATTLE_LABEL:-broken_rust_app}"
export CHUMP_BATTLE_PRINT_METRICS=1
# Non-interactive defaults for scripted sim (expand as needed).
export CHUMP_AUTO_APPROVE_LOW_RISK="${CHUMP_AUTO_APPROVE_LOW_RISK:-1}"
export CHUMP_AUTO_APPROVE_TOOLS="${CHUMP_AUTO_APPROVE_TOOLS:-read_file,write_file,edit_file,run_cli,list_dir,git,cargo,run_test}"

PROMPT='The project in this directory is failing to build and test. Identify the issues, fix the code, and ensure `cargo test` passes. Output only DONE (all caps) when finished.'

CHUMP_BIN="${CHUMP_BIN:-$ROOT/target/release/chump}"
TIMEOUT_SECS="${BATTLE_SIM_TIMEOUT_SECS:-900}"

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
OUT_FILE="$ROOT/logs/battle-sim-last-$$.log"
set +e
if [[ -x "$CHUMP_BIN" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" "$CHUMP_BIN" --chump "$PROMPT" >"$OUT_FILE" 2>&1
  else
    "$CHUMP_BIN" --chump "$PROMPT" >"$OUT_FILE" 2>&1
  fi
else
  echo "[battle-sim] CHUMP_BIN not executable; using cargo run --release (slower)..." >&2
  if command -v timeout >/dev/null 2>&1; then
    (cd "$ROOT" && timeout "$TIMEOUT_SECS" cargo run -q --release --bin chump -- --chump "$PROMPT") >"$OUT_FILE" 2>&1
  else
    (cd "$ROOT" && cargo run -q --release --bin chump -- --chump "$PROMPT") >"$OUT_FILE" 2>&1
  fi
fi
RC=$?
set -e

JSON_LINE="$(grep 'CHUMP_BATTLE_BASELINE_JSON:' "$OUT_FILE" | tail -n 1 | sed 's/^.*CHUMP_BATTLE_BASELINE_JSON://' || true)"
if [[ -z "$JSON_LINE" ]]; then
  JSON_LINE="{\"error\":\"no_baseline_json\",\"exit_code\":$RC,\"note\":\"set CHUMP_BATTLE_PRINT_METRICS=1 and ensure CHUMP_BATTLE_BENCHMARK=1; see $OUT_FILE\"}"
fi

echo "$TS $JSON_LINE" >>"$ROOT/logs/battle_baselines.txt"
echo "[battle-sim] wrote baseline line to logs/battle_baselines.txt (exit $RC)"
echo "$JSON_LINE"
exit "$RC"
