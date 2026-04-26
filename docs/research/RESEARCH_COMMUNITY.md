# Chump Research Community

We are running controlled A/B studies of synthetic cognitive architecture in local LLM agents. We want more data — different hardware, different models, different task domains — and we want the community to help design what to study next.

This document tells you how to run studies, how to contribute results, and where the highest-value open questions are.

---

## Why This Matters

The Scaffolding U-curve finding (§4.3 of the research paper) is a small-N result that deserves replication. The key question: **does consciousness-inspired scaffolding help small and large models while hurting mid-size models, and does this pattern hold across hardware and model families?**

If the curve replicates on NVIDIA hardware, across Llama/Mistral/Qwen/Phi families, it suggests a fundamental property of model capacity and context integration. If it doesn't replicate, it may be an artifact of Apple Silicon inference, our specific fixture, or our judge calibration.

One researcher with different hardware is worth more to this project right now than ten more runs on the same machine.

---

## Hardware You Need

You don't need a supercomputer. You need enough RAM to hold model weights during inference:

| What you want to test | Minimum hardware |
|-----------------------|------------------|
| 1B–3B models only | Any laptop with 8 GB RAM |
| Up to 7B–8B models | 16 GB unified memory (Mac Mini M4, M2 MacBook Pro) |
| Up to 14B models | 24 GB unified memory (Mac Mini M4 Pro, Mac Studio M3) |
| Up to 32B models | 48 GB unified memory (Mac Studio M4 Max) |
| Up to 70B models | 96–192 GB unified memory (Mac Studio M4 Ultra) |
| NVIDIA GPU | 24 GB VRAM (RTX 4090) for up to 14B; 80 GB (A100) for 70B |
| Cloud inference | Any; set OLLAMA_BASE to your endpoint |

Apple Silicon's unified memory is why local 14B inference is accessible on a ~$1,500 machine. If you have an NVIDIA rig, your data is especially valuable because we don't have it yet.

---

## Running the Studies

### Prerequisites

```bash
# Clone the repo
git clone https://github.com/repairman29/chump
cd chump

# Install Rust (https://rustup.rs)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install Ollama (https://ollama.ai)
# Then pull the models you want to test:
ollama pull llama3.2:1b
ollama pull llama3.2:3b
ollama pull qwen2.5:7b
ollama pull qwen2.5:14b
ollama pull qwen3:8b

# Build Chump
cargo build --release

# (Optional but recommended) Anthropic API key for Claude Sonnet judge
export ANTHROPIC_API_KEY=sk-ant-...
```

### Study 1: Consciousness Framework A/B (COG-001 replication)

```bash
# Full 5-model battery (takes ~2-3 hours)
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY scripts/eval/run-consciousness-study.sh

# Single model (faster, ~20-30 minutes)
CHUMP_NEUROMOD_MODEL=llama3.2:1b scripts/eval/run-consciousness-study.sh
```

Results land in `logs/ab/` (per-trial JSONL) and `logs/study/` (summaries).

### Study 2: Neuromodulation Ablation (COG-006)

```bash
# 50-task neuromodulation A/B (qwen3:8b, ~1 hour)
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY scripts/eval/run-neuromod-study.sh

# Override model
scripts/eval/run-neuromod-study.sh --model qwen2.5:14b

# Dry run (preview without executing)
scripts/eval/run-neuromod-study.sh --dry-run
```

### Study 3: Partial Ablation (4 conditions)

```bash
# Tests all-on, all-off, framework-on+neuromod-off, framework-on+perception-off
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY scripts/eval/run-ablation-study.sh

# Specify model and limit
scripts/eval/run-ablation-study.sh --model qwen2.5:14b --limit 20
```

---

## Submitting Results

1. **Run any study** — the harness writes a summary JSON to `logs/study/`
2. **Open a PR** with your results file added to `logs/study/contributed/`
3. **Name your file** as: `<study>-<model>-<hardware>-<date>.json`
   - Example: `cog001-qwen2514b-rtx4090-20260501.json`
4. **Add a brief note** in the PR description: hardware, OS, any deviations from default config

We will incorporate contributed results into the paper and credit contributors in the acknowledgments section.

### Result file format

The harness produces a standard summary JSON. If you are running a variant study, include at minimum:

