#!/usr/bin/env bash
# eval-reflection-ab.sh — EVAL-008: A/B accuracy comparison between
# reflect_heuristic (heuristic keyword matching) and reflect_via_provider
# (LLM-assisted) on a 25-episode labeled ground-truth dataset.
#
# Usage:
#   scripts/eval/eval-reflection-ab.sh [--with-llm] [--episodes <path>]
#                                  [--chump-bin ./target/release/chump]
#
# --with-llm       Enable the LLM leg. Fails loud if no endpoint is reachable
#                  ($OPENAI_API_BASE or Ollama :11434 or MLX :8000).
#                  Requires CHUMP_REFLECTION_LLM=1 to activate the provider
#                  branch inside chump.
#
# --episodes <path>  Override the episode JSON path
#                    (default: scripts/eval-reflection-ab/episodes.json).
#
# --chump-bin <path>  Path to the chump binary
#                    (default: ./target/release/chump).
#
# Exit codes:
#   0   Heuristic-only run completed, or LLM variant ≥15% more accurate.
#   1   LLM variant present but accuracy delta below the 15% threshold.
#   2   Configuration error (no binary, no episodes file, no provider).
#
# EVAL-008 acceptance:
#   Loads ≥20 seed episodes with labeled ErrorPattern, runs both
#   reflect_heuristic and reflect_via_provider against each, reports
#   per-pattern confusion matrix + overall accuracy. A/B gate: LLM
#   variant must classify ≥15% more patterns correctly. Fail-loud if
#   provider unavailable (no silent heuristic fallback during A/B runs).

set -euo pipefail

WITH_LLM=0
CHUMP_BIN="./target/release/chump"
EPISODES_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-llm)     WITH_LLM=1; shift;;
    --episodes)     EPISODES_PATH="$2"; shift 2;;
    --chump-bin)    CHUMP_BIN="$2"; shift 2;;
    -h|--help)      sed -n '2,28p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ── Locate repo root ──────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ── Binary check ─────────────────────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "[eval-reflection-ab] Building chump first (cargo build --release) …"
  cargo build --release --bin chump 2>&1 | tail -5
  if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "ERROR: $CHUMP_BIN not found after build." >&2
    exit 2
  fi
fi

# ── Probe LLM endpoint (when --with-llm) ─────────────────────────────────────
probe_endpoint() {
  curl -sf --connect-timeout 2 "$1/models" >/dev/null 2>&1
}

if [[ $WITH_LLM -eq 1 ]]; then
  if [[ -z "${OPENAI_API_BASE:-}" ]]; then
    if probe_endpoint "http://127.0.0.1:11434/v1"; then
      export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
      export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
      export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:7b}"
    elif probe_endpoint "http://127.0.0.1:8000/v1"; then
      export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
      export OPENAI_API_KEY="${OPENAI_API_KEY:-mlx}"
      export OPENAI_MODEL="${OPENAI_MODEL:-mlx-community/Qwen3-14B-4bit}"
    else
      echo "ERROR: --with-llm set but no LLM endpoint reachable. Start Ollama (:11434) or MLX (:8000)." >&2
      exit 2
    fi
  fi
  export CHUMP_REFLECTION_AB_WITH_LLM=1
  export CHUMP_REFLECTION_LLM=1
  echo "[eval-reflection-ab] LLM leg: $OPENAI_MODEL @ $OPENAI_API_BASE"
else
  echo "[eval-reflection-ab] Heuristic-only run (pass --with-llm to include LLM leg)"
fi

# ── Run ───────────────────────────────────────────────────────────────────────
REFLECT_AB_ARGS=("--reflect-ab")
if [[ -n "$EPISODES_PATH" ]]; then
  REFLECT_AB_ARGS+=("--reflect-ab-episodes" "$EPISODES_PATH")
fi

exec "$CHUMP_BIN" "${REFLECT_AB_ARGS[@]}"
