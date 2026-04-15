# Model testing and dogfood — logs you can tail

Use **one terminal** to watch progress while you stress the model elsewhere (battle QA, PWA chat, Discord, autonomy).

## One command (recommended)

From repo root:

```bash
chmod +x ./scripts/tail-model-dogfood.sh   # once
./scripts/tail-model-dogfood.sh
```

This runs `tail -F` on every **existing** file among:

| File | When it gets lines |
|------|---------------------|
| `logs/battle-qa.log` | [Battle QA](BATTLE_QA.md) / `battle-qa.sh` |
| `logs/chump.log` | Web (`chump --web`), CLI tool audit, approvals |

Add more paths (comma-separated, repo-relative):

```bash
CHUMP_TAIL_LOGS="logs/battle-pwa-live.log,logs/discord.log,logs/ollama-serve.log" ./scripts/tail-model-dogfood.sh
```

If nothing exists yet, the script prints what to start first.

## Manual tails (single file)

```bash
tail -F logs/battle-qa.log
tail -F logs/chump.log
tail -F logs/battle-pwa-live.log    # ./scripts/battle-pwa-live.sh
```

Battle QA also writes **`logs/battle-qa-failures.txt`** (append on failures)—good for `tail -F` after a run starts failing.

## JSONL / timing runs

- **Golden path timing:** `logs/golden-path-timing-*.jsonl` — use `ls -t logs/golden-path-timing-*.jsonl | head -1` then `tail -f` that file while [golden-path-timing.sh](../scripts/golden-path-timing.sh) runs.
- **Latency envelope:** [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) → `logs/latency-envelope-*.jsonl` from [`scripts/latency-envelope-measure.sh`](../scripts/latency-envelope-measure.sh).

## In-app / API “tails”

- **Dashboard:** `GET /api/dashboard` includes `ship_log_tail` and related fields ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)).
- **Jobs:** `GET /api/jobs` for async autonomy / job lines in SQLite.

## Dogfood checklists

- **PWA / desktop week:** [UI_WEEK_SMOKE_PROMPTS.md](UI_WEEK_SMOKE_PROMPTS.md) (day 1 expects `chump.log` tail).
- **Battle QA deep run:** [BATTLE_QA.md](BATTLE_QA.md).
