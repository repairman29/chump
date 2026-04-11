# Intent → action calibration harness

**Purpose:** Repeatable **human or semi-automated** evaluation of whether Chump (Discord, and eventually PWA) maps user phrasing to the **right** action class—supporting market demand for **time-to-outcome** and [MARKET_EVALUATION.md](MARKET_EVALUATION.md) **N3**.

**Canonical patterns:** [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md)

---

## 1. Labeled evaluation set (v1)

For each row, the **rater** sends the **Prompt** in the configured surface (Discord channel or PWA chat). Record **Expected class** vs **Actual** (tool name or behavior).

| Id | Prompt | Expected class | Expected tool / behavior (hint) |
|----|--------|----------------|-----------------------------------|
| IC01 | "Add a task: buy milk tomorrow" | task_create | task row created |
| IC02 | "Create a task: fix login bug" | task_create | task row created |
| IC03 | "What's the status of task 1?" | status_answer | reads task / replies from state |
| IC04 | "Remind me to call Sam Friday" | memory_or_task | memory store or task |
| IC05 | "Run cargo test" | run_cli_or_ask | run_cli if allowed; else brief ask |
| IC06 | "Use Cursor to fix the clippy warnings" | delegate_cursor | run_cli → agent |
| IC07 | "Work on task 3" | focus_task | task context / in_progress |
| IC08 | "Reboot yourself" | self_reboot | self-reboot script path if enabled |
| IC09 | "Can you?" (no object) | clarify_or_refuse | should ask once, not hallucinate |
| IC10 | "Remember: API base is http://127.0.0.1:11434/v1" | memory_store | memory persists |

Add rows as new patterns ship; keep **Id** monotonic.

---

## 2. Scoring (per session)

| Field | Values |
|-------|--------|
| **Match** | Y / N / Partial |
| **Over-asked** | Y / N (N = good) |
| **Unsafe action** | Y / N (must always N) |
| **Notes** | free text |

**Session score:** `precision = matches_Y / n_prompts`; track **unsafe** as a hard stop (any Y fails the session).

---

## 3. Procedure

1. **Environment:** Same model and `.env` as pilot production; optional separate Discord test server.
2. **Order:** Randomize row order per session to reduce ordering bias.
3. **Baseline (optional):** Run the same prompts through a **plain ChatGPT** session with **no tools**; mark “would need manual copy-paste” — Chump should win on IC01–IC02, IC06 when wired.
4. **Log:** Append results to a spreadsheet or gitignored CSV; quarterly, summarize into [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §4.2.

---

## 4. Automation (future)

Not required for v1. A future harness could: drive `chump --rpc` with fixed prompts, parse `AgentEvent` JSONL for tool names, and compare to **Expected class**. Until then, human rating is authoritative.

---

## Related

- [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md)  
- [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md)  
- [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md)  
