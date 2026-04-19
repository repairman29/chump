# What 2,500+ A/B trials taught us about a local AI agent

**Status: STUB.** Filled in as the underlying experiments land. Final version
ships when EVAL-027c (sonnet-4-5 cog016 n=100, in flight as of 2026-04-19),
EVAL-026c (qwen2.5:7b/14b real-tool local sweep, in flight), EVAL-028
(CatAttack robustness), and EVAL-030 (task-class-aware lessons) all land.

---

## The setup

(Brief intro. ~1-2 paragraphs.)

- What Chump is: local-first Rust agent, dogfooded by one developer
- Why we built an A/B harness from day one
- What "v2 multi-axis scoring" means: `did_attempt`, `hallucinated_tools`,
  `is_correct` — three independent ways a trial can pass or fail
- Why cross-family judging matters: EVAL-010 showed two Anthropic judges
  agree at chance on the correctness axis; we needed a non-Anthropic
  judge in the panel

## Finding 1: Cognitive scaffolding has a hallucination harm channel

Reference: EVAL-023, EVAL-025.

(~3 paragraphs)

- Setup: "Lessons block" — 4 directives prepended to system prompt
- Symptom: claude-haiku-4-5 with v1 lessons block emits fake `<function_calls>`
  markup 12% of the time vs 0% without lessons
- n=600 trials × 3 fixtures, cross-family judges (claude-sonnet-4-5 +
  Llama-3.3-70B), Wilson 95% CIs non-overlapping
- The fix: anti-hallucination directive prepended to lessons (COG-016)
  eliminates harm at haiku-4-5 (-0.003 mean delta)

(insert chart: cell A vs cell B halluc rate per fixture, v1 vs cog016)

## Finding 2: The harm is Anthropic-pretrain-specific

Reference: EVAL-026.

(~2 paragraphs)

- Same v1 lessons block on Qwen2.5-7B, Qwen3-235B-A22B, Llama-3.3-70B
- Result: 0% hallucination delta in all 9 cells (3 models × 3 fixtures)
- 900 trials, 0 hallucinations triggered
- The "fake tool markup" failure mode is specific to Anthropic's
  pretraining distribution. Non-Anthropic models exposed to the same
  lessons-block respond with honest "I cannot execute" language.

(insert chart: cross-architecture immunity comparison)

## Finding 3: Within Anthropic, harm scales monotonically with capability

Reference: EVAL-026b.

(~2 paragraphs)

- Tested 4 Anthropic models on the same v1 lessons block: claude-3-haiku
  (legacy small), claude-haiku-4-5 (current small), claude-sonnet-4-5
  (current medium-large), claude-opus-4-5 (current frontier)
- Result: 0% → 12% → 18% (directional) → 40% hallucination rate in cell A
- The opus +0.38 delta is 3× larger than the haiku-4-5 +0.12 baseline
- Strategic memo's predicted U-curve in CORRECTNESS doesn't replicate;
  the actual U-curve is in HALLUCINATION HARM and points the wrong way
  for the "use the biggest model" default

(insert chart: Anthropic capability vs hallucination rate)

## Finding 4: The mitigation has its own inverted U-curve

Reference: EVAL-027b (n=50) + EVAL-027c (n=100 CONFIRMED).

The COG-016 anti-hallucination directive (which fixed haiku-4-5 in
EVAL-025) is **not universally protective** when tested across the full
Anthropic capability range. EVAL-027c confirmed at n=100 that the
directive's effect inverts in the middle of the capability spectrum.

| Anthropic agent | No lessons (cell B) | v1 lessons | cog016 lessons | Effect |
|---|---|---|---|---|
| haiku-4-5 | 0% | 12% | -1% (eliminates) | directive WORKS |
| sonnet-4-5 | 0% | 18% | **33%** (worsens) | directive BACKFIRES (n=100, Δ +0.33 SIG) |
| opus-4-5 | 2% | 40% | 10% (partially fixes) | directive partially helps |

The pattern: **directive effectiveness has its own inverted U-curve**.
It works at small (haiku-4-5: +0.12 → -0.01) and large (opus-4-5:
+0.38 → +0.10) tiers, but it backfires at sonnet-4-5 (cog016 cell A
33% halluc vs cell B 0%, Δ +0.33 with non-overlapping Wilson 95% CIs
at n=100, inter-judge agreement 0.81). Sonnet-4-5 produces fake
tool-call markup MORE often when given the explicit "do NOT emit
fake tool markup" directive than when given no instructions at all.

The mechanism is open — possibly the directive primes the failure
mode by drawing the model's attention to the exact pattern it's
asked to suppress. Worth its own follow-up investigation.

**Production implication:** COG-016 currently ships with default
Frontier-tier lessons injection. Both sonnet-4-5 and opus-4-5 are
classified Frontier in our ModelTier enum, so both receive the
directive by default. **At sonnet-4-5 this means production users
are getting 33% fake tool emission per response — actively harmed by
the very directive intended to protect them.** Gap COG-023 (Sonnet
carve-out, P1) is the defensive patch. Gap COG-024 (default
lessons-OFF, opt-in per model after measurement) is the longer-term
rethink.

