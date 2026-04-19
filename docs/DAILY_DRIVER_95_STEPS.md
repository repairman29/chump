# Daily Driver: 95% Reliability Steps

Runbook for achieving 95%+ uptime on the daily driver stack (Mac + Pixel + cloud cascade). See [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) for the OOM runbook.

## Definition of "daily driver"

- Chump responds to Discord/PWA within 10s of message receipt
- vLLM-MLX on 8000 is serving (or Ollama fallback is active within 30s)
- Battle QA passes at ≥ 85%
- At least one heartbeat completes per day without fatal error

## Step-by-step reliability setup

### 1. Install Oven Tender (vLLM auto-restart)

```bash
./scripts/install-roles-launchd.sh oven-tender
# Polls port 8000 every 60s; restarts vllm-mlx if down
```

### 2. Install Farmer Brown (stack diagnostics)

```bash
./scripts/install-roles-launchd.sh farmer-brown
# Runs hourly; diagnoses + fixes stale processes on 11434/18765
launchctl list | grep farmer-brown  # verify
```

### 3. Conservative vLLM defaults

```bash
# In .env or serve-vllm-mlx.sh:
VLLM_MAX_NUM_SEQS=1      # prevents Metal OOM from parallel sequences
VLLM_CACHE_PERCENT=0.12  # conservative KV cache
```

### 4. Ollama as hot fallback

Ensure Ollama is running and qwen2.5:14b is pulled:
```bash
brew services start ollama
ollama pull qwen2.5:14b
# Set CHUMP_FALLBACK_API_BASE=http://localhost:11434/v1 in .env
```

### 5. Sentinel mutual supervision

```bash
# Chump monitors Mabel; Mabel monitors Chump
./scripts/verify-mutual-supervision.sh
# Should report: PASS for both directions
```

### 6. Regular battle QA

```bash
./scripts/battle-qa.sh --quick    # ~5 min
# Or full: ./scripts/battle-qa.sh
# Pass rate < 85% = stack issue, not model issue
```

### 7. Memory DB health

```bash
# Check DB isn't growing unbounded
ls -lh sessions/chump_memory.db
# Should grow < 5MB/week at normal usage
# If > 50MB: run chump --chump "curate your memory"
```

## Failure modes and recovery

| Symptom | Root cause | Recovery |
|---------|------------|----------|
| Bot not responding | vLLM OOM or port 8000 down | `./scripts/restart-vllm-if-down.sh` |
| Slow responses (>30s) | KV cache fragmentation | Restart vLLM with `VLLM_CACHE_PERCENT=0.10` |
| "Model HTTP unreachable" | Ollama not running | `brew services start ollama` |
| Battle QA < 70% | Model regression or tool bug | Run `dogfood-t1-1-probe.sh` to isolate |
| Memory DB locked | SQLite lock from crashed session | `kill $(lsof -t sessions/*.db)` |
| Heartbeat silent > 4h | Heartbeat process crashed | `./scripts/restart-chump-heartbeat.sh` |

## 95% uptime math

- vLLM OOM: ~2/week × 5 min recovery = 99.7% uptime from this cause alone
- With Oven Tender: auto-recovery in 60s → negligible
- With Farmer Brown + mutual supervision: mean detection time < 5 min

## See Also

- [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) — full OOM runbook
- [OPERATIONS.md](OPERATIONS.md) — Farmer Brown, roles, Oven Tender
- [GPU_TUNING.md](GPU_TUNING.md) — memory thresholds and conservative defaults
- [BENCHMARKS.md](BENCHMARKS.md) — measuring baseline reliability
