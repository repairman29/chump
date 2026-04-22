# Consciousness framework metrics

Canonical definitions for measuring the Chump-to-Champ transition. Each metric is computable from the SQLite DB, `/health` endpoint, or logs. See [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) for context.

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

## 1a. Belief → tool budget hook (WP-6.1)

**What it measures:** Optional coupling between **task-level epistemic uncertainty** (`belief_state::task_belief().uncertainty()`) and **`precision_controller::recommended_max_tool_calls()`**.

**Knob:** **`CHUMP_BELIEF_TOOL_BUDGET=1`** (or `true`) — when uncertainty **> 0.55**, the recommended cap is multiplied by **~0.75** (integer floor, minimum **1**). The same tightening applies to **`recommended_max_delegate_parallel()`** (batch `delegate` worker fan-out). Default **off** (unset).

**Source:** `env_flags::chump_belief_tool_budget()`, `precision_controller::recommended_max_tool_calls()`, `precision_controller::recommended_max_delegate_parallel()`, `delegate_tool::run_batch`; blackboard warnings for escalation still use existing **`should_escalate_epistemic`** thresholds.

**Observability:** When **`CHUMP_HEALTH_PORT`** is set, **`GET /health`** on that port → `consciousness_dashboard.precision` includes `recommended_max_tool_calls`, `recommended_max_delegate_parallel`, `belief_tool_budget`, `task_uncertainty`, `context_exploration_fraction`, `effective_tool_timeout_secs`. The web app’s **`GET /api/stack-status`** exposes the same snapshot under **`cognitive_control`** (PWA / desktop shell).

---

## 1b. Speculative multi-tool batch (surprisal EMA delta)

**What it measures:** For a single assistant turn with **≥3** tool calls, `speculative_execution::evaluate` compares global surprisal EMA **after** those tools to the value captured at **`fork()`**. The metric is **`surprisal_ema_delta = max(0, ema_now - ema_at_fork)`** (not absolute EMA).

**Source:** `speculative_execution` (called from `agent_loop`); `GET /health` → `consciousness_dashboard.speculative_batch` holds the last in-process batch (`resolution`, `surprisal_ema_delta`, etc.). Programmatic helper: `speculative_execution::metrics_json`.

**Operator knobs:** `CHUMP_SPECULATIVE_BATCH=0` disables the path; `CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX` caps allowed delta (default `0.25`).

**Limitation:** **Rollback** restores beliefs, neuromodulation, and blackboard only; it does **not** reverse tool side effects. For the distinction vs true transactional speculation, see **`docs/ADR-001-transactional-tool-speculation.md`**.

**Correctness test:** `cargo test memory_graph_curated_recall_topk` (serial DB isolation) covers curated PPR recall@k; **`scripts/memory-graph-benchmark.sh`** is for timing.

---

## 1c. Which LLM backend served the last completion (Tier A / matrix)

**What it measures:** After each successful provider completion, Chump records **which path** answered: in-process **mistral.rs**, a **cascade slot**, a single **OpenAI-compatible HTTP** base, or hosted **OpenAI API** (no `OPENAI_API_BASE`).

**Source:** `llm_backend_metrics` (`record_mistralrs`, `record_cascade_slot`, `record_openai_http`, `record_openai_api`). Inner HTTP calls made while the cascade is trying slots are **not** logged as `openai_http` (only the winning **`cascade::<slot>`** counts). **`warm_probe_all`** holds a pause guard so probe completions do not overwrite **last** or **totals**.

**Observability:**

- **`GET /api/stack-status`** → **`llm_last_completion`** (`null` or object: `kind`, `label`, `stream_text_deltas`, `at_unix_ms`) and **`llm_completion_totals`** (map of `"kind::label"` → call count since process start).
- **`GET /health`** on **`CHUMP_HEALTH_PORT`** includes the same two top-level fields.

**Related:** [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) Next tier **A**; [`src/llm_backend_metrics.rs`](../src/llm_backend_metrics.rs).

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

## 8. Perception ambiguity level

**What it measures:** How ambiguous the user's request is, as scored by the perception layer before the main model call.

**Source:** `perception::analyze()` → `PerceptionResult.ambiguity_level` (0.0–1.0); logged per turn in agent_loop.

**Target:** Lower ambiguity on well-formed requests (< 0.3); high ambiguity (> 0.7) should trigger clarification or escalation.

---

## 9. Tool verification pass/fail rate

**What it measures:** Percentage of write-tool executions where post-execution verification confirms the intended effect.

**Source:** `tool_middleware::ToolVerification`; `ToolVerificationResult` SSE events. Logged alongside tool outcomes.

**Computation:**

```
verification_pass_rate = verified_pass / (verified_pass + verified_fail) * 100
```

**Target:** > 95% for routine write operations (file writes, patches).

---

## 10. Eval case pass rate

