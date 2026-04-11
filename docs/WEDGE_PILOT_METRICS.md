# Wedge pilot metrics (H1: intent → task → autonomy / Cursor → done)

**Purpose:** Give pilots a **repeatable way** to answer north-star metrics **N3** and **N4** from [MARKET_EVALUATION.md](MARKET_EVALUATION.md) without ad hoc log spelunking (SQL + **`GET /api/pilot-summary`**).

**Database file:** `sessions/chump_memory.db` at **repo root** (or `CHUMP_HOME` / `CHUMP_REPO` runtime base per [OPERATIONS.md](OPERATIONS.md)). Same file as episodic memory and tool call ring buffer.

**CLI:** `sqlite3 sessions/chump_memory.db` (or absolute path). Read-only queries below are safe.

---

## 1. Tasks (throughput and outcomes)

**Open tasks by assignee:**

```sql
SELECT status, assignee, COUNT(*) AS n
FROM chump_tasks
GROUP BY status, assignee
ORDER BY status, assignee;
```

**Recently updated tasks (pilot week):** `updated_at` is stored as epoch seconds with fractional part (string). Rough filter for “last 7 days” in wall time—adjust the cutoff:

```sql
SELECT id, title, status, assignee, updated_at
FROM chump_tasks
WHERE CAST(updated_at AS REAL) > (strftime('%s', 'now') - 7*86400)
ORDER BY id DESC
LIMIT 50;
```

**Done rate (all time):**

```sql
SELECT status, COUNT(*) FROM chump_tasks GROUP BY status;
```

**Export JSON for a spreadsheet (requires sqlite3 JSON1):**

```sql
.mode json
.once /tmp/chump_tasks_export.json
SELECT id, title, status, assignee, created_at, updated_at FROM chump_tasks ORDER BY id DESC LIMIT 200;
```

---

## 2. Tool calls (includes `run_cli` / Cursor handoff proxy)

Ring buffer **last 200** rows only ([introspect_tool.rs](../src/introspect_tool.rs)).

**Recent `run_cli` calls (Cursor CLI is usually invoked via `run_cli`):**

```sql
SELECT tool, args_snippet, outcome, called_at
FROM chump_tool_calls
WHERE tool LIKE '%run_cli%' OR args_snippet LIKE '%agent%'
ORDER BY id DESC
LIMIT 30;
```

**All recent tools:**

```sql
SELECT tool, substr(args_snippet,1,120) AS args, outcome, called_at
FROM chump_tool_calls
ORDER BY id DESC
LIMIT 40;
```

**API (no SQL):** With `CHUMP_HEALTH_PORT` set and Discord/health sidecar up, `GET http://127.0.0.1:<port>/health` includes `recent_tool_calls` ([ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md)).

---

## 3. Cursor / RPC JSONL mirror (optional)

If `CHUMP_RPC_JSONL_LOG` is set to a file path, `chump --rpc` appends each JSONL line to that file ([rpc_mode.rs](../src/rpc_mode.rs)). Count automation turns:

```bash
wc -l "$CHUMP_RPC_JSONL_LOG"
grep -c '"type":"event"' "$CHUMP_RPC_JSONL_LOG" || true
```

Correlate timestamps with task status changes in SQLite.

---

## 4. Episodes (narrative trail)

**Recent episodes (summary):**

```sql
SELECT id, happened_at, substr(summary,1,120) AS summary, tags, sentiment
FROM chump_episodes
ORDER BY id DESC
LIMIT 30;
```

Autonomy rounds often leave summaries containing task ids or “autonomy”—filter:

```sql
SELECT id, happened_at, summary
FROM chump_episodes
WHERE lower(summary) LIKE '%autonomy%' OR lower(summary) LIKE '%task%'
ORDER BY id DESC
LIMIT 20;
```

---

## 5. Web API (minimal SQL)

### `GET /api/pilot-summary` (N4 aggregate JSON)

Read-only snapshot: `tasks_by_status`, `tasks_total`, `episodes_total`, `tool_calls_ring_buffer_rows`, `run_cli_invocations_in_ring`, `last_tool_calls_sample`, `speculative_batch_last`. Same **Bearer** rule as `POST /api/tasks` when `CHUMP_WEB_TOKEN` is set ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)).

```bash
./scripts/export-pilot-summary.sh
# or:
curl -sS -H "Authorization: Bearer $CHUMP_WEB_TOKEN" "http://127.0.0.1:${CHUMP_WEB_PORT:-3000}/api/pilot-summary" | python3 -m json.tool
```

### Other web calls (no SQL)

| Metric | Call |
|--------|------|
| Task list for briefing | `curl -s http://127.0.0.1:3000/api/briefing \| jq '.sections'` (shape varies; includes tasks when configured) |
| Raw tasks | `curl -s http://127.0.0.1:3000/api/tasks` — requires `Authorization: Bearer …` when `CHUMP_WEB_TOKEN` is set |

---

## 6. Mapping to N3 / N4

| North star | Pilot instrument |
|------------|------------------|
| **N3** Autonomy throughput | Count `done` / `blocked` transitions per week (SQL on `chump_tasks`); run `./scripts/run-autonomy-tests.sh` for regression; optional `./target/release/chump --autonomy-once` counts |
| **N4** Outcome / PR attribution | **`GET /api/pilot-summary`** + `./scripts/export-pilot-summary.sh` for weekly aggregates; **PR URLs** still manual or in task `notes` / episodes until GitHub linkage |

---

## Related

- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §3  
- [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md)  
- [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)  
