# Chump Roadmap — 30 days (2026-05-06 → 2026-06-06)

> **What this is.** The explicit plan that gaps implement, not the other way
> around. Read this before filing new work; if your gap doesn't serve a stated
> outcome, it probably belongs in the backlog (P2/P3) not the active queue.
>
> **Cadence.** Reviewed by the operator weekly (Sundays). Updated by the
> Mission Driver session (see [`CLAUDE.md` → Mission Driver](../CLAUDE.md#mission-driver--every-session-not-just-when-asked))
> when an outcome lands or a week ends.

## 4-pillar mission & current cycle thrusts

Build agents that are **Credible**, **Effective**, **Resilient**, and **Zero-Waste**.

| Pillar | Focus (this cycle) | Sample thrusts |
|---|---|---|
| **Effective** | User-facing velocity | App integration (PRODUCT-036/037), agent decision quality (FLEET-052), end-to-end flows |
| **Credible** | Measurable progress | Effort sizing (INFRA-708), operator feedback loops (FLEET-048), pillar metrics (FLEET-053/054) |
| **Resilient** | Failure tolerance | SWARM-domain exclusion (INFRA-710), stall detection (INFRA-705), worker health (FLEET-042) |
| **Zero-Waste** | Cycle efficiency | Effort-scaled timeout (INFRA-707), wedge diagnosis (INFRA-706), pre-ship quality (INFRA-666) |

**This week's bets** (Week 2 — Credible evidence, May 14→21):
- **EVAL-101** P0 — cognition A/B sweep (prereg filed, runner ready, start sweep)
- **INFRA-595** P1 ✅ — per-PR coupling-tax measurement (`chump pr-coupling-cost`)
- **INFRA-601** P1 ✅ — bandit Thompson vs UCB1 replay study (done in #1225)
- **COG-053** P1 ✅ — subagent self-ship rate measurement (done in #1310)

**Sunset** (last 5 PRs shipped, 2026-05-10):
- #1389 — session gaps from CREDIBLE-017: commit.sh mutex fix, worktree config diag, bot-merge scope, handoff format, CONTINUAL_LEARNING.md
- #1388 — CREDIBLE-017: standardize CLI exit codes (exit(3)→exit(1))
- #1386 — INFRA-736: correct claude-opus-4.7 and deepseek-v3 model rates
- #1385 — INFRA-610: `chump fleet restart` subcommand
- #1383 — INFRA-738: auto-default to chump-local when ANTHROPIC_API_KEY unset

---

## Vision (June 6 2026)

An operator runs **`chump start --orchestrator opus`** on a clean Mac and gets
a self-driving multi-agent fleet that:

- Translates plain-English operator intent ("ship the offline quickstart by
  EOD") into concrete gap filings + fleet operations.
- Spawns + tears down the fleet without remembering env vars.
- Emits an honest 4-pillar mission grade every iter, unprompted.
- Ships real user-facing features (not only fleet plumbing).

This is the front door for the **offline-LLM mission** (per
`memory/project_offline_local_llm_mission.md`): a solo dev with a 24GB Mac,
Ollama, and one binary should be able to drive a coding-agent fleet without
paying Anthropic/OpenAI.

## Success criteria (June 6 demo)

A 5-minute video that shows, on a clean macOS install:

1. `brew tap repairman29/chump && brew install chump` — installs cleanly.
2. `chump init` — wizard, pinned deps, ~/.chump/config.toml.
3. `chump gen "add a /health endpoint to my axum server"` — single-shot
   coding task, produces a working PR.
4. `chump orchestrate` — conversational loop, operator types
   "spawn the fleet on infra p0/p1", fleet starts, ships ≥1 gap, reports back.
5. `chump fleet-status` (real-time and JSON) — visible activity.

If the video records cleanly without operator hand-holding, the roadmap
shipped.

---

## Week 1 — User-facing front door (May 6 → 13) ✅ SHIPPED

**Outcome.** A solo dev with Ollama can run `chump gen "<task>"` and get
a working PR. **Achieved.**

**Implementing gaps:**
- **INFRA-593** — `chump gen <task>` single-shot coding command ✅ (#1204)
- **INFRA-591** — offline-LLM quickstart doc ✅ (#1216)
- **INFRA-610** — `chump fleet` subcommand (start/stop/status/restart) ✅ (#1385)
- **INFRA-743** — `chump init` lists available Ollama models ✅ (#1384)
- **INFRA-733** — free-tier dispatch harness (non-Claude LLMs) ✅ (#1355 + #1373)
- **INFRA-594** — chump-gen smoke suite ✅ (#1276)

**Remaining.** FTUE clean-machine CI test (pre-existing Ollama-unreachable failure on main; not a Week 1 regression — defer to Week 4 polish).

---

## Week 2 — Credible evidence (May 14 → 21)

**Outcome.** Published numbers showing whether the cognition stack helps and
by how much. We've shipped COG-041 / COG-046 / COG-042 / COG-043 on faith;
this week we measure.

**Implementing gaps:**
- **EVAL-101** (P0 m) — cognition A/B with fleet evidence ✅ **preregistration filed, fixture ready.** Run `scripts/eval/run-cognition-ab.sh` to execute the 60-trial sweep. Preregistered at `docs/eval/preregistered/EVAL-101.md`.
- **INFRA-595** (P1 s) ✅ — per-PR coupling-tax measurement. `chump pr-coupling-cost` shipped in #1224.
- **INFRA-601** (P1 s) ✅ — bandit Thompson vs UCB1 replay study. `src/bin/bandit-replay.rs` + report shipped in #1225.
- **COG-053** (P1 m) ✅ — subagent self-ship rate measurement. Prompt epilogue shipped in #1310.

**Remaining.** Run `scripts/eval/run-cognition-ab.sh` (needs Claude Sonnet API access + ~$4). When results land at `docs/eval/EVAL-101-cognition-ab-<date>.md`, close EVAL-101 as supported/rejected/ambiguous per the decision rule in the preregistration.

**Out of scope this week.** Anything that doesn't produce a measurable
number. No new infra, no new features unless they unblock a measurement.

---

## Week 3 — Orchestrator MVP (May 22 → 28)

**Outcome.** Operator types `chump orchestrate`, has a natural-language
session with Opus, and Opus drives the fleet (files gaps, spawns workers,
reports back) without human-typing each chump CLI command.

**Implementing gaps:**
- **INFRA-796** — `chump orchestrate` conversational Opus loop (m, Opus-driven, dispatches to chump CLI) — filed 2026-05-10
- **INFRA-797** — mission auto-grader: emit 4-pillar scorecard to ambient every 30min unprompted (s) — filed 2026-05-10
- **INFRA-798** — intent parser: natural language → structured chump ops (s, prompt template + tool-router) — filed 2026-05-10
- **INFRA-NEW** — `chump init` first-run wizard (m, dependency check + `~/.chump/config.toml` + brew tap) — file when INFRA-743 scope is confirmed done

**Acceptance criteria.** Operator can:
- Type "spawn the fleet on infra p0/p1, size 4" → fleet starts.
- Type "what's our mission grade?" → orchestrator reads ambient + emits grade.
- Type "ship the offline quickstart by EOD" → orchestrator promotes INFRA-591 to P0 and confirms.
- Type "stop the fleet" → INFRA-581 cascade-kill teardown.

---

## Week 4 — Polish + demo (May 29 → June 6)

**Outcome.** Pitch-ready 5-min demo on a clean Mac.

**Implementing gaps:**
- **PRODUCT-025** — PWA dashboard MVP (L; split into shippable slices: registry view, fleet pane, ambient stream pane)
- **INFRA-799** — FTUE clean-machine CI test (brew install + chump init + chump gen on fresh runner) — filed 2026-05-10
- **DOC-NEW** — README rewrite anchored on the demo flow — file Week 4
- **INFRA-NEW** — performance tuning at FLEET_SIZE=10 with cascade hot — file Week 4

**Out of scope.** Anything that doesn't appear in the 5-minute demo.

---

## Explicitly out of scope (entire 30 days)

- **SWARM-* proprietary work.** Lives in `~/Projects/chump-proprietary/`. Not in this repo's queue except as opaque placeholders.
- **Hardware (RTX 6000 Blackwell) decisions.** That's exec-summary work, not engineering work. See `memory/exec_summary_hardware_economics.md`.
- **Cross-machine fleet (NATS).** FLEET-006 already shipped. The Pi mesh / dual-Mac vision is post-June-6.
- **Fine-tuning a 405B on Chump data.** Per `memory/project_model_strategy.md`, that's a 4-8 week effort owned outside the agent fleet.
- **Adding more pillars or rewriting the mission.** The 4 pillars are stable.

## Hygiene rules (active for all 30 days)

1. **P0 budget = 5 max** at any moment (per CLAUDE.md Mission Driver).
2. **Pillar pickable balance** — none < 2, none > 50% of pool.
3. **Gap retention** — any gap idle >90 days either gets done or demoted to P3 with justification (TBD: needs scripts/ops/gap-retention-sweep.sh — file as part of week 4 polish).
4. **Roadmap-before-gaps.** Gaps must reference a stated outcome here, or be filed as P2/P3 backlog.

## Status (live; updated by Mission Driver)

- **Updated.** 2026-05-10
- **Week 1 (May 6–13) — OUTCOME SHIPPED.** User-facing front door complete:
  - `chump gen <task>` shipped (INFRA-593, #1204). ✅
  - Offline-LLM quickstart doc shipped (INFRA-591, #1216). ✅
  - `chump fleet start/stop/status/restart` shipped (INFRA-610, #1385). ✅
  - `chump init` lists live Ollama models (INFRA-743, #1384). ✅
  - Free-tier dispatch wired (INFRA-733 + #1373). ✅
  - Remaining: FTUE clean-machine CI test (ftue job failing pre-existing on main — Ollama unreachable in CI runner; not a regression).
  - **INFRA-791 P0 blocker open**: dispatched agents receive no tools (tools_ms=0). Carried into Week 2.
- **Week 2 (May 14–21) — not yet set up.** File EVAL-101 scope-up + COG-053 + bandit replay study before May 14.
- **Week 3 (May 22–28) — zero gaps filed.** All 4 orchestrator gaps still "INFRA-NEW" placeholders. File before May 21.
- **Pillar balance (2026-05-10):** EFFECTIVE 43% (dominant), CREDIBLE 20%, RESILIENT 13%, ZERO-WASTE 6%, MISSION 3%. 86 pickable, 107 vague (no ACs — unpickable).
- **Next actions:**
  1. Fix INFRA-791 (P0 blocker — tools not reaching agents).
  2. Verify INFRA-593 (`chump gen`) status; promote to Week 1 close if shipped.
  3. File Week 2 gaps (EVAL-101 scope-up, COG-053, bandit replay) before May 14.
  4. File 4 Week 3 orchestrator gaps before May 21.
  5. File Week 4 FTUE integration test + README rewrite gaps.
