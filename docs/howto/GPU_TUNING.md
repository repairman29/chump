# GPU Tuning and Memory Management

Operational guide for tuning unified memory on Apple Silicon (M4 24 GB reference) to keep vLLM-MLX stable.

## 1. Before long sessions — free unified memory

Run `./scripts/setup/enter-chump-mode.sh` before starting `serve-vllm-mlx.sh`. This script quits memory-heavy apps (browsers, Electron) to free unified memory for the model. On a fresh boot with only Chump running, the 14B 4-bit model needs ~9–10 GB; macOS background processes can consume 4–6 GB on their own.

```bash
./scripts/setup/enter-chump-mode.sh    # frees unified memory
./scripts/setup/restart-vllm-if-down.sh
./scripts/setup/wait-for-vllm.sh
```

## 2. Conservative throttle defaults (stable first)

Set these in `.env` before the first long run. Only raise them after days of clean operation.

| Env var | Safe start | Meaning |
|---------|-----------|---------|
| `VLLM_MAX_NUM_SEQS` | `1` | One in-flight request at a time — prevents KV-cache explosion |
| `VLLM_MAX_TOKENS` | `4096` | Output cap per request |
| `VLLM_CACHE_PERCENT` | `0.12` | 12% of unified memory for KV cache (~2.9 GB on 24 GB) |
| `CHUMP_MAX_CONCURRENT_TURNS` | `1` | One Chump turn at a time — no parallel GPU pressure |
| `HEARTBEAT_LOCK` | `1` | Serializes heartbeat rounds so they don't pile up |

**Raising after stability:** After 3–4 days with no OOM: try `VLLM_MAX_TOKENS=8192`, then `VLLM_CACHE_PERCENT=0.15`. On any Metal OOM revert immediately.

## 3. OOM signatures and recovery

**Symptoms:**
- `logs/oom-context-*.txt` files appearing
- vLLM log shows model loaded → `GET /v1/models` → immediate shutdown
- `lsof -i :8000` returns nothing after a previously healthy run

**Recovery steps:**
1. `./scripts/setup/restart-vllm-if-down.sh` — restarts with current `.env` throttles
2. If it crashes again within minutes, reduce `VLLM_CACHE_PERCENT` by 0.02 and restart
3. If still unstable, drop to the 7B model: `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit` on port 8001

**Emergency (model won't stay up):** use Ollama as a fallback while you tune:
```bash
OPENAI_API_BASE=http://127.0.0.1:11434/v1 OPENAI_MODEL=qwen2.5:14b ./run-web.sh
```

## 4. Memory pressure thresholds

On a 24 GB M4:

| Scenario | Approximate VRAM usage | Notes |
|----------|----------------------|-------|
| System idle | 4–6 GB | macOS + background apps |
| 14B 4-bit loaded, no inference | ~9–10 GB | Model weights in unified memory |
| 14B 4-bit + KV cache (12%) | ~12–13 GB | Safe headroom |
| 14B 4-bit + KV cache (20%) | ~14–15 GB | Risky on 24 GB with background load |
| Two models loaded (OOM territory) | >20 GB | Avoid — `serve-vllm-mlx.sh` stops Ollama before starting |

Chump's startup scripts (`run-web.sh`, `run-discord-full.sh`, `keep-chump-online.sh`) run `scripts/setup/stop-ollama-if-running.sh` before starting vLLM-MLX to prevent this.

## 5. Model sizing guide

| Model | Approx VRAM | Notes |
|-------|------------|-------|
| 1B–3B 4-bit | 1–2 GB | Fleet mesh nodes (Pi, phone) |
| 7B 4-bit | ~4–5 GB | Port 8001, safe on 8 GB |
| 14B 4-bit | ~9–10 GB | Default; best quality on 24 GB |
| 32B 4-bit | ~18–20 GB | Tight on 24 GB; disable all other processes |
| 70B | Not viable locally | Use cloud cascade slots |

## 6. Automation (Farmer Brown / Oven Tender)

[Farmer Brown](OPERATIONS.md#roles) monitors port 8000 and calls `restart-vllm-if-down.sh` when it detects the server is down. It does NOT adjust throttles — that's manual. Oven Tender handles scheduled restarts and warmup.

For the full recovery playbook see [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md).

## See Also

- [Inference Stability](INFERENCE_STABILITY.md)
- [Inference Profiles](INFERENCE_PROFILES.md)
- [Steady Run](STEADY_RUN.md)
- [Operations](OPERATIONS.md)
