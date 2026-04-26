# EVAL-037 — Multi-Agent Coordination A/B: Does chump-coord Pay for Its Overhead?

**Gap:** EVAL-037
**Date filed:** 2026-04-20
**Status:** Design complete — sweep pending (requires live chump-coord NATS broker)
**Priority:** P3 (effort: l)
**Owner:** chump-agent (claude/eval-037 worktree)
**Depends on:** (none)

---

## Research question

Does `chump-coord` NATS-based multi-agent coordination add measurable value on tasks
that require multi-step handoffs, compared to a solo agent handling the same task in
one context window?

The chump-coord layer (see `docs/process/AGENT_COORDINATION.md`) adds real runtime overhead:
NATS broker startup, event publishing per step, and coordination-bus fan-out on each
intermediate result. If coordination does not improve pass rates on tasks that genuinely
require handoffs, the overhead is net-negative and the layer should be optional/off by
default or redesigned.

---

## Hypothesis

**H1 (coordination pays off):** On tasks requiring intermediate state propagation
between steps (multi-hop lookups, conditional branches, write-then-verify sequences),
a coordinated agent (Cell B) will complete more steps correctly because the coordination
bus makes intermediate results explicit and recoverable. Predicted: +5–15 pp on
`is_correct` for `coordination_required=true` tasks.

**H0 (coordination is noise):** The model's single-context ability to chain steps is
sufficient. The coordination overhead adds latency without improving pass rate. The
solo agent (Cell A) performs within sampling noise of the coordinated agent.

**H2 (coordination harms on simple tasks):** The coordination layer introduces
additional round-trips and prompt-injection of coordination metadata that dilutes
task-specific signal on simpler tasks. This would be visible as Cell B *worse* than
Cell A on tasks with shallow handoff requirements.

---

## Cell definitions

| Cell | Description | Env flags |
|------|-------------|-----------|
| **A — solo agent (baseline)** | Single `chump -p <prompt>` call; no coordination layer | `CHUMP_COORD_ENABLED` unset |
| **B — coord-enabled** | Same prompt dispatched with coordination layer active; NATS broker required | `CHUMP_COORD_ENABLED=1` + `CHUMP_COORD_NATS_URL=nats://localhost:4222` |

Both cells use the same chump binary and model. The only variable is whether the
coordination bus is active. Cell A is the control; Cell B is the treatment.

---

## Coordination fixture: `scripts/ab-harness/fixtures/coordination_tasks.json`

The fixture contains 10 tasks, all marked `coordination_required: true`. Each task
was designed to require one or more of the following handoff patterns:

| Pattern | Tasks | Why coordination should help |
|---------|-------|------------------------------|
| Sequential file read (step 1 result feeds step 2 query) | coord-01, coord-02 | Intermediate value (flag name, version string) must propagate |
| Conditional branching on intermediate result | coord-03 | Branch direction depends on step-1 output |
| Multi-source aggregation | coord-04, coord-07 | Multiple reads must be combined before synthesis |
| Dependency-chain traversal | coord-05, coord-10 | Multi-hop graph walk over gaps.yaml |
| Write-then-verify | coord-06 | Write result must be confirmed by read-back |
| Iterative search with accumulator | coord-08 | Pattern search across multiple files → deduplicated list |
| State propagation across documents | coord-09 | Keywords extracted from doc A used to search doc B |

### Task summary

| ID | Category | Handoff description |
|----|----------|---------------------|
| coord-01 | sequential_file_edit | Read env_flags.rs → extract flag name → verify in reflection_db.rs |
| coord-02 | cross_file_verification | Read Cargo.toml version → search Rust source for that version string |
| coord-03 | conditional_branching | Check gaps.yaml for in_progress → branch to either list or fallback |
| coord-04 | multi_source_aggregation | Find all .rs files containing EVAL → extract and deduplicate EVAL IDs |
| coord-05 | dependency_resolution | Read EVAL-035 deps → look up status of each dep |
| coord-06 | write_then_verify | Write /tmp file → read back → confirm contents |
| coord-07 | gather_then_synthesize | Three parallel reads (Cargo.toml, main.rs, gaps.yaml) → one sentence |
| coord-08 | iterative_search | Search src/ for `fn.*reflection` → sort, deduplicate, truncate to 5 |
| coord-09 | state_propagation | Read AGENT_COORDINATION.md failure modes → cross-ref with gaps.yaml |
| coord-10 | multi_hop | Two-level dep tree for EVAL-036 (direct deps + transitive deps of first dep) |

---

## Methodology

### Scoring

Each trial is scored on three axes using `scoring_v2.score_trial()`:

| Axis | Measurement |
|------|-------------|
| `is_correct` | Primary: judge says output addresses all required steps |
| `did_attempt` | Secondary: genuine effort (not a refusal stub) |
| `hallucinated_tools` | Quality gate: fake `<function_calls>` emission |

