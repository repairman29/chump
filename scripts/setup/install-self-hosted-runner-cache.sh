#!/usr/bin/env bash
# install-self-hosted-runner-cache.sh — INFRA-1540 (deliver INFRA-1534 AC #4)
#
# Provision the persistent cache directory on a self-hosted runner. Run ONCE
# per runner machine after the actions-runner agent itself is installed.
#
# What this script does:
#   1. Creates /var/cache/chump-runner/cargo-target (writable by the runner user)
#   2. Writes a small env file the runner agent sources so $CARGO_TARGET_DIR
#      points at the shared cache
#   3. Reports the cache size baseline so subsequent runs can claim hits
#
# Why it matters:
#   Without a persistent target-dir, every CI run on a self-hosted runner
#   cold-rebuilds the full Rust workspace (~5-10 min). With it, incremental
#   builds finish in 30-90s. This is the 5-10x throughput win INFRA-1534
#   AC #4 promised but never delivered.

set -euo pipefail

# Default to user-writable cache root so no-sudo automation works. Override
# via CHUMP_RUNNER_CACHE_ROOT to use /var/cache for system-wide setups.
# Auto-fallback: if the requested root needs sudo and we're non-interactive,
# fall back to $HOME/.cache/chump-runner.
DEFAULT_ROOT="${HOME}/.cache/chump-runner"
CACHE_ROOT="${CHUMP_RUNNER_CACHE_ROOT:-$DEFAULT_ROOT}"
TARGET_DIR="${CACHE_ROOT}/cargo-target"
ENV_FILE="${CACHE_ROOT}/runner.env"

RUNNER_USER="${RUNNER_USER:-$(whoami)}"

echo "[chump-runner-cache] root        : $CACHE_ROOT"
echo "[chump-runner-cache] target_dir  : $TARGET_DIR"
echo "[chump-runner-cache] env_file    : $ENV_FILE"
echo "[chump-runner-cache] runner_user : $RUNNER_USER"

# 1. Provision the directory tree (no sudo unless explicitly system-wide).
if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
    if [[ "$CACHE_ROOT" == /var/cache/* || "$CACHE_ROOT" == /usr/* ]]; then
        # System path — try sudo (will fail non-interactively).
        if sudo -n true 2>/dev/null; then
            sudo mkdir -p "$TARGET_DIR"
            sudo chown -R "$RUNNER_USER" "$CACHE_ROOT"
        else
            echo "[chump-runner-cache] WARN: cannot write $CACHE_ROOT (sudo would be interactive)"
            echo "[chump-runner-cache]       falling back to $DEFAULT_ROOT"
            CACHE_ROOT="$DEFAULT_ROOT"
            TARGET_DIR="${CACHE_ROOT}/cargo-target"
            ENV_FILE="${CACHE_ROOT}/runner.env"
            mkdir -p "$TARGET_DIR"
        fi
    else
        # Non-system path that we still can't write — hard error.
        echo "[chump-runner-cache] FATAL: cannot mkdir $TARGET_DIR" >&2
        exit 1
    fi
fi

# 2. Write env file the runner sources.
cat > "$ENV_FILE" <<EOF
# INFRA-1540: source me from the actions-runner service environment so every
# job on this runner shares the same cargo target dir.
export CARGO_TARGET_DIR="$TARGET_DIR"
export CHUMP_RUNNER_CACHE_ROOT="$CACHE_ROOT"
EOF

echo "[chump-runner-cache] wrote $ENV_FILE"
echo "[chump-runner-cache] add this line to your actions-runner .env (or launchd EnvironmentVariables):"
echo "      source $ENV_FILE"
echo

# 3. Baseline metrics.
size_bytes=$(du -sk "$TARGET_DIR" 2>/dev/null | awk '{print $1*1024}')
size_human=$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')
echo "[chump-runner-cache] baseline cache size: $size_human ($size_bytes bytes)"
echo "[chump-runner-cache] ready."
