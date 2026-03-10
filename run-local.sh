#!/usr/bin/env bash
# Run rust-agent against local Ollama (no paid API).
# Requires: Ollama installed and running, and a model pulled (e.g. ollama pull llama3.2:1b).

export OPENAI_API_BASE=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export OPENAI_MODEL="${OPENAI_MODEL:-llama3.2:1b}"

exec cargo run -- "$@"
