# Chump Offline Quickstart

> **Goal:** A working AI coding agent on your Mac — no Anthropic key, no OpenAI key, no cloud bill.
> **Time:** ~15 min (most of it is the model download).
> **Tested on:** author's Mac (Apple Silicon, 24 GB, macOS 14+). See `scripts/qa/test-offline-quickstart.sh` for the automated fixture.

---

## Step 1 — Install Chump

```bash
brew tap repairman29/chump
brew install chump
```

Verify:

```bash
chump --version
```

---

## Step 2 — Install Ollama and pull a model

[Ollama](https://ollama.com/) serves local LLMs over an OpenAI-compatible HTTP API.

```bash
brew install ollama
ollama serve &          # starts the inference server on port 11434
ollama pull llama3.2    # ~2 GB download; fits comfortably in 24 GB RAM
```

Wait for the pull to finish before continuing.

> **Smaller Mac (8–16 GB)?** Use `ollama pull llama3.2:1b` (~800 MB) instead.
> **Want better quality?** `ollama pull llama3.2:70b` needs ~48 GB unified memory.

---

## Step 3 — Point Chump at Ollama

Chump speaks the OpenAI API wire format, so you just redirect the base URL:

```bash
export OPENAI_API_BASE=http://localhost:11434/v1
export OPENAI_API_KEY=ollama          # any non-empty string — Ollama ignores it
export CHUMP_MODEL=llama3.2           # match what you pulled
```

Add these three lines to your shell profile (`~/.zshrc` or `~/.bashrc`) so they survive reboots.

---

## Step 4 — Verify the agent

```bash
chump --once 'Hello — what model are you?'
```

You should see a reply from `llama3.2` in your terminal within a few seconds. If you see a connection error, make sure `ollama serve` is still running (`pgrep -l ollama`).

---

## Step 5 — Reserve your first gap and dispatch a fleet worker

Chump's dispatcher coordinates work across agent sessions. Try it end-to-end:

```bash
# 1. Reserve a gap (a unit of work)
chump gap reserve --domain DEMO --title "My first offline gap"

# 2. Claim it (creates an isolated git worktree + lease)
chump claim <GAP-ID>          # GAP-ID printed by the previous command

# 3. Dispatch one fleet worker against it
chump dispatch --gap <GAP-ID> --workers 1

# 4. Watch progress
tail -f .chump-locks/ambient.jsonl
```

The worker runs inside the worktree, commits its changes, and ships a PR — all locally, no cloud required.

---

## Authentication modes (API key vs subscription OAUTH)

Chump supports two Anthropic auth modes. Both are first-class — the fleet detects, prefers, and can fall back between them automatically.

| Mode | Credential | When to use |
|---|---|---|
| API key | `ANTHROPIC_API_KEY=sk-ant-...` | Pay-per-token accounts, CI, most users |
| Subscription OAUTH | `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...` | Claude subscription (Max / Pro) accounts |

### Auto-detection (default)

Set whichever credential you have and Chump figures out the rest:

```bash
export ANTHROPIC_API_KEY=sk-ant-...          # OR
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

When both are present, the API key is preferred. Override with:

```bash
export CHUMP_AUTH_MODE=oauth      # force subscription OAUTH
export CHUMP_AUTH_MODE=api-key    # force API key
export CHUMP_AUTH_MODE=auto       # default: prefer API key, fall back to OAUTH
```

### OAUTH token refresh (subscription mode)

Subscription OAUTH tokens expire. The fleet auto-refreshes them every 5 minutes by writing the current token to `~/.chump/oauth-token.json`. Workers re-read this file before each `claude -p` call so they always have a fresh token.

If a 401 occurs (both modes configured), the fleet falls back to the other mode and emits a `fleet_auth_fallback` event to `ambient.jsonl`.

### Validate your auth setup

```bash
chump fleet doctor    # validates both API key and OAUTH paths
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `connection refused` on port 11434 | Run `ollama serve` in a separate terminal |
| `model not found` | Run `ollama pull llama3.2` and retry |
| Slow first response | Normal — Ollama loads the model into RAM on first request |
| `chump: command not found` | Run `brew link chump` or restart your terminal |

---

## Next steps

- **Full setup guide:** [docs/process/EXTERNAL_GOLDEN_PATH.md](process/EXTERNAL_GOLDEN_PATH.md)
- **Fleet scaling:** [CLAUDE.md § Fleet scaling gate](../CLAUDE.md)
- **All docs:** [repairman29.github.io/chump](https://repairman29.github.io/chump/)
