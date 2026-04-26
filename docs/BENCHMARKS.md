---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump benchmarks

Chump's public number, measured the same way twice, reproducible locally.

OpenJarvis's headline is **"88.7% of single-turn queries at interactive latency"** (from their [Intelligence Per Watt](https://www.intelligence-per-watt.ai/) research). That's a meaningful baseline and we publish our own numbers against a comparable scenario mix.

## How to reproduce

```bash
# Ensure your local LLM is running (Ollama / vLLM-MLX / etc.).
./scripts/chump-bench.sh
# or: ./scripts/chump-bench.sh --scenario chat
# or: ./scripts/chump-bench.sh --list
```

Output: `logs/chump-bench/<ts>/report.json` (structured) + `summary.md` (human-readable). To publish a new public result, paste the aggregate section from the latest summary into the table below, along with the model + host row, and commit.

## Scenarios

Eight scenarios covering the core usage modes. Deterministic prompts so repeated runs are comparable across model changes.

| name | timeout | interactive budget | what it exercises |
|---|---|---|---|
| `chat` | 60 s | 30 s | baseline greeting; no tools |
| `task-list` | 180 s | 60 s | single-tool (`task`), small output |
| `read-small` | 180 s | 60 s | single-tool (`read_file`, ≤5 KB) |
| `read-line-range` | 240 s | 90 s | `read_file` with explicit line range; counting logic |
| `rg-search` | 240 s | 90 s | `run_cli` + stdout parsing |
| `multi-tool` | 360 s | 150 s | two tools in sequence + narration |
| `code-explain` | 240 s | 90 s | `read_file` + multi-sentence explanation |
| `math-reason` | 60 s | 30 s | pure reasoning; no tools |

**Pass criteria** (same as the dogfood matrix in `scripts/dogfood-matrix.sh`):

- Chump exit code == 0
- Stdout does not contain "model HTTP unreachable"
- vLLM log slice for this scenario contains no Metal assertion / `MTLCommandBuffer` failure
- Final line of stdout is not whitespace-only

**Interactive** means the scenario passed AND finished inside its interactive budget (default 30 s, overridable per-scenario in the matrix).

## Metrics

- **pass rate** — % of scenarios that satisfy the pass criteria.
- **interactive pct** — % of scenarios that passed inside the interactive budget. This is the metric closest to OpenJarvis's "interactive latency" claim.
- **median / p95 latency (pass)** — wall-clock duration, restricted to passing scenarios so a failure doesn't skew the distribution toward the timeout.
- **median tokens/sec (pass)** — throughput during generation.

## Published results

> Fill this table after running `scripts/chump-bench.sh` locally. Each row should link to the full report JSON committed under `logs/chump-bench/`.

| date | model | backend | host | pass rate | interactive pct | median latency | median tok/s | report |
|---|---|---|---|---|---|---|---|---|
| _pending_ | _pending_ | _pending_ | _pending_ | — | — | — | — | — |

## What these numbers mean vs OpenJarvis's 88.7%

Not-apples-to-apples (yet). Their claim is on a broad single-turn chat + reasoning mix at interactive latency; ours includes agent-loop tool use, which is strictly harder (multiple round-trips per scenario) and strictly slower. Expect our interactive-pct to start well below their 88.7% on tool-heavy scenarios and sit near it on chat + reasoning.

The comparison we care about is **trend over time on the same benchmark**: does a model swap or a cascade tweak move the needle? That's what `report.json` + version control give us.

## Roadmap for this benchmark

- [x] Scenario runner, JSON report, summary doc (2026-04-17)
- [ ] LLM-as-judge accuracy score per scenario (reuses `src/eval_harness.rs::LlmJudge`)
- [ ] Energy per query via `src/telemetry_energy.rs` on Apple Silicon
- [ ] Leaderboard mode — run against multiple `OPENAI_MODEL` in one session and produce a ranking table
- [ ] Continuous tracking — one `report.json` per `main` commit, plotted on the project site
