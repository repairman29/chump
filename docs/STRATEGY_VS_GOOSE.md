# Chump vs goose: Strategic Positioning (2026-04-19)

## TL;DR

- goose (Block, now Linux Foundation AAIF) is a well-funded, broadly-distributed general-purpose Rust agent framework. We will not out-feature it.
- Chump's defensible niche is the **eval-rigorous local agent for serious developers**: cognitive layer + multi-axis A/B harness + published findings goose architecturally cannot reproduce.
- We should adopt the open standards goose helps codify (AGENTS.md, Recipes-style packaged workflows, brew distribution) without chasing parity on the GUI/provider/extensions surface.
- Our recent EVAL-023/025/026 trilogy and the EVAL-026b opus +0.38 hallucination finding are the kind of artifact that make Chump a *research-grade* tool, not a goose alternative.
- Roadmap should harden the niche (research story Q2), align with standards (Q3), and benchmark cross-agent (Q4).

## Honest capability comparison

| Feature | goose | Chump |
|---|---|---|
| Implementation language | Rust (Apache 2.0, ~4.3K commits) | Rust (same) |
| Distribution | Desktop app (Mac/Linux/Windows), `brew install --cask block-goose`, CLI, embeddable API | CLI only; no brew, no desktop |
| LLM providers | 15+ (Anthropic, OpenAI, Google, Ollama, OpenRouter, Azure, Bedrock, Databricks, LM Studio, Docker Model Runner, …) | Anthropic + local (Ollama / mistral.rs); narrower by design |
| MCP extensions | 70+ official, ecosystem of 3000+ servers | 3 in-tree (chump-mcp-adb, chump-mcp-github, chump-mcp-tavily) |
| Packaged workflows | **Recipes** (instructions + extensions + params + retry, shareable) | No equivalent (gap COMP-008) |
| Sandbox / safety | Sandbox mode + **Adversary Mode** (LLM reviewer w/ adversary.md NL rules, default-monitors shell + automation_script) | Partial: tool-call gating, no LLM-based adversary reviewer (gap COMP-011a/b) |
| Multi-agent coordination | Not a primary concern | **chump-coord crate**: NATS, worktrees, lease files, gap registry, ambient.jsonl |
| Cognitive layer | None | lessons block, neuromodulation, perception, blackboard, belief_state, reflection, memory_db, memory_graph |
| A/B eval harness | None shipped | run-cloud-v2.py + scoring_v2 (did_attempt / hallucinated_tools / is_correct) + Wilson CIs + cross-family judge median |
| Published research findings | None | EVAL-023, EVAL-025, EVAL-026, EVAL-026b (opus +0.38 SIG) |
| Governance | Linux Foundation AAIF founding project | Single-repo, single-maintainer, no foundation |
| Community | ~29K GitHub stars, AAIF Platinum backers (AWS, Anthropic, Google, MS, OpenAI, Bloomberg, Cloudflare) | Tiny |

## Where goose is materially ahead

- **Distribution and onboarding.** brew cask + desktop app means a non-CLI user can be productive in minutes.
- **MCP ecosystem reach.** 70+ first-party extensions plus discovery into 3000+ community servers; we ship three.
- **Recipes.** Packaged, parameterized, retry-aware shareable workflows — a real reuse primitive we lack.
- **Adversary Mode.** Production-grade LLM-based, context-aware tool-call review with natural-language policy is a feature we have specced but not shipped.
- **Governance and backing.** AAIF founding-project status with Platinum backers gives goose enterprise oxygen we cannot match on resources.

## Where Chump is genuinely ahead

- **Eval rigor.** Multi-axis scoring (did_attempt / hallucinated_tools / is_correct) with Wilson CIs and cross-family judge median is not a feature goose ships.
- **Reproducible safety findings.** EVAL-025 shows the cog016 anti-hallucination directive eliminates harm to a -0.003 mean delta; EVAL-026 confirms cross-architecture immunity (Qwen-7B/235B + Llama-70B all 0% delta with v1 lessons).
- **Cross-family judge validation.** EVAL-023 demonstrates haiku-4-5 produces a +0.137 hallucination delta visible only via cross-family judging — a methodology goose has no harness for.
- **Capability-scaling hallucination evidence.** EVAL-026b shows Anthropic-family hallucination harm scales monotonically with capability (haiku-3 0% → haiku-4-5 +0.12 → sonnet-4-5 +0.16 directional → opus-4-5 +0.38 SIG, non-overlapping CI at n=50). This is a publishable finding.
- **Multi-agent coordination as primitives.** chump-coord (worktrees + leases + gap registry + ambient.jsonl) treats concurrent agents as a first-class environment, not a future problem.

