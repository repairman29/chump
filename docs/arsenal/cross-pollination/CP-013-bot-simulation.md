# CP-013: Harvest bot-simulation-service → Chump fleet test harness

**Target:** Chump fleet test harness — INFRA-518 scaling-gate validation needs synthetic load without burning real LLM cost on every test.
**Arsenal match:** `repairman29/bot-simulation-service` — 11.2 MB Node.js synthetic-load generator with 5 user archetypes, fatigue simulation, funnel analytics, drop-off detection, Railway-native deploy. Upstream `main` at `450f9c5c2eed45477c9e3260e11f197ceac59e08` (2026-01-31).
**Recommended route:** **(a) Vendor the archetype scheduler into `scripts/dispatch/synthetic-fleet.sh` + a thin `chump-coord` subcommand. Chump owns the orchestration logic.**
**Status:** proposed (2026-05-23, INFRA-1845)

## The Target

INFRA-518 (Fleet scaling gate) defines six metrics that gate `2 → 3` and `3 → 4` worker scale-ups: waste rate < 20%, ship rate ≥ 70%, zero `fleet_wedge`, ≤1 `silent_agent`, ≤1 `pr_stuck`, zero open INFRA P0/P1 fleet-blockers. Today the only way to exercise that gate is **run a real fleet for 2 hours and read ambient.jsonl** — every dry-run costs real Claude API spend and consumes the operator's wall-clock attention.

The Quality Firewall direction (memory: `project_productization_plan_2026-05-22.md`, Direction 3) demands that *every* shipped behavior be mirrored by a local check that runs in < 60s. INFRA-1841 (CP-009) is putting that substrate in place for LLM-touching tests via offline mock servers. INFRA-1845 is the **load-generation companion** — a way to feed those mocks (and a sandbox `state.db`) with traffic patterns that *look like real fleet behavior* so we can flush bugs without paying real cost.

Pairs with: INFRA-1841 (mock-services), INFRA-721 (fleet-brief), INFRA-518 (scaling gate), META-068 (productization).

## The Arsenal Match — 5 bot archetypes

All five archetypes live in `services/gameplaySimulationService.js:18-86` as a single `botArchetypes` object. Each archetype is a deterministic record of behavior parameters. Fatigue is modeled via `attentionSpan` (hard timeout) and `patienceThreshold` (per-action timeout); a "difficulty" modifier (`easy|normal|hard|expert` at lines 749-753) multiplies the three core parameters.

| Archetype | attentionSpan | patienceThreshold | completionDrive | errorRecovery | Use case |
|---|---|---|---|---|---|
| `casual` | 5 min | 3000 ms | 0.6 | `abandon` | Light explorer, lazy scroll, gives up on errors |
| `focused` | 20 min | 5000 ms | 0.9 | `retry` | Goal-oriented, retries on failure |
| `impatient` | 3 min | 1500 ms | 0.2 | `rage_quit` | Fast/aggressive, low completion, leaves loudly |
| `methodical` | 30 min | 8000 ms | 0.95 | `systematic` | Thorough, exhaustive, very high completion |
| `mobile_user` | 4 min | 2000 ms | 0.7 | `retry_once` | Touch device, viewport 375x667, mobile-specific failure modes |

Additional knobs per archetype: `explorationTendency` (0-1), `riskTolerance` (0-1), `interactionPatterns.clickFrequency` (ms between clicks), `interactionPatterns.scrollBehavior` (`lazy|purposeful|rapid|thorough|touch_scroll`), `interactionPatterns.formFilling` (`minimal|complete|rush|detailed|adaptive`).

### Funnel analytics output (`generateFunnelAnalysis`, lines 1187-1229)

Output is a **single JSON object** keyed by phase name. Default phases are game-domain (`authentication`, `character_creation`, `mission_selection`, `combat`, `rewards`, `economy`) but the structure is generic — only the phase strings need re-targeting for the Chump-fleet domain.

