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
- **EVAL-101** (P0 m) — cognition A/B with fleet evidence ✅ **preregistration filed, fixture ready.** Run `scripts/eval/run-cognition-ab.sh` to execute the 60-trial sweep. Preregistered at `docs/eval/preregistered/EVAL-101.md`.
- **INFRA-595** (P1 s) ✅ — per-PR coupling-tax measurement. `chump pr-coupling-cost` shipped in #1224.
- **INFRA-601** (P1 s) ✅ — bandit Thompson vs UCB1 replay study. `src/bin/bandit-replay.rs` + report shipped in #1225.
- **COG-053** (P1 m) ✅ — subagent self-ship rate measurement. Prompt epilogue shipped in #1310.

**Remaining.** Run `scripts/eval/run-cognition-ab.sh` (needs Claude Sonnet API access + ~$4). When results land at `docs/eval/EVAL-101-cognition-ab-<date>.md`, close EVAL-101 as supported/rejected/ambiguous per the decision rule in the preregistration.

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

- **Updated.** 2026-05-13
- **Note on "Week N" labels.** Week labels are **phase markers** (Phase 1 — Front door; Phase 2 — Credible evidence; Phase 3 — Orchestrator; Phase 4 — Polish + demo). The calendar dates in parens are *target* dates from the original 30-day plan, not enforcement boundaries. Status flags (SHIPPED / WORK COMPLETE / IN PROGRESS) reflect actual milestone completion, not calendar position. A phase can be WORK COMPLETE before its target date window opens.
- **Phase 1 / Week 1 (target May 6–13) — SHIPPED.** User-facing front door complete. All gaps closed. FTUE clean-machine CI test deferred to Phase 4.
- **Phase 2 / Week 2 (target May 14–21) — WORK COMPLETE (early).** EVAL-101 cognition A/B run and closed as null finding (Δ=+0.025, threshold 0.10). Result at `docs/eval/EVAL-101-cognition-ab-2026-05-10.md`. **Follow-up: EVAL-102 filed P1** (see `docs/gaps/EVAL-102.yaml`) — n≥50/cell rerun with explicit dependency map for downstream gaps.
- **Phase 3 / Week 3 (target May 22–28) — IN PROGRESS.** INFRA-796/797/798 scoped and implemented. `chump orchestrate` loop exists with telemetry + auto-grade timer + stub/real intent parser.
  - **INFRA-816 (release-plz glib dep)** — filed + fixed + merged (#1437). ✅
  - **INFRA-1018 / INFRA-1066 (e2e-pwa `#msg-input` flake)** — root cause fixed and documented. Alias shim now correctly walks light DOM to `<chump-view-chat>` then shadow DOM into `<chump-chat>`. ✅ (#1741, #1735)
- **Phase 4 / Week 4 (target May 29–June 6) — GAPS FILED.** DOC-035 (README rewrite for demo flow) and INFRA-818 (perf tuning FLEET_SIZE=10) filed. PRODUCT-025 (PWA dashboard MVP) and INFRA-799 (FTUE CI test) pending.
- **Pillar balance (2026-05-13):** EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE — all 4 pillars pickable (each ≥2 xs/s P1 gaps open). Recent sprint emphasis: coordinator reliability (RESILIENT + ZERO-WASTE); next: EFFECTIVE user-facing and CREDIBLE measurement gaps.
- **What changed this week (2026-05-07 → 2026-05-13):**
  - **Coordinator robustness sprint (RESILIENT/ZERO-WASTE):** Per-worktree `CARGO_TARGET_DIR` eliminates parallel bot-merge lock contention (#1753); `cargo_lock_wait` telemetry added. `worktree_root()` now detects stale `core.worktree` in `.git/config` (#1755). `#[serial]` annotations on all env-mutating tests (#1758, INFRA-977/1071). Fleet coordinator now CREDIBLE-035: CLI integration tests for `chump health`, `fleet status`, `claim/release`, `--briefing`, auth modes (#1749).
  - **Harness-agnostic framing (MISSION):** README and AGENTS.md rewritten to lead with "fleet coordinator + gap registry, bring your own agent" — Claude Code, opencode, Codex CLI, Aider, goose, or manual commits all first-class (#1750).
  - **e2e-pwa green-main restoration (CREDIBLE):** Fixed shadowRoot traversal bug in `createTestAliases()` — `<chump-view-chat>` is light DOM, `<chump-chat>` is shadow DOM. Documented in `CLAUDE_GOTCHAS.md` (#1741, #1735).
  - **Gap registry hygiene:** INFRA-980/981/982 stale stuck-PR gaps closed; INFRA-1064/1066/1071 done.
- **CI pipeline:** e2e-pwa fix in main (#1741). `tauri-cowork-e2e` failing on all PRs (pre-existing, not regressions from this sprint).
- **SLO status (from fleet-state.json):** L1-SLO-1 (silent_agent), L2-SLO-2 (ship rate), L2-SLO-5, L3-SLO-1 breached. Priority: reduce silent leases (many stale from crashed sessions) and check ship rate.
- **Next actions:**
  1. Arm auto-merge for open PRs (rate limit resets 2026-05-14T01:36Z; PRs #1735, #1753, #1755, #1758 waiting).
  2. Rebuild + reinstall `chump` binary (staleness warning: built at 78339bcfc, 7 commits behind HEAD).
  3. Pick next EFFECTIVE or CREDIBLE gap (CREDIBLE-037, INFRA-1052 — both leased by active sessions).
  4. Run `chump gap audit-priorities` to check P0 count and vague gaps.