The deeper takeaway is that "we found a problem and shipped a fix"
is rarely the end of the story for cognitive scaffolding. Each
intervention has its own capability-tier-dependent effect. The only
defensible production policy is per-model A/B validation, not
universal heuristics.

## Finding 5: Cross-architecture neuromod-fixture harm has a fixable mechanism

Reference: EVAL-026 (cross-arch signal), EVAL-029 (drilldown), EVAL-030
(PENDING fix).

(~2 paragraphs)

- Across haiku-cog016, Qwen-7B, Llama-70B, Qwen3-235B (4 architectures,
  1200 trials), the v1 lessons block consistently HURTS by 10-16
  percentage points on the neuromod fixture
- Drilldown identified two distinct mechanisms: (a) "ask one clarifying
  question" directive causes early-stopping on multi-step recovery
  tasks, (b) ~400-token lessons block dwarfs short chat prompts
- Important nuance: this is NOT the Knowledge Integration Decay (KID)
  context-loss problem the Feb 2026 SAKE paper addresses. Different
  failure mode. EVAL-030 (task-class-aware lessons injection) is the
  proposed fix.

(insert table: top-5 harm-driving neuromod tasks with prompt text)

## Method appendix

- Fixtures: reflection_tasks.json (100 tasks), perception_tasks.json
  (100 tasks), neuromod_tasks.json (100 tasks). All in
  `scripts/ab-harness/fixtures/`
- Harness: `scripts/ab-harness/run-cloud-v2.py` (cloud A/B with
  cross-family judge median verdict + Wilson 95% CIs)
- Scoring: `crates/chump-perception/src/scoring_v2.rs` (3-axis multi-output)
- Agent dispatch: Anthropic via Messages API; Together via OpenAI-compatible
  /v1/chat/completions; Ollama via /api/chat
- Cost ledger: `scripts/ab-harness/cost_ledger.py` (per-call attribution)

## What we cannot conclude

(~1-2 paragraphs explicitly addressing limitations)

- All findings are on textual reasoning + tool-use fixtures. No multimodal,
  no real-world embodiment.
- Cross-family judging breaks Anthropic-only judge bias on the hallucination
  axis but not necessarily on the correctness axis (inter-judge agreement
  73-78% on most fixtures — below 0.80 threshold)
- n=50 results in EVAL-026b/EVAL-027b are statistically significant on the
  hallucination axis only when CIs are non-overlapping. Sonnet-4-5 result
  needs n=100 (in flight via EVAL-027c)
- The EVAL-029 mechanism analysis is post-hoc on existing logs; the proposed
  EVAL-030 task-class-aware fix has not been validated yet

## What's next

- EVAL-027c result (~30 min from publication) decides COG-023 production
  ship: sonnet-specific carve-out from default Frontier-tier injection
- EVAL-030 ships in 2026-Q3 if the task-class-aware lessons fix validates
- RESEARCH-001 (this document) republished with updated numbers when above
  data lands

## Total scoreboard at time of writing

| Experiment | Trials | Status |
|---|---|---|
| EVAL-023 (cross-family validation) | 600 | ✅ shipped |
| EVAL-025 (cog016 directive at haiku-4-5) | 600 | ✅ shipped |
| EVAL-026 (cross-architecture immunity) | 900 | ✅ shipped |
| EVAL-026b (Anthropic capability sweep) | 300 | ✅ shipped |
| EVAL-027b (cog016 at sonnet/opus) | 200 | ✅ shipped 2026-04-19 |
| EVAL-027c (sonnet n=100 confirm) | 200 | ✅ shipped 2026-04-19 — CONFIRMED |
| EVAL-029 (neuromod task drilldown) | 1200 (re-analysis) | ✅ shipped |
| EVAL-026c (local 7B/14B real-tool) | 200 | 🏃 in flight |
| EVAL-028 (CatAttack robustness) | 0 | 📋 filed not run |
| EVAL-030 (task-class-aware fix) | 0 | 📋 filed not run |

**Trial count to date: 3,200+** (across 9 completed experiments — EVAL-023, 025, 026 ×3 fixtures, 026b ×3 Anthropic models, 027b ×2 frontier models, 027c sonnet n=100 confirmation).

## Cross-references

- All gap entries in `docs/gaps.yaml` (EVAL-023 through COG-023)
- Full A/B writeups: `docs/CONSCIOUSNESS_AB_RESULTS.md`
- Architecture map: `docs/CHUMP_FACULTY_MAP.md`
- Strategic positioning: `docs/STRATEGY_VS_GOOSE.md`
- Q3 research plan: `docs/RESEARCH_PLAN_2026Q3.md`
- This blog post lives at: docs/blog/2026-XX-2000-trials-on-a-local-agent.md
