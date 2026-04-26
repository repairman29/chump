#!/usr/bin/env bash
# Vector 3: run one automated "battle" against tests/mock_projects/broken_rust_app, record baselines.
#
# Prerequisites: local OpenAI-compatible server (e.g. Ollama) per .env; Chump built (--release recommended).
# Usage:
#   ./scripts/ci/run-battle-sim-suite.sh
#   CHUMP_BIN=/path/to/chump ./scripts/ci/run-battle-sim-suite.sh
#   BATTLE_SIM_TIMEOUT_SECS=600 ./scripts/ci/run-battle-sim-suite.sh
#
# Env (optional): CHUMP_AUTO_APPROVE_* already supported by Chump for non-interactive tool runs.
# Sets: CHUMP_BATTLE_BENCHMARK=1, CHUMP_BATTLE_PRINT_METRICS=1, CHUMP_REPO=temp copy of mock project.
# Appends one line per run to logs/battle_baselines.txt (JSON after ISO timestamp).

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"

_prior_openai_base="${OPENAI_API_BASE:-}"
_prior_openai_model="${OPENAI_MODEL:-}"
_prior_openai_key="${OPENAI_API_KEY:-}"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi
# Caller / CI may export these after .env would have set them; keep explicit overrides.
[[ -n "$_prior_openai_base" ]] && export OPENAI_API_BASE="$_prior_openai_base"
[[ -n "$_prior_openai_model" ]] && export OPENAI_MODEL="$_prior_openai_model"
[[ -n "$_prior_openai_key" ]] && export OPENAI_API_KEY="$_prior_openai_key"

# GitHub Actions / agents: no local LLM by default — fixing broken_rust_app requires a model.
if [[ "${BATTLE_SIM_SKIP_IF_NO_LLM:-}" == "1" ]]; then
  if [[ -z "${OPENAI_API_BASE:-}" ]] && [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[battle-sim] skip: BATTLE_SIM_SKIP_IF_NO_LLM and no OPENAI_API_BASE / OPENROUTER_API_KEY" >&2
    exit 0
  fi
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
export CHUMP_AUTO_APPROVE_TOOLS="${CHUMP_AUTO_APPROVE_TOOLS:-read_file,write_file,patch_file,run_cli,list_dir,git,cargo,run_test}"

PROMPT='The project in this directory is failing to build and test. Identify the issues, fix the code, and ensure `cargo test` passes. Output only DONE (all caps) when finished.'

CHUMP_BIN="${CHUMP_BIN:-$ROOT/target/release/chump}"
# CI runs `cargo test` + debug `chump` for E2E; avoid a second full `cargo run --release` compile.
if [[ "${BATTLE_SIM_SKIP_CARGO:-}" == "1" ]] && [[ ! -x "$CHUMP_BIN" ]] && [[ -x "$ROOT/target/debug/chump" ]]; then
  CHUMP_BIN="$ROOT/target/debug/chump"
  echo "[battle-sim] BATTLE_SIM_SKIP_CARGO: using $CHUMP_BIN" >&2
fi
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
