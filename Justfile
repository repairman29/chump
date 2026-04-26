# Chump — task runner (thin wrapper around existing scripts)
# Install just: https://github.com/casey/just

set dotenv-load
set shell := ["bash", "-c"]

# List available recipes
default:
    @just --list

# ──────────────────────────────────────────────
# GETTING STARTED
# ──────────────────────────────────────────────

# One-time local setup: .env, Ollama check, run instructions
setup:
    ./scripts/setup/setup-local.sh

# ──────────────────────────────────────────────
# RUN
# ──────────────────────────────────────────────

# Poll /v1/models until HTTP 200 — does not start vLLM (use restart-vllm-if-down first)
wait-vllm:
    ./scripts/setup/wait-for-vllm.sh

# Start the Chump Web PWA (ensures vLLM-MLX is up if needed)
web:
    ./run-web.sh

# Run Chump CLI against local Ollama (e.g. just cli "What is 2+2?")
cli *ARGS:
    ./run-local.sh -- {{ARGS}}

# Start the Discord bot (loads DISCORD_TOKEN from .env)
discord:
    ./run-discord.sh

# ──────────────────────────────────────────────
# TEST
# ──────────────────────────────────────────────

# Run unit tests
test:
    cargo test --bin chump

# Unified preflight checks (requires web server running)
preflight:
    ./scripts/ci/chump-preflight.sh

# Non-interactive external golden-path verification
verify:
    ./scripts/ci/verify-external-golden-path.sh

# ──────────────────────────────────────────────
# QUALITY
# ──────────────────────────────────────────────

# Type-check without building
check:
    cargo check --bin chump

# Lint with clippy (deny warnings)
lint:
    cargo clippy --workspace --all-targets -- -D warnings

# Check formatting (no changes)
fmt:
    cargo fmt --all -- --check

# ──────────────────────────────────────────────
# UTILITIES
# ──────────────────────────────────────────────

# Quick health check against local web server
health:
    @curl -s http://127.0.0.1:3000/api/health | python3 -m json.tool

# Build debug binary
build:
    cargo build --bin chump

# Build optimised release binary
build-release:
    cargo build --release --bin chump

# Remove build artefacts
clean:
    cargo clean

# ──────────────────────────────────────────────
# DOGFOOD (Chump works on itself)
# ──────────────────────────────────────────────

# Run Chump on its own codebase with a prompt (e.g. just dogfood "fix clippy warning in src/foo.rs")
dogfood *PROMPT:
    ./scripts/eval/dogfood-run.sh {{PROMPT}}

# Run Chump autonomy_once on its own task queue
dogfood-auto:
    ./scripts/eval/dogfood-run.sh

# Fixed T1.1 acceptance probe (set model tag, e.g. qwen2.5:14b); see docs/DOGFOOD_T1_1_MODEL_PROBE.md
dogfood-t1-1-probe MODEL:
    OPENAI_MODEL={{MODEL}} ./scripts/eval/dogfood-t1-1-probe.sh
