# Chump Android Companion — Pixel 8 Pro via Termux

Run the Chump binary as **Mabel** on a Pixel 8 Pro (or similar aarch64 Android device) using Termux, cross-compiled from Mac, with llama.cpp + Vulkan for local inference.

**Mabel vs Chump:** Mabel runs on the Pixel with **her own Discord Application and token**; Chump runs on the MacBook with his. Same binary, different config. On the Pixel, `~/chump/.env` must use **Mabel’s** bot token (from the Discord Developer Portal app you create for Mabel). On the Mac, Chump uses Chump’s app and token. Do not use Chump’s token on the Pixel.

**Why this works:** The Chump binary has no macOS-specific code in the agent path. The Discord bot, tools, SQLite memory, sessions, and audit log are all platform-agnostic. The only Mac-specific pieces are vLLM-MLX (inference) and ChumpMenu (SwiftUI) — both replaced on the Pixel by llama.cpp and Termux.

---

## Native terminal vs Termux

| | Native "Run Linux terminal on Android" | Termux |
|---|----------------------------------------|--------|
| **What it is** | Debian VM (AVF) launched from Settings; `/mnt/shared` = device Downloads | Proot Linux env; own package manager (`pkg`), SSH on 8022 |
| **Background / 24/7** | VM likely **suspends when the Terminal app is closed** — not suitable for a persistent Discord bot | **Stays running** with `termux-wake-lock`; can run Chump + llama-server in background |
| **GPU / Vulkan** | No GPU passthrough to the VM → llama.cpp would be **CPU-only** (slow) | **Vulkan** works; build llama.cpp with `-DGGML_VULKAN=ON` for Tensor G3 |
| **Deploy** | Push binary/scripts via **ADB** to a path visible in the VM (e.g. Downloads → `/mnt/shared`), then run commands inside the Terminal app UI | **SSH** (port 8022): `scp`/`rsync` from Mac; `scripts/build-android.sh --deploy user@pixel-ip` |
| **When to use** | One-off runs, experiments, or if you prefer not to install Termux | **Recommended** for a real "Chump on Pixel" companion that runs 24/7 with GPU |