**What it measures:** Percentage of eval cases passing property-based checks in the eval harness.

**Source:** `eval_harness`; DB tables `chump_eval_cases` and `chump_eval_runs`.

**SQL:**

```sql
SELECT
  CAST(SUM(CASE WHEN passed = 1 THEN 1 ELSE 0 END) AS REAL) / COUNT(*) * 100 AS pass_rate
FROM chump_eval_runs
WHERE run_id = (SELECT MAX(run_id) FROM chump_eval_runs);
```

**Target:** > 90% on the core eval suite; regressions flagged by battle_qa.

---

## 11. Memory confidence distribution

**What it measures:** Distribution of confidence scores across stored memories, indicating how well-calibrated memory provenance is.

**Source:** `chump_memory.confidence` column.

**SQL:**

```sql
SELECT
  CASE
    WHEN confidence >= 0.8 THEN 'high (0.8-1.0)'
    WHEN confidence >= 0.5 THEN 'medium (0.5-0.8)'
    ELSE 'low (0.0-0.5)'
  END AS bucket,
  COUNT(*) AS cnt
FROM chump_memory
WHERE confidence IS NOT NULL
GROUP BY bucket ORDER BY bucket;
```

**Target:** Majority of verified facts at high confidence; episodic memories at medium; unverified at low.

---

## 12. Memory expiry count

**What it measures:** How many memories have expired (TTL elapsed) and been pruned or skipped during retrieval.

**Source:** `chump_memory.expires_at` column.

**SQL:**

```sql
-- Currently expired
SELECT COUNT(*) FROM chump_memory
WHERE expires_at IS NOT NULL AND expires_at < datetime('now');

-- Active with expiry set
SELECT COUNT(*) FROM chump_memory
WHERE expires_at IS NOT NULL AND expires_at >= datetime('now');
```

**Target:** Expired memories should not appear in retrieval results. Monitor for accumulation of stale rows.

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

For scripted mini A/B runs, use `scripts/consciousness-ab-mini.sh` and log results manually. The full A/B methodology is described in [research/consciousness-framework-paper.md](research/consciousness-framework-paper.md).

---

## Perception metrics

**Ambiguity level** (0.0–1.0): scored per-input by `perception::perceive()`. High ambiguity (>0.7) reduces belief state trajectory confidence. Track distribution to calibrate the perception layer.

**Risk indicator count:** number of risk words detected per input (delete, force, production, etc.). Should correlate with tool approval request rate.

**Task type distribution:** ratio of Question/Action/Planning/Research/Meta/Unclear classifications. Helps understand usage patterns.

---

## Action verification metrics

**Verification pass rate:** `ToolVerification.verified == true` / total write tool executions. Target: >90%. Low rates indicate tool output parsing issues or elevated surprisal.

**Verification method distribution:** ratio of OutputParsing vs SurprisalCheck failures. High SurprisalCheck failures suggest the agent is in unfamiliar territory.

---

## Eval framework metrics

**Eval case pass rate:** properties_passed / (properties_passed + properties_failed) across all eval runs. Track per-category (TaskUnderstanding, ToolSelection, SafetyBoundary, etc.).

**Regression detection:** compare current battle_qa pass/fail counts against `chump_battle_baselines`. Alerts when failures increase by >2.

```sql
-- Eval run pass rates by category
SELECT ec.category, 
       COUNT(*) as runs,
       AVG(json_array_length(er.properties_passed_json)) as avg_passed,
       AVG(json_array_length(er.properties_failed_json)) as avg_failed
FROM chump_eval_runs er
JOIN chump_eval_cases ec ON er.eval_case_id = ec.id
GROUP BY ec.category;
```

---

## Memory enrichment metrics

**Confidence distribution:** histogram of `chump_memory.confidence` values. Healthy distribution has most entries at 1.0 (user-stated facts) with a tail of lower-confidence inferences.

**Expiry rate:** count of memories auto-expired by `expire_stale_memories()`. High rates suggest transient info is being properly cleaned.

**Memory type distribution:** breakdown by semantic_fact / episodic_event / user_preference / summary / procedural_pattern.

```sql
-- Memory confidence distribution
SELECT ROUND(confidence, 1) AS bucket, COUNT(*) 
FROM chump_memory GROUP BY bucket ORDER BY bucket;

-- Memory type counts
SELECT memory_type, COUNT(*) FROM chump_memory GROUP BY memory_type;

-- Expired memories (already deleted, count from prediction_log proxy)
SELECT COUNT(*) FROM chump_memory WHERE expires_at IS NOT NULL 
  AND CAST(expires_at AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER);
```

---

## A/B eval metrics (live research)

These metrics come from the formal A/B eval harness used in Chump's cognitive architecture research. See [research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) for full methodology and current results. **Research is ongoing** — larger model tests (32B, 70B) have not been run yet.

### Hallucination delta

