# bot-merge.sh phase-progress heartbeat observability (INFRA-1732)

`bot-merge.sh` runs as a long unattended pipeline (rebase → build/test → push
→ PR → arm auto-merge → wait for merge → ship gap). A silent stall — the
process still alive but making no forward progress — was observed
2026-05-22 and was only caught by elapsed-time inspection, not by any
programmatic signal. This doc catalogs the ambient events that make
phase-progress observable so a stall can be detected by *pattern*, not by a
human noticing the clock.

## 1. Ambient events per phase-progress stage

All events are appended as one JSON line to `.chump-locks/ambient.jsonl`.

| Event kind | Emitted when | Key fields | Source |
|---|---|---|---|
| `bot_merge_step_started` | A tracked step begins (META-156 AC#1) | `step`, `gap`, `pid` | `scripts/coord/bot-merge.sh` (~L366) |
| `bot_merge_step_done` | The step's `started` counterpart completes, success or failure | `step`, `gap`, `pid`, `duration_ms`, `rc` | `scripts/coord/bot-merge.sh` (~L381) |
| `bot_merge_step_stalled` | A per-step `gtimeout` fires — the step exceeded its own budget | `step_name`, `elapsed_seconds`, `last_progress_ts`, `cmd_label`, `timeout_s`, `pid` | `scripts/coord/bot-merge.sh` (~L224, INFRA-2272) |
| `bot_merge_phase_duration` | A `run_timed_hb`-wrapped phase completes (success path) | `phase`, `elapsed_s`, `gap`, `branch` | `scripts/coord/bot-merge.sh` (~L1093) |
| `bot_merge_phase_failure` | A phase exits non-zero for a *named* reason (not a timeout) | `step`, `exit_code`, `gap_id`, `branch`, `note` | `scripts/coord/bot-merge.sh` (~L433, RESILIENT-011) |
| `bot_merge_timeout` | The overall run is killed by SIGTERM from the wall-clock budget watchdog, or the PR-poll loop hits its 15m hard cap | `gap`/`gap_id`, `phase`, `elapsed_s`, `budget_s`, (poll variant adds `pr`, `polls`, `source`) | `scripts/coord/bot-merge.sh` (~L324 INFRA-2426; ~L4030 INFRA-2119) |
| `bot_merge_hang` (ALERT) | A `run_timed_hb`-wrapped phase's `gtimeout` returns exit 124 — the phase itself hung | `phase`, `timeout_secs`, `gap_id` | `scripts/coord/bot-merge.sh` (~L1198, INFRA-587) |
| `botmerge_wedged` | A stage watchdog (`_bm_stage_watchdog`) sees a stage exceed its allotted budget without calling `stage_done()` | `stage`, `elapsed_s`, `budget_s`, `gap` | `scripts/coord/bot-merge.sh` (~L1031, INFRA-1422) |
| `bot_merge_crashed` | A step's `started` event was written but no matching `done` was found by end-of-run (process died mid-step) | `step`, `pid`, `steps_file` | `scripts/coord/bot-merge.sh` (~L298) |

Read the raw stream at any time:

```bash
tail -50 .chump-locks/ambient.jsonl | grep -E '"kind":"bot_merge_|"kind":"botmerge_'
```

## 2. Cost tracking

Only **`bot_merge_hang`** carries a direct token-cost estimate. `src/waste_tally.rs::default_tokens_per_kind()` maps it to a fixed estimate of **15,000 tokens** per event — the largest estimate of any waste kind (META-055 audit #2 found `bot_merge_hang` responsible for ~17% of 7-day fleet waste). That estimate rolls into `chump waste-tally` reporting automatically; no separate wiring is needed.

Every other kind in the table above (`bot_merge_step_started/done/stalled`, `bot_merge_phase_duration`, `bot_merge_phase_failure`, `bot_merge_timeout`, `botmerge_wedged`, `bot_merge_crashed`) is a **pipeline-state signal, not a cost signal** — `default_tokens_per_kind()` returns `0` for kinds it doesn't recognize, and none of these are registered with a non-zero estimate. They exist so a *detector* can recognize a stall pattern (e.g. "no `bot_merge_step_done` after a `bot_merge_step_started` for N minutes"); they do not themselves represent burned tokens. Do not double-count a `bot_merge_hang` and its associated `botmerge_wedged`/`bot_merge_timeout` siblings as separate cost line items — only `bot_merge_hang` carries the estimate.

## 3. Failure-class taxonomy: transient vs. permanent

| Class | Kind(s) | Characteristics | Recovery action |
|---|---|---|---|
| **Transient — step-local stall** | `bot_merge_step_stalled` | A single step's own `gtimeout` fired; the rest of the pipeline is unaffected | Re-run bot-merge; the per-step timeout is usually generous enough that a repeat succeeds. If it repeats 2-3× on the same step, treat as permanent (see circuit-breaker below). |
| **Transient — stage-budget wedge** | `botmerge_wedged` | A stage watchdog fired but no repeated pattern yet on this phase | Retry with `CHUMP_BOT_MERGE_RECOVERY_MODE=1` per the message the tool prints; investigate the underlying child process if it recurs. |
| **Transient — webhook/poll timeout** | `bot_merge_timeout` (poll variant, `source` field present) | PR-poll loop hit its 15m hard cap waiting on GitHub webhook/CI state | Switch to manual recovery per the CLAUDE.md manual-ship fallback (`git push` / `gh pr create` / `chump gap ship` / `gh pr merge --auto --squash`) rather than re-polling. |
| **Permanent — circuit-breaker-tripped repeated hang** | 3+ `bot_merge_hang` events for the same phase within 1h | `circuit_breaker_check` in `run_timed_hb` refuses to even start the phase (INFRA-954) — printed as `INFRA-954: circuit-breaker tripped` | Investigate the wedged child process manually; clear with `scripts/coord/bot-merge-circuit-breaker.sh clear` only after root-causing, not as a routine unblock. |
| **Permanent — named phase failure** | `bot_merge_phase_failure` | The phase itself returned a non-zero, non-timeout exit — a real error (e.g. rebase conflict, CI red, gap-registry mutation failure) | Read `note`/`exit_code` and fix the underlying cause; this is not a retry-and-hope situation. |
| **Permanent — mid-step crash** | `bot_merge_crashed` | A `started` was logged with no matching `done` — the bot-merge process itself died (killed, OOM, crashed) mid-step | Check for OOM/kill signals on the host, then restart bot-merge from scratch; do not assume a plain retry fixes the root cause. |

Rule of thumb: single-occurrence step/stage timeouts are transient and retry-safe; anything the circuit-breaker has flagged, or anything with a concrete non-timeout exit code, is permanent and needs a human/manual diagnosis before retrying.

## 4. Smoke tests + manual liveness check

```bash
scripts/ci/test-bot-merge-heartbeat.sh          # heartbeat_begin/end + progress-file freshness
scripts/ci/test-bot-merge-step-emits.sh         # bot_merge_step_started/done emission shape
scripts/ci/test-bot-merge-phase-duration.sh     # bot_merge_phase_duration emission on success
scripts/ci/test-bot-merge-hang-detection.sh     # bot_merge_hang ALERT on gtimeout rc=124
scripts/ci/test-bot-merge-circuit-breaker.sh    # 3+ bot_merge_hang in 1h trips circuit_breaker_check
scripts/ci/test-bot-merge-watchdog.sh           # botmerge_wedged stage watchdog
scripts/ci/test-bot-merge-liveness.sh           # end-to-end liveness signal wiring
scripts/ci/test-bot-merge-exit-phases.sh        # exit-code-to-phase mapping
```

Manual liveness check while a bot-merge run is in flight:

```bash
tail -f .chump-locks/ambient.jsonl | grep --line-buffered -E '"kind":"bot_merge_|"kind":"botmerge_'
```

If a `bot_merge_step_started` appears with no matching `bot_merge_step_done`/`bot_merge_step_stalled`/`bot_merge_crashed` within the step's expected budget, the run is stalled — this is the programmatic replacement for "it's been N minutes, is it stuck?".
