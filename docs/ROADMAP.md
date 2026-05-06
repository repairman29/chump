# Chump Roadmap — 30 days (2026-05-06 → 2026-06-06)

> **What this is.** The explicit plan that gaps implement, not the other way
> around. Read this before filing new work; if your gap doesn't serve a stated
> outcome, it probably belongs in the backlog (P2/P3) not the active queue.
>
> **Cadence.** Reviewed by the operator weekly (Sundays). Updated by the
> Mission Driver session (see [`CLAUDE.md` → Mission Driver](../CLAUDE.md#mission-driver--every-session-not-just-when-asked))
> when an outcome lands or a week ends.

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

## Week 1 — User-facing front door (May 6 → 13)

**Outcome.** A solo dev with Ollama can run `chump gen "<task>"` and get
a working PR.

**Implementing gaps:**
- **INFRA-593** — `chump gen <task>` single-shot user-facing coding command (P0 m, **in flight #1204**)
- **INFRA-591** — offline-LLM quickstart doc (P1 s, pickable)
- **INFRA-XXX** — `chump fleet` subcommand (start/stop/status) — **to be filed**
- **INFRA-594** — chump-gen fixture suite (10 tasks, asserts working code) (P1 s, pickable)
- **INFRA-592** — chump gap reserve progress output (P1 xs, **in flight #1201**)

**Out of scope this week.** Orchestrator conversation, PWA dashboard,
cognition A/B (those are weeks 2-4).

---

## Week 2 — Credible evidence (May 14 → 21)

**Outcome.** Published numbers showing whether the cognition stack helps and
by how much. We've shipped COG-041 / COG-046 / COG-042 / COG-043 on faith;
this week we measure.

**Implementing gaps:**
- **EVAL-101** — cognition A/B with fleet evidence (P1, **needs scope-up to P0 + concrete fixture**)
- **COG-053** — subagent self-ship rate measurement (P0 m, currently auto-skipped by fleet — needs operator dispatch or domain promotion)
- **INFRA-595** — per-PR coupling-tax measurement (P1 s, pickable)
- **EVAL-NEW** — bandit Thompson vs UCB1 replay study (1000 cascade decisions, regret comparison) — **to be filed**

**Out of scope this week.** Anything that doesn't produce a measurable
number. No new infra, no new features unless they unblock a measurement.

---

## Week 3 — Orchestrator MVP (May 22 → 28)

**Outcome.** Operator types `chump orchestrate`, has a natural-language
session with Opus, and Opus drives the fleet (files gaps, spawns workers,
reports back) without human-typing each chump CLI command.

**Implementing gaps (to be filed as a coherent set):**
- **INFRA-NEW** — `chump init` first-run wizard (m, dependency check + `~/.chump/config.toml` + brew tap verification)
- **INFRA-NEW** — `chump orchestrate` conversational loop (m, Opus-driven, reads CLAUDE.md doctrine + dispatches to chump CLI)
- **INFRA-NEW** — intent parser: natural language → structured chump ops (s, prompt template + tool-router)
- **INFRA-NEW** — mission auto-grader emits 4-pillar scorecard to ambient every 30min unprompted (s)

**Acceptance criteria.** Operator can:
- Type "spawn the fleet on infra p0/p1, size 4" → fleet starts.
- Type "what's our mission grade?" → orchestrator reads ambient + emits grade.
- Type "ship the offline quickstart by EOD" → orchestrator promotes INFRA-591 to P0 and confirms.
- Type "stop the fleet" → INFRA-581 cascade-kill teardown.

---

## Week 4 — Polish + demo (May 29 → June 6)

**Outcome.** Pitch-ready 5-min demo on a clean Mac.

**Implementing gaps:**
- **PRODUCT-025** — PWA dashboard MVP (currently L; split into shippable slices: registry view, fleet pane, ambient stream pane)
- **INFRA-NEW** — clean-Mac FTUE integration test (replays `brew install … chump init … chump gen` on a fresh runner)
- **DOC-NEW** — README rewrite anchored on the demo flow
- **INFRA-NEW** — performance tuning at FLEET_SIZE=10 with cascade hot (Cerebras/Groq slots loaded, measure cost savings vs Anthropic baseline)

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

- **Updated.** 2026-05-06 (initial)
- **Ships toward outcomes:** Week 1 (user-facing) — 0 of 5 outcomes shipped (INFRA-593 in flight)
- **Blocked.** None currently.
- **Next action.** File the 4 INFRA-NEW gaps for Week 3 orchestrator MVP + the PRODUCT-025 split for Week 4. Run EVAL-101 in Week 2.
