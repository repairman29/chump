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

**Sunset** (last 5 meaningful PRs shipped, 2026-05-13):
- #1758 — fix(INFRA-1071): RESILIENT — `#[serial]` on ambient_rotate env-mutating tests (cargo test race)
- #1755 — fix(INFRA-1064): RESILIENT — `worktree_root()` returns CWD when CHUMP_REPO points at sibling
- #1753 — feat(INFRA-1063): ZERO-WASTE — per-worktree CARGO_TARGET_DIR + `cargo_lock_wait` telemetry
- #1750 — docs(DOC-047): MISSION — harness-agnostic framing in README + AGENTS.md
- #1741 — fix(INFRA-1018): CREDIBLE — repair `#msg-input` alias (shadowRoot bug) blocking e2e-pwa

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
- **EVAL-101** (P0 m) — cognition A/B pilot ✅ **null result (Δ=+0.025, n=20/cell, Qwen local).** Result cannot be cited — protocol violated preregistration (wrong agent, structural-only scoring, no Cell C, no LLM judges). See audit trail in EVAL-102 prereg.
- **EVAL-102** (P1 m) 🏗️ **preregistration locked 2026-05-11, harness run PENDING.** Corrected re-run: Sonnet 4.6, n=50/cell, Cell C padding control, dual judges (haiku + Llama-3.3-70B), deviation-locked runner. Preregistered at `docs/eval/preregistered/EVAL-102.md`. Result doc stub at `docs/eval/EVAL-102-cognition-ab-followup-2026-05-14.md`. Run the sweep to get a citable result.
- **INFRA-595** (P1 s) ✅ — per-PR coupling-tax measurement. `chump pr-coupling-cost` shipped in #1224.
- **INFRA-601** (P1 s) ✅ — bandit Thompson vs UCB1 replay study. `src/bin/bandit-relay.rs` + report shipped in #1225.
- **COG-053** (P1 m) ✅ — subagent self-ship rate measurement. Prompt epilogue shipped in #1310.

**Remaining.** Execute EVAL-102 harness sweep (needs Anthropic API ~$5 + Together AI free tier + ~24h). Smoke-check first: `python3.12 scripts/ab-harness/run-local-v2.py --gap EVAL-102 --n 2 ...`. Full decision rule and downstream consequence map in `docs/eval/EVAL-102-cognition-ab-followup-2026-05-14.md`.

**Out of scope this week.** Anything that doesn't produce a measurable
number. No new infra, no new features unless they unblock a measurement.

---

## Week 3 — Orchestrator MVP (May 22 → 28) 🏗️ IN PROGRESS

**Outcome.** Operator types `chump orchestrate`, has a natural-language
session with Opus, and Opus drives the fleet (files gaps, spawns workers,
reports back) without human-typing each chump CLI command.

**Implementing gaps:**
- **INFRA-796** — Telemetry, cost tracking, failure taxonomy ✅ **scoped + implemented.** `emit_ambient_event`, `estimate_tokens`, `classify_failure` added. Each iteration emits `kind=orchestrate_intent` to ambient.jsonl.
- **INFRA-797** — Mission auto-grader: emit 4-pillar scorecard to ambient every 30min unprompted ✅ **scoped + implemented.** Background `tokio::spawn` task runs a 30-min `interval` calling `emit_grade()`.
- **INFRA-798** — Intent parser: natural language → structured chump ops ✅ **scoped + AC'd.** Stub parser (keyword matching) + real Opus-driven parser both verified. System prompt + tool-router already shipped in INFRA-598 loop.
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

