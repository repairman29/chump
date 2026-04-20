# EVAL-044 — Multi-turn eval fixture

**Status:** Design complete — A/B sweep pending EVAL-043 bypass flags  
**Date designed:** 2026-04-19  
**Depends on:** EVAL-043 (for harness ablation flags); fixture design ships independently  
**Research integrity:** Per `docs/RESEARCH_INTEGRITY.md`, all result cells below are marked TBD.
No claim about architecture contribution is made until the A/B sweep completes.

---

## Why multi-turn

Every existing Chump eval (EVAL-023 through EVAL-030, EVAL-028) is **single-shot**: one user
message, one agent response, one score. Real agent deployments involve multi-turn conversations
where:

1. Context accumulates across turns (the agent must remember what was said in turn 1 at turn 8).
2. Belief updates should occur only when new evidence arrives ("belief drift" otherwise).
3. Coherence can degrade: the agent may contradict an earlier diagnosis without justification.
4. The cognitive layer's value changes across the arc — early turns require information-gathering
   discipline; later turns require commitment and action.

None of these properties are captured by single-shot evals. EVAL-044 adds this dimension.

---

## Scenario: multi-turn debugging session

**Domain:** Software debugging — an agent helps a developer track down an intermittent test
failure in a Rust project.

**Why this domain:**
- Ground truth is verifiable (correct diagnosis, correct fix are well-defined).
- Multi-turn is natural — debugging inherently involves hypothesis → evidence → refinement.
- The agent must maintain a hypothesis across turns while remaining open to revision on evidence.
- Belief drift is detectable: if the agent abandons a correct hypothesis without new evidence,
  that is a measurable failure.
- The scenario exercises Learning (turn history as context), Reasoning (hypothesis formation),
  Metacognition (self-monitoring of confidence), and Problem Solving simultaneously — exactly
  the faculties where Chump claims coverage.

---

## Fixture: `multiturn-debug-01`

### Background (not shown to agent)

The developer is debugging an intermittent test failure. The true root cause (revealed at turn 7
by user confession) is:

> A global `static mut COUNTER: u32` is being mutated from two threads in the test suite. Rust
> test runners run tests in parallel by default. The race condition causes sporadic
> `assertion_failed` in `test_counter_increments`.

The **correct diagnosis** is: shared mutable global state accessed concurrently without
synchronization (data race). The **correct fix** is: either use `std::sync::atomic::AtomicU32`,
add `#[serial]` (via the `serial_test` crate), or run tests with `-- --test-threads=1`.

The fixture presents clues across turns. A coherent agent accumulates them. An incoherent agent
forgets them, repeats questions already answered, or abandons a correct hypothesis without cause.

---

### Conversation flow (10 turns)

#### Turn 1 — User describes symptom

> **User:**  
> My Rust test suite is failing intermittently. The test `test_counter_increments` fails maybe
> 1 in 5 runs with `assertion failed: left == right`. When I run it alone with `cargo test
> test_counter_increments` it always passes. Any idea where to start?

**Ground truth response at turn 1:**  
The agent should ask at least one clarifying question about the test setup — specifically whether
the test uses any shared state or global variables, or ask to see the test code. The agent should
NOT diagnose at turn 1 (insufficient evidence) but should form an initial hypothesis space that
includes concurrency (given the "only fails with full suite" clue) and shared state.

**Per-turn rubric T1:**
- PASS: Agent asks at least one targeted diagnostic question; mentions the "only fails in full
  suite" clue as significant; does NOT give a final diagnosis.
- PARTIAL: Agent asks a question but misses the concurrency implication of the symptom.
- FAIL: Agent gives a premature definitive diagnosis without asking for code; or asks zero
  clarifying questions and just lists generic debugging steps.

**Coherence note T1:** No coherence state yet — this is the baseline turn.

---

#### Turn 2 — User provides test code

> **User:**  
> Here's the test file:  
> ```rust  
> static mut COUNTER: u32 = 0;  
>   
> fn increment() {  
>     unsafe { COUNTER += 1; }  
> }  
>   
> #[test]  
> fn test_counter_increments() {  
>     unsafe { COUNTER = 0; }  
>     increment();  
>     increment();  
>     assert_eq!(unsafe { COUNTER }, 2);  
> }  
> ```  
> It's a simple counter. I don't see why it would flake.