**Judge:** `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (cross-family, non-Anthropic).
If `TOGETHER_API_KEY` is absent, the harness falls back to heuristic scoring (non-empty
non-refusal = 0.7). LLM judging is strongly recommended for accurate results.

**Rubrics:** Each task has a custom `judge_rubric` field specifying what a correct
multi-step answer must contain. The rubric explicitly requires evidence that intermediate
steps were completed (e.g., specific line numbers, actual file contents, correct dep lists).

### Statistical reporting

- Wilson 95% CIs on all rates per cell
- Delta = Cell B rate minus Cell A rate
- `cis_overlap=True` → within sampling noise; do not cite as finding
- Primary decision axis: `is_correct` on `coordination_required=true` tasks

### Sample size

n=10 tasks per cell (full fixture) is sufficient for a preliminary directional signal.
For a ship-or-cut decision, extend to n=50 per cell using fixture augmentation or
by running 5 repetitions per task with jittered prompts.

---

## Infrastructure note: Cell B requires live chump-coord NATS broker

Cell A (solo baseline) can be run immediately with only a built chump binary and API keys.

Cell B requires:
1. NATS server running on `localhost:4222` (or override with `--nats-url`)
2. `chump-coord` broker process running and subscribed to the coordination bus
3. `CHUMP_COORD_ENABLED=1` env var (set automatically by the harness for Cell B)

See `docs/process/AGENT_COORDINATION.md` for full broker setup instructions.

**If NATS is not available:** Run `--cell a` to collect the Cell A baseline. Once the
broker is available, run `--cell b` and combine the JSONL output files before building
the summary. The harness supports incremental runs by appending to the same JSONL log.

---

## Reproduction command

```bash
# Cell A baseline only (no NATS required):
python3 scripts/ab-harness/run-coordination-ab.py \
    --fixture scripts/ab-harness/fixtures/coordination_tasks.json \
    --model claude-haiku-4-5 \
    --chump-bin ./target/release/chump \
    --tag eval037-baseline \
    --cell a

# Full A/B sweep (requires chump-coord NATS broker on localhost:4222):
python3 scripts/ab-harness/run-coordination-ab.py \
    --fixture scripts/ab-harness/fixtures/coordination_tasks.json \
    --model claude-haiku-4-5 \
    --chump-bin ./target/release/chump \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --tag eval037-ab \
    --cell ab

# With custom NATS URL:
python3 scripts/ab-harness/run-coordination-ab.py \
    --fixture scripts/ab-harness/fixtures/coordination_tasks.json \
    --model claude-haiku-4-5 \
    --nats-url nats://myhost:4222 \
    --tag eval037-ab-custom-nats \
    --cell ab
```

Prerequisites:
- `cargo build --release` (chump binary)
- `ANTHROPIC_API_KEY` set (for claude-haiku-4-5 agent model)
- `TOGETHER_API_KEY` set (for LLM judge — optional, falls back to heuristic)
- NATS server + chump-coord broker running (Cell B only)

---

## Expected timeline

- **Cell A baseline:** ~15 min to run once binary is built and `ANTHROPIC_API_KEY` is set.
  10 tasks × 1 cell × ~90s per task = ~15 min.
- **Full A/B sweep:** ~30 min once NATS is active.
  10 tasks × 2 cells × ~90s per task = ~30 min.
- **Full A/B with judge:** ~45 min (adds ~30s per trial for LLM judging).

**PENDING — requires live chump-coord NATS broker.** See `docs/process/AGENT_COORDINATION.md`
for setup. Once the broker is running, Cell A results can be collected immediately as
the baseline, with Cell B added when broker availability is confirmed.

---

## Results

**Status: PENDING — Cell A and Cell B sweeps not yet executed.**

Results will be published here once the sweeps complete. Expected format:

```
=== EVAL-037 coordination A/B summary: eval037-ab ===
gap=EVAL-037  fixture=coordination_tasks.json
model=claude-haiku-4-5  judge=meta-llama/Llama-3.3-70B-Instruct-Turbo
cells_run=ab  nats_url=nats://localhost:4222

  cell A (solo agent (no coord)  ): correct=X.XX [X.XX–X.XX]  attempt=X.XX  halluc=X.XX  mean_judge=X.XXX  n=10
  cell B (coord-enabled (NATS)   ): correct=X.XX [X.XX–X.XX]  attempt=X.XX  halluc=X.XX  mean_judge=X.XXX  n=10

  Delta is_correct              : +X.XXX [provisional signal / WITHIN NOISE]
  Delta did_attempt             : +X.XXX
  Delta hallucinated_tools      : +X.XXX

Decision rule: Cell B > Cell A with non-overlapping 95% Wilson CIs on is_correct
on coordination_required tasks → chump-coord overhead is justified.
```

---

## Decision criteria

| Finding | Action |
|---------|--------|
| Cell B `is_correct` delta ≥ +0.05, CIs non-overlapping, ≥7/10 tasks correct in B | Coordination pays off → chump-coord should be default-on for multi-step tasks |
| Delta within ±0.05 or CIs overlapping | Null result → coordination is noise on this fixture; extend to n=50 before deciding; review broker latency overhead |
| Cell B `is_correct` delta ≤ −0.05 | Coordination is net-negative → file architectural review gap; disable by default |
| Cell B `hallucinated_tools` rate > Cell A rate | Coordination metadata contaminates prompt → file prompt-injection bug against chump-coord |

---

## Cross-links

- Gap: `docs/gaps.yaml` (EVAL-037)
- Fixture: `scripts/ab-harness/fixtures/coordination_tasks.json`
- Harness: `scripts/ab-harness/run-coordination-ab.py`
- Coordination system: `docs/process/AGENT_COORDINATION.md`
- Prior A/B harness reference: `scripts/ab-harness/run-spawn-lessons-ab.py` (MEM-006-VALIDATE)
- Scoring library: `scripts/ab-harness/scoring_v2.py`
- Related eval: EVAL-036 (prompt-assembler ablation — similar methodology)
