#!/data/data/com.termux/files/usr/bin/bash
# Switch Mabel's local model to Qwen3-4B Q4_K_M. Run on the Pixel (Termux).
# Downloads the GGUF if missing, stops llama-server and bot, starts companion with new model.
#
# Usage: bash ~/chump/scripts/setup/switch-mabel-to-qwen3-4b.sh
# From Mac: ssh -p 8022 termux 'cd ~/chump && bash scripts/setup/switch-mabel-to-qwen3-4b.sh'

set -e
cd ~/chump
MODEL="$HOME/models/Qwen3-4B-Q4_K_M.gguf"
URL="https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"

echo "=== Switch Mabel to Qwen3-4B Q4_K_M ==="

# 1. Download model if missing
mkdir -p "$HOME/models"
if [[ ! -f "$MODEL" ]]; then
  echo "Downloading Qwen3-4B Q4_K_M (~2.5GB)..."
  curl -L -o "$MODEL" "$URL"
  echo "Downloaded."
else
  echo "Model already present: $MODEL"
fi

# 2. Ensure start-companion uses new default (CHUMP_MODEL unset => Qwen3-4B path)
# Remove any old CHUMP_MODEL from .env so default is used
if [[ -f .env ]] && grep -q "^CHUMP_MODEL=.*qwen2.5-3b" .env 2>/dev/null; then
  sed -i '/^CHUMP_MODEL=.*qwen2.5-3b/d' .env
  echo "Cleared old CHUMP_MODEL from .env"
fi

# 3. Stop existing server and bot
echo "Stopping llama-server and Chump bot..."
pkill -f "llama-server" 2>/dev/null || true
pkill -f "chump.*--discord" 2>/dev/null || true
sleep 3

# 4. Start companion (server + bot)
echo "Starting companion with Qwen3-4B..."
nohup ./start-companion.sh >> logs/companion.log 2>&1 &
echo "Started. Check: tail -f ~/chump/logs/companion.log"
