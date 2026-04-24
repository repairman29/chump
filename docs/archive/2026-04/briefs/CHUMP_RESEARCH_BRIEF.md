# Chump Research Brief

One-page summary for external reviewers (Gemini, collaborators, pilot users). Describes what Chump is, what's been measured, and what open questions remain.

**Full cognitive architecture details:** [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md). **Competitive context:** [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md).

> **Research integrity note (read before citing claims):**
> Chump’s *cognitive architecture as a whole* is **not validated**. The main validated empirical thesis is
> **tier-dependent instruction injection** (lessons block helps haiku-4-5 on a reflection fixture, but can
> backfire on frontier tiers). Individual-module contribution claims (surprisal EMA, belief state,
> neuromodulation) are prohibited until isolation ablations ship. See `docs/RESEARCH_INTEGRITY.md`.

---

## What Chump is

Chump is a **local-first AI agent framework** built in Rust, designed to run continuously on consumer hardware (tested on M4 MacBook Pro 24GB). It wraps LLM APIs with a cognitive architecture layer inspired by active inference: surprisal EMA, neuromodulation signals, belief state, and a speculative execution engine.

Key differentiators vs. other agent frameworks:
- **Cognitive architecture:** belief state, surprisal EMA, neuromodulation (serotonin/dopamine analogs), EFE tool selection
- **Memory system:** SQLite-backed episodic memory with cross-encoder reranking; async LLM summarization to semantic
- **Evaluation harness:** A/B sweeps with Wilson CIs and explicit A/A noise calibration on key findings; cross-family judging is required for publication-grade claims (see `docs/RESEARCH_INTEGRITY.md`)
- **Multi-agent coordination:** lease files, ambient stream, musher dispatcher, pre-commit guards
- **Provider cascade:** vLLM-MLX (local 14B) → Ollama → Together.ai → OpenAI

## What has been measured

| Finding | Method | Effect | Status |
|---------|--------|--------|--------|
| Single-judge bias | EVAL-010 | 38–63% agreement at chance | Validated |
| A/B vs A/A noise floor | EVAL-024 | 10.7× ratio established | Validated |
| Instruction injection: haiku-4-5 response (COG-016 directive) | EVAL-025, n=100×3 (cross-family judge) | hallucinated tool-call delta reduced to ≈ −0.003 pp mean | Validated |
| Instruction injection: sonnet-4-5 backfire (COG-023) | EVAL-027c, n=100 | +0.33 hallucination rate — tier-dependent harm | Validated |
| Surprisal EMA signal | EVAL-011..015 | Delta ≈ 0 on qwen2.5:7b; −0.10 to −0.30 on second-LLM rescore | Unconfirmed — EVAL-043 ablation sweep pending (`CHUMP_BYPASS_SURPRISAL` flag shipped 2026-04-19) |
| Neuromodulation cross-architecture signal | EVAL-029 | −0.10 to −0.16 mean delta across four models | Net-negative — EVAL-043 ablation sweep pending (`CHUMP_BYPASS_NEUROMOD` flag shipped 2026-04-19; `CHUMP_NEUROMOD_ENABLED=0` is the legacy gate) |
| Entity-keyed blackboard injection | COG-015 | Reduces context re-fetch | Unablated (no isolation eval yet) |

## Open questions

1. **Does the cognitive layer help on real tasks?** Battle QA pass rate with `CHUMP_CONSCIOUSNESS_ENABLED=1` vs `0` has not been run as a controlled experiment. Procedure: [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md).

2. **What's the ROI of lessons at 32B?** The 1B–14B sweep (EVAL-026) showed a U-curve; the 32B endpoint is unmeasured.

3. **Does belief state add value?** EVAL-043 ablation infrastructure is shipped (`CHUMP_BYPASS_BELIEF_STATE`, `CHUMP_BYPASS_SURPRISAL`, `CHUMP_BYPASS_NEUROMOD` flags all implemented). Sweeps pending. Per `docs/RESEARCH_INTEGRITY.md`, "belief state improves agent performance" is prohibited until EVAL-043 + EVAL-035 sweeps both complete at n≥100 with cross-family judges. See `docs/eval/EVAL-043-ablation.md`.

4. **Is memory retrieval multi-hop?** MEM-007 / EVAL-034 are open gaps. Current system handles single-hop well; multi-hop QA is untested.

## Infrastructure for external review

- **A/B harness:** `python3.12 scripts/ab-harness/run-cloud-v2.py --help` (supports `--mode ab|aa|abc`, `--null-prose-match`, `--n-per-cell`)
- **Fixtures:** `scripts/ab-harness/fixtures/` — reflection fixture is used by EVAL-025 and preregistered RESEARCH-018/021
- **Judging:** cross-family judges are required for publication-grade claims per `docs/RESEARCH_INTEGRITY.md` (Anthropic-only judging is preliminary)
- **Cost:** varies by provider/model; see `docs/eval/preregistered/COST_OPTIMIZATION.md`

## See Also

- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — full cognitive architecture
- [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) — complete EVAL chain
- [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — competitive landscape
- [ROADMAP_FULL.md](ROADMAP_FULL.md) — 186 gaps, 50 open, 136 done
