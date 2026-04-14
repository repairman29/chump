# Docker sidecar profile

One-command local setup: **Ollama + Chump Web PWA**.

## Quick start

```bash
cd docker
docker compose up
# Open http://localhost:3000
```

First run builds the Chump binary (~3 min) and pulls the default model (~4.4 GB).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_MODEL` | `qwen2.5:7b` | Model to pull and use |
| `CHUMP_WEB_TOKEN` | _(none)_ | Bearer token for PWA auth |
| `CHUMP_OLLAMA_KEEP_ALIVE` | `30m` | How long Ollama keeps model in memory |

Override with:

```bash
OLLAMA_MODEL=qwen2.5:14b docker compose up
```

## What's included

- **ollama** — Model server on port 11434
- **ollama-pull** — One-shot model pull (waits for ollama healthy)
- **chump-web** — Chump PWA on port 3000 with `CHUMP_LIGHT_CONTEXT=1`

## Volumes

- `ollama_data` — Cached model weights (survives `docker compose down`)
- `chump_data` — Chump sessions/SQLite state
- `chump_logs` — Chump server logs

## Teardown

```bash
docker compose down           # stop, keep data
docker compose down -v        # stop + delete volumes
```
