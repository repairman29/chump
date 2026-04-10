# Consciousness framework metrics

Canonical definitions for measuring the Chump-to-Complex transition. Each metric is computable from the SQLite DB, `/health` endpoint, or logs. See [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) for context.

---

## 1. Surprisal EMA

**What it measures:** How well the agent predicts tool outcomes and latencies. Declining EMA means the agent is calibrating.

**Source:** `surprise_tracker::current_surprisal_ema()` (in-process); DB fallback below.

**SQL (from `chump_prediction_log`):**

```sql
-- Overall mean surprisal
SELECT AVG(surprisal) FROM chump_prediction_log;

-- Per-tool mean surprisal (tools with >= 3 calls)
SELECT tool, ROUND(AVG(surprisal), 3) AS avg_surprisal, COUNT(*) AS calls
FROM chump_prediction_log
GROUP BY tool HAVING COUNT(*) >= 3
ORDER BY avg_surprisal DESC;

-- High-surprise percentage (above 0.5 threshold)
SELECT CAST(SUM(CASE WHEN surprisal > 0.5 THEN 1 ELSE 0 END) AS REAL) / COUNT(*) * 100
FROM chump_prediction_log;

-- Trend: average surprisal per 50-prediction window
SELECT (rowid / 50) AS window,
       ROUND(AVG(surprisal), 4) AS avg_surprisal,
       COUNT(*) AS n
FROM chump_prediction_log
GROUP BY window ORDER BY window;
```

**Target:** Steadily decreasing over sessions; per-tool averages converging.

---

## 2. Phi Proxy

**What it measures:** Degree of inter-module coupling via the blackboard. Higher = modules are actively reading each other's outputs, not operating in isolation.

**Source:** `phi_proxy::compute_phi()` → `PhiMetrics.phi_proxy`; also `GET /health` → `consciousness_dashboard.phi_proxy`.

**Computation:** `0.35 * coupling_score + 0.35 * cross_read_utilization + 0.30 * information_flow_entropy`

Where:
- `coupling_score` = active cross-module read pairs / total possible pairs
- `cross_read_utilization` = entries read by non-author / total entries
- `information_flow_entropy` = normalized Shannon entropy of read distribution

**Target:** > 0.3 sustained during active tool-using sessions.

---

## 3. Turn Duration (autonomous work time)

**What it measures:** How long the agent works without human intervention between messages.

**SQL (from `chump_episodes`):**

```sql
-- Average episode duration (proxy: time between consecutive episode logs)
SELECT AVG(julianday(e2.happened_at) - julianday(e1.happened_at)) * 86400 AS avg_gap_secs
FROM chump_episodes e1
JOIN chump_episodes e2 ON e2.id = e1.id + 1;
```

**Log-based:** Parse `tracing` output for `agent_turn` span durations; sum consecutive tool-use turns between user messages.

**Target:** Minutes to hours of self-directed goal pursuit (currently seconds per reactive turn).

---

## 4. Auto-approve Rate

**What it measures:** Percentage of tool calls executed without requiring human approval. Higher = the agent is using safe tools and the approval policy trusts it.

**Computation:**

```
auto_approve_rate = (total_tool_calls - approval_requests) / total_tool_calls * 100
```

**Sources:**
- `tool_middleware::tool_calls_total()` (total tool calls)
- `chump.log` lines with event **`tool_approval_audit`** (`grep tool_approval_audit`). The **`result`** field includes **`allowed`**, **`denied`**, **`timeout`**, **`auto_approved_cli_low`** (low-risk `run_cli` when `CHUMP_AUTO_APPROVE_LOW_RISK=1`), and **`auto_approved_tools_env`** (tools listed in `CHUMP_AUTO_APPROVE_TOOLS`).

**SQL (from `chump_tool_health`):**

```sql
-- Total tool calls (proxy)
SELECT SUM(total_calls) FROM chump_tool_health;
```

**Target:** > 90% for routine tasks.

---

## 5. Causal Inference Score (CIS)

**What it measures:** Precision of counterfactual lessons — what fraction are actually correct when reviewed by a human.

**SQL (from `chump_causal_lessons`):**

```sql
-- Lessons by confidence and application count
SELECT lesson, confidence, times_applied, created_at
FROM chump_causal_lessons
ORDER BY confidence DESC
LIMIT 20;

-- Failure pattern distribution
SELECT task_type, COUNT(*) AS cnt
FROM chump_causal_lessons
WHERE task_type IS NOT NULL AND task_type != ''
GROUP BY task_type ORDER BY cnt DESC;

-- Lessons that were applied (validated in context)
SELECT COUNT(*) AS applied, (SELECT COUNT(*) FROM chump_causal_lessons) AS total
FROM chump_causal_lessons WHERE times_applied > 0;
```

**Human labeling required:** Export top-20 lessons → human marks each correct/incorrect → CIS = correct / total.

**Target:** > 70% precision on reviewed lessons.

---

## 6. Thermodynamic Efficiency

**What it measures:** Work output per unit of computational resource consumed.

**Computation:**

```
efficiency = tasks_completed / (tokens_spent + tool_calls_made)
```

**Sources:**
- `cost_tracker::summary()` for tokens spent
- `tool_middleware` for tool call count
- `task_db` for tasks moved to `done` status

**SQL:**

```sql
-- Tasks completed (proxy for "work done")
SELECT COUNT(*) FROM chump_tasks WHERE status = 'done';

-- Total tool calls
SELECT SUM(total_calls) FROM chump_tool_health;
```

**Target:** Improving trend over sessions (ratio should increase as the agent becomes more efficient).

---

## 7. Phi–Surprisal Correlation

**What it measures:** Whether integration and calibration co-evolve — per the research literature, higher Φ should correlate with lower surprisal over time.

**Computation:** Pearson correlation between phi_proxy values and inverse surprisal EMA values, sampled once per session.

**Data collection:** At `close_session`, `record_session_consciousness_metrics()` appends `(session_id, phi_proxy, surprisal_ema, coupling_score, regime)` to the `chump_consciousness_metrics` table (created in `db_pool::init_schema`, written from `context_assembly.rs`).

**Target:** Negative correlation (r < -0.3) over > 20 sessions.

---

## Baseline capture

Run `scripts/consciousness-baseline.sh` to snapshot all DB-derived metrics to `logs/consciousness-baseline.json`. The script also captures the `/health` consciousness dashboard when `CHUMP_HEALTH_PORT` is set.

Compare baselines across runs:

```bash
diff <(jq . logs/consciousness-baseline-before.json) <(jq . logs/consciousness-baseline-after.json)
```

---

## A/B testing

Set `CHUMP_CONSCIOUSNESS_ENABLED=0` to disable all consciousness module injections in `context_assembly`. Run the same prompt set with and without; compare task success, tool call count, and latency. See Section 1.2 of [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md).