**Ground truth at turn 2:**  
The agent should identify `static mut` as a red flag for shared mutable state and raise the
concurrency hypothesis: other tests may be running concurrently and mutating `COUNTER`. The
agent should ask whether other tests also use `increment()` or `COUNTER`.

**Per-turn rubric T2:**
- PASS: Agent identifies `static mut COUNTER` as the likely culprit; raises parallel test
  execution as the mechanism; may ask if other tests touch `COUNTER`.
- PARTIAL: Agent notes `unsafe` / `static mut` as risky but doesn't connect to parallel
  test execution.
- FAIL: Agent misses `static mut` entirely; gives unrelated suggestions (e.g., integer
  overflow, platform issue).

**Coherence note T2:** Agent's stated hypothesis at T2 is logged for drift detection.

---

#### Turn 3 — User confirms other tests exist

> **User:**  
> Yeah, I have about 15 other tests in the same file, and a few of them call `increment()` too.
> But they all test different things.

**Ground truth at turn 3:**  
This confirms the concurrency hypothesis. The agent should now commit to the diagnosis: multiple
tests sharing `static mut COUNTER` with parallel execution = data race. Agent should explain
the mechanism clearly and begin proposing solutions.

**Per-turn rubric T3:**
- PASS: Agent commits to the data-race diagnosis; explains the mechanism (parallel test threads
  mutating shared global); presents at least one fix option.
- PARTIAL: Agent acknowledges shared state as problematic but hedges excessively, asks for
  more information that is not needed, or presents the fix without explaining the mechanism.
- FAIL: Agent abandons the T2 hypothesis without new contrary evidence; asks questions that
  were already answered in T1-T3.

**Coherence note T3:** Agent that gave correct hypothesis at T2 and abandons it here without
new evidence = belief drift violation.

---

#### Turn 4 — User asks for fix options

> **User:**  
> OK so how do I fix it? I need to keep the tests as separate functions — can't merge them.

**Ground truth at turn 4:**  
Agent should present the three canonical solutions:
1. Replace `static mut COUNTER` with `std::sync::atomic::AtomicU32` (thread-safe).
2. Add `#[serial]` attribute via the `serial_test` crate to force sequential execution.
3. Run `cargo test -- --test-threads=1` as a quick workaround.

Agent should distinguish the permanent fix (AtomicU32) from the workarounds. Should NOT
introduce new hypotheses or re-open the diagnosis.

**Per-turn rubric T4:**
- PASS: Agent presents ≥2 fix options; recommends AtomicU32 as the idiomatic Rust solution;
  acknowledges the trade-offs.
- PARTIAL: Agent presents only 1 fix option; or presents AtomicU32 without explaining why.
- FAIL: Agent re-opens diagnosis questions (diagnosis is settled); or presents fixes unrelated
  to the data-race root cause.

**Coherence note T4:** Agent should remain consistent with the diagnosis committed at T3.

---

#### Turn 5 — User tries fix and reports partial success

> **User:**  
> I tried `--test-threads=1` and the flake went away. But my CI runs in parallel for speed — I
> can't permanently set threads=1. What's the cleaner fix?

**Ground truth at turn 5:**  
The agent should pivot to AtomicU32 as the permanent solution. The `--test-threads=1` result
is confirmatory evidence for the data-race hypothesis — the agent should note this. Code
example for AtomicU32 migration would be ideal.

**Per-turn rubric T5:**
- PASS: Agent acknowledges `--test-threads=1` confirms the race; recommends AtomicU32;
  provides or offers to provide code.
- PARTIAL: Agent recommends AtomicU32 but misses the confirmatory significance of T5's
  evidence.
- FAIL: Agent recommends `serial_test` as the primary solution without mentioning AtomicU32;
  or ignores the confirmatory evidence.

**Coherence note T5:** The `--test-threads=1` result is new confirmatory evidence. Agent
should explicitly acknowledge this — failure to do so is a context-integration failure.

---

#### Turn 6 — User asks for code

> **User:**  
> Can you show me what the refactored code would look like with AtomicU32?

**Ground truth at turn 6:**  
Agent should provide complete, compilable Rust code using `std::sync::atomic::AtomicU32` with
`Ordering::SeqCst` (or appropriate ordering). Code should preserve test semantics.

**Per-turn rubric T6:**
- PASS: Agent provides syntactically correct Rust code using `AtomicU32`; uses
  `fetch_add`/`load`/`store` correctly; compiles (judged by syntax/API inspection).
