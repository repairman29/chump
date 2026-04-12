#!/usr/bin/env bash
# Source for a tuned in-process mistral session (web UX + measurement).
#   source ./scripts/env-mistralrs-power.sh
#
# Does not set CHUMP_INFERENCE_BACKEND or CHUMP_MISTRALRS_MODEL — set those in .env.
# After sourcing, run mistralrs tune and set CHUMP_MISTRALRS_ISQ_BITS to match; see
# docs/MISTRALRS_AGENT_POWER_PATH.md §4
# Intentionally no `set -e` — safe to `source` from an interactive shell.

export CHUMP_MISTRALRS_STREAM_TEXT_DELTAS="${CHUMP_MISTRALRS_STREAM_TEXT_DELTAS:-1}"
export CHUMP_MISTRALRS_PAGED_ATTN="${CHUMP_MISTRALRS_PAGED_ATTN:-1}"
export CHUMP_MISTRALRS_THROUGHPUT_LOGGING="${CHUMP_MISTRALRS_THROUGHPUT_LOGGING:-1}"

# ISQ: override after `mistralrs tune` (2–8); default 8 if unset is upstream-style auto
export CHUMP_MISTRALRS_ISQ_BITS="${CHUMP_MISTRALRS_ISQ_BITS:-8}"

# Prefix cache: 16 is mistral.rs default; use off/none/disable to experiment
export CHUMP_MISTRALRS_PREFIX_CACHE_N="${CHUMP_MISTRALRS_PREFIX_CACHE_N:-16}"