```json
{
  "hardware": "RTX 4090, 24 GB VRAM, Ubuntu 22.04",
  "ollama_version": "0.6.x",
  "model": "qwen2.5:14b",
  "fixture": "reflection_tasks.json",
  "limit": 20,
  "by_mode": {
    "A": {"passed": N, "failed": N, "rate": 0.XX, "avg_tool_calls": X.XX},
    "B": {"passed": N, "failed": N, "rate": 0.XX, "avg_tool_calls": X.XX}
  },
  "delta": 0.XX,
  "tool_efficiency_delta": -X.XXX,
  "judge_model": "claude-sonnet-4-6",
  "judge_api": "anthropic",
  "generated_at": "2026-MM-DDTHH:MM:SSZ"
}
```

---

## Open Research Questions

These are the questions with the highest value-to-effort ratio. Pick one and run it.

### HIGH VALUE

**Does the U-curve replicate on NVIDIA hardware?**
Run the 5-model COG-001 battery on an RTX 3090/4090 or A100. If the curve holds, it's a property of model architecture. If it doesn't, it may be an Apple Silicon inference artifact. This is the single most important replication.

**Does a 32B model show stronger framework benefit than 14B?**
The U-curve predicts monotonically increasing benefit above 14B. Run the COG-001 study with a 32B model (requires ~48 GB). Models to try: `qwen2.5:32b`, `llama3.1:32b`.

**Does neuromodulation help Phi-4 (14B) the way it helps qwen2.5:14b?**
qwen2.5:14b shows +10pp on the full framework. Testing the same fixture on `phi4:14b` would tell us whether this is model-family-specific or a general 14B phenomenon.

### MEDIUM VALUE

**What is the latency overhead?**
The study harness records trial duration but our current logging didn't capture it cleanly. Run `scripts/eval/run-consciousness-study.sh` and check whether `logs/ab/*.jsonl` entries have non-null `duration_ms` values. If latency data is present, analyze it and send us the results.

**Does the effect persist across different fixtures?**
`reflection_tasks.json` tests multi-step reasoning and self-correction. Try running the framework A/B on a coding task fixture (write a function, fix a bug) or a document task fixture (summarize, extract, edit). Write a 10-task fixture following the format in `scripts/ab-harness/fixtures/` and run it.

**Does the 3B model U-curve dip persist at longer context windows?**
The study used `CHUMP_OLLAMA_NUM_CTX=8192`. Try `CHUMP_OLLAMA_NUM_CTX=4096` or `16384` — does the 3B model's negative delta persist, improve, or worsen? This tests whether context-window size is confounded with the framework effect.

### EXPLORATORY

**Design a session-learning fixture.**
The cold-start study can't measure memory graph accumulation benefits. A longitudinal fixture would run the same agent through 5–10 sequential sessions, with each session building on context from the last. Design the fixture and let us know if you want help running it.

**Build a better judge prompt.**
Claude Sonnet 4.6 as judge is good but the calibration may drift across prompt types. Try building a rubric-based judge that specifies explicit scoring criteria per task category (multi-step, clarification, graceful exit) and compare its scores to the default judge on existing result files.

---

## Adding New Subsystem Flags

The current ablation flag set is:
- `CHUMP_CONSCIOUSNESS_ENABLED` — all six subsystems
- `CHUMP_NEUROMOD_ENABLED` — neuromodulation only
- `CHUMP_PERCEPTION_ENABLED` — perception preprocessing
- `CHUMP_REFLECTION_INJECTION` — counterfactual lesson injection

If you want to add a per-subsystem flag (e.g., `CHUMP_MEMORY_GRAPH_ENABLED`), open an issue or PR. The flags are read in `src/context_assembly.rs` and `src/neuromodulation.rs` — adding a new flag is a ~10-line Rust change plus a docs update.

---

## Community Norms

- **Share negative results.** A model that shows no effect is as informative as one that shows benefit. The null result is the prior.
- **Document your hardware.** "It worked" is much less useful than "RTX 4090, 24 GB, CUDA 12.3, Ollama 0.6.2, qwen2.5:14b, delta=+8pp."
- **Replicate before extending.** If you want to run a new fixture, first run the standard battery so we have a baseline for your hardware.
- **One PR per study run.** Don't aggregate multiple models into one unstructured file.

---

## Contact and Discussion

Open an issue on GitHub with tag `[research]` for questions, proposed fixtures, or anomalous results you want to discuss. The author monitors GitHub issues daily.

For hardware-level questions (CUDA setup, Ollama configuration, model quantization), the Ollama Discord is the fastest resource.

---

*Chump research infrastructure lives in `scripts/ab-harness/`. The paper is at `docs/research/consciousness-framework-paper.md`. Raw study data: `logs/ab/`, `logs/study/`.*