```json
{
  "authentication": {
    "entered": 47,
    "completed": 39,
    "completionRate": 0.829,
    "conversionFromPrevious": 1.0
  },
  "character_creation": {
    "entered": 39,
    "completed": 31,
    "completionRate": 0.795,
    "conversionFromPrevious": 1.0
  }
}
```

The export endpoint (`routes/api.js:84-126`) emits either pretty JSON (full simulation record) or a flat CSV of interactions (`timestamp,phase,action,duration,success,error`). For Chump consumption we prefer **JSONL streamed to `.chump-locks/synthetic.jsonl`** so it composes with the existing ambient stream tooling — see subcommand spec below.

### Bottleneck detection (`analyzePerformanceIssues` + `analyzeUserJourney`, lines 835-1066)

Triggers and output format (per call, all severities surface in one `issues[]` array):

| Trigger condition | Severity | Output shape |
|---|---|---|
| `slow_count > 10% of interactions` (slow = duration > patienceThreshold) | medium |  `{type:'performance', severity, description, affectedPhases, impact, recommendation, codeExamples, estimatedEffort, expectedImpact}` |
| `slow_count > 20%` | high | same |
| `very_slow_count > 0` (duration > 2× patienceThreshold) | critical | adds `affectedElements` |
| `errors > behavior.errorTolerance × interactions` (line 892) | high | `{type:'error_handling', ...}` |
| `completionRate < 0.5` and `phase has >3 interactions` (line 1032) | medium/high | `{type:'usability', phase, completionRate, ...}` |
| `abandonmentRate > dropOffPoints[phase].dropOffRate` (line 1051) | high | `{type:'usability', reason, ...}` |
| `keyboardInteractions < 10% of interactions` (line 1079) | medium | `{type:'accessibility', wcag, ...}` |
| `touchTargetSize < 44px` (mobile only, line 1124) | mobile-specific | `{type:'mobile', ...}` |

Recommendations include React/JS `codeExamples`, `estimatedEffort`, and `expectedImpact` — game-domain noise that we strip during the Chump adaptation; we keep only `{type, severity, description, recommendation, affectedPhases}`.

## Archetype → Chump worker mapping

The archetype semantics translate cleanly onto Chump worker types — the underlying signal (impatience, thoroughness, error tolerance) is domain-agnostic.

| Archetype | Chump worker | Rationale |
|---|---|---|
| `casual` | Haiku sweep worker | Cheap, fast, abandons mid-task on first error — matches Haiku's `--dangerously-skip-permissions` hesitation pattern (INFRA-515) and its use for low-stakes mechanical sweeps. |
| `focused` | Sonnet implementer | Default per-gap worker; 20-min attention span matches Sonnet's median wall-clock per gap (`xs`+`s`); high completion drive (0.9) matches our 80%+ ship rate target. |
| `impatient` | High-throughput sweep workers | Burst patterns; low completion is **the right model** for sweeps that touch many files but ship narrow PRs (e.g. INFRA-755 budget sweeps). Maps to `FLEET_MODEL=haiku` mass runs. |
| `methodical` | Opus PM / critical-path implementer | 30-min attention, 0.95 completion, systematic error recovery — matches Opus's role per `feedback_opus_pm_role.md`: owns P0s, reviews subagents, re-ranks gaps. |
| `mobile_user` | **Constrained-environment worker** (Pi mesh, low-RAM box) | Reframes the "mobile" semantic into Chump-domain: 4-min attention + smaller "viewport" → Pi-node compute budgets, narrower context windows. Maps to the offline / local-LLM strategy (memory: `project_offline_local_llm_mission.md`). |

**Confidence:** mapping 1-4 is high; mapping 5 (`mobile_user` → constrained-env) is the deliberate creative leap. The alternative is to drop `mobile_user` and add a new `low_context` archetype with `attentionSpan: 240000, patienceThreshold: 2000, completionDrive: 0.7` — same numbers, different name. **Recommended:** keep the upstream archetype name and add `low_context` as a synonym to preserve diff-able lineage to the source repo.

