# Wedge Pilot Metrics

SQL queries, API endpoints, and JSONL recipes for measuring pilot success at the N3 (engaged user) and N4 (daily driver) retention tiers. See [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §8 for the framework.

## Tier definitions

| Tier | Definition | Metric |
|------|------------|--------|
| **N1** | Installed and ran once | `chump_sessions` count ≥ 1 |
| **N2** | Completed onboarding (FTUE) | `chump_memory` has `ftue_complete = true` |
| **N3** | Engaged — 3+ sessions, 1+ tasks completed | Sessions ≥ 3 AND tasks completed ≥ 1 |
| **N4** | Daily driver — active 5 of last 7 days | Active days ≥ 5 in last 7 days |

---

## SQL queries

### N3: Engaged users (sessions ≥ 3, tasks completed ≥ 1)

```sql
-- Count sessions per user (pilot: single-user, so count total)
SELECT
  COUNT(*) as total_sessions,
  COUNT(DISTINCT date(start_time)) as active_days,
  (SELECT COUNT(*) FROM chump_tasks WHERE status = 'complete') as tasks_completed
FROM chump_sessions;

-- Pass N3 if: total_sessions >= 3 AND tasks_completed >= 1
```

### N4: Daily driver (5 of last 7 days active)

```sql
SELECT COUNT(DISTINCT date(start_time)) as recent_active_days
FROM chump_sessions
WHERE start_time >= datetime('now', '-7 days');

-- Pass N4 if: recent_active_days >= 5
```

### Tool usage breadth

```sql
SELECT tool_name, COUNT(*) as calls, AVG(duration_ms) as avg_ms
FROM chump_tool_health
WHERE called_at >= datetime('now', '-30 days')
GROUP BY tool_name
ORDER BY calls DESC;
```

### Memory growth (engagement signal)

```sql
SELECT COUNT(*) as memory_count,
       AVG(confidence) as avg_confidence,
       MIN(created_at) as first_memory,
       MAX(created_at) as latest_memory
FROM chump_memory
WHERE memory_type != 'ephemeral';
```

---

## API endpoints

### Pilot summary export

```bash
GET /api/pilot-summary
Authorization: Bearer $CHUMP_WEB_TOKEN

# Returns JSON with N1/N2/N3/N4 tier status + key metrics
```

```json
{
  "tiers": {
    "n1": true,
    "n2": true,
    "n3": { "pass": true, "sessions": 12, "tasks_completed": 4 },
    "n4": { "pass": false, "recent_active_days": 3 }
  },
  "memory_count": 47,
  "tool_calls_30d": 312,
  "top_tools": ["read_file", "task", "memory"],
  "last_session": "2026-04-18T22:14:00Z"
}
```

### Export via script

```bash
./scripts/export-pilot-summary.sh > logs/pilot-summary-$(date +%Y-%m-%d).json
```

---

## JSONL format for pilot data export

```jsonl
{"event":"session","ts":"2026-04-18T22:14:00Z","turns":8,"tools_used":["read_file","task","memory"]}
{"event":"task_complete","ts":"2026-04-18T22:20:00Z","task_id":"t_abc123","title":"Fix auth bug"}
{"event":"memory_write","ts":"2026-04-18T22:21:00Z","key":"user_preference_dark_mode","confidence":0.9}
```

---

## Smoke test for N3 milestone

```bash
# 1. Run 3 sessions with real tasks
./scripts/wedge-h1-smoke.sh --tier n3

# Checks: sessions >= 3, tasks_completed >= 1, /api/health returns ok
# Exit 0 = N3 pass, exit 1 = not yet
```

---

## See Also

- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — full market evaluation framework
- [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — `/api/pilot-summary` spec
- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) — N1→N2 onboarding path
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) — friction points blocking N2 conversion
