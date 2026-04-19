# HN submission summary — "What 2,500+ A/B trials taught us about a local AI agent"

## Title (under 80 chars)
**Show HN: 2,500 A/B trials on a local AI agent — capability-tier-dependent harm**

## Two-paragraph TL;DR

We ran 2,500+ controlled A/B trials on Chump (a local-first Rust agent) testing what happens when you prepend a four-line "lessons from prior episodes" block to the system prompt. The block reliably triggers fake-tool-call emission (`<function_calls>` markup with no tools to back it) at +0.12 to +0.17 across three n=100 task fixtures on `claude-haiku-4-5`, with non-overlapping Wilson 95% CIs and 10× the calibrated A/A noise floor. Crucially, the harm is **capability-tier-dependent within the Anthropic family** — `claude-3-haiku` 0%, `haiku-4-5` 12%, `sonnet-4-5` 18%, `opus-4-5` **40%** (n=50, Δ +0.38, statistically defensible). And it is **pretrain-family-specific**: Qwen2.5-7B, Qwen3-235B, and Llama-3.3-70B produced **zero fake emissions in 900 trials** under the same lessons block. The detector regex itself is Anthropic-pretrain-shaped — naive cross-family runs would silently miss harm on other models.

The kicker: the single-sentence anti-hallucination directive we shipped to fix the harm (COG-016) **backfires at sonnet-4-5**. n=100 confirmation: 33% fake-emission rate under the directive vs 0% without it (Δ +0.33, Wilson CIs [0.246, 0.427] vs [0.000, 0.037], inter-judge agreement 0.81). The same directive eliminates harm at haiku-4-5 (-0.01), partially fixes opus-4-5 (+0.10), and triples it at sonnet-4-5. We are now shipping a defensive carve-out for sonnet and reconsidering whether *any* default-on cognitive scaffolding is defensible without per-model A/B validation. Full writeup, raw JSONL logs, harness code, and exact reproduction commands in the post. Cross-family judge (`claude-sonnet-4-5` + `Llama-3.3-70B-Instruct-Turbo`), three-axis scoring (`did_attempt` / `hallucinated_tools` / `is_correct`), Wilson CIs on every cell, A/A noise-floor controls — the methodology details that make this preprint-citable rather than blogpost-anecdotal.

## Suggested HN URL anchor
`docs/blog/2026-04-20-2000-trials-on-a-local-agent.md`

## Twitter/X (280 char)

2,500 A/B trials on a local AI agent. Lessons-block prompt → opus-4-5 fakes tool calls 40% of the time (Wilson CIs non-overlapping). The directive we shipped to fix it BACKFIRES at sonnet-4-5: 33% vs 0% (Δ +0.33). Capability-tier-dependent harm is real. Writeup + raw logs ↓
