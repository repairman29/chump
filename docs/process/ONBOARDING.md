---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump — Onboarding

> **Goal:** run one command, get a working AI assistant with PWA in under 60 seconds.

## Quick start (macOS)

```bash
brew install chump          # or: cargo install chump
chump init                  # detects your model, writes .env, starts server, opens browser
```

That's it. The PWA opens at `http://localhost:3000/v2/` automatically.

---

## Step 1 — Install

**Homebrew (recommended):**
```bash
brew tap repairman29/chump
brew install chump
```

**From source:**
```bash
git clone https://github.com/repairman29/chump
cd chump
cargo build --release
# binary at target/release/chump
```

---

## Step 2 — `chump init`

`chump init` runs four sub-steps automatically:

| Step | What it does |
|---|---|
| **1/4 Model detection** | Checks for ANTHROPIC_API_KEY, Ollama at localhost:11434, vllm-mlx at localhost:8000/8001, OPENAI_API_KEY |
| **2/4 Write .env** | Creates `.env` in the repo root with the detected provider settings. Skipped if `.env` already exists. |
| **3/4 Start server** | Spawns `chump --web --port 3000` in the background. Waits up to 15s for the health endpoint. |
| **4/4 Open browser** | Opens `http://localhost:3000/v2/` in your default browser. |

**Example output:**
```
🚀  chump init — first-run setup

  [1/4] model detection ... found qwen2.5:7b via Ollama (localhost:11434)
  [2/4] wrote /path/to/chump/.env
  [3/4] server started on port 3000
         waiting for server............... ready (3s)
  [4/4] opening http://localhost:3000/v2/

  ✓  Setup complete.
     PWA: http://localhost:3000/v2/
```

---

## Step 3 — The PWA

Once the browser opens, you see the Chump chat interface:

<!-- Screenshots: run `chump init` and capture the following states -->
<!-- docs/img/onboarding-01-model-picker.png -->
- **Model picker** (top right) — switch between local and cloud models
<!-- docs/img/onboarding-02-chat.png -->
- **Chat panel** — send messages, see streaming responses and tool-call cards
<!-- docs/img/onboarding-03-nav.png -->
- **Nav** — access settings, memory, task history

---

## No local model?

If `chump init` reports no local model found:

**Option A — Ollama (recommended, free):**
```bash
brew install ollama
ollama pull qwen2.5:7b     # ~4.7 GB
ollama serve               # starts on localhost:11434
chump init                 # re-run — now detects Ollama
```

**Option B — Anthropic API:**
```bash
export ANTHROPIC_API_KEY=sk-ant-...
chump init
```

**Option C — OpenAI API:**
```bash
export OPENAI_API_KEY=sk-...
chump init
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `chump init` starts but browser doesn't open | Navigate to `http://localhost:3000/v2/` manually |
| Server doesn't start | Check `chump --web --port 3000` in a terminal; look for port conflict |
| Model not detected | Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in `.env`, then `chump init` |
| `.env` has wrong settings | Delete `.env` and re-run `chump init` |
| FTUE > 60s | Check model download is complete; ensure port 3000 is free |

---

## FTUE benchmark

To measure your first-run experience time:
```bash
NO_BROWSER=1 ./scripts/eval/measure-ftue.sh --budget 60
```

Expected output on an M4 Mac with Ollama pre-installed:
```
[ftue] Starting FTUE measurement (budget=60s)
[ftue] PWA target: http://localhost:3000/v2/
[ftue] Waiting for PWA to respond...
[ftue] READY in 4.2s
[ftue] PASS: 4.2s <= 60s budget
```

CI budget is 90s (`--budget 90`).