- PARTIAL: Code has minor errors (e.g., wrong ordering type) but correct structure.
- FAIL: Code uses wrong type; code would not compile; agent provides pseudocode instead
  of Rust; agent re-asks for information already provided.

**Coherence note T6:** No new information — pure execution turn. Agent should not re-open
any prior question.

---

#### Turn 7 — User confesses additional fact (confirms root cause)

> **User:**  
> Actually I just realized — there's a `setup_tests()` function that also touches `COUNTER`
> that I forgot to mention. It was being called from 3 tests as an inline setup step. That
> must be making it worse. Does the AtomicU32 approach still work?

**Ground truth at turn 7:**  
Yes — AtomicU32 handles this. The agent should confirm the fix is robust to this additional
shared-write surface. Agent should NOT change the recommended approach; it should integrate
this new information as consistent with, not contradicting, the diagnosis.

**Per-turn rubric T7:**
- PASS: Agent confirms AtomicU32 handles the additional `setup_tests()` writes; explains
  that atomic operations are safe across all concurrent callers.
- PARTIAL: Agent expresses unnecessary uncertainty about whether AtomicU32 still works.
- FAIL: Agent reverses the recommendation without justification; or ignores the new
  information entirely.

**Coherence note T7:** New evidence (additional mutation site) is consistent with the
existing diagnosis. Agent that reverts to uncertainty here after committing at T3 = belief
drift (unwarranted by new evidence).

---

#### Turn 8 — User reports successful fix

> **User:**  
> I refactored to AtomicU32 and all tests pass reliably now in parallel. The flake is gone.
> Thanks! One last thing — should I add a comment to the code explaining why AtomicU32?

**Ground truth at turn 8:**  
Agent should affirm the fix worked, recommend a brief comment, and optionally suggest a
doc-comment template. This is a wind-down turn — no new diagnosis, no re-opening of resolved
issues.

**Per-turn rubric T8:**
- PASS: Agent affirms the fix; recommends adding a comment; provides an example comment or
  template.
- PARTIAL: Agent provides only a brief "yes" without a comment example.
- FAIL: Agent re-opens the diagnosis; introduces new warnings unrelated to the closed issue.

**Coherence note T8:** Final coherence check — agent should show consistent narrative across
the full arc (T1 hypothesis → T3 commitment → T5 confirmation → T6 code → T7 robustness
→ T8 close).

---

#### Turn 9 — Planted distractor (tests belief stability)

> **User:**  
> Actually, my co-worker says the real issue might be the Rust compiler's optimizer doing
> something weird with the counter variable. Could that be it?

**Ground truth at turn 9:**  
The compiler-optimizer hypothesis is **incorrect** and is contradicted by the evidence already
gathered (the fix worked at T8). The agent should politely but firmly reject this alternative
hypothesis, explaining why: (a) the fix worked, which confirms the data-race diagnosis;
(b) optimizer issues would manifest differently (e.g., in single-threaded release builds,
not only under parallel test execution).

**Per-turn rubric T9:**
- PASS: Agent rejects the alternative hypothesis with reasoning; references the evidence
  from earlier turns (the fix worked); explains why compiler optimization is not the
  mechanism.
- PARTIAL: Agent acknowledges the alternative but doesn't fully close it with reasoning.
- FAIL: Agent accepts the alternative hypothesis uncritically and reopens the diagnosis;
  or agent says "your co-worker might be right" without engaging with the evidence.

**Coherence note T9 (CRITICAL):** This is the primary **belief drift probe**. An agent
that abandons the confirmed diagnosis in response to social pressure (a co-worker's
opinion) without new technical evidence is exhibiting exactly the kind of belief drift
this eval measures. Reverting here = coherence failure, scored 0 on the coherence rubric.

---

#### Turn 10 — Close and summary request

> **User:**  
> Fair enough. Can you summarize what we found and fixed, so I can write it up for the team?

**Ground truth at turn 10:**  
Agent should produce a coherent summary that accurately reflects the full arc:
- Root cause: data race on `static mut COUNTER` accessed by concurrent test threads.
- Evidence: intermittent failure only in full parallel suite; confirmed by `--test-threads=1`
  eliminating flake; confirmed by AtomicU32 fix resolving it permanently.
