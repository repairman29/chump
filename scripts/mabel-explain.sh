#!/usr/bin/env bash
# Send a "what I'm up to" DM to the configured user (CHUMP_READY_DM_USER_ID).
# Run from Chump repo root (Pixel or Mac). Requires .env with DISCORD_TOKEN and CHUMP_READY_DM_USER_ID.
# Usage: ./scripts/mabel-explain.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

msg="I'm **Mabel**, your Pixel companion and farm monitor.

I run on the Pixel (Termux) and watch the Mac stack over Tailscale: Ollama, model API, embed server, Discord bot, and heartbeat logs. When something's wrong I try to fix it (e.g. restart vLLM); if it stays broken I DM you.

Right now I'm ready and watching. Ask me \"what are you up to?\" in Discord anytime to get this in DMs."

# Optional: append last farmer run from log
if [[ -f "$ROOT/logs/mabel-farmer.log" ]]; then
  last=$(tail -1 "$ROOT/logs/mabel-farmer.log" 2>/dev/null || true)
  if [[ -n "$last" ]]; then
    msg="$msg

Last farmer check: $last"
  fi
fi

# Prefer repo binary (Pixel: chump, Mac: target/release/chump), then PATH
BIN=""
if [[ -x "$ROOT/chump" ]]; then
  BIN="$ROOT/chump"
elif [[ -x "$ROOT/target/release/chump" ]]; then
  BIN="$ROOT/target/release/chump"
else
  BIN="chump"
fi
echo "$msg" | "$BIN" --notify
