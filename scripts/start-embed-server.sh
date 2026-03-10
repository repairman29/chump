#!/usr/bin/env sh
# Start the local Chump embedding server (sentence-transformers). Keeps running; run in a separate terminal or under launchd.
# Requires: pip install -r scripts/requirements-embed.txt (use a venv on Homebrew Python — see README).
# Env: CHUMP_EMBED_PORT (default 18765), CHUMP_EMBED_MODEL (default all-MiniLM-L6-v2)

cd "$(dirname "$0")/.." || exit 1
PORT="${CHUMP_EMBED_PORT:-18765}"
export CHUMP_EMBED_PORT="$PORT"
# Prefer venv Python when present (Homebrew Python is externally-managed and blocks system pip).
if [ -x ".venv/bin/python3" ]; then
  PYTHON=".venv/bin/python3"
else
  PYTHON="python3"
fi
echo "Starting Chump embed server on port $PORT (model: ${CHUMP_EMBED_MODEL:-sentence-transformers/all-MiniLM-L6-v2})"
exec "$PYTHON" scripts/embed_server.py --port "$PORT"
