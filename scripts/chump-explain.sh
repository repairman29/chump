#!/usr/bin/env bash
# Send a proactive "I'm up and ready" DM to the configured user (CHUMP_READY_DM_USER_ID).
# Same idea as mabel-explain.sh but for Chump (Mac). Run from Chump repo root.
# Requires .env with DISCORD_TOKEN and CHUMP_READY_DM_USER_ID.
# Usage: ./scripts/chump-explain.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

msg="I'm **Chump**, your Mac Discord bot.

I'm running on this Mac with access to the repo, web search (Tavily), and the model on 8000 (or Ollama). You can DM me or @mention me in a server; I'll use memory to remember what we discuss.

Right now I'm up and ready to chat."

# Prefer repo binary, then PATH
BIN="$ROOT/target/release/rust-agent"
[[ -x "$BIN" ]] || BIN="rust-agent"
echo "$msg" | "$BIN" --notify