**Recommendation:** For a Discord bot that stays up and uses the GPU, **use Termux**. The native terminal is viable only for short-lived or CPU-only runs and has no built-in SSH. See [Native terminal (experimental)](#native-terminal-experimental) below if you want to try it anyway.

---

## Get Mabel online (checklist)

0. **Deploy from Mac** (if you haven’t): run `./scripts/deploy-android-adb.sh` so the device has the binary and scripts under `/sdcard/Download/chump` (or `~/storage/downloads/chump` after step 1).
1. **In Termux — one-time setup (reliable SSH + Vulkan deps):**  
   Run `termux-setup-storage` once, then:  
   `bash ~/storage/downloads/chump/setup-termux-once.sh`  
   This installs `openssh` and `shaderc` (needed for llama.cpp Vulkan build), creates `~/.termux/boot/01-sshd.sh` so **sshd starts automatically** when Termux starts (install **Termux:Boot** from F-Droid), and starts sshd now. Set **Termux → Battery → Unrestricted** so Android doesn’t kill Termux (and SSH) in the background.
2. **In Termux — copy files and run setup:**  
   `bash ~/storage/downloads/chump/setup-and-run.sh`  
   (Or from `/sdcard/Download/chump/` if you didn’t use storage. This copies chump, start-companion.sh, and .env to `~/chump`, then tries to start the companion; if llama or model are missing, it exits with a clear error.)
3. **In Termux — build llama.cpp and download model (one-time):**  
   `bash ~/storage/downloads/chump/setup-llama-on-termux.sh`  
   (Installs deps including shaderc, builds llama-server with Vulkan, downloads Qwen3-4B Q4_K_M via curl to `~/models/`. Takes 15–30+ min.)
4. **In Termux — start Mabel:**  
   `cd ~/chump && ./start-companion.sh`  
   (Starts llama-server then the Discord bot. Use `nohup ... &` or tmux if you want it to keep running after you close Termux.)

For **max Mabel** (all tools, lean device) and env do/don't set, see [Mabel performance spec — Max Mabel on Pixel](MABEL_PERFORMANCE.md#6-max-mabel-on-pixel-all-tools-lean-device).

**From Mac via SSH:** After step 1, sshd is up. Add your Mac’s public key to `~/.ssh/authorized_keys` on the Pixel (see setup-termux-once.sh output), then run `./scripts/run-setup-via-ssh.sh <whoami>@<pixel-ip>` to do step 2 and start Mabel in the background. You still need step 3 (llama + model) on the device once.

---

## Architecture on the Pixel

```
┌─────────────────────────────────────────────────┐
│  Pixel 8 Pro (Termux)                           │
│                                                 │
│  ┌──────────────┐    ┌────────────────────────┐ │
│  │  chump       │◄──►│  llama-server           │ │
│  │  (Discord    │    │  (llama.cpp + Vulkan)   │ │
│  │   bot)       │    │  port 8000              │ │
│  │  ~15-20 MB   │    │  OpenAI-compat API      │ │
│  └──────┬───────┘    └────────────────────────┘ │
│         │                                       │
│  ┌──────┴───────┐                               │
│  │ SQLite + FTS5│   sessions/chump_memory.db    │
│  │ memory       │   sessions/chump_memory.json  │
│  └──────────────┘   logs/chump.log              │
└─────────────────────────────────────────────────┘
         │
         ▼ (Discord WebSocket via serenity)
    Discord API
```

---

## 1. Prerequisites

### On your Mac (build machine)

Install the Android NDK cross-compilation target:

```bash
# Install the Rust target for aarch64 Android (Termux uses Bionic libc)
rustup target add aarch64-linux-android

# Install Android NDK (if you don't already have it)
# Option A: via Homebrew
brew install --cask android-ndk

# Option B: via Android Studio → SDK Manager → NDK (Side by Side)
# Typical path: ~/Library/Android/sdk/ndk/<version>/
```

Set up the linker. Create or add to `~/.cargo/config.toml`:

```toml
[target.aarch64-linux-android]
linker = "/path/to/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android28-clang"
# Adjust the path to your NDK location and API level (28 = Android 9+, Pixel 8 Pro runs 14+)
```

> **NDK path examples:**
> - Homebrew: `/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/`
> - Android Studio: `~/Library/Android/sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/darwin-x86_64/bin/`

### On the Pixel 8 Pro (Termux)

**Recommended (reliable SSH):** Run the one-time setup script so SSH stays up and Vulkan build works:

```bash
# Install Termux from F-Droid (not Play Store — Play Store version is stale)
# In Termux:
termux-setup-storage   # once, so ~/storage/downloads/ works
bash ~/storage/downloads/chump/setup-termux-once.sh
```

That script installs `openssh` and `shaderc`, creates `~/.termux/boot/01-sshd.sh` (sshd on boot), and starts sshd. Then:

- Install **Termux:Boot** from F-Droid so sshd starts automatically after a reboot.
- **Settings → Apps → Termux → Battery → Unrestricted** so Android doesn’t kill Termux in the background (which would drop SSH).
- Add your Mac’s SSH key to `~/.ssh/authorized_keys` (see script output).
- Note your username: `whoami` (e.g. `u0_a314`) and IP (same Wi‑Fi as Mac).

**Run setup from Mac via SSH:** After the one-time setup, from the Chump repo run:
`./scripts/run-setup-via-ssh.sh u0_a314@10.1.10.9` (use your `whoami` and Pixel IP). This copies chump + .env to `~/chump` and starts Mabel in the background.

#### SSH config (Mac → Pixel)

To use a short host name (e.g. `ssh termux`) and avoid passing user@ip every time, add a block to `~/.ssh/config` on your Mac. **Important:** Termux’s login user is the Android app user, not your Mac username. In Termux run `whoami` (e.g. `u0_a314`) and use that as `User`.

```text
Host termux
    HostName 100.78.73.64
    Port 8022
    User u0_a314
    IdentityFile ~/.ssh/termux_pixel
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Replace `100.78.73.64` with your Pixel’s IP (same Wi‑Fi or Tailscale) and `u0_a314` with the value of `whoami` in Termux. Then: `ssh termux` and `scp -P 8022` is handled via the config when you use the host alias.

**Troubleshooting:**

| Symptom | Likely cause |
| -------- | -------------- |
| **Connection timed out** | Pixel unreachable: different network, device asleep, or IP changed. Ensure same Wi‑Fi or Tailscale and that Termux is running with sshd (port 8022). **After a network swap:** see [NETWORK_SWAP.md](NETWORK_SWAP.md) and run `./scripts/check-network-after-swap.sh` on the Mac. |
| **Permission denied (publickey)** | Wrong `User`: SSH is trying your Mac username. Set `User` in the config to the Termux username from `whoami`. Also ensure your Mac’s public key is in `~/.ssh/authorized_keys` on the Pixel. |
| **Connection refused** | sshd not running in Termux. In Termux run `sshd`; use Termux:Boot so it starts after reboot. |

For capturing Mabel timing from the Mac (SSH + script that tells you when to send Discord messages), see [Mabel performance — Capturing from the Mac](MABEL_PERFORMANCE.md#72-capturing-timing).

**Deploy all to Pixel (one command):** From the Chump repo on your Mac, run `./scripts/deploy-all-to-pixel.sh [termux]` to build, push the binary and scripts (including `mabel-farmer.sh`), apply Mabel env (soul, CHUMP_MABEL=1), and restart the bot. The deploy script pushes Mac cascade keys (Groq/Cerebras) to the Pixel as `~/chump/.env.mac` so the apply script can inject them into Mabel's `.env`; without this, Mabel would have no cloud cascade and only the local model. For binary-only deploy use `./scripts/deploy-mabel-to-pixel.sh [termux]`. See [Mabel performance — Deploy and restart from Mac](MABEL_PERFORMANCE.md#75-deploy-and-restart-from-mac) for details and troubleshooting.

**Restart Mabel when Pixel is on USB:** Run `./scripts/restart-mabel-bot-on-pixel.sh`. The script detects one ADB device and uses `adb forward tcp:8022 tcp:8022` so SSH goes over the cable (no WiFi). Ensure Termux is running with sshd on 8022.

**Mabel as farm monitor:** To have Mabel monitor the Mac stack over Tailscale (Farmer Brown, Sentinel, Heartbeat Shepherd from the Pixel), see [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) and run `scripts/mabel-farmer.sh` on the Pixel (loop or cron).

---

## 2. Cross-Compile Chump

From the Chump repo root on your Mac:

```bash
# Set NDK env vars (adjust paths to your NDK)
export ANDROID_NDK_HOME="/opt/homebrew/share/android-ndk"
export CC_aarch64_linux_android="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar"

# Build release (no inprocess-embed — skip fastembed/ONNX for now)
cargo build --release --target aarch64-linux-android
```

The binary lands at `target/aarch64-linux-android/release/rust-agent`.

### Known build considerations

| Dependency | Status | Notes |
|---|---|---|
| **axonerai** | Should work | Pure Rust + serde + reqwest |
| **tokio** | Works | Full async runtime, well-tested on Android |
| **reqwest** | Needs `rustls` | Uses `rustls_backend` via serenity; avoid `native-tls` (needs OpenSSL) |
| **rusqlite (bundled)** | Works | Compiles SQLite from C source via cc crate; NDK clang handles it |
| **serenity** | Works | Already uses `rustls_backend` feature — no OpenSSL needed |
| **fastembed** | Skip for now | ONNX Runtime on Android is possible but finicky; use keyword-only recall |
| **wasmtime CLI** | Skip for now | Not needed on phone; calculator tool degrades gracefully |

### If reqwest TLS fails

Chump's Cargo.toml uses `reqwest` with `default-features = false` and serenity pulls in rustls. If you hit OpenSSL link errors, make sure reqwest isn't pulling in `native-tls`. Add to Cargo.toml if needed:

```toml
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
```

---

## 3. Set Up llama.cpp on the Pixel

### Option A: Build in Termux (recommended for Vulkan)

**Requires `glslc` (shaderc) and `spawn.h` (libandroid-spawn):** The Vulkan build compiles compute shaders at build time; the full build (server + tests) needs `spawn.h` for subprocess code (see [llama.cpp #18615](https://github.com/ggml-org/llama.cpp/issues/18615)). Install before building:

```bash
# In Termux on the Pixel (or run setup-termux-once.sh / setup-llama-on-termux.sh which do this):
pkg install cmake clang git make vulkan-headers vulkan-loader-android shaderc libandroid-spawn

git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp

# Build with Vulkan backend (uses Tensor G3 GPU)
cmake -B build -DGGML_VULKAN=ON
cmake --build build --config Release -j$(nproc)

# The server binary:
ls build/bin/llama-server
```

Without `shaderc`, CMake fails with "Could NOT find Vulkan (missing: glslc)". Without `libandroid-spawn`, the full build fails with `spawn.h file not found`. CPU-only is possible with `-DGGML_VULKAN=OFF` but much slower for a 3B model.

### Option B: Cross-compile llama.cpp from Mac

More complex (needs Android NDK CMake toolchain). Building natively in Termux is simpler and ensures Vulkan links correctly against the device's drivers.

### Download a model

Pick a model that fits in ~6-8 GB RAM (Android needs headroom). Using **curl** avoids Python/pip (huggingface-hub can fail on Termux):

```bash
# In Termux — no Python needed
mkdir -p ~/models

# Recommended: Qwen3-4B Q4_K_M (default for Mabel; good tool-calling)
# Or run: bash ~/chump/scripts/switch-mabel-to-qwen3-4b.sh
curl -L -o ~/models/Qwen3-4B-Q4_K_M.gguf \
  "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"

# Alternative: Qwen 2.5 7B Q4 (tighter fit, better quality)
# curl -L -o ~/models/qwen2.5-7b-instruct-q4_k_m.gguf \
#   "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf"
```

### Start the server

```bash
# Start llama.cpp server with OpenAI-compatible API
~/llama.cpp/build/bin/llama-server \
  --model ~/models/Qwen3-4B-Q4_K_M.gguf \
  --port 8000 \
  --host 127.0.0.1 \
  --n-gpu-layers 99 \
  --ctx-size 4096 \
  --chat-template chatml
```

Verify it's up:

```bash
curl http://127.0.0.1:8000/v1/models
```

### Model size vs RAM budget

| Model | GGUF Q4_K_M | RAM needed (approx) | Quality | Recommended |
|---|---|---|---|---|
| Qwen3-4B Q4_K_M | ~2.5 GB | ~3.5 GB with context | Good tool-calling, better reasoning | Yes (default) |
| Qwen 2.5 3B | ~2 GB | ~3 GB with context | Decent for tools | Yes |
| Qwen 2.5 7B | ~4.5 GB | ~6 GB with context | Good balance | Yes (if stable) |
| Phi-3.5 Mini 3.8B | ~2.3 GB | ~3.5 GB | Strong for size | Alternative |
| Qwen 2.5 14B Q3 | ~6 GB | ~8 GB | Better reasoning | Tight, test first |

The Pixel 8 Pro has 12 GB total RAM. Android itself uses 3-5 GB. Target 6-7 GB max for model + Chump combined. Default is Qwen3-4B; graduate to 7B if stable. For tunables (context size, GPU layers, 7B vs 3B) and optimization, see [Mabel performance spec](MABEL_PERFORMANCE.md).

---

## 4. Deploy and Run Chump

### Deploy from Mac (one command)

If the Pixel has Termux with SSH enabled (see [On the Pixel](#on-the-pixel-8-pro-termux)):

```bash
# On Mac, from Chump repo:
brew install --cask android-ndk   # once, if not already installed
./scripts/build-android.sh --deploy user@<pixel-ip>
```

Replace `user` with the Termux username (`whoami` in Termux) and `<pixel-ip>` with the device IP (same Wi‑Fi). The script builds, then copies `chump` and `start-companion.sh` to `~/chump/` on the Pixel. SSH port defaults to 8022; set `DEPLOY_PORT` if different.

Then on the Pixel (Termux): create `~/chump/.env` with **Mabel’s** Discord token (from Mabel’s own Discord Application), and run `./start-companion.sh`. See [Mabel: naming and chat front-end](MABEL_FRONTEND.md) for a custom chat UI.

### Transfer the binary (manual)

```bash
# From your Mac:
scp -P 8022 target/aarch64-linux-android/release/rust-agent \
  user@<pixel-ip>:~/chump/chump
```

### Set up the working directory

```bash
# In Termux:
mkdir -p ~/chump/sessions ~/chump/logs
cd ~/chump
chmod +x chump
```

### Create `.env` (use Mabel’s token)

On the Pixel, use **Mabel’s** Discord bot token (from Mabel’s Discord Application in the Developer Portal), not Chump’s.

```bash
cat > ~/chump/.env << 'EOF'
DISCORD_TOKEN=your-mabel-bot-token-here

# Point at local llama.cpp
OPENAI_API_BASE=http://127.0.0.1:8000/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=default

# Optional: Tavily for web search
# TAVILY_API_KEY=your-key

# Lock down CLI (phone is more exposed than a dev Mac)
CHUMP_CLI_ALLOWLIST=ls,cat,echo,date,uptime,df,free,uname
CHUMP_CLI_BLOCKLIST=rm,su,apt,pkg,pip

# Optional: get a DM when Mabel comes online
# CHUMP_READY_DM_USER_ID=your-discord-user-id
EOF
```

### Run the bot

```bash
cd ~/chump
set -a && source .env && set +a
./chump --discord
```

You should see the bot come online as Mabel in the terminal and, if configured, a DM in Discord.

### Run in background (survive terminal close)

```bash
# Option A: nohup
nohup ./chump --discord > logs/chump-stdout.log 2>&1 &

# Option B: tmux (recommended — you can reattach)
pkg install tmux
tmux new -s chump
cd ~/chump && set -a && source .env && set +a
./chump --discord
# Ctrl-B, D to detach; tmux attach -t chump to reattach
```

---

## 5. Startup Script

Create `~/chump/start-companion.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
# Start Chump companion: llama.cpp server + Discord bot
set -e
cd ~/chump

# Load env
set -a && source .env && set +a

# Start llama.cpp if not running
if ! curl -s http://127.0.0.1:8000/v1/models > /dev/null 2>&1; then
  echo "Starting llama.cpp server..."
  ~/llama.cpp/build/bin/llama-server \
    --model ~/models/Qwen3-4B-Q4_K_M.gguf \
    --port 8000 \
    --host 127.0.0.1 \
    --n-gpu-layers 99 \
    --ctx-size 4096 \
    --chat-template chatml \
    > logs/llama-server.log 2>&1 &

  # Wait for server to be ready
  echo "Waiting for model server..."
  for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:8000/v1/models > /dev/null 2>&1; then
      echo "Model server ready."
      break
    fi
    sleep 2
  done
fi

# Start Chump
echo "Starting Chump Discord bot..."
exec ./chump --discord
```

```bash
chmod +x ~/chump/start-companion.sh
```

---

## 6. What Works, What Doesn't

### Works on Android (no changes needed)

- Discord bot (serenity + rustls, no OpenSSL)
- All tool dispatch (tool registry, JSON schema validation)
- SQLite + FTS5 memory (bundled, compiles from source)
- Keyword-based recall
- Session persistence (file-based, per channel)
- CLI tool (`run_cli` — uses `sh -c`, works in Termux)
- Calculator (pure Rust `calc_tool`)
- Audit log (`logs/chump.log`)
- Delegate tool (if `CHUMP_DELEGATE=1`, uses same `OPENAI_API_BASE`)
- Tavily web search (if `TAVILY_API_KEY` is set)
- Rate limiting, message caps, concurrent turn limits
- Ego state, tasks, episodes, schedules (all SQLite)

### Doesn't apply / skip

| Feature | Why | Alternative |
|---|---|---|
| vLLM-MLX | Apple Silicon only | llama.cpp + Vulkan |
| ChumpMenu | SwiftUI / macOS | `start-companion.sh` or tmux |
| `warm-the-ovens.sh` | Expects macOS mlx server | Baked into `start-companion.sh` |
| `inprocess-embed` | fastembed/ONNX iffy on Android | Keyword recall (FTS5) works fine |
| `wasm_calc` | wasmtime not in Termux easily | Falls back to `calc_tool` (pure Rust) |
| `serve-vllm-mlx.sh` | MLX | llama.cpp server |
| heartbeat-learn.sh | Calls agent binary, should work | Test; may need path adjustments |

### Might need tweaks

- **Repo tools** (`read_file`, `write_file`, `list_dir`): Work if `CHUMP_REPO` points to a valid path in Termux. Not critical for a companion bot.
- **GitHub tools**: Work if `GITHUB_TOKEN` is set. Network from Termux is fine.
- **Heartbeat**: The script calls the agent binary; if paths are adjusted it should run. Battery drain is a consideration — maybe shorter intervals or plug in overnight.

---

## 7. Pixel-Specific Tips

### Battery and thermal management

The Tensor G3's GPU running Vulkan inference will generate heat. For sustained use:
- Keep the phone plugged in and on a cool surface
- Consider a phone cooler clip if running 7B+ models
- The 3B model runs cooler and is fine for extended Discord bot duty

### Termux wake lock

Termux can acquire a wake lock to prevent Android from killing it:

```bash
termux-wake-lock    # keep CPU alive when screen is off
termux-wake-unlock  # release when done
```

Or use `Termux:Boot` (from F-Droid) to auto-start on reboot.

### Termux:Boot (auto-start on reboot)

```bash
# Install Termux:Boot from F-Droid
# Create boot script (starts Mabel bot + heartbeat):
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-chump.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sleep 10  # wait for network
~/chump/start-companion.sh > ~/chump/logs/boot.log 2>&1 &
# Start Mabel heartbeat (patrol, research, report, intel, peer_sync rounds)
nohup bash ~/chump/scripts/heartbeat-mabel.sh >> ~/chump/logs/heartbeat-mabel.log 2>&1 &
EOF
chmod +x ~/.termux/boot/start-chump.sh
```

After this, rebooting the phone starts llama.cpp, the Mabel bot, and the Mabel heartbeat automatically. The heartbeat script is pushed to `~/chump/scripts/` when you run `deploy-all-to-pixel.sh`.

### Mabel heartbeat

**heartbeat-mabel.sh** runs on the Pixel and drives Mabel’s autonomous rounds: **patrol** (runs mabel-farmer.sh, checks Mac stack and Chump heartbeat), **research**, **report** (unified fleet report + notify), **intel**, and **peer_sync** (message_peer to Chump). See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md).

- **Env (in ~/chump/.env):** `MABEL_HEARTBEAT_DURATION=8h`, `MABEL_HEARTBEAT_INTERVAL=5m`, `MABEL_HEARTBEAT_RETRY=1` (optional). For patrol/research/report, set `CHUMP_CLI_ALLOWLIST` to include `curl`, `ssh`, and optionally `sqlite3`. Mac SSH: `MAC_TAILSCALE_IP`, `MAC_TAILSCALE_USER`, `MAC_SSH_PORT`, `MAC_CHUMP_HOME`.
- **Pause:** `touch ~/chump/logs/pause` on the Pixel skips rounds (same convention as Chump). Remove the file to resume.
- **Start/stop from Mac:** ChumpMenu has **Start Mabel heartbeat** and **Stop Mabel heartbeat** (SSH to termux, port 8022). You can also start manually: `ssh -p 8022 termux 'cd ~/chump && nohup bash scripts/heartbeat-mabel.sh >> logs/heartbeat-mabel.log 2>&1 &'` and stop: `ssh -p 8022 termux 'pkill -f heartbeat-mabel || true'`.
- **Log:** `~/chump/logs/heartbeat-mabel.log`.
- **Shared brain:** Clone at `~/chump/chump-brain` (repo [repairman29/chump-brain](https://github.com/repairman29/chump-brain)); Pixel’s SSH key is added as a deploy key so push/pull works. Heartbeat pulls at round start and pushes at round end. See [CHUMP_BRAIN.md](CHUMP_BRAIN.md#shared-brain-mabel--chump).
- **Hybrid inference:** Set `MABEL_HEAVY_MODEL_BASE=http://<MAC_TAILSCALE_IP>:8000/v1` in `~/chump/.env` so research and report rounds use the Mac 14B; other rounds use local Qwen3-4B. The Mac’s API on 8000 must be reachable from the Pixel (bind to `0.0.0.0` or Tailscale).

### OCR on Pixel (screen-ocr)

Mabel can read screen text without a vision model: screencap + tesseract. Enables closed-loop phone control (read notifications, foreground app, verify launched app).

- **Install (once in Termux):** `pkg install tesseract`
- **Allowlist:** Add `tesseract` to `CHUMP_CLI_ALLOWLIST` in `~/chump/.env` (e.g. `CHUMP_CLI_ALLOWLIST=curl,ssh,sqlite3,tesseract,bash`).
- **Script:** `scripts/screen-ocr.sh [IMAGE_PATH]`. With no arg, tries to capture the screen (may require root or Termux:API). With a path, runs tesseract on that image. Mabel: `run_cli "bash scripts/screen-ocr.sh"` or `run_cli "bash scripts/screen-ocr.sh /path/to/screenshot.png"`. Output is plain text to stdout.
- **Deploy:** `deploy-all-to-pixel.sh` pushes `screen-ocr.sh` to `~/chump/scripts/`.

### Storage

Termux home is on the internal storage. The Qwen3-4B GGUF is ~2.5 GB, 7B is ~4.5 GB. The Pixel 8 Pro has 128-512 GB storage — this is not a constraint. SQLite memory and logs are tiny.

---

## 8. Cross-Compile Script

Save as `scripts/build-android.sh` in the repo:

```bash
#!/usr/bin/env bash
# Cross-compile Chump for Android (aarch64) from macOS.
# Requires: rustup target add aarch64-linux-android, Android NDK installed.
#
# Usage: ./scripts/build-android.sh [--deploy <user@host>]

set -e
cd "$(dirname "$0")/.."

# --- NDK detection ---
if [[ -z "$ANDROID_NDK_HOME" ]]; then
  # Try common locations
  for candidate in \
    /opt/homebrew/share/android-ndk \
    "$HOME/Library/Android/sdk/ndk/"* \
    /usr/local/share/android-ndk; do
    if [[ -d "$candidate/toolchains" ]]; then
      export ANDROID_NDK_HOME="$candidate"
      break
    fi
  done
fi

if [[ -z "$ANDROID_NDK_HOME" ]]; then
  echo "Error: ANDROID_NDK_HOME not set and NDK not found in common locations."
  echo "Install via: brew install --cask android-ndk"
  exit 1
fi

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
export CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"

if [[ ! -f "$CC_aarch64_linux_android" ]]; then
  echo "Error: Clang not found at $CC_aarch64_linux_android"
  echo "Check your NDK installation and API level."
  exit 1
fi

echo "NDK: $ANDROID_NDK_HOME"
echo "CC:  $CC_aarch64_linux_android"
echo "Building chump for aarch64-linux-android..."

cargo build --release --target aarch64-linux-android

BINARY="target/aarch64-linux-android/release/rust-agent"
SIZE=$(du -sh "$BINARY" | cut -f1)
echo "Built: $BINARY ($SIZE)"

# --- Optional deploy ---
if [[ "$1" == "--deploy" ]] && [[ -n "$2" ]]; then
  DEST="$2"
  echo "Deploying to $DEST:~/chump/chump via SSH (port 8022)..."
  scp -P 8022 "$BINARY" "$DEST:~/chump/chump"
  echo "Deployed. SSH in and restart: cd ~/chump && ./chump --discord"
fi
```

Usage:

```bash
# Build only
./scripts/build-android.sh

# Build and deploy to Pixel
./scripts/build-android.sh --deploy user@192.168.1.42
```

---

## Native terminal (experimental)

You can run Chump inside the Pixel’s **Run Linux terminal on Android** (Debian VM) instead of Termux. This is **experimental** and has important limits:

- **No 24/7:** The VM likely suspends when you close the Terminal app, so the Discord bot will not stay running.
- **No GPU:** The VM has no Vulkan/GPU passthrough; llama.cpp runs CPU-only and will be slow.
- **No SSH:** You deploy by pushing files with ADB and run commands in the Terminal app UI.

### Deploy via ADB

1. **Build on Mac** (from Chump repo root):
   ```bash
   ./scripts/build-android.sh
   ```
   Or use `scripts/deploy-android-adb.sh` to build and push in one step.

2. **Push to device storage** that the VM can see. The VM’s `/mnt/shared` usually maps to the device’s shared storage (e.g. Downloads). From your Mac:
   ```bash
   adb push target/aarch64-linux-android/release/rust-agent /sdcard/Download/chump/chump
   adb push scripts/start-companion.sh /sdcard/Download/chump/
   ```
   (Adjust the path if your device uses a different name for Downloads; check in the VM with `ls /mnt/shared`.)

3. **On the Pixel,** open the **Terminal** app (Linux development environment). In the Debian shell:
   ```bash
   cd /mnt/shared/chump
   chmod +x chump start-companion.sh
   # Create .env with DISCORD_TOKEN, OPENAI_API_BASE=http://127.0.0.1:8000/v1, etc.
   ./chump --discord
   ```
   You’ll need to run llama-server separately (e.g. in another Terminal tab if the app supports it, or build/run it inside the same VM). The VM has network access so Discord and the model server can communicate.

Use this path only for one-off tests or if you explicitly prefer not to install Termux. For a real 24/7 companion with GPU, use Termux (see the rest of this doc).

---

## 9. Future Improvements

- **In-process embeddings on Android:** Once `ort` (ONNX Runtime) has stable aarch64-android support, enable `--features inprocess-embed` for semantic recall. Track ort releases.
- **Vulkan performance tuning:** llama.cpp's Vulkan backend is improving rapidly. Watch for Tensor G3-specific optimizations and `--split-mode` for CPU+GPU hybrid.
- **Termux widget:** A Termux:Widget shortcut on the home screen to start/stop Chump with one tap (alternative to Termux:Boot).
- **Shared memory between Mac and Pixel:** Sync `chump_memory.db` between devices so both Chumps share long-term memory. Could be as simple as `rsync` on a cron, or a future SQLite replication tool.
- **Smaller models with tool-calling:** As 1-3B models get better at structured tool output, the companion can run leaner. Watch for Qwen3 small variants with native tool-call support.
