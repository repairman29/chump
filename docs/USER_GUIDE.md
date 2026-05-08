# Chump User Guide

> **Who this is for.** Anyone using Chump to run an AI coding agent on their own machine — no cloud bill, no prior agent-framework experience required.
>
> **Prerequisite.** You have completed [QUICKSTART_OFFLINE.md](QUICKSTART_OFFLINE.md) and can run `chump --once 'Hello'` successfully.

---

## Contents

1. [Core concepts in plain English](#1-core-concepts-in-plain-english)
2. [Choosing a model for your hardware](#2-choosing-a-model-for-your-hardware)
3. [Common workflows](#3-common-workflows)
4. [Troubleshooting](#4-troubleshooting)
5. [Quick reference](#5-quick-reference)

---

## 1. Core concepts in plain English

| Term | What it means |
|------|---------------|
| **Gap** | A unit of work — like a ticket or task. You describe what you want; Chump's agent does it. |
| **Fleet** | One or more agent workers running in parallel, each claiming and working a gap. |
| **Worktree** | An isolated copy of your git repo where the agent writes code. Your working copy stays untouched. |
| **Lease** | A lock file that says "agent X is working gap Y." Prevents two agents from colliding. |
| **Claim** | The act of an agent taking ownership of a gap before it starts coding. |

You don't need to manage any of these by hand — `chump` commands handle them. The list is here so error messages make sense.

---

## 2. Choosing a model for your hardware

Pick the largest model that fits comfortably in your Mac's unified memory. "Comfortably" means the model uses ≤ 70% of your total RAM so macOS has breathing room.

### Quick picks

| Your Mac | Recommended model | Pull command | RAM used |
|----------|------------------|--------------|---------|
| 8 GB | `llama3.2:1b` | `ollama pull llama3.2:1b` | ~1.5 GB |
| 16 GB | `llama3.2` (3B) | `ollama pull llama3.2` | ~3 GB |
| 24 GB | `llama3.2` or `qwen2.5-coder:14b` | `ollama pull qwen2.5-coder:14b` | ~9 GB |
| 48 GB+ | `qwen2.5-coder:32b` or `llama3.1:70b` | `ollama pull qwen2.5-coder:32b` | ~22 GB |

### Model trade-offs

**Speed vs. quality.** Smaller models respond in seconds; larger models take 10–30 s per reply but produce better code. For quick experiments use a 1B–3B model; for real coding tasks use 7B+.

**Coding-specialist models.** Models with `coder` in the name (e.g. `qwen2.5-coder`, `deepseek-coder`) are fine-tuned on source code and tend to outperform general models of the same size on programming tasks.

**Changing models.** Update the env var and restart:

```bash
export CHUMP_MODEL=qwen2.5-coder:14b
chump --once 'write a hello-world in Rust'
```

Add the export to `~/.zshrc` to make it permanent.

---

## 3. Common workflows

### 3.1 One-shot coding task

Use this when you want a quick answer or a small code change without setting up a full gap.

```bash
chump --once 'Add a /health endpoint to my Axum server in src/main.rs'
```

The agent writes code to stdout. Review it, then paste into your editor.

---

### 3.2 Reserve a gap and dispatch a worker

Use this for anything larger than a one-liner — the agent works in an isolated worktree and opens a PR when done.

```bash
# 1. Describe the work
chump gap reserve --domain DEMO --title "Add input validation to the login form"

# 2. Note the GAP-ID printed (e.g. DEMO-007), then dispatch
chump dispatch --gap DEMO-007 --workers 1

# 3. Watch progress (Ctrl-C to stop watching; work continues)
tail -f .chump-locks/ambient.jsonl
```

When the agent finishes it opens a pull request. Review the PR in your browser or with `gh pr view`.

---

### 3.3 Run multiple gaps in parallel (fleet mode)

When you have several independent tasks ready, run them in parallel:

```bash
# Reserve two gaps
chump gap reserve --domain DEMO --title "Refactor auth module"
chump gap reserve --domain DEMO --title "Add CSV export"

# Dispatch 2 workers (one per gap)
chump dispatch --workers 2
```

The dispatcher assigns each worker to an unclaimed gap automatically.

> **How many workers?** A safe starting point is one worker per 8 GB of RAM you can spare after the model is loaded. On a 24 GB Mac running a 9 GB model you have ~15 GB left — 2 workers is comfortable.

---

### 3.4 Check what's in the queue

```bash
chump gap list --status open
```

This shows every open gap with its priority, domain, and whether it has been claimed.

---

### 3.5 Review and merge a finished PR

```bash
gh pr list                        # see open PRs
gh pr view <NUMBER>               # read the description
gh pr diff <NUMBER>               # review the diff
gh pr merge <NUMBER> --squash     # merge when happy
```

---

### 3.6 Cancel or abandon a gap

If you change your mind:

```bash
chump gap set <GAP-ID> --status closed
```

If a worker is still running, kill its terminal pane first, then release its lease:

```bash
chump --release   # run inside the worker's session, or:
rm .chump-locks/<session-id>.json
```

---

## 4. Troubleshooting

### "connection refused" when running `chump --once`

Ollama is not running.

```bash
ollama serve &
```

If it was already running but died, check the log:

```bash
cat /tmp/ollama-serve.log 2>/dev/null || journalctl -u ollama --no-pager | tail -20
```

---

### The agent is very slow (> 60 s per reply)

1. **Check model size.** If you pulled a model larger than your RAM allows, the OS swaps to disk — performance collapses. Run `ollama list` and switch to a smaller model.

2. **Keep the model loaded.** By default Ollama unloads the model after 5 minutes. Set `OLLAMA_KEEP_ALIVE=-1` to keep it hot:

   ```bash
   export OLLAMA_KEEP_ALIVE=-1
   ollama serve &
   ```

3. **Free RAM.** Quit browsers and Electron apps before starting a long session. On Apple Silicon, every byte of unified memory freed goes directly to the GPU:

   ```bash
   scripts/setup/enter-chump-mode.sh   # if you have this script
   ```

4. **Use the speed startup script:**

   ```bash
   scripts/setup/ollama-serve-fast.sh
   ```

---

### The agent produces garbled or incomplete code

- Switch to a larger or coding-specialist model (see [§2](#2-choosing-a-model-for-your-hardware)).
- Reduce `OLLAMA_CONTEXT_LENGTH` if it is set above 4096 — very long contexts degrade quality on small models.
- Add more detail to your gap title or use `--once` with a longer description.

---

### "gap is not pickable" / preflight fails

```bash
chump gap show <GAP-ID>    # read the gap details
```

Common causes:

| Symptom | Fix |
|---------|-----|
| `status: closed` | The gap is already done — file a new one if needed. |
| `depends_on` lists an open gap | Complete the dependency first. |
| Another session holds the lease | Wait for it to finish or release the stale lease: `rm .chump-locks/<session>.json` |

---

### PR opened but never merged / CI is stuck

```bash
gh pr checks <NUMBER>    # see which check is failing
gh pr view <NUMBER>      # read the PR body for hints
```

If CI passes but auto-merge hasn't fired:

```bash
gh pr merge <NUMBER> --auto --squash
```

---

### "no valid auth path found" (`chump fleet doctor`)

Chump needs either an Anthropic API key or a Claude subscription OAuth token for cloud-model workers. For fully offline use with Ollama only, set:

```bash
export OPENAI_API_BASE=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export CHUMP_MODEL=<your-ollama-model>
```

Then re-run `chump fleet doctor` — it should pass.

---

### Out-of-memory crash (macOS "killed" message or Ollama restarts)

Your model is too large for available RAM. Fix:

1. Pull a smaller model: `ollama pull llama3.2:1b`
2. Set `CHUMP_MODEL=llama3.2:1b`
3. Restart Ollama: `pkill -f ollama && ollama serve &`

For ongoing stability with larger models see [`howto/GPU_TUNING.md`](howto/GPU_TUNING.md).

---

## 5. Quick reference

```bash
# One-shot task (no gap)
chump --once '<describe what you want>'

# Reserve a gap
chump gap reserve --domain DEMO --title '<what you want done>'

# List open gaps
chump gap list --status open

# Claim and work a gap manually
chump claim <GAP-ID>

# Dispatch workers (auto-picks gaps)
chump dispatch --workers <N>

# Watch live activity
tail -f .chump-locks/ambient.jsonl

# Health check
chump fleet doctor

# Release a lease (cleanup)
chump --release

# Change model
export CHUMP_MODEL=<model-name>
```

---

**Next steps:**
- Faster inference: [`howto/OLLAMA_SPEED.md`](howto/OLLAMA_SPEED.md)
- Apple Silicon memory tuning: [`howto/GPU_TUNING.md`](howto/GPU_TUNING.md)
- First-run setup detail: [`howto/SETUP_AND_RUN.md`](howto/SETUP_AND_RUN.md)
