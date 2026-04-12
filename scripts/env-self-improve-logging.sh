#!/usr/bin/env bash
# Source from repo root for a self-improve / debug session:
#   source ./scripts/env-self-improve-logging.sh
#
# Does not override RUST_LOG if you already exported it.

export RUST_LOG="${RUST_LOG:-warn,rust_agent::agent_loop=debug,rust_agent::provider_cascade=debug,rust_agent::local_openai=debug,rust_agent::task_executor=info,rust_agent::web_server=info,axonerai=info}"

export CHUMP_LOG_TIMING="${CHUMP_LOG_TIMING:-1}"
export CHUMP_LOG_STRUCTURED="${CHUMP_LOG_STRUCTURED:-1}"
export CHUMP_TRACING_FILE="${CHUMP_TRACING_FILE:-1}"

# Uncomment as needed:
# export CHUMP_TRACING_JSON_STDERR=1
# export CHUMP_WEB_HTTP_TRACE=1
