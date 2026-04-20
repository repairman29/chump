# EVAL-049 — Binary-mode ablation harness: CHUMP_BYPASS_* via chump binary

**Gap:** EVAL-049
**Date filed:** 2026-04-20
**Status:** Harness shipped — full sweep pending (n=30+ required)
**Owner:** chump-agent (EVAL-049 worktree)
**Priority:** P1 — prerequisite for any Metacognition faculty claim

---

## Why binary-mode is necessary

All prior harnesses (`run-cloud-v2.py`, `run-ablation-sweep.py`) call the
Anthropic API directly — the chump Rust binary is never invoked. As a result:

- `CHUMP_BYPASS_BELIEF_STATE=1` has **no effect** in those harnesses
- `CHUMP_BYPASS_SURPRISAL=1` has **no effect** in those harnesses
- `CHUMP_BYPASS_NEUROMOD=1` has **no effect** in those harnesses

The bypass flags are implemented inside the Rust binary
(`crates/chump-belief-state/src/lib.rs`, `src/surprise_tracker.rs`,
`src/neuromodulation.rs`). They only fire when the binary is executed as a
subprocess. This harness fixes that by running every trial through
`chump --chump "<task>"` with the relevant env var set in the subprocess
environment.

See `docs/eval/EVAL-048-ablation-results.md` for the original discovery of this
architectural caveat.

---

## Setup

| Parameter | Value |
|---|---|
| Binary invocation | `./target/release/chump --chump "<task>"` |
| Cell A (control) | Normal run — `CHUMP_BYPASS_<MODULE>=0` |
| Cell B (ablation) | Bypass active — `CHUMP_BYPASS_<MODULE>=1` |
| Scoring heuristic | Correct = exit code 0 AND output length > 10 chars |
| Hallucination proxy | Output contains "I cannot" or "I don't know" |
| Session isolation | CLI session file cleared between trials (matches run.sh pattern) |
| Per-trial timeout | 300 seconds |
| Task set | 30 built-in tasks (factual, reasoning, instruction categories) |
| Output format | JSONL per trial + summary table at end |

### Modules and bypass flags

| Module | Env flag | Code location |
|---|---|---|
| `belief_state` | `CHUMP_BYPASS_BELIEF_STATE` | `crates/chump-belief-state/src/lib.rs::belief_state_enabled()` |
| `surprisal` | `CHUMP_BYPASS_SURPRISAL` | `src/surprise_tracker.rs::record_prediction()` |
| `neuromod` | `CHUMP_BYPASS_NEUROMOD` | `src/neuromodulation.rs::neuromod_enabled()` |

---

## Dry-run command output (2026-04-20)

The binary was not available at ship time (full build requires an OPENAI_API_BASE
endpoint). The harness `--dry-run` confirms all subprocess commands are
correctly formed without requiring a built binary or API keys.

```
[eval-049] Binary-mode ablation harness
[eval-049] Modules: belief_state, surprisal, neuromod
[eval-049] n/cell:  5  (total trials: 30)
[eval-049] Mode:    DRY-RUN (no subprocess execution)

--- Module: belief_state (CHUMP_BYPASS_BELIEF_STATE) ---
  Cell A: control (bypass OFF)
  [dry-run] CHUMP_BYPASS_BELIEF_STATE=0 ./target/release/chump --chump "What is 17 multiplied by 23?"
  [dry-run] CHUMP_BYPASS_BELIEF_STATE=0 ./target/release/chump --chump "Name the capital city of Japan."
  ...
  Cell B: ablation (bypass ON)
  [dry-run] CHUMP_BYPASS_BELIEF_STATE=1 ./target/release/chump --chump "What is 17 multiplied by 23?"
  [dry-run] CHUMP_BYPASS_BELIEF_STATE=1 ./target/release/chump --chump "Name the capital city of Japan."
  ...

--- Module: surprisal (CHUMP_BYPASS_SURPRISAL) ---
  [dry-run commands follow same pattern with CHUMP_BYPASS_SURPRISAL=0/1]

--- Module: neuromod (CHUMP_BYPASS_NEUROMOD) ---
  [dry-run commands follow same pattern with CHUMP_BYPASS_NEUROMOD=0/1]
```

