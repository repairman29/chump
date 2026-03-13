#!/data/data/com.termux/files/usr/bin/bash
# One-time setup on Pixel/Termux: build llama.cpp with Vulkan and download Qwen3-4B Q4_K_M.
# Run in Termux after copying chump/start-companion/.env to ~/chump.
# Usage: bash /sdcard/Download/chump/setup-llama-on-termux.sh
#        or bash ~/storage/downloads/chump/setup-llama-on-termux.sh

set -e

echo "=== llama.cpp + model setup for Mabel ==="

# 1. Dependencies: shaderc (glslc for Vulkan), libandroid-spawn (spawn.h for full build including tests)
echo "Installing packages (Vulkan + full build deps)..."
pkg update -y
pkg install -y cmake clang git make vulkan-headers vulkan-loader-android shaderc libandroid-spawn

# 2. llama.cpp
if [[ ! -f "$HOME/llama.cpp/build/bin/llama-server" ]]; then
  echo "Cloning and building llama.cpp (Vulkan)..."
  [[ -d "$HOME/llama.cpp" ]] || git clone https://github.com/ggerganov/llama.cpp "$HOME/llama.cpp"
  cd "$HOME/llama.cpp"
  cmake -B build -DGGML_VULKAN=ON
  cmake --build build --config Release -j$(nproc)
  echo "llama-server built."
else
  echo "llama-server already present."
fi

# 3. Model (curl avoids pip/huggingface-hub which can fail on Termux)
mkdir -p "$HOME/models"
MODEL="$HOME/models/Qwen3-4B-Q4_K_M.gguf"
if [[ ! -f "$MODEL" ]]; then
  echo "Downloading Qwen3-4B Q4_K_M (~2.5GB, may take a while)..."
  curl -L -o "$MODEL" \
    "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
  echo "Model downloaded."
else
  echo "Model already present: $MODEL"
fi

echo ""
echo "Setup done. Start Mabel with:"
echo "  cd ~/chump && ./start-companion.sh"
echo "(Use tmux or nohup to keep it running.)"
