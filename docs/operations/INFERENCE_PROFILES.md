---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Hardware & RAM Inference Profiles

Chump works cleanly across `$0` local model servers, cloud API cascades, and hybrid setups on **macOS (Apple Silicon & Intel), Linux (NVIDIA CUDA / AMD ROCm / CPU), and Windows**. Use the profiles below to size local models and worker concurrency without triggering OS swap thrashing.

---

## 1. Local Hardware Sizing Matrix

Keep model weights + KV cache at **≤ 70% of available RAM / VRAM** so `cargo`, `node`, `pytest`, and git worktrees have headroom:

| Machine Tier | Recommended Local Backend | Recommended Coding Model | Context Window | Safe `desired_workers` |
|--------------|---------------------------|--------------------------|----------------|------------------------|
| **8 GB RAM / VRAM** | Ollama / `llama.cpp` | `qwen2.5-coder:3b` (`Q4_K_M`) | `8192` | `1` (or cloud cascade primary) |
| **16 GB RAM / VRAM** | Ollama / LM Studio | `qwen2.5-coder:7b` (`Q4_K_M`) | `16384` | `1–2` |
| **24–32 GB RAM / VRAM** | Ollama / vLLM / MLX | `qwen2.5-coder:14b` (`Q4_K_M` / `8-bit`) | `32768` | `2–3` |
| **48–64+ GB RAM / VRAM** | vLLM / Ollama / `llama.cpp` | `qwen2.5-coder:32b` or `70b` | `32768–65536` | `4–8` |

---

## 2. Standard OpenAI-Compatible Local Servers

Point either `[[providers]]` in `~/.chump/config.toml` or `OPENAI_API_BASE` at any local server speaking `/v1/chat/completions`:

| Server | Default `base_url` | Quick Start | Best For |
|--------|--------------------|-------------|----------|
| **Ollama** | `http://127.0.0.1:11434/v1` | `ollama serve && ollama pull qwen2.5-coder:14b` | Zero-config cross-OS setup on macOS, Linux, and Windows |
| **vLLM / vLLM-MLX** | `http://127.0.0.1:8000/v1` | `vllm serve Qwen/Qwen2.5-Coder-14B-Instruct --port 8000` | High-throughput continuous batching on Linux GPUs or Apple Silicon |
| **LM Studio** | `http://127.0.0.1:1234/v1` | Enable **Local Server** in LM Studio UI | Desktop GUI model browsing and GGUF quantization inspection |
| **llama.cpp (`llama-server`)** | `http://127.0.0.1:8080/v1` | `llama-server -m model.gguf -c 16384 --port 8080` | Minimal C++ footprint on CPU/Vulkan/CUDA/Metal |

### Keeping Weights Warm (`Ollama`)

By default Ollama unloads idle models after 5 minutes, adding a 10–20s cold-start pause on the next agent turn. Set `OLLAMA_KEEP_ALIVE=30m` (or `-1` on dedicated workstations) and `OLLAMA_NUM_PARALLEL=2` when running 2 concurrent workers.

---

## 2b. Optional In-Process `mistral.rs` Backend

When you want single-binary, in-process Rust inference without an external HTTP model server, build `chump` with the optional `mistralrs-infer` feature (add `mistralrs-metal` on macOS Apple Silicon or `mistralrs-cuda` on Linux/Windows NVIDIA GPUs):

```bash
# macOS Apple Silicon (Metal acceleration)
cargo build --release --bin chump --features mistralrs-infer,mistralrs-metal

# CPU / generic Linux or Windows
cargo build --release --bin chump --features mistralrs-infer
```

Configure runtime environment variables:

```bash
export CHUMP_INFERENCE_BACKEND=mistralrs
export CHUMP_MISTRALRS_MODEL=Qwen/Qwen2.5-Coder-7B-Instruct
export CHUMP_MISTRALRS_ISQ=Q4K                 # Optional in-situ quantization
export CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1    # Stream incremental SSE deltas in --web
# Optional JSON-schema constraint on tool-free turns:
# export CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA=/path/to/schema.json
```

When `CHUMP_INFERENCE_BACKEND=mistralrs` and `CHUMP_MISTRALRS_MODEL` are set, `GET /api/stack-status` reports `primary_backend: "mistralrs"` and `probe: "mistralrs_in_process"`.

---

## 3. Recommended Hybrid Profile (Cloud Frontier + Local Floor)

Most multi-agent teams run a **two-tier hybrid profile** in `~/.chump/config.toml`:

1. **Primary Cloud / Subscription Tier (`priority = 5..15`):** Handles complex multi-file architecture, deep code review, and 100K+ token context windows via Claude OAuth/Sonnet/Opus, Gemini Pro/Flash, or Codestral.
2. **Local GPU Floor (`priority = 20..30`, `tier = "local"`):** Absorbs high-frequency scout tasks, summarization, offline travel work, and automatic spillover whenever cloud RPM quotas tighten.

Test any profile interactively with the [Fleet Throughput & Cost Simulator](https://repairman29.github.io/chump/tools/fleet-simulator/).

---

## Related Guides

- [Offline Local Models](../QUICKSTART_OFFLINE.md)
- [Provider Cascade & OAuth](../architecture/PROVIDER_CASCADE.md)
- [Inference Stability](INFERENCE_STABILITY.md)
