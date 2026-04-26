---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Wedge H1 Golden Path Extension

Extends [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) with the PWA task flow and optional `autonomy_once` flag. This is the complete "aha moment" path for new users.

See [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) for the PWA-only path (no Discord required).

## What this covers

The H1 golden extension adds two things beyond the base golden path:
1. **PWA task creation** — user submits their first task via the web UI Tasks panel
2. **`autonomy_once` flag** — Chump picks up the task autonomously without prompting

## Prerequisites

Base golden path complete (Chump running, Ollama model pulled). See [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).

## Extended steps

### Step 6 — Open the Tasks panel

Navigate to `http://localhost:5173`. Click **Tasks** in the sidebar. The task creation form opens.

### Step 7 — Submit your first task

Type a simple, bounded task. Good first tasks:
- "List the 5 most recently modified files in this repo"
- "Summarize the last 3 git commits"
- "What are the open P1 gaps?"

Click **Submit** (or press Enter).

### Step 8 — Watch autonomous execution

Chump streams tool calls in the Activity feed. You'll see:
1. Intent classified (e.g. `status_query`)
2. Tool call fired (e.g. `list_gaps`)
3. Response generated and streamed

Total time: 10–30 seconds on local Ollama 14B.

### Step 9 — Autonomy once (optional)

If `CHUMP_AUTONOMY_MODE=1` is set in `.env`, Chump will pick up the next open gap from `docs/gaps.yaml` autonomously after your session ends. This is the "set it and go" mode.

To trigger a single autonomy run without persistent mode:

```bash
curl -X POST http://localhost:5173/api/autonomy_once \
  -H "Authorization: Bearer $CHUMP_WEB_TOKEN"
```

Chump will: pick a gap → claim lease → implement → open PR → release lease.

## Smoke test script

```bash
# wedge-h1-smoke.sh — run after setup to verify the golden path works
scripts/wedge-h1-smoke.sh

# Checks:
# 1. Web server responds at :5173
# 2. Task submit returns a streaming response
# 3. Tool call appears in activity feed
# 4. Session ends cleanly (no orphaned tool calls)
```

## See Also

- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) — base first-install path
- [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) — PWA-only path detail
- [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) — N1–N4 tier metrics
