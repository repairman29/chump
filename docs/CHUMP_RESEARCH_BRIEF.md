# Chump Research Brief

One-page summary for external reviewers (Gemini, collaborators, pilot users). Describes what Chump is, what's been measured, and what open questions remain.

**Full cognitive architecture details:** [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md). **Competitive context:** [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md).

---

## What Chump is

Chump is a **local-first AI agent framework** built in Rust, designed to run continuously on consumer hardware (tested on M4 MacBook Pro 24GB). It wraps LLM APIs with a cognitive architecture layer inspired by active inference: surprisal EMA, neuromodulation signals, belief state, and a speculative execution engine.

Key differentiators vs. other agent frameworks:
- **Cognitive architecture:** belief state, surprisal EMA, neuromodulation (serotonin/dopamine analogs), EFE tool selection
- **Memory system:** SQLite-backed episodic memory with cross-encoder reranking; async LLM summarization to semantic
- **Evaluation harness:** 2000+ A/B trials with multi-judge scoring; A/A controls; Wilson 95% CI
- **Multi-agent coordination:** lease files, ambient stream, musher dispatcher, pre-commit guards
- **Provider cascade:** vLLM-MLX (local 14B) → Ollama → Together.ai → OpenAI

## What has been measured

| Finding | Method | Effect | Status |
|---------|--------|--------|--------|
| Single-judge bias | EVAL-010 | 38–63% agreement at chance | Validated |
| A/B vs A/A noise floor | EVAL-024 | 10.7× ratio established | Validated |
| Instruction injection: haiku-4-5 response (COG-016 directive) | EVAL-025, n=100×3 | −0.14 mean reduction in fake-tool calls | Validated |
| Instruction injection: sonnet-4-5 backfire (COG-023) | EVAL-027c, n=100 | +0.33 hallucination rate — tier-dependent harm | Validated |
| Surprisal EMA signal | EVAL-011..015 | Delta ≈ 0 on qwen2.5:7b; −0.10 to −0.30 on second-LLM rescore | Unablated (EVAL-043 pending) |
| Neuromodulation cross-architecture signal | EVAL-029 | −0.10 to −0.16 mean delta across four models | Net-negative (EVAL-030-VALIDATE pending) |
| Entity-keyed blackboard injection | COG-015 | Reduces context re-fetch | Unablated (no isolation eval yet) |

## Open questions

1. **Does the cognitive layer help on real tasks?** Battle QA pass rate with `CHUMP_CONSCIOUSNESS_ENABLED=1` vs `0` has not been run as a controlled experiment. Procedure: [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md).

2. **What's the ROI of lessons at 32B?** The 1B–14B sweep (EVAL-026) showed a U-curve; the 32B endpoint is unmeasured.

3. **Does belief state add value?** EVAL-035 is a planned ablation: disable `belief_state.rs` and measure task quality at n=100.

4. **Is memory retrieval multi-hop?** MEM-007 / EVAL-034 are open gaps. Current system handles single-hop well; multi-hop QA is untested.

## Infrastructure for external review

- **A/B harness:** `scripts/run-cloud-v2.py --fixture <name> --n 100 --model <id>`
- **Fixtures:** `eval/fixtures/` — 12 task types covering tool calls, multi-turn, distractor suppression
- **Judge:** cross-family (OpenAI judge via Ollama) to reduce same-family bias
- **Cost:** ~$0.15 per n=100 run with sonnet-4-7 subject + haiku judge

## See Also

- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — full cognitive architecture
- [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) — complete EVAL chain
- [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — competitive landscape
- [ROADMAP_FULL.md](ROADMAP_FULL.md) — 186 gaps, 50 open, 136 done
