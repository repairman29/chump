# Market Evaluation

Framework for evaluating Chump's market position, pilot readiness, and competitive standing. See [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) for the competitive analysis.

## §1 — Product identity

**North Star:** Understanding the user in Discord (or PWA) and acting on intent — infer what they want from natural language; create tasks, run commands, or answer without over-asking.

**Three concurrent product axes** (tension documented in [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md)):
1. Personal ops bot (Discord/PWA, task management, intent parsing)
2. Cognitive architecture research platform (A/B harness, consciousness framework)
3. Fleet OS for personal compute (Mac + Pixel + cloud, inference mesh)

## §2 — Baseline scores

### §2b — Capability baseline

| Capability | Status | Evidence |
|------------|--------|----------|
| Basic task management | ✓ Shipped | `chump_tasks`, task tool, heartbeat |
| Memory across sessions | ✓ Shipped | SQLite + FTS5 + graph RRF |
| Web search | ✓ Shipped | Tavily + air-gap mode |
| File read/write in repo | ✓ Shipped | read_file, write_file, patch_file |
| Discord bot | ✓ Shipped | `--discord` mode |
| PWA / web UI | ✓ Shipped | `--web` mode, Dashboard |
| Provider cascade | ✓ Shipped | 8 providers, ~72k free RPD |
| Local inference | ✓ Shipped | Ollama + vLLM-MLX + mistral.rs |
| A/B eval harness | ✓ Shipped | 1,620+ trials, Wilson CIs |
| Multi-platform messaging | ✓ Shipped | Slack, Telegram, Signal adapters |
| ACP (Zed/JetBrains) | ✓ Shipped | 96 unit tests |
| Browser automation | 🔧 Scaffold | V1 stub; V2 (chromiumoxide) pending |
| Cross-family judge | 🔧 Partial | Ollama judge wired; EVAL-023 done |
| Benchmark results | ✗ Pending | `scripts/chump-bench.sh` exists; no results published |
| Brew install | ✗ Pending | COMP-010 (S effort) |

## §4 — Sprint tracking

### §4.2 — Sprint tracker

| Sprint | Theme | Status |
|--------|-------|--------|
| Q1 2026 W1 | Foundation: multi-surface, heartbeat, memory | ✓ Done |
| Q1 2026 W2 | Cognitive framework A/B validation | ✓ Done |
| Q1 2026 W3 | Multi-agent coordination system | ✓ Done |
| Q1 2026 W4 | ACP integration + provider cascade | ✓ Done |
| Q2 2026 W1 | AUTO-013 orchestrator + EVAL-028/030 | 🔧 In progress |
| Q2 2026 W2 | COG-023 + RESEARCH-001 + COMP-010 | Planned |

### §4.4 — Progress line

Velocity: ~24 PRs/36h autonomous session; ~4–8 PRs/session typical.
P1 gaps closed this month: COG-016, EVAL-025, INFRA-MERGE-QUEUE (partial).
Remaining P1s: 10 gaps (EVAL-026/027/030, COG-023, RESEARCH-001, INFRA-AGENT-CODEREVIEW, AUTO-013, FRONTIER-005, INFRA-PUSH-LOCK, one more).

## §5 — Pilot readiness

**Current pilot posture:** Defense/high-assurance. See [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md).

**N3 milestone:** 3+ sessions, 1+ tasks completed. SQL queries and API: [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md).

**N4 milestone:** Daily driver — 5 of last 7 days active.

**Blockers for external pilot:**
1. No signed/notarized distribution (COMP-010 + PACKAGING_AND_NOTARIZATION.md §TODO)
2. Benchmark results not published (BENCHMARKS.md empty table)
3. COG-016 lessons block still active for weak models (COG-023 Sonnet carve-out in progress)
4. `config/` not in `.gitignore` (security gap; fix: add `config/*.yaml`)

## §7 — Competitive differentiation

**Where Chump wins vs Hermes/goose:**
- Memory graph with PageRank (no competitor has entity resolution)
- Empirical A/B validation (10.7× A/A noise floor; goose has no benchmarks)
- Single Rust binary (vs Python install friction)
- Consciousness framework (surprisal EMA, neuromodulation, belief state)
- ACP first-class (Zed/JetBrains native integration)

**Where Chump is behind:**
- No brew/signed installer (goose has it)
- No adversary mode (goose has it)
- Fewer MCP servers (goose has 70+; Chump has 3)
- No published benchmarks

See [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) for the full analysis.

## §8 — Market wedge index

Primary docs for market positioning:

| Doc | Purpose |
|-----|---------|
| [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) | N3/N4 SQL + API recipes |
| [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) | Defense/high-assurance pilot setup |
| [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) | Hermes/goose/AutoGen analysis |
| [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | First-install experience (N1→N2) |
| [BENCHMARKS.md](BENCHMARKS.md) | Published performance numbers |
| [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) | Empirical research validation |

## See Also

- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — honest current-state assessment
- [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — what ships this quarter
- [RED_LETTER.md](RED_LETTER.md) — adversarial weekly review
