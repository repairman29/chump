# Offline-First Workflow — Chump on Local LLMs

## Mission

Enable a solo developer with a 24GB Mac, Ollama, and one binary to ship shipping-quality software using a multi-agent fleet, entirely offline with no GitHub/internet access and no cloud LLM API calls required.

This document validates the end-to-end workflow and provides the quickstart path.

## System Requirements

- **macOS** 13.0+ with M1/M2/M3/M4 (or equivalent)
- **RAM** 24GB minimum (tested: M4 Max with 24GB)
- **Ollama** latest (https://ollama.ai) — stores ~12GB for 14B models
- **Chump** binary (self-contained, zero additional dependencies)

## Setup (5 minutes)

### 1. Install Ollama and a local model

```bash
# Install Ollama (or use existing install)
# https://ollama.ai

# Pull a capable 14B model (qwen2:14b recommended for Chump work)
ollama pull qwen2:14b           # ~9GB, 4-6 min on fast internet
# or
ollama pull llama2:13b          # ~7GB alternative

# Start ollama server (runs in background)
ollama serve
# or use: open -a Ollama  # on macOS
```

### 2. Install Chump

```bash
# Option A: From Homebrew (once available)
# brew tap repairman29/chump && brew install chump

# Option B: From source (development)
git clone https://github.com/repairman29/chump.git
cd chump
cargo build --release
export PATH="./target/release:$PATH"

# Verify installation
chump --version
chump --help
```

### 3. Configure Chump for offline + local LLM

```bash
# Initialize local config (creates ~/.chump/config.toml)
chump init

# In ~/.chump/config.toml, ensure:
[offline]
enabled = true
local_llm_endpoint = "http://localhost:11434"  # Ollama default
local_llm_model = "qwen2:14b"

[auth]
mode = "offline"  # no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN needed

[fleet]
size = 2           # start small: 2 workers for testing
orchestrator = "local"
```

Verify config:
```bash
chump config validate
```

## Workflow — Single Developer, Single Machine

### Phase 1: Single-shot task (no fleet)

```bash
# Describe a coding task in plain English
chump gen "add a /health endpoint to my axum server"

# Chump:
# 1. Claims a local gap in .chump/state.db
# 2. Spawns one worker (Ollama → qwen2:14b)
# 3. Worker creates a PR branch, writes code, opens PR locally
# 4. Worker merges via local git (not GitHub)
# 5. Prints PR details to stdout

# Output: "#42 /health endpoint — https://github.com/you/repo/pull/42 (merged locally)"
```

**Validation:** Run `git log --oneline | head -5` and see your merged commit.

### Phase 2: Fleet operations (conversational)

```bash
# Start a persistent fleet
chump orchestrate

# You type: "spawn the fleet on infra p0/p1, size 2"
# Orchestrator:
# 1. Reads ROADMAP.md + CLAUDE.md doctrine
# 2. Files 2-4 gaps locally in .chump/state.db
# 3. Spawns workers, each claiming a gap
# 4. Workers code and merge in parallel
# 5. Reports back: "shipped 2 of 3, 1 blocked on INFRA-708"

# You type: "what's our mission grade?"
# Returns: {effective: 60%, credible: 40%, resilient: 80%, zero_waste: 70%}

# You type: "ship the offline quickstart by eod"
# Orchestrator promotes INFRA-591 to P0 and assigns to workers

# Type Ctrl+C to exit (fleet keeps running in tmux)
```

### Phase 3: Fleet status (real-time monitoring)

```bash
# In a separate terminal, watch the fleet
chump fleet-status
# or
chump fleet-status --json > /tmp/fleet.json && cat /tmp/fleet.json

# Output:
# Worker 1: [████████░░░░░░░░] PRODUCT-036 (30/45 min) — diff: 342 lines
# Worker 2: [░░░░░░░░░░░░░░░░] idle, waiting for P0
# Ambient: 847 events, 12 active leases, 0 collisions
```

## Validation Checklist

Run these before considering the workflow validated:

```bash
#!/bin/bash
set -e

echo "=== Offline-First Workflow Validation ==="

# 1. No internet required
echo "[1] Checking no active cloud API calls..."
sudo log stream --predicate 'process == "chump"' --level debug 2>&1 | \
  grep -q "ANTHROPIC_API\|OpenAI\|llm-cloud" && \
  echo "❌ FAIL: Found cloud API reference" || \
  echo "✓ PASS: No cloud LLM APIs detected"

# 2. Ollama is serving
echo "[2] Checking local Ollama availability..."
curl -s http://localhost:11434/api/tags > /dev/null && \
  echo "✓ PASS: Ollama responding" || \
  echo "❌ FAIL: Ollama not running"

# 3. Single-shot coding task works
echo "[3] Testing single-shot task..."
chump gen "add a TODO comment to main.rs" && \
  echo "✓ PASS: Single-shot task completed" || \
  echo "❌ FAIL: Single-shot task failed"

# 4. Fleet can spawn and claim gaps
echo "[4] Testing fleet spawn..."
FLEET_SIZE=2 chump fleet start && \
  sleep 5 && \
  [ $(ls .chump-locks/*.json | wc -l) -ge 2 ] && \
  echo "✓ PASS: Fleet spawned with 2 workers" || \
  echo "❌ FAIL: Fleet spawn incomplete"

# 5. Workers can claim and code
echo "[5] Testing worker coding cycle..."
chump gap reserve --domain TEST --title "test gap for validation" && \
  sleep 30 && \
  git log -1 --format=%s | grep -q "test gap" && \
  echo "✓ PASS: Worker completed full cycle" || \
  echo "❌ FAIL: Worker cycle incomplete"

# 6. Cleanup
echo "[6] Cleaning up test gaps..."
chump fleet stop
chump --release

echo ""
echo "=== All checks passed ==="
```

Run the validation:
```bash
bash validation-checklist.sh
```

## Known Limitations (v1.0)

1. **Model quality ceiling.** qwen2:14b (~95 IQ) is capable for Rust/Python/Go but struggles with complex architectural decisions. Opus (~180 IQ) is still 2-3× better for refactoring and design review. Offline chain-of-thought (ORCA, etc.) is being evaluated.

2. **No model caching yet.** Each `chump gen` or gap-coding starts fresh (no prompt cache). Expect 2-4 min per task on 24GB M4 vs 30-60s with Opus.

3. **Limited to single machine.** Cross-machine mesh (NATS, LAN) is roadmap but not active. Multi-Mac fleets must use shared GitHub repo today.

4. **No auto-fallback to cloud.** If Ollama crashes, Chump fails. (Planned: soft fallback to Anthropic API if `ANTHROPIC_API_KEY` present, with explicit operator confirmation.)

5. **Batch operations not yet distributed.** Fleet workers run sequentially on local workers — parallel batch ops (measuring 1000 decisions) still require cloud Groq/Cerebras endpoints.

## Troubleshooting

### "Ollama not responding" (error 111)

```bash
# Check if Ollama is running
ollama list  # hangs? → ollama serve not started

# Restart Ollama
pkill ollama
sleep 2
ollama serve &
ollama list  # should return model list
```

### "Model out of context" (model crashes mid-generation)

```bash
# qwen2:14b has ~8K context. Large files trigger OOM.
# Workaround: ask workers to split tasks:
chump gen "split main.rs into 3 modules before refactoring"
# then
chump gen "refactor module A (see main_a.rs)"
```

### "Fleet workers not claiming gaps"

```bash
# Check leases
cat .chump-locks/*.json | jq .

# Check ambient stream for lease_overlap or silent_agent
tail -50 .chump-locks/ambient.jsonl | grep -E "lease|silent"

# If stuck, reset:
chump --release --all
chump fleet stop
rm -f .chump-locks/*.json
```

## Next Steps

1. **Local model fine-tuning** (Q2 2026). Fine-tune Llama 405B on Chump code + IR, expect 1.5-2× quality lift.
2. **Multi-machine mesh** (Q3 2026). NATS-based sync for 2-4 Macs in a home lab.
3. **Offline documentation search** (Q2 2026). Embedding-based retrieval from local docs instead of GitHub/StackOverflow.
4. **Visual dashboard** (Q2 2026). PWA that runs on localhost:3000, no external CDN.

## References

- [`ROADMAP.md`](./ROADMAP.md) — product vision for June 6 demo
- [`AGENTS.md`](./AGENTS.md) — multi-agent architecture
- [`memory/project_offline_local_llm_mission.md`](../memory/project_offline_local_llm_mission.md) — strategic framing
- Ollama docs: https://github.com/ollama/ollama
- qwen2 model card: https://huggingface.co/Qwen/Qwen2-14B-Instruct