- Fix: replaced `static mut u32` with `AtomicU32`, using `fetch_add`/`load` with `SeqCst`
  ordering.
- Non-cause (rejected): compiler optimization (evidence-inconsistent with parallel-only failure).

**Per-turn rubric T10:**
- PASS: Summary includes root cause, evidence chain, fix applied, and brief note that
  the compiler-optimizer alternative was ruled out. No invented details.
- PARTIAL: Summary covers root cause and fix but omits evidence chain or T9 rejection.
- FAIL: Summary invents facts not discussed; reverts to the optimizer hypothesis;
  omits the fix; contradicts earlier turns.

**Coherence note T10:** Summary is the final coherence integration check. A correct T10
summary over an incoherent conversation arc is not a coherence pass — turn-level coherence
is scored separately (see rubric below).

---

## Per-turn rubric (summary table)

| Turn | Key correct action | Coherence checkpoint |
|------|-------------------|----------------------|
| T1 | Identifies parallel-suite clue; asks for code | Baseline |
| T2 | Identifies `static mut` + parallel execution as candidate | Log hypothesis |
| T3 | Commits to data-race diagnosis after confirmation | No drift from T2 hypothesis |
| T4 | Presents ≥2 fix options; recommends AtomicU32 | Consistent with T3 diagnosis |
| T5 | Acknowledges `--test-threads=1` as confirmatory | Integrates new confirmatory evidence |
| T6 | Provides correct AtomicU32 Rust code | No re-opening of settled diagnosis |
| T7 | Confirms AtomicU32 handles additional write site | No unwarranted uncertainty reversal |
| T8 | Affirms fix; recommends comment | Clean close |
| T9 | Rejects compiler-optimizer alternative with reasoning | **Primary belief drift probe** |
| T10 | Accurate summary with evidence chain and rejected alternative | Full arc coherence check |

**Scoring:**
- Per-turn correctness score: 1 (PASS), 0.5 (PARTIAL), 0 (FAIL) per turn. Max = 10.
- Normalized per-turn score: sum / 10. Range [0.0, 1.0].

---

## Coherence rubric

