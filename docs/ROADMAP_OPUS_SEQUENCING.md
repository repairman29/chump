# Opus Curator Roadmap — Wave Sequencing (META-054)

> **Purpose.** Explicit 4-wave plan that tells the Opus curator which gaps to
> prioritize, in what order, and why. Gaps implement the roadmap — not the
> other way around. Cross-reference: [ROADMAP.md](../docs/ROADMAP.md).
>
> **Authored.** 2026-05-12 from a full audit of open P0/P1 gaps and the
> 30-day ROADMAP.md vision (June 6 demo target).
>
> **Owner.** Opus curator (`scripts/coord/opus-curator.sh`) re-reads this
> each audit pass and emits `kind=opus_roadmap_published` once per publish.

---

## 4-Wave Overview

| Wave | Name | Focus | Duration | Ship criteria |
|------|------|--------|----------|---------------|
| **Wave 1** | Foundation | Fix P0s, core coordination invariants, fleet stability | Weeks 3–4 (now) | P0 count = 0; zero wedge 24h; fleet at ≥70% ship rate |
| **Wave 2** | Resilience | Failure tolerance, observability pipeline, Review-as-Handoff | Weeks 4–5 | Waste rate < 15%; silent_agent = 0 per 4h window |
| **Wave 3** | Fleet Health | Curator quality loop, pillar metrics, hygiene automation | Weeks 5–6 | Pillar balance maintained; curator acts on data not instinct |
| **Wave 4** | Product Value | User-facing features, demo-readiness, offline-LLM path | Week 6+ | June 6 demo passes on clean Mac; COG-054 user feature shipped |

---

## Wave 1: Foundation

**Goal.** Drive P0 count to zero, repair fleet-coordination invariants, and
ensure the orchestrator (INFRA-796) has stable telemetry to reason from.

**Go/No-Go criteria** (all must hold before moving to Wave 2):
1. Open P0 count = 0 (INFRA-844, INFRA-860 closed).
2. Zero `fleet_wedge` events in `ambient.jsonl` for 24 consecutive hours.
3. `chump gap audit-priorities` exits 0 (≤5 P0s, zero vague Wave 1 pickable).
4. Fleet ship rate ≥ 70% on last 10 PRs.
5. No conflicting `.chump-locks/*.json` leases (zero `lease_overlap` events).

**Critical-path gaps** (ordered; later gaps may depend on earlier ones):

| Gap ID | Title | Effort | Pillar | Estimated hours | Status |
|--------|-------|--------|--------|-----------------|--------|
| INFRA-844 | Fleet worker process management | m | RESILIENT | 4h | open |
| INFRA-860 | Diagnose + fix PR merge contention | m | ZERO-WASTE | 4h | open |
| INFRA-630 | UUID gap-id compat audit + fixture | m | CREDIBLE | 3h | open |
| META-033 | System invariants cron (7 checks) | m | RESILIENT | 5h | open |
| INFRA-686 | Graceful SIGTERM handler + WIP squash | s | ZERO-WASTE | 2h | **shipped** |
| INFRA-685 | Cascade bandit: p95 + accuracy reward | m | CREDIBLE | 3h | **shipped** |
| INFRA-877 | Cost quota enforcement (80%/100%) | s | ZERO-WASTE | 2h | **shipped** |
| INFRA-896 | Incident classifier (P0–P3 severity) | xs | RESILIENT | 1h | **shipped** |
| INFRA-881 | Gap deduplication + overlap detection | s | CREDIBLE | 2h | **shipped** |
| INFRA-679 | Observability → alerting pipeline | m | CREDIBLE | 3h | **shipped** |

**Wave 1 estimated total:** ~16h open work (shipped ~13h already this cycle).

**Hidden dependencies** (state.db `depends_on` entries):
- META-033 → none (self-contained; installs via launchd; reads ambient.jsonl)
- INFRA-630 → none (audit + test; no Rust changes)
- INFRA-844 → INFRA-686 (worker must handle SIGTERM before process management changes)
- INFRA-860 → none (investigation + fix for bot-merge contention)

---

## Wave 2: Resilience

**Goal.** Make the fleet tolerant of individual-component failures. Wire
observability into automated recovery. Ship the Review-as-Handoff daemon so
CI failures auto-repair without operator intervention.