## Harvest route

| Route | Pros | Cons |
|---|---|---|
| **(a) Vendor scheduler** | Chump owns orchestration. No Node.js runtime added. Easy to wire into `chump-coord`. Direct access to `state.db`. | Hand-port of ~200 lines of JS → shell/Rust. |
| (b) Rust crate `chump-synthetic-load` | Strong types, reusable. | Premature formalization; the load gen is a CI fixture, not a product. ~2-3 days of Rust work to port faithfully. |
| (c) Microservice mode | Zero code rewrite. Stays close to upstream. | Adds a Node.js runtime to the fleet dependency surface. Harder to debug — load gen lives behind an HTTP boundary. Network coupling violates the offline mission. |

**Decision: (a).** The five archetypes are ~80 lines of constant data; the simulation lifecycle is ~120 lines of glue. Hand-port to a `scripts/dispatch/synthetic-fleet.sh` is < 1 day of work, lives in the same toolbox as the rest of the dispatch layer, and emits directly to the existing ambient/funnel JSONL files. (b) is reserved for a later promotion if the synthetic harness becomes a shipped feature; (c) violates the offline mission.

## `chump fleet simulate` subcommand spec

### Args

```text
chump fleet simulate \
  --archetypes casual:3,methodical:2,impatient:1 \
  --duration 1h \
  --sandbox /tmp/chump-sim-XXXX/state.db \
  --output-format jsonl|json|csv \
  --output-dir .chump-locks/synthetic/ \
  --seed 42
```

### Behavior

1. `mktemp -d` a sandbox, copy current `.chump/state.db` schema (no data) into it via `chump db init --schema-only`.
2. Pre-load N synthetic open gaps (deterministic from `--seed`) — mix of P0/P1/P2, mix of domains, mix of `xs/s/m` sizes.
3. Launch `casual:3 + methodical:2 + impatient:1 = 6` synthetic worker processes against the sandbox. Each worker:
   - Picks `attentionSpan` and `patienceThreshold` from its archetype.
   - Polls the sandbox `state.db` at `clickFrequency` cadence.
   - On lock contention, applies `errorRecovery` (abandon / retry / rage_quit / systematic / retry_once).
   - Emits `kind=synthetic_claim`, `kind=synthetic_ship`, `kind=synthetic_abandon` to the per-run JSONL.
4. After `--duration`, emit a single `summary.json` with the funnel analytics output (per-phase entered/completed/completionRate) and the bottleneck issues array.
5. Run `chump waste-tally --window <duration> --source synthetic.jsonl` and `chump fleet-brief --source synthetic` to compute the INFRA-518 scaling-gate metrics against the synthetic run.

### Output

`.chump-locks/synthetic/<sim_id>/`
- `synthetic.jsonl` — one event per claim/ship/abandon (mirrors `ambient.jsonl` schema, kind-prefixed `synthetic_`).
- `funnel.json` — phase entered/completed/completionRate/conversionFromPrevious. Phases for Chump: `picked`, `claimed`, `committed`, `pushed`, `merged`, `shipped`.
- `bottlenecks.json` — issues array (severity, description, recommendation).
- `summary.json` — INFRA-518 scaling-gate verdict (`pass|fail`) + per-metric breakdown.

## Smoke test spec — `scripts/ci/test-synthetic-fleet.sh`

1. `mktemp -d` → `SANDBOX=$(mktemp -d)`
2. Init sandbox state.db: `chump db init --schema-only --path "$SANDBOX/state.db"`.
3. Seed 20 synthetic gaps (P0:2, P1:8, P2:10) via `chump gap reserve --sandbox "$SANDBOX/state.db"` (loop).
4. Run `chump fleet simulate --archetypes casual:2,methodical:1 --duration 5m --sandbox "$SANDBOX/state.db" --output-dir "$SANDBOX/out" --seed 1`.
5. Assertions:
   - `[ -f "$SANDBOX/out/<sim_id>/synthetic.jsonl" ]`
   - `[ $(wc -l < "$SANDBOX/out/<sim_id>/synthetic.jsonl") -ge 3 ]` (at least 3 synthetic events fired)
   - `jq -e '.funnel.picked.entered > 0' "$SANDBOX/out/<sim_id>/funnel.json"` (picked phase saw traffic)
   - `jq -e '.scaling_gate.verdict == "pass" or .scaling_gate.verdict == "fail"' "$SANDBOX/out/<sim_id>/summary.json"` (verdict emitted, either value OK).