- **Updated.** 2026-05-15
- **Note on "Week N" labels.** Week labels are **phase markers** (Phase 1 — Front door; Phase 2 — Credible evidence; Phase 3 — Orchestrator; Phase 4 — Polish + demo). The calendar dates in parens are *target* dates from the original 30-day plan, not enforcement boundaries. Status flags (SHIPPED / WORK COMPLETE / IN PROGRESS) reflect actual milestone completion, not calendar position. A phase can be WORK COMPLETE before its target date window opens.
- **Phase 1 / Week 1 (target May 6–13) — SHIPPED.** User-facing front door complete. All gaps closed. FTUE clean-machine CI test deferred to Phase 4.
- **Phase 2 / Week 2 (target May 14–21) — WORK COMPLETE (early), citable result PENDING.** EVAL-101 closed null (Δ=+0.025) but cannot be cited (preregistration violated). **EVAL-102 (rerun) still PENDING operator-action**: needs ~$5 API spend + Together AI + ~24h harness time. **Without EVAL-102, Week 2 has no citable credible-evidence number.**
- **Phase 3 / Week 3 (target May 22–28) — IN PROGRESS.** INFRA-796/797/798 scoped and implemented. `chump orchestrate` loop exists with telemetry + auto-grade timer + stub/real intent parser. **Operator end-to-end smoke test still PENDING** — no one has typed the four demo prompts ("spawn the fleet…", "what's our grade?", "ship X by EOD", "stop the fleet") against the real binary and verified the fleet responds.
- **Phase 4 / Week 4 (target May 29–June 6) — STARTED EARLY.** PWA cockpit work was undertaken ahead of schedule (see Cockpit detour below). **INFRA-799 (FTUE clean-machine CI test) SHIPPED** (PR #1468, commit c00102be) — covers brew install → `chump --version` → `chump init` → `chump gen` → `chump mcp list` → `chump fleet start/status/stop`. **Gap discovered 2026-05-15:** the existing FTUE workflow does NOT cover `chump orchestrate` (June 6 demo criterion #4 — "operator types 'spawn the fleet…', fleet starts"). Extending the FTUE workflow tonight to add a 3-intent smoke step. DOC-035 (README rewrite for demo flow) also pending.
- **Cockpit detour (2026-05-15) — major cycle, not on the original 30-day spec.** A "PWA isn't running" session start expanded into a full cockpit reshape:
  - PRODUCT-121 ✅ — PWA cockpit roadmap doc shipped (#2024) with 4 phases + ship-criteria
  - PRODUCT-122 ✅ — Cockpit-MVP landing shell shipped (#2030) composing 22 existing components
  - PRODUCT-120 🟡 — Action-first cockpit (Read/Signal/Noise framework + 5 action wires + 2 new endpoints) in PR #2063 (auto-merge armed, sibling rebasing); doctrine docs merged (#2067, #2094)
  - PRODUCT-132 🟡 — Operator-attention dedup in PR #2066
  - INFRA-1349 🟡 — `target/` artifact reaper in PR #2083 (addresses today's 97%-full disk crisis)
  - **Honest assessment:** the cockpit work is arguably Week 4 polish surfaced as PRODUCT-025 (PWA dashboard MVP). It moves the project forward but **does NOT directly satisfy any of the 5 June-6 demo criteria** (brew install, chump init, chump gen, chump orchestrate, chump fleet-status). The demo is CLI-driven.
- **Pillar balance (2026-05-15):** Fleet brief reported `EFFECTIVE=12 CREDIBLE=3 RESILIENT=4 ZERO-WASTE=6 (of 33 pickable)` — balanced. Ship velocity ~7.3 ships/hr / 176 ships/24h.
- **SLO status:** earlier disk_critical alerts (97% full) recovered to ~90% after sibling-agent worktree reaping; INFRA-1349 launchd install pending for permanent fix. 13 active leases at session-end.
- **Next actions (priority order for June 6):**
  1. **FTUE workflow extended for `chump orchestrate`** (in this same PR). Adds a smoke step that asserts 3 canonical intents route to the right chump commands. Plugs the demo-criterion #4 hole.
  2. **EVAL-102 rerun.** Operator-action required (~$5 API + 24h). Until this lands, Week 2 has no citable number.
  3. **`chump orchestrate` LLM-driven e2e** (not just intent-parser stub). Operator types real prompts; orchestrator drives the fleet via Anthropic. The FTUE smoke covers the routing; this covers the cognition.
  4. **DOC-035 README rewrite** anchored on the 5-step demo flow.
  5. **5-minute screencast on clean Mac.** Final June 6 deliverable; operator-action.
  6. **PWA cockpit PRs** (#2063 + #2066 + #2083) — already auto-merge armed, riding through CI; no further action needed.
  7. **PRODUCT-133 (right-zone treatment)** — gated on #2063 landing first.