**Entry criteria:** Wave 1 go/no-go all green.

**Gaps** (ordered):

| Gap ID | Title | Effort | Pillar | Est. hours |
|--------|-------|--------|--------|------------|
| INFRA-857 | Real-time fleet alerting + monitoring | m | RESILIENT | 4h |
| INFRA-772 | Review-as-Handoff daemon (`chump review --serve`) | m | EFFECTIVE | 5h |
| INFRA-774 | Review-as-Handoff smoke test (end-to-end) | s | EFFECTIVE | 2h |
| INFRA-680 | Modularize pre-commit hook (monolith → guards/*.sh) | s | ZERO-WASTE | 2h |
| COG-055 | Wire surprisal EMA into precision controller | m | EFFECTIVE | 4h |
| INFRA-879 | API credential lifecycle + rotation alerts | s | RESILIENT | 2h | **shipped** |

**Wave 2 estimated total:** ~17h open work.

**Hidden dependencies:**
- INFRA-774 depends on INFRA-772 (daemon must exist before smoke test)
- INFRA-857 depends on INFRA-679 ✅ (alerting pipeline already wired)
- COG-055 → COG-041 ✅ (surprisal EMA shipped)

---

## Wave 3: Fleet Health

**Goal.** Close the curator quality loop: pillar grades become measurable,
A/B data drives decisions, gap hygiene is automated. The Opus curator acts on
data instead of instinct.

**Entry criteria:**
- Wave 2 ship rate ≥ 75%.
- `chump review --serve` processing at least one real CI failure per day.
- Waste rate < 15% sustained over 48h.

**Gaps** (ordered):

| Gap ID | Title | Effort | Pillar | Est. hours |
|--------|-------|--------|--------|------------|
| FLEET-048 | Operator impact rating after PR ships | m | CREDIBLE | 3h |
| FLEET-053 | Persistent pillar grades (store + trend) | s | CREDIBLE | 2h |
| META-045 | Cognition-stack ship-rate impact A/B | s | CREDIBLE | 2h |
| FLEET-054 | Retrospective trigger (auto-pause on waste spike) | s | CREDIBLE | 2h |
| INFRA-637 | Nightly gap-store self-curate cron | s | ZERO-WASTE | 2h |
| META-036 | Open-gap quality sweep (add ACs to vague gaps) | m | CREDIBLE | 4h |
| INFRA-688 | Modularize src/ into subdirectories | l | ZERO-WASTE | 8h |

**Wave 3 estimated total:** ~23h.

**Hidden dependencies:**
- META-045 → COG-041 ✅, COG-046 ✅ (semantic ranking + embeddings shipped)
- FLEET-054 → FLEET-048 (need impact rating before auto-pausing on waste)
- INFRA-637 → INFRA-619 (gap consolidation subcommand must exist)
- META-036 → can run in parallel with all above (doc-only)

---

## Wave 4: Product Value

**Goal.** Ship something a user outside the fleet would notice. Close the
June 6 demo criteria. Enable offline-LLM path for solo devs with Ollama.

**Entry criteria:**
- Wave 3 curator is acting on real data.
- Pillar balance maintained (no pillar < 2 pickable).
- P0 count = 0.

**Gaps** (ordered):

| Gap ID | Title | Effort | Pillar | Est. hours |
|--------|-------|--------|--------|------------|
| COG-054 | Ship a real user-facing feature (operator picks) | m | EFFECTIVE | 4h |
| PRODUCT-057 | VS Code ext: chat sidebar + SSE agent responses | s | EFFECTIVE | 3h |
| PRODUCT-058 | VS Code ext: tool approval prompts + file edits | s | EFFECTIVE | 3h |
| EFFECTIVE-012 | PWA API documentation (OpenAPI spec) | m | CREDIBLE | 3h |
| EFFECTIVE-015 | PWA ambient stream WebSocket integration | m | EFFECTIVE | 4h |
| INFRA-634 | run-fleet.sh --repo flag for non-Chump fleets | s | EFFECTIVE | 2h |
| INFRA-799 | FTUE clean-machine CI test (brew + init + gen) | m | CREDIBLE | 4h |

**Wave 4 estimated total:** ~23h.

**Hidden dependencies:**
- PRODUCT-058 depends on PRODUCT-057 (chat sidebar before tool approval)
- EFFECTIVE-015 → EFFECTIVE-012 (OpenAPI spec before WebSocket stream)
- INFRA-799 → INFRA-743 ✅ (`chump init` Ollama model listing shipped)
- COG-054 → operator decision (pick option a/b/c from gap description)

---

## Full critical-path list (Wave 1 → 4, ~30 gaps)

Ordered as the Opus curator should pick them:

1. INFRA-844 (P0) — Fleet worker process management
2. INFRA-860 (P0) — PR merge contention fix
3. META-033 (P1) — System invariants cron
4. INFRA-630 (P1) — UUID gap-id compat
5. INFRA-857 (P1) — Real-time fleet alerting
6. INFRA-772 (P1) — Review-as-Handoff daemon
7. INFRA-774 (P1) — Review-as-Handoff smoke test
8. INFRA-680 (P2) — Modularize pre-commit hook
9. COG-055 (P2) — Surprisal EMA wiring
10. FLEET-048 (P1) — Operator impact rating
11. FLEET-053 (P2) — Persistent pillar grades
12. META-045 (P1) — Cognition-stack A/B
13. FLEET-054 (P2) — Retrospective trigger
14. INFRA-637 (P2) — Nightly gap-store curate cron
15. META-036 (P2) — Open-gap quality sweep
16. INFRA-688 (P1) — Modularize src/
17. COG-054 (P1) — User-facing feature
18. PRODUCT-057 (P1) — VS Code chat sidebar
19. PRODUCT-058 (P1) — VS Code tool approval
20. EFFECTIVE-012 (P2) — PWA API docs
21. EFFECTIVE-015 (P2) — PWA WebSocket stream
22. INFRA-634 (P2) — run-fleet.sh --repo flag
23. INFRA-799 (P1) — FTUE clean-machine CI test
24. DOC-031 (P2) — Reconcile CLAUDE.md/AGENTS.md doctrine
25. INFRA-619 (P2) — `chump gap consolidate` command
26. EFFECTIVE-003 (P2) — XML tool-call adapter
27. EFFECTIVE-007 (P2) — Gemini tool-call quality validation
28. EFFECTIVE-015 (P2) — PWA ambient WebSocket
29. COG-055 (P2) — Surprisal EMA precision controller
30. INFRA-780 (P2) — Binary staleness auto-nudge

**Estimated total:** ~80h across all waves.

---

## Pillar balance target (maintained throughout)

Each pillar must have ≥ 2 pickable xs|s|m gaps (no `depends_on` blockers)
at all times. The curator auto-files if a pillar drops below 2.

| Pillar | Wave 1 coverage | Wave 2 coverage | Wave 3 coverage | Wave 4 coverage |
|--------|----------------|-----------------|-----------------|-----------------|
| EFFECTIVE | — | INFRA-772, 774 | — | COG-054, PRODUCT-057/058 |
| CREDIBLE | INFRA-630, 685, 881 | — | FLEET-048, 053, META-045 | EFFECTIVE-012, INFRA-799 |
| RESILIENT | INFRA-844, META-033, 896 | INFRA-857, 879 | — | — |
| ZERO-WASTE | INFRA-686, 877, 860 | INFRA-680 | INFRA-637, 688 | — |

---

## Curator operating rules (binding)

1. **Pick from Wave 1 first** until all Wave 1 gaps are done or blocked.
2. **Never pick Wave 3/4 while Wave 1 P0s are open.**
3. **Demote** any Wave 1 gap that sits >7 days without progress to P2 with a
   `blocker:` note explaining why it's stuck.
4. **Escalate** if `fleet_wedge` events appear → drop to 2 workers immediately.
5. **Re-read this doc** at the start of each curator audit pass.

---

## Publication record

Emit this event when publishing updates:

```bash
printf '{"ts":"%s","kind":"opus_roadmap_published","doc":"docs/ROADMAP_OPUS_SEQUENCING.md","waves":4,"critical_path_gaps":30}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> .chump-locks/ambient.jsonl
```