6. Cleanup: `rm -rf "$SANDBOX"`.
7. Wall-clock budget: < 5 min (matches simulate `--duration 5m` + setup overhead).

Tagged `kind=synthetic_fleet` in ambient for CI-side discoverability.

## Convergence with INFRA-518 + INFRA-721

- **INFRA-518 scaling gate** is currently operator-run with prose: "look at ambient for 2h, count wedges." After CP-013 lands, the gate becomes `chump fleet simulate ... && chump fleet-doctor --strict-from synthetic` — fully scripted, < 5 min, no real LLM spend.
- **INFRA-721 fleet-brief** reads from `ambient.jsonl` today. Extend to read from `--source synthetic` when a synthetic run is active, so the same brief format works for real and simulated fleets. One brief generator, two input modes.
- **META-068 productization plan** Direction 3 (Quality Firewall): synthetic-fleet is the load-generation half; mock-services (CP-009 / INFRA-1841) is the target half. Together they give us a complete offline-runnable fleet test.

## Vendoring lineage

```text
upstream: repairman29/bot-simulation-service @ 450f9c5c2eed45477c9e3260e11f197ceac59e08 (2026-01-31)
file:     services/gameplaySimulationService.js, lines 18-86 (botArchetypes)
file:     services/gameplaySimulationService.js, lines 1187-1229 (generateFunnelAnalysis)
file:     services/gameplaySimulationService.js, lines 835-1066 (bottleneck detection)
file:     routes/api.js, lines 84-126 (JSON/CSV export shape)
license:  MIT (see upstream LICENSE)
```

Vendor commit message template:

```text
feat(INFRA-1845): vendor bot-simulation archetypes into scripts/dispatch/synthetic-fleet.sh

Source: repairman29/bot-simulation-service @ 450f9c5c
- 5 archetypes (casual/focused/impatient/methodical/mobile_user) hand-ported
- funnel-analysis shape preserved (entered/completed/completionRate)
- bottleneck-detection triggers preserved (slow %, abandonment rate)
- game-domain phases re-targeted to Chump fleet phases (picked/claimed/.../shipped)
License: MIT (upstream LICENSE preserved at scripts/dispatch/SYNTHETIC_FLEET_LICENSE)
```

## Lineage / Risk

- **Domain mismatch surface:** archetypes are named for game UX users; the parameters are domain-agnostic but the **names carry semantic baggage** (`mobile_user` doesn't mean "phone" in Chump). Mitigation: add Chump-domain synonyms (`low_context` for `mobile_user`) and document the mapping in the script header.
- **Re-tuning risk:** the absolute timeout values (5min/20min/30min attention span) are calibrated for human web sessions, not for compute-bound worker loops. Expect to scale them by ~0.1x for Chump (workers iterate faster than humans). The **relative ordering** is what matters; absolute values get re-tuned by running against a known-good fleet baseline and matching `synthetic.jsonl` event-rate to `ambient.jsonl` event-rate.
- **Probabilistic re-keying:** Math.random() in upstream is replaced with seeded RNG (`--seed N`) so synthetic runs are deterministic — required for CI reproducibility.
- **Coverage gap:** upstream simulates UI/UX (clicks, scrolls); Chump simulates work claims/ships. The interaction *primitives* differ even though the archetype *parameters* port directly. Expect to write Chump-specific `claim()`, `ship()`, `abandon()` action implementations rather than reusing upstream's click/scroll/form-fill.