Full run command:
```bash
cargo build --release --bin chump
python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30
```

---

## Results

> **Full sweep pending — n=30+ per cell required for publishable claims.**
> Per `docs/RESEARCH_INTEGRITY.md`: Wilson 95% CI, A/A baseline ±0.03, and
> cross-family judging are required before citing any module as validated or
> net-negative.

### Results table (TBD — pending full sweep)

| Module | n/cell | Acc A (control) | Acc B (bypass) | Wilson CI (A) | Wilson CI (B) | Delta | Verdict |
|--------|--------|-----------------|----------------|---------------|---------------|-------|---------|
| belief_state | — | TBD | TBD | TBD | TBD | TBD | pending n=30 sweep |
| surprisal | — | TBD | TBD | TBD | TBD | TBD | pending n=30 sweep |
| neuromod | — | — | — | — | — | TBD | prior signal: −0.10 to −0.16 (EVAL-026); retest pending |

Note: Delta = Acc(B) − Acc(A). Negative delta means bypass *improves* accuracy
(module is net-harmful). Prior EVAL-026 evidence showed neuromod at −0.10 to
−0.16 across four models; this sweep will confirm or rebut that with proper
binary-mode isolation.

---

## Methodology

### Why not use run-cloud-v2.py or run-ablation-sweep.py?

Those harnesses send prompts directly to the Anthropic API (or Together API).
The response comes from the LLM provider without any Rust code executing.
Bypass flags like `CHUMP_BYPASS_BELIEF_STATE` are read by Rust modules that run
inside the chump binary — they are invisible to a bare API call. This harness
invokes `chump --chump "<task>"` as a subprocess, which initialises all Rust
modules and respects the bypass flags.

### Cell design

Each module gets an independent A/B pair:

```
Cell A: CHUMP_BYPASS_<MODULE>=0  (module active, normal run)
Cell B: CHUMP_BYPASS_<MODULE>=1  (module bypassed, returns defaults)
```

All other bypass flags are left at their default (0 = active) so only the
targeted module is isolated. This matches the cell design in EVAL-043.

### Scoring heuristic

The harness uses a structural heuristic (no LLM judge required):
- **Correct:** subprocess exits 0 AND `len(output.strip()) > 10`
- **Hallucination proxy:** output contains "I cannot" or "I don't know"

This is intentionally conservative. A non-zero exit code or empty output is
treated as failure regardless of content. For publishable claims, an LLM judge
sweep (using `scripts/ab-harness/score.py` with `--judge-claude` and
`--judge-together`) should be run on the JSONL output.

### Sample size guidance

| n/cell | Use |
|--------|-----|
| 5 | Smoke test — verify harness runs end-to-end |
| 30 | Directional signal only — Wilson CI still wide |
| 100 | Publishable claim per RESEARCH_INTEGRITY.md |

---

## Verdict

**Cannot determine until full n=30+ sweep completes.**

Prior evidence from EVAL-026 (direct API harness, pre-bypass isolation):
- Neuromodulation showed −0.10 to −0.16 harm signal across four models
- belief_state and surprisal EMA were not isolated (conflated with other modules)

This harness is the first mechanism that can cleanly isolate each module's
contribution. Run it with `--n-per-cell 30` to get directional signal.

---

## Cross-links

- Harness script: `scripts/ab-harness/run-binary-ablation.py`
- Architectural caveat: `docs/eval/EVAL-048-ablation-results.md`
- Bypass flag definitions: `docs/eval/EVAL-043-ablation.md`
- Faculty map: `docs/CHUMP_FACULTY_MAP.md` (row 7, Metacognition)
- Research integrity gate: `docs/RESEARCH_INTEGRITY.md`
- Prior neuromod signal: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
