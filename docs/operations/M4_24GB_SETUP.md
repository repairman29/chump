---
doc_tag: tested
owner_gap: PRODUCT-023
last_audited: 2026-05-10
---

# Tested Stable: 24GB M4 GPU (MacBook Air) with qwen2.5:7b

## Executive Summary

**Best working setup on 24GB unified memory (M4 MacBook Air):**

```bash
OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:7b
CHUMP_THINKING=1
CHUMP_CASCADE_ENABLED=0
```

**Result:** Stable tool calling in both web and CLI modes, no hangs, no OOM crashes. Tested 2026-05-10.

---

## Hardware Constraints (24GB M4)

### Model Sizing

| Model | Base Size | With Thinking + KV + Inference | Status |
|-------|-----------|--------------------------------|--------|
| **qwen2.5:7b** | 5GB | ~10-15GB total | ✅ **Stable** |
| qwen2.5:14b | 9GB | ~19-24GB total | ❌ OOMs, hangs |
| qwen3:8b | 5GB | ~10-15GB total | ⚠️ Works but CLI thinking mode hangs |
| qwen3:14b | 9GB | ~19-24GB total | ❌ OOMs on inference |

### Why 14B Fails

14B models use 9GB of weights alone. During inference:
- KV cache grows with context window (default 8192 tokens)
- Thinking blocks add intermediate state
- Model activation states accumulate across layers
- Total memory under sustained tool use: **19-24GB** = no headroom

Result: Model crashes silently, Ollama becomes unreachable, CLI hangs, web timeouts.

### Why qwen2.5:7b Works

- Base weights: 5GB
- Inference overhead: 5-10GB (KV cache + activations)
- Total under load: ~10-15GB
- GPU headroom: 9-14GB for system, browser, rust-analyzer, background apps

---

## Tested Features (qwen2.5:7b + thinking on 24GB M4)

✅ **Web mode:**
- Tool calling (calculator, read_file, run_cli proven)
- Thinking enabled and stable
- Tool approval flow works
- No timeouts or crashes
- Response latency: 1-3s first token, clean output

✅ **CLI mode (no cascade, no cascade thinking):**
- Direct queries work
- Tools execute (run_cli tested)
- Thinking enabled: no hangs (unlike qwen3:8b)
- Memory-stable under repeated turns

✅ **Memory/Brain:**
- Tool is registered and available
- Not fully tested for cross-session persistence in CLI, but web mode access works

---

## Complete Setup Steps

### 1. Install Ollama

```bash
brew install ollama
brew services start ollama
ollama pull qwen2.5:7b
```

Verify:
```bash
curl -s http://127.0.0.1:11434/api/tags | jq '.models[] | select(.name == "qwen2.5:7b")'
```

### 2. Configure `.env`

```bash
cat >> .env << 'EOF'
# 24GB M4 GPU — qwen2.5:7b stable profile (2026-05-10)
OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:7b
CHUMP_THINKING=1
CHUMP_CASCADE_ENABLED=0
CHUMP_REPO=/Users/jeffadkins/Projects/Chump
EOF
```

### 3. Build and Run

```bash
cargo build --release
./run-web.sh
# or: chump --web --port 3000
```

### 4. Verify

**Health check:**
```bash
curl -s http://127.0.0.1:3000/api/health | jq '.model'
```

**Web UI:**
```
http://127.0.0.1:3000
```

**CLI test:**
```bash
chump "What is 2+2?"
```

Expected: Instant response, no timeout.

---

## Don't Do This (Known Failures)

| ❌ Mistake | Reason | Fix |
|-----------|--------|-----|
| `OPENAI_MODEL=qwen2.5:14b` | OOM under thinking + tools | Use `qwen2.5:7b` |
| `OPENAI_MODEL=qwen3:8b` with `CHUMP_THINKING=1` in CLI | Timeout hangs after 20s | Use qwen2.5:7b or disable thinking |
| Running Ollama + vLLM-MLX together | GPU memory fragmentation | Stop Ollama before starting MLX: `brew services stop ollama` |
| `CHUMP_CASCADE_ENABLED=1` | Cloud cascade may interfere with local model | Use `CHUMP_CASCADE_ENABLED=0` for pure local operation |

---

## If You Run Into Issues

**Ollama becomes unreachable:**
```bash
killall ollama
sleep 2
brew services start ollama
ollama pull qwen2.5:7b
```

**Model is very slow (>10s first token):**
- Check memory with `Activity Monitor` → Memory tab
- Quit unnecessary apps (Xcode, Discord, lots of browser tabs)
- Model needs ~10-15GB during inference; system needs ~9-14GB for everything else

**Web requests timeout (60s approval expired):**
- This is expected behavior; tool approval expires after 60s
- Re-send the request or disable tool approval with `CHUMP_TOOLS_ASK=` if working solo

**CLI says "I can't call tools":**
- Ensure `CHUMP_REPO` is set
- Ensure tools are registered: `chump --check-config` should list 14+ tools

---

## Alternative Strategies (Not Tested Here)

### vLLM-MLX on Port 8000 (Better Throughput)

If you want faster inference and have time to set up Python:
```bash
source scripts/dev/env-max_m4.sh
# Builds and runs 14B on 8000, full Chump toolkit
./run-discord-full.sh
```

See [`docs/operations/INFERENCE_PROFILES.md`](INFERENCE_PROFILES.md) § 1b for details.

**Trade-offs:** Faster, stronger model (14B), but requires Python + vLLM-MLX install.

### Smaller Models (qwen2.5:3b, llama3.2:3b)

May fit even tighter:
```bash
ollama pull qwen2.5:3b  # ~2GB base
```

Expect reduced reasoning; good for lightweight tasks.

---

## Future Work

- [ ] INFRA-184: Route thinking deltas so reasoning steps don't appear in chat
- [ ] PRODUCT-024: Optimize reasoning model latency (qwen3.5-9B is slower)
- [ ] PRODUCT-023: Update `.env.example` to default to 7B for Ollama profile
- [ ] Clarify memory_brain persistence in CLI mode across disconnects

---

## Checklist Before Calling it "Stable"

- [x] Web mode + calculator tool = success
- [x] Web mode + file read = success  
- [x] CLI + thinking enabled = no hangs
- [x] CLI + run_cli = tool executes
- [x] Memory available (tool registration confirmed)
- [x] No OOM crashes after 10+ turns
- [x] Approval flow works (web)
- [x] Tool routing table visible (system prompt intact)