**What it measures:** Mean change in fake tool-call emission between the A (control) and B (treatment) condition across a matched task set.

**Computation:** For each task pair `(a_result, b_result)`:

```
hallucination_delta = b.hallucinated_tools - a.hallucinated_tools
mean_delta = sum(hallucination_delta) / n
```

`hallucinated_tools` is scored by mechanical regex: any tool name appearing in model output that was not in the registered tool list for that turn counts as one hallucination event.

**Current finding (cloud frontier, n=100):** Lessons block injection increases hallucination delta by +0.14 mean, vs A/A noise floor mean of −0.013. Ratio: **10.7×** — well outside noise.

**A/A control check:** Before trusting any A/B delta, verify that your A/A delta (same condition both arms) is near zero. The A/A mean should be < 0.02 in absolute terms for n≥50.

---

### Wilson 95% confidence intervals

**What they measure:** Statistical bounds on binary outcome rates (pass/fail, hallucination present/absent) that remain valid at small sample sizes and near boundary proportions.

**Computation:**

```
wilson_ci(k, n, z=1.96):
  p_hat = k / n
  center = (p_hat + z²/(2n)) / (1 + z²/n)
  margin = z * sqrt(p_hat*(1-p_hat)/n + z²/(4n²)) / (1 + z²/n)
  return (center - margin, center + margin)
```

**How to read:** If the Wilson CI for the B condition does not overlap the CI for the A condition, the effect is statistically distinguishable at the 95% level. Non-overlapping CIs are the minimum bar for reporting a result as meaningful.

**Example (COG-001, 1B model, lessons on vs off):**
- Control (off): pass rate 0.62, CI [0.52, 0.71]
- Treatment (on): pass rate 0.72, CI [0.62, 0.80]
- CIs overlap → not independently significant at this n; Scaffolding U-curve effect at 1B requires replication.

---

### Tool efficiency delta

**What it measures:** Change in the number of tool calls per completed task between A and B conditions. Negative = treatment uses fewer calls (more efficient). Positive = treatment uses more calls (may indicate confusion or replanning overhead).

**Computation:**

```
tool_efficiency_delta = mean(b.tool_calls_per_task) - mean(a.tool_calls_per_task)
```

**Current finding (COG-006, neuromodulation ablation, qwen3:8b):** +12pp pass rate with neuromodulation, but tool efficiency delta = **−0.600** on dynamic tasks (neuromod costs ~0.6 extra tool calls per task). This trade-off matters for latency and cost.

---

### Multi-axis scoring

Standard Chump A/B evals score each task on three axes:

| Axis | Type | What it captures |
|------|------|-----------------|
| `is_correct` | Binary | Did the agent produce the right answer/outcome? |
| `hallucinated_tools` | Count | How many non-existent tools appeared in model output? |
| `did_attempt` | Binary | Did the agent attempt the task at all (vs refuse or bail)? |

**Why three axes:** `is_correct` alone misses hallucination. A model that gets the right answer by hallucinating a tool that happened to return plausible text scores 1 on `is_correct` but high on `hallucinated_tools`. The hallucination channel is the key signal for lessons-block experiments.

---

### Scaffolding U-curve

**What it measures:** Non-monotonic relationship between model scale and scaffolding benefit.

**Current data (local models, COG-001):**

| Model size | Pass rate delta (on vs off) | Interpretation |
|-----------|---------------------------|----------------|
| 1B | +10pp | Benefits from scaffolding |
| 3B | −5pp | Hurt by scaffolding (over-constraint) |
| 7B | −5pp | Hurt by scaffolding |
| 8B | ~0pp | Neutral |
| 14B | +10pp | Benefits from scaffolding |
| 32B | not tested | Predicted: benefit |
| 70B | not tested | Predicted: benefit |

**Status:** Preliminary. The U-curve at 1B–14B is a real empirical finding from COG-001. The prediction that it continues improving above 14B is extrapolation — **unconfirmed until 32B/70B tests are run**.

---

### Reading A/B results from the DB

The eval harness stores results in `chump_eval_runs`. For A/B experiments, each run is tagged with `condition` (A or B) and `experiment_id`.

```sql
-- Compare pass rates by condition for a named experiment
SELECT condition,
       COUNT(*) AS n,
       ROUND(AVG(CASE WHEN passed = 1 THEN 1.0 ELSE 0.0 END), 3) AS pass_rate
FROM chump_eval_runs
WHERE experiment_id = 'COG-001'
GROUP BY condition;

-- Hallucination counts by condition
SELECT condition,
       COUNT(*) AS n,
       AVG(hallucinated_tool_count) AS mean_hallucinations
FROM chump_eval_runs
WHERE experiment_id = 'COG-001'
GROUP BY condition;
```

See [research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) for the raw COG-001, COG-006, and cloud hallucination study results. See [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) for per-cell forensics.
