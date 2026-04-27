#!/usr/bin/env bash
# Source from repo root for a self-improve / debug session:
#   source ./scripts/dev/env-self-improve-logging.sh
#
# Does not override RUST_LOG if you already exported it.

export RUST_LOG="${RUST_LOG:-warn,chump::agent_loop=debug,chump::provider_cascade=debug,chump::local_openai=debug,chump::task_executor=info,chump::web_server=info,axonerai=info}"

export CHUMP_LOG_TIMING="${CHUMP_LOG_TIMING:-1}"
export CHUMP_LOG_STRUCTURED="${CHUMP_LOG_STRUCTURED:-1}"
export CHUMP_TRACING_FILE="${CHUMP_TRACING_FILE:-1}"

# Uncomment as needed:
# export CHUMP_TRACING_JSON_STDERR=1
# export CHUMP_WEB_HTTP_TRACE=1