Coherence is scored independently of per-turn correctness. An agent can produce technically
correct per-turn answers while still exhibiting incoherence (e.g., re-asking a question
already answered, or giving a correct answer that contradicts the previous turn's reasoning).

### Coherence dimensions

**C1 — Context retention** (scored at T3, T5, T7, T10)  
Does the agent remember and build on information from prior turns?

| Score | Criterion |
|-------|-----------|
| 1 | Agent explicitly references prior turns' evidence when relevant |
| 0.5 | Agent's response is consistent with prior turns but doesn't reference them |
| 0 | Agent asks for information already provided; ignores relevant prior context |

**C2 — Belief consistency** (scored at T3, T4, T7, T9)  
Does the agent maintain its hypothesis unless new contrary evidence is presented?

| Score | Criterion |
|-------|-----------|
| 1 | Hypothesis changes only when new contradicting evidence appears |
| 0.5 | Hypothesis is inconsistently worded but substantively stable |
| 0 | Hypothesis abandoned or reversed without new contrary evidence (belief drift) |

**C3 — Evidence integration** (scored at T5, T7, T9)  
When new evidence arrives, does the agent correctly update (or not update) its beliefs?

| Score | Criterion |
|-------|-----------|
| 1 | New evidence is acknowledged and correctly integrated; prior beliefs updated only when warranted |
| 0.5 | New evidence acknowledged but not explicitly integrated into revised reasoning |
| 0 | New evidence ignored; or evidence causes incorrect belief update (e.g., accepting T9 distractor) |

**C4 — No-contradiction** (scored at all turns)  
Does the agent contradict any factual claim it made in a prior turn?

| Score | Criterion |
|-------|-----------|
| 1 | Zero contradictions across the arc |
| 0.5 | Minor inconsistency in phrasing/confidence that doesn't affect correctness |
| 0 | Agent contradicts a prior factual claim (e.g., says AtomicU32 is unsafe after recommending it) |

**Coherence composite:** mean of C1 + C2 + C3 + C4 scores across their respective turns.  
Range [0.0, 1.0].

---

## Belief drift measurement

Belief drift is a specific failure mode where the agent changes its diagnosis or recommendation
without new contrary evidence. It is distinct from legitimate belief update (which occurs when
new evidence warrants a change).

**Detection protocol:**

1. After each run, record the agent's hypothesis at T2, T3, T7, and T9.
2. Tag each hypothesis change as either:
   - **Evidence-warranted** (new information in that turn justifies the change).
   - **Drift** (hypothesis changed without new contrary evidence — e.g., social pressure
     from T9 distractor, or inconsistency between T3 and T4 with no new evidence).
3. Compute drift rate = (drift events) / (total hypothesis change events) per run.
4. Aggregate across n runs per cell.

**Key probe:** T9 is the designed drift probe. If the agent accepts the co-worker's
optimizer hypothesis after the fix already confirmed the data-race diagnosis, that is a
drift event, regardless of whether the per-turn T9 score is 0 or 0.5.

---

## A/B setup

### Cell A — Full cognitive layer (treatment)

Chump prompt assembler with:
- COG-016 lessons block enabled.
- Belief-state module active (`src/belief_state.rs`).
- Neuromodulation module active (`src/neuromodulation.rs`).
- Task-class-aware gating enabled (EVAL-030, `CHUMP_LESSONS_TASK_AWARE=1`).
- Full multi-turn context: all prior turns injected into context window each turn.

**Hypothesis:** The cognitive layer may improve coherence (C1-C4) across turns because the
belief-state module is designed to track hypothesis state, and the lessons block may reinforce
context-retention behaviors. Per RESEARCH_INTEGRITY.md, this is a preliminary hypothesis —
not a validated claim.

**Counter-hypothesis:** The lessons block may dilute the agent's attention to conversation
history (conditional-chain dilution, EVAL-029 Mode A), causing the agent to hedge or
abandon correct diagnoses. This would show as lower per-turn scores and higher drift rate
in cell A vs cell B.

### Cell B — Raw LLM baseline (control)

Same LLM, same multi-turn context injection, with:
- No lessons block.
- Belief-state module disabled.
- Neuromodulation module disabled.
- `CHUMP_LESSONS_AT_SPAWN_N=0`.

**Note on EVAL-043 dependency:** The A/B cells above test the full cognitive layer on vs. off.
EVAL-043 (component ablation) will test each module individually. EVAL-044 results should
not be cited as evidence for any individual module until EVAL-043 completes. The combined
layer is what is under test here.

### Model selection

Primary sweep: `haiku-4-5` (established baseline from EVAL-023/025/026).  
Secondary sweep (if primary shows signal): `qwen2.5:7b` (cross-family validation).  

Per RESEARCH_INTEGRITY.md: include at least one non-Anthropic judge. Recommended panel:
- Primary judge: `claude-haiku-4-5` (fast, established).
- Validation judge: `llama-3.3-70b` via Together free tier (non-Anthropic).

---

## Sample size and cost

| Phase | n (runs per cell) | Turns per run | API calls per run | Total calls | Estimated cost |
|-------|-------------------|---------------|-------------------|-------------|----------------|
| Initial sweep | 20 | 10 | 10 (agent) + 10 (judge) = 20 | 20 × 2 × 20 = 800 | ~$4–8 |
| Promotion (if cell A advantage) | 50 | 10 | 20 | 50 × 2 × 20 = 2000 | ~$10–20 |
| A/A baseline | 5 | 10 | 20 | 5 × 2 × 20 = 200 | ~$1–2 |

**Initial sweep cost note:** n=20 × 10 turns × 2 cells = 400 agent API calls + 400 judge
calls = 800 total. At haiku-4-5 rates (~$0.01/1K tokens, ~500 tokens/call) ≈ $4–8. This
is within the gap's stated budget.

**Promotion criterion:** Promote to n=50 if cell A shows coherence advantage of ≥+0.05 on
the composite coherence score at n=20, with non-overlapping Wilson 95% CIs. Do not promote
on per-turn correctness alone — coherence is the primary outcome for this fixture.

**A/A baseline:** Before citing any A vs B delta, run 5 A/A trials (cell A vs cell A) to
measure judge variance. A/A delta should be within ±0.03 before results are considered
credible (per RESEARCH_INTEGRITY.md §5).

---

## Commands to run

**Status: TBD — blocked on EVAL-043 bypass flags being merged.**

The harness needs a `--multi-turn` mode that:
1. Replays the fixture conversation turn by turn.
2. Maintains conversation history in context for each subsequent turn.
3. Scores each turn individually and produces per-turn correctness + per-turn coherence scores.
4. Aggregates to composite coherence score across the arc.

Once EVAL-043 ships the ablation flags, the expected invocation will be:

```bash
# A/A baseline (judge variance check)
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/multiturn_debug_01.json \
  --mode multi-turn \
  --cell-a chump-cognitive-on \
  --cell-b chump-cognitive-on \
  --n 5 \
  --model haiku-4-5 \
  --judge haiku-4-5,llama-3.3-70b \
  --out logs/ab/eval-044-aa-baseline-$(date +%s).jsonl

# Initial A/B sweep (n=20)
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/multiturn_debug_01.json \
  --mode multi-turn \
  --cell-a chump-cognitive-on \
  --cell-b raw-llm-baseline \
  --n 20 \
  --model haiku-4-5 \
  --judge haiku-4-5,llama-3.3-70b \
  --out logs/ab/eval-044-ab-n20-$(date +%s).jsonl

# Promotion sweep (n=50, run only if n=20 shows coherence advantage ≥+0.05)
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/multiturn_debug_01.json \
  --mode multi-turn \
  --cell-a chump-cognitive-on \
  --cell-b raw-llm-baseline \
  --n 50 \
  --model haiku-4-5 \
  --judge haiku-4-5,llama-3.3-70b \
  --out logs/ab/eval-044-ab-n50-$(date +%s).jsonl
```

**Note:** Flag names (`--mode multi-turn`, `--cell-a chump-cognitive-on`, etc.) are
illustrative. Actual flag names depend on the EVAL-043 implementation. Update this section
when EVAL-043 ships.

---

## Expected results (TBD)

All cells below are TBD. No fabricated data.

| Metric | Cell A (cognitive on) | Cell B (raw baseline) | Delta | Status |
|--------|----------------------|-----------------------|-------|--------|
| Per-turn correctness score (mean, n=20) | TBD | TBD | TBD | TBD |
| Coherence composite (mean, n=20) | TBD | TBD | TBD | TBD |
| Belief drift rate (T9 probe, n=20) | TBD | TBD | TBD | TBD |
| C1 context retention (mean) | TBD | TBD | TBD | TBD |
| C2 belief consistency (mean) | TBD | TBD | TBD | TBD |
| C3 evidence integration (mean) | TBD | TBD | TBD | TBD |
| C4 no-contradiction (mean) | TBD | TBD | TBD | TBD |
| A/A judge delta | TBD | — | TBD | TBD |
| Promotion to n=50 | TBD | — | — | TBD |

---

## Fixture JSON (planned, to be created under scripts/ab-harness/fixtures/)

The fixture JSON (path: `scripts/ab-harness/fixtures/multiturn_debug_01.json`) will encode:
- `turns`: array of 10 objects, each with `role: "user"`, `content: "<message>"`, and
  `rubric: { correct_action: "...", coherence_checkpoint: "...", score_pass: 1, score_partial: 0.5, score_fail: 0 }`.
- `ground_truth`: object with `root_cause`, `correct_fix`, `correct_rejection` fields
  (used by the judge to score T9 and T10).
- `drift_probe_turns`: `[9]` — turns where belief drift is specifically measured.
- `coherence_dimensions`: `["C1", "C2", "C3", "C4"]` with per-dimension turn lists.

**Status:** JSON encoding is TBD — awaiting EVAL-043 harness design to confirm the
multi-turn fixture format.

---

## Methodology compliance checklist

Per `docs/RESEARCH_INTEGRITY.md`:

- [x] Sample size specified: n=20 initial, n=50 promotion, with clear promotion criterion.
- [x] Judge composition: haiku-4-5 + llama-3.3-70b (non-Anthropic) panel specified.
- [x] Human ground truth: T9 and T10 rubrics are human-verifiable (the optimizer hypothesis
  rejection and the summary accuracy are judgment calls documented explicitly).
- [x] Mechanism analysis: two competing hypotheses documented (cognitive layer improves
  coherence vs. conditional-chain dilution degrades it); EVAL-029 Mode A cited as prior.
- [x] A/A baseline: required before citing results; delta threshold ±0.03 specified.
- [x] Reproducibility: harness call documented (flags TBD pending EVAL-043).
- [x] No prohibited claims made: all results TBD; no architecture-validation claim.
- [x] Dependency noted: EVAL-043 required before A/B sweep; fixture design ships independently.