## What to take from goose (in priority order)

1. **COMP-007 — AGENTS.md adoption.** Standards alignment is cheap and increases interoperability with the AAIF ecosystem.
2. **COMP-008 — Recipes.** A packaged-workflow primitive is the highest-leverage feature we lack; should map cleanly onto our existing CLI invocations.
3. **COMP-010 — `brew install chump`.** Distribution friction is currently our biggest barrier to outside contributors.
4. **COMP-011a/b — Adversary Mode.** LLM-based tool-call reviewer with NL policy fits naturally over our existing tool-call gate; reuse the adversary.md format for portability.
5. **COMP-009 — MCP-server expansion.** Triage the goose 70+ list; pick the 5–10 highest-utility ones (filesystem, sqlite, fetch) to ship as Chump-tested.
6. **INFRA-MCP-DISCOVERY.** Dynamic discovery from the public MCP registry so we are not maintaining a static list.

## What NOT to take from goose

- **Desktop GUI.** Premature for our user base; doubles the surface area we have to keep working under model churn.
- **15+ provider list.** We are local-first and Anthropic-quality-anchored. Adding Bedrock / Databricks / Azure dilutes the eval signal that makes Chump worth running.
- **General-purpose framing.** "An agent for everyone" is goose's positioning; ours is "a research-grade local agent for developers who care about hallucination rates."
- **Custom branded distributions.** Block-goose, vendor-skinned forks — these are an enterprise-sales motion, not an OSS health signal.

## Chump's defensible niche

Chump is **the eval-rigorous local agent for serious developers**. The differentiator is not features; it is the closed loop between the cognitive layer (lessons, neuromodulation, reflection, memory_db) and the A/B eval harness (run-cloud-v2 + scoring_v2 + cross-family judge) that makes every behavioral change a measurable, reproducible scientific claim.

Goose architecturally cannot produce a finding like EVAL-026b — the harness, the cross-family judge, the multi-axis scoring, and the cognitive-layer instrumentation that generated it do not exist in their codebase and would not fit their general-purpose framing. That trilogy of artifacts (EVAL-023 cross-family judge validation, EVAL-025 mitigation efficacy, EVAL-026 cross-architecture immunity, EVAL-026b capability-scaling harm) is a research moat goose cannot trivially close. We should stop trying to be a smaller goose and start being the agent people cite when they publish about agent safety and capability scaling.

## 12-month roadmap

**2026-Q2 (now) — Harden the niche.**
- Land EVAL-027b, SAKE, CatAttack benchmarks.
- Ship RESEARCH-001: the publishable narrative weaving EVAL-023/025/026/026b into a single artifact.
- Tighten cog016 model-tier gating (CHUMP_LESSONS_MIN_TIER) and document the U-curve.

**2026-Q3 — Align with standards, lower distribution friction.**
- COMP-007 AGENTS.md compatibility.
- COMP-008 Recipes-equivalent packaged workflows.
- COMP-010 `brew install chump`.
- Begin COMP-011a/b adversary mode reusing goose's adversary.md NL format.

**2026-Q4 — Cross-agent benchmarking.**
- FRONTIER-007: run our eval harness against goose, Claude Code, Cursor agents on the same scoring rubric.
- Publish comparative hallucination + correctness numbers; make Chump's harness the de facto cross-agent benchmark.

## Sources

- https://block.github.io/goose/ — goose docs
- https://github.com/block/goose — goose source (v1.31.0, 2026-04-17)
- https://www.linuxfoundation.org/press/linux-foundation-launches-agentic-ai-foundation — AAIF launch (Dec 2025)
- https://block.github.io/goose/docs/guides/recipes — Recipes spec
- https://block.github.io/goose/docs/guides/adversary-mode — Adversary Mode
- https://github.com/modelcontextprotocol/servers — MCP server ecosystem
- Internal: `docs/gaps.yaml` (COMP-007/008/009/010/011a/011b, INFRA-MCP-DISCOVERY, FRONTIER-005/007, RESEARCH-001)
- Internal: `docs/eval/EVAL-023*.md`, `docs/eval/EVAL-025*.md`, `docs/eval/EVAL-026*.md`, `docs/eval/EVAL-026b*.md`
