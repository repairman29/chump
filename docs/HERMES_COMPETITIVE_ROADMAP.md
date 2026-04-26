---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Hermes Competitive Roadmap

> **Note:** "Hermes" was an internal codename for the cross-agent benchmarking initiative. This doc redirects to the current competitive analysis docs.

## Current competitive analysis

See [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) for the live competitive landscape covering goose, Cursor, GitHub Copilot Workspace, Devin, OpenHands, and others.

See [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §7 for Chump's differentiation positioning.

## Cross-agent benchmarking (FRONTIER-007)

The plan to apply the Chump eval harness to competing agents:

**Status:** Open gap, P2, M effort.

**Scope:**
- Run the same `eval/fixtures/` task suite against goose and one other agent (e.g. aider)
- Use the same multi-judge scoring (cross-family judge via Ollama)
- Compare on: task completion rate, tool call accuracy, multi-turn coherence, cost per task

**Blockers:** Need to instrument competing agents' output format for the judge. goose outputs Markdown; Chump outputs structured JSON tool calls. Normalization step needed.

**Effort estimate:** M (1–3 days for instrumentation + 1 run = ~$5 in cloud spend).

## goose positioning (FRONTIER-005)

Chump vs. goose differentiation: see [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) §goose.

Key Chump advantages over goose:
- Cognitive architecture (belief state, surprisal, neuromodulation)
- 2000+ A/B trials with Wilson CI — quantitative, not vibes
- Multi-agent coordination (lease files, ambient stream)
- Local-first (14B on M4; no cloud required)

Key goose advantages:
- Broader plugin ecosystem
- Lower barrier to install
- More polish on the CLI UX

## See Also

- [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — competitive landscape
- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — market positioning
- [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — emerging models and frameworks to watch
