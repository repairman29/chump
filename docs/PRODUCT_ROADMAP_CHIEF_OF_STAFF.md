# Product roadmap: Chump as chief of staff

**Audience:** Jeff (principal), Chump (orchestrator), Cursor (executor). **Engineering backlog** for implementation details remains in [ROADMAP.md](ROADMAP.md), [ROADMAP_FULL.md](ROADMAP_FULL.md), and [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md). **This doc** is the *product* roadmap for **high autonomy**, **rules of engagement**, and **aspirational outcomes**—including Chump **finding problems**, **leveling up**, and **shipping adjacent repos/products**.

**Companion:** Run `./scripts/generate-cos-weekly-snapshot.sh` for a Markdown snapshot of tasks + episodes (`logs/cos-weekly-YYYY-MM-DD.md`).

---

## 1. North star

Chump operates as a **chief of staff** with **wide runway**: he prioritizes, executes, delegates, and reports—while **defaulting to action** when intent is clear, **grounding** claims in repo/docs/memory/metrics, **respecting** tool approval and safety policy, and **aligning** with [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) and [ROADMAP.md](ROADMAP.md). He may **propose and build** new small products/repos when a real-world problem is validated and governance (privacy, trust, archive) is satisfied.

---

## 2. Rules of engagement (non‑negotiables)

| Rule | Source / behavior |
|------|-------------------|
| Prefer action over needless clarification when intent is clear | Soul + [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md) |
| Hand off heavy implementation to Cursor with goal, roadmap cite, paths/logs | [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md), [AGENTS.md](../AGENTS.md) |
| Battle tests / hardening before broad outward research when shipping risk dominates | [AGENTS.md](../AGENTS.md) Learned prefs |
| Archive / retention discipline as the repo grows | [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) |
| Defense/federal positioning and procurement framing when relevant | [AGENTS.md](../AGENTS.md), defense docs index |
| MacBook + native surfaces alongside Discord; Discord not sole interface | [AGENTS.md](../AGENTS.md) |
| No secrets in learned memory; exclude one-off transient junk | Continual-learning guardrails |

---

## 3. Strategic themes → engineering streams

| Theme | What “done” looks like | Primary surfaces |
|-------|------------------------|------------------|
| **T1 — Operating picture** | Weekly priorities, risks, ship status without manual re-brief | Web dashboard, `/api/briefing`, snapshot script, tasks |
| **T2 — Autonomous execution** | Heartbeat + autonomy loops complete scoped work; interruptions only on policy | `autonomy_loop`, task leases, approvals |
| **T3 — Discovery & prevention** | CI/issues/docs drift found and turned into tasks | GitHub tools, scripts, Farmer Brown |
| **T4 — Capability growth** | Tooling gaps become tools or prompts with measured wins | Cursor, `src/*`, battle QA |
| **T5 — Product factory** | Validated problem → thin repo → MVP → metrics → ship or sunset | New repos, pilot metrics docs |
| **T6 — Trust & compliance** | Approvals, audit logs, trust docs for anything user-facing | TOOL_APPROVAL, TRUST docs, PWA |

---

## 4. Delivery waves (build sequence)

### Wave 1 — **Instrument the COS** (now)

| ID | Deliverable | Acceptance |
|----|-------------|------------|
| W1.1 | **`scripts/generate-cos-weekly-snapshot.sh`** | Writes `logs/cos-weekly-*.md` from `chump_tasks` + `chump_episodes`; read-only; documents usage in this file |
| W1.2 | **Schedule snapshot** (cron/launchd one-liner in OPERATIONS or here) | Operator runs weekly; file appears in `logs/` |
| W1.3 | **Task templates for COS epics** | Each Wave 2+ epic has a default task title prefix `[COS]` and acceptance section in task contract (template below) |
| W1.4 | **ChumpMenu / web link** | README or ChumpMenu doc points to this roadmap + script |

**`[COS]` task contract (paste into task title + notes):**

- **Title:** `[COS] <short outcome>` (e.g. `[COS] Weekly snapshot scheduled on Mabel Mac]`).
- **Notes / contract:**
  - **Wave / story:** e.g. W2.4, CS-12.
  - **Acceptance:** bullet list of observable outcomes (URLs, log lines, API behavior).
  - **Owner:** `chump` | `jeff` | `cursor`.
  - **Evidence:** paths to logs, PRs, or docs that prove done.
  - **Lease / blocker:** if leased, until when; what unblocks.

**Heartbeat context:** On rounds `work`, `cursor_improve`, `discovery`, and `opportunity`, the agent context includes the latest `logs/cos-weekly-*.md` (by file mtime) when present. Set `CHUMP_INCLUDE_COS_WEEKLY=0` to disable; `CHUMP_INCLUDE_COS_WEEKLY=1` to always inject (high token use). Cap size with `CHUMP_COS_WEEKLY_MAX_CHARS` (default 8000). Requires `CHUMP_HOME` / `CHUMP_REPO` / cwd so `logs/` resolves correctly.

### Wave 2 — **Close the loop** (autonomy + reporting)

| ID | Deliverable | Acceptance |
|----|-------------|------------|
| W2.1 | **“Weekly COS” heartbeat prompt** | [x] `heartbeat-self-improve.sh`: Monday gate + `WEEKLY_COS_PROMPT`; `weekly_cos` round + snapshot in context; opt out `CHUMP_WEEKLY_COS_HEARTBEAT=0` |
| W2.2 | **Interrupt policy config** | [x] `CHUMP_INTERRUPT_NOTIFY_POLICY=restrict` + `CHUMP_NOTIFY_INTERRUPT_EXTRA`; `notify` gated during heartbeat; `docs/COS_DECISION_LOG.md`; system DMs bypass via `set_pending_notify_unfiltered` |
| W2.3 | **Decision log convention** | [x] `docs/COS_DECISION_LOG.md` — path `cos/decisions/YYYY-MM-DD.md` under `CHUMP_BRAIN_PATH`, template + interrupt tag table |
| W2.4 | **ChumpMenu tool approvals** | [x] Chat tab uses streaming SSE; on `tool_approval_request`, Allow/Deny → `POST /api/approve` (see ARCHITECTURE / TOOL_APPROVAL) |

### Wave 3 — **Discovery factory** (find + fix)

| ID | Deliverable | Acceptance |
|----|-------------|------------|
| W3.1 | **GitHub triage bot path** | [x] **`scripts/github-triage-snapshot.sh`** — `gh issue list` → Markdown table + `[COS]` stubs; `CHUMP_TRIAGE_REPO`, optional `CHUMP_TRIAGE_OUT` |
| W3.2 | **CI failure → single task** | [x] **`scripts/ci-failure-digest.sh`** — failure excerpts + `[COS]` stub; **fingerprint dedupe** in `logs/ci-failure-dedupe.tsv` (`CI_FAILURE_DEDUPE_FILE`, `--no-dedupe`, `CI_FAILURE_DEDUPE=0`) |
| W3.3 | **Repo health sweep** | [x] **`scripts/repo-health-sweep.sh`** — git/disk/cargo checks; **`REPO_HEALTH_AUTOFIX=1`** safe `chmod +x` on top-level `scripts/*.sh` only; optional `REPO_HEALTH_JSONL` |
| W3.4 | **Cold-start friction detector** | [x] **`scripts/golden-path-timing.sh`** — JSONL timings, threshold exit, `docs/EXTERNAL_GOLDEN_PATH.md` |

### Wave 4 — **Adjacent products** (ship + measure)

| ID | Deliverable | Acceptance |
|----|-------------|------------|
| W4.1 | **Problem validation checklist** | [x] [PROBLEM_VALIDATION_CHECKLIST.md](PROBLEM_VALIDATION_CHECKLIST.md) + episode stub |
| W4.2 | **Repo scaffold script** | [x] **`scripts/scaffold-side-repo.sh`** + **`templates/side-repo/`** (LICENSE, CI, README, issue template) |
| W4.3 | **Portfolio map** | [x] [templates/cos-portfolio.md](templates/cos-portfolio.md) → copy to `cos/portfolio.md` in brain |
| W4.4 | **Quarterly COS memo** | [x] **`scripts/quarterly-cos-memo.sh`** → `logs/cos-quarterly-YYYY-Qn.md` |

---

## 5. User story catalog (60)

**Legend:** **A** = Chief-of-staff staff work · **B** = Self-directed discovery & capability · **C** = Product factory & real-world shipping

| ID | Tag | Headline |
|----|-----|----------|
| CS-01 | A | Weekly operating picture from roadmap + tasks + episodes |
| CS-02 | A | Monday ranked backlog from roadmap + gates |
| CS-03 | A | Nightly autonomy pass on leased tasks within policy |
| CS-04 | A | Interrupt only on threshold crossings |
| CS-05 | A | Vague intent → concrete task tree + acceptance |
| CS-06 | A | Pre-brief Cursor per handoff contract |
| CS-07 | A | Apply positioning prefs to outbound work |
| CS-08 | A | Decision log in brain/wiki |
| CS-09 | A | Own battle-QA smoke after material changes |
| CS-10 | A | Consciousness baseline when inference/cascade changes |
| CS-11 | A | Federal BD pipeline deltas (evidence-linked) |
| CS-12 | A | Prep for external conversations from docs + metrics |
| CS-13 | A | Storage/archive hygiene proposals |
| CS-14 | A | Route sensitive actions through approvals |
| CS-15 | A | GitHub branch/PR hygiene on `chump/*` |
| CS-16 | A | Rules-of-engagement card in context assembly |
| CS-17 | A | Precompute FAQ answers from memory + docs |
| CS-18 | A | Daily ship risk review (PRs, CI, flaky) |
| CS-19 | A | Post-mortems → episodes + counterfactuals |
| CS-20 | A | Bounded multi-step research pipeline |
| CS-21 | A | Task queue COS behavior (reprioritize, leases, blocker nag) |
| CS-22 | A | Exec summaries of long threads |
| CS-23 | A | Mac-first parity (PWA + ChumpMenu chat) |
| CS-24 | A | Challenge scope creep with tradeoffs |
| CS-25 | A | Weekly “what moved” accountability report |
| CS-26 | B | Scan GitHub issues → ranked fix queue |
| CS-27 | B | CI failures → single task per cluster |
| CS-28 | B | Periodic repo health sweeps |
| CS-29 | B | Dedupe conflicting docs |
| CS-30 | B | Dependency drift batch upgrades |
| CS-31 | B | Flaky test detection + stabilization tasks |
| CS-32 | B | Log signature → owner mapping |
| CS-33 | B | Cold-start simulation tasks |
| CS-34 | B | Track unknowns until resolved |
| CS-35 | B | Challenge broken manual workflows |
| CS-36 | B | Capability matrix (tools/PATH/cascade) |
| CS-37 | B | Benchmark tool latencies after infra change |
| CS-38 | B | Demand-driven new tool proposals + Cursor build |
| CS-39 | B | Self-play adversarial prompt suite |
| CS-40 | B | Weekly failure-episode mining |
| CS-41 | B | A/B prompt variants on safe workloads |
| CS-42 | B | Prioritized skills backlog |
| CS-43 | B | Reduce uncertainty/clarification rates |
| CS-44 | B | Scheduled clippy/test hygiene |
| CS-45 | B | Enforce conventions from rules + PR feedback |
| CS-46 | C | Validate real-world problem before repo |
| CS-47 | C | Bootstrap new repo (README, CI, templates) |
| CS-48 | C | Ship thin vertical MVP first |
| CS-49 | C | Public trust doc per product |
| CS-50 | C | Pilot metrics for new product |
| CS-51 | C | Product ops loop (issues, milestones, changelog) |
| CS-52 | C | Partner/API ToS evaluation gate |
| CS-53 | C | Internal tool first, then public promotion |
| CS-54 | C | Open-source spinouts when generalized |
| CS-55 | C | Portfolio map of experiments |
| CS-56 | C | Sunset failed experiments cleanly |
| CS-57 | C | Adversarial product review pre-launch |
| CS-58 | C | Structured MVP feedback → issues |
| CS-59 | C | Defense/federal alignment when relevant |
| CS-60 | C | Quarterly “what we built” memo |

---

## 6. Appendix — full user stories

### A. Chief of staff (CS‑01–CS‑25)

1. **As** Jeff, **I want** Chump to maintain a living **weekly operating picture** (priorities, risks, next moves) from roadmap + task queue + recent episodes, **so that** I open one surface and see where we are without re-briefing him.  
2. **As** Jeff, **I want** Chump to **propose a ranked backlog** each Monday from unchecked roadmap items, task DB, and failing gates (tests, battle QA smoke), **so that** I approve direction once and he drives execution cadence for the week.  
3. **As** Jeff, **I want** Chump to run a **nightly autonomy pass** on leased tasks (planner → executor → verifier) within my tool-approval and risk policy, **so that** merged work lands with tests green without me micromanaging each step.  
4. **As** Jeff, **I want** Chump to **only interrupt me** when a threshold is crossed (ship blocked, approval pending >30m, security/cascade open circuit, or explicit “human” tag), **so that** max autonomy does not become notification spam.  
5. **As** Jeff, **I want** Chump to **translate vague intent** (“get us ready for pilot N4”) into a **concrete task tree** with acceptance checks and file paths, **so that** aspirational goals become shippable slices without me writing the WBS.  
6. **As** Jeff, **I want** Chump to **pre-brief Cursor** with goal, roadmap citation, logs, and “one item per run” discipline before invoking CLI, **so that** delegated coding stays aligned with Chump–Cursor handoffs.  
7. **As** Jeff, **I want** Chump to **mine my stated preferences** (defense/federal posture, procurement vs grants framing, Colorado LLC context) into actions and doc pointers—not chat filler, **so that** outbound work stays consistent with my positioning rules.  
8. **As** Jeff, **I want** Chump to **maintain a decision log** in the brain/wiki for major calls (what we chose, why, links), **so that** aspirational threads stay auditable when we revisit months later.  
9. **As** Jeff, **I want** Chump to **own the battle-QA smoke loop** after material changes (inference, tools, prompts), triage failure categories, and open a single fix task per pattern, **so that** “max runway” does not erode reliability.  
10. **As** Jeff, **I want** Chump to **schedule and run** the consciousness/baseline checks when we change model or cascade, and only alert on regression gates, **so that** aspirational cognition work does not silently drift.  
11. **As** Jeff, **I want** Chump to **watch federal BD pipelines** we care about (SAM scan rhythm, pilot charter artifacts) and summarize deltas with links—not claims, **so that** I get staff work, not hype.  
12. **As** Jeff, **I want** Chump to **prepare me for external conversations** (objections, proof points, what to demo, what not to promise) using repo docs and pilot metrics recipes, **so that** meetings stay grounded in what we can show.  
13. **As** Jeff, **I want** Chump to **enforce storage/archive hygiene** when logs or artifacts bloat the repo (suggest rotation per `STORAGE_AND_ARCHIVE.md`), **so that** long autonomous runs do not punish future me with disk and clone pain.  
14. **As** Jeff, **I want** Chump to **route sensitive actions** through approval flows (`CHUMP_TOOLS_ASK`, explicit confirmations for destructive `run_cli`), **so that** autonomy is wide but not reckless.  
15. **As** Jeff, **I want** Chump to **keep GitHub hygiene** (branches, PR drafts, checklists) on `chump/*` conventions unless I’ve explicitly enabled auto-publish, **so that** aspirational velocity does not bypass repo safety norms.  
16. **As** Jeff, **I want** Chump to **maintain a “rules of engagement” card** visible in context assembly (when to act vs ask, when to delegate, when to log episodes), **so that** every long-running agent honors the same contract without me repeating it.  
17. **As** Jeff, **I want** Chump to **precompute answers** to recurring internal questions (“where is wedge doc?”, “what’s DSIP status note?”, “how do I run golden path?”) from memory + docs, **so that** my team-of-bots reduces repeated lookups.  
18. **As** Jeff, **I want** Chump to **run a daily “ship risk review”**: open PRs, CI posture, flaky tests, dependency drift signals, summarized with severities, **so that** I can ignore it until something is red or time-sensitive.  
19. **As** Jeff, **I want** Chump to **capture post-mortems** after incidents (what broke, what we changed, what we watch next) into episodes + counterfactual lessons, **so that** autonomy compounds instead of repeating failures.  
20. **As** Jeff, **I want** Chump to **coordinate multi-step research** (queue brief, iterate passes, write `research/latest.md`, stop when diminishing returns) without claiming finished science, **so that** aspirational research stays bounded and reviewable.  
21. **As** Jeff, **I want** Chump to **manage my task queue like a COS**: reprioritize when new urgent items arrive, release leases cleanly, and nag only on true blockers, **so that** autonomy doesn’t deadlock the system.  
22. **As** Jeff, **I want** Chump to **prepare “exec summaries”** of long threads (Discord/web) with decisions, open questions, and next actions, **so that** I can re-enter context after travel without reading everything.  
23. **As** Jeff, **I want** Chump to **operate Mac-first surfaces** (PWA + ChumpMenu chat) as parity paths to Discord for routine staff work, **so that** my primary workspace is not trapped in chat scrollback.  
24. **As** Jeff, **I want** Chump to **challenge scope creep** when new asks conflict with roadmap focus—propose tradeoffs rather than silently absorbing, **so that** aspirational work stays strategically coherent.  
25. **As** Jeff, **I want** Chump to **end each week with a short “what moved” report**: shipped, learned, risks, next week’s top 3 bets—grounded in tasks/episodes/commits, **so that** max autonomy still produces accountability I can trust.

### B. Self-directed discovery & capability (CS‑26–CS‑45)

26. **As** Jeff, **I want** Chump to **scan open issues** across repos in `CHUMP_GITHUB_REPOS` for high-impact, well-scoped bugs and propose a ranked “fix queue,” **so that** new problems surface without me triaging every board.  
27. **As** Jeff, **I want** Chump to **monitor CI failures** on default branches and open a single task per failure cluster with log excerpts, **so that** regressions become owned work items, not chat noise.  
28. **As** Jeff, **I want** Chump to **run periodic “repo health” sweeps** (stale branches, missing LICENSE headers, broken links in README, outdated golden-path steps) and fix what’s safe automatically, **so that** entropy is reduced continuously.  
29. **As** Jeff, **I want** Chump to **detect duplicate or conflicting docs** (two sources of truth for the same procedure) and propose a merge plan with one canonical path, **so that** operators stop getting contradictory instructions.  
30. **As** Jeff, **I want** Chump to **watch for dependency drift** (Rust crates, npm where relevant) and batch upgrade proposals behind a PR with tests, **so that** security and compatibility issues are found early.  
31. **As** Jeff, **I want** Chump to **identify flaky tests** from historical patterns (intermittent failures, timing-sensitive suites) and schedule stabilization work, **so that** autonomy doesn’t amplify noise into false crises.  
32. **As** Jeff, **I want** Chump to **parse production-like logs** (when provided) for recurring error signatures and map them to code owners / files, **so that** real-world pain becomes actionable engineering.  
33. **As** Jeff, **I want** Chump to **simulate “new user cold start”** periodically (clone, build, golden path) and file friction items into onboarding-style tasks, **so that** adoption issues are discovered before marketing pushes.  
34. **As** Jeff, **I want** Chump to **track “unknown unknowns”** as questions in the brain when evidence is thin, then resolve or close them when data arrives, **so that** speculation doesn’t masquerade as decisions.  
35. **As** Jeff, **I want** Chump to **challenge broken workflows** it observes (e.g., repeated manual steps every heartbeat) and propose automation with risk notes, **so that** it solves meta-problems, not only tickets.  
36. **As** Jeff, **I want** Chump to **maintain a capability matrix** (tools available vs missing on PATH, cascade slots, embed server, web auth) and self-heal within policy, **so that** its “hands” match what it thinks it can do.  
37. **As** Jeff, **I want** Chump to **benchmark tool latencies** (read_file, run_cli, memory recall) after infra changes and record baselines, **so that** performance regressions become visible.  
38. **As** Jeff, **I want** Chump to **propose new tools** when it repeatedly hits the same impedance (same bash one-liner 10×) by drafting a minimal Rust tool + schema + tests, then delegating implementation to Cursor, **so that** capability growth is demand-driven.  
39. **As** Jeff, **I want** Chump to **run “self-play” battle scenarios** against synthetic adversarial prompts (injection, tool misuse, approval bypass attempts) and tighten prompts/policies when it fails, **so that** robustness improves without exposing users first.  
40. **As** Jeff, **I want** Chump to **review its own failure episodes** weekly and extract durable lessons into memory + counterfactual store, **so that** it stops repeating the same class of mistakes.  
41. **As** Jeff, **I want** Chump to **A/B prompt and context-assembly variants** on non-production tasks and pick winners using measurable outcomes (success rate, tokens, time), **so that** “aspirational intelligence” is tuned empirically.  
42. **As** Jeff, **I want** Chump to **maintain a “skills backlog”** (what it wishes it could do: OCR, browser automation, better PDF parsing) prioritized by unblock count, **so that** capability investments follow real friction.  
43. **As** Jeff, **I want** Chump to **instrument its own uncertainty** (when it asks clarifying questions, when approvals stall) and reduce those rates via better defaults, **so that** autonomy feels competent, not chatty.  
44. **As** Jeff, **I want** Chump to **schedule periodic clippy/test/dead-code hygiene** as first-class tasks with zero scope creep, **so that** the codebase stays shippable while it explores new work.  
45. **As** Jeff, **I want** Chump to **learn repo conventions** from `.cursor/rules` and past PR feedback, then enforce them in generated patches, **so that** self-improvement matches house style.

### C. Product factory & real-world impact (CS‑46–CS‑60)

46. **As** Jeff, **I want** Chump to **hypothesize a real-world problem** from public signals we care about (e.g., operator toil in a domain we serve) and validate it with lightweight research artifacts, **so that** new products start from pain, not features.  
47. **As** Jeff, **I want** Chump to **bootstrap a new repo** (README, LICENSE, CI, minimal app, docs, issue templates) for a validated problem, under naming and privacy rules you set, **so that** shipping a new product doesn’t begin from an empty folder.  
48. **As** Jeff, **I want** Chump to **ship a “thin vertical” MVP** in that repo (one workflow end-to-end) before adding breadth, **so that** real users can exercise the core loop early.  
49. **As** Jeff, **I want** Chump to **create a public-facing trust doc** for any new product (data handling, limitations, rollback story) aligned with speculative-rollback honesty, **so that** aspirational launches don’t outrun credibility.  
50. **As** Jeff, **I want** Chump to **define pilot metrics** for a new product using the same N3/N4 recipes we use elsewhere, **so that** success is measurable and comparable across initiatives.  
51. **As** Jeff, **I want** Chump to **operate a small “product ops” loop**: issues triage, milestone labels, release notes, changelog discipline, **so that** the new repo behaves like a real maintained product.  
52. **As** Jeff, **I want** Chump to **identify integration partners** (APIs, datasets) needed for a real-world fix and evaluate ToS/licensing constraints before coding, **so that** autonomy doesn’t create legal/ethical debt.  
53. **As** Jeff, **I want** Chump to **build an internal-only tool first** (CLI or local web) for a real workflow, then promote to public only after hardening, **so that** “new product” risk is staged.  
54. **As** Jeff, **I want** Chump to **package repeatable fixes** as open-source utilities when they generalize beyond Chump (e.g., a log triage helper), **so that** solving our problems also helps the ecosystem.  
55. **As** Jeff, **I want** Chump to **maintain a portfolio map** of products/repos it created or adopted, with status (experiment / active / sunset) and owners, **so that** aspirational expansion stays governable.  
56. **As** Jeff, **I want** Chump to **sunset failed experiments** cleanly (archive repo, document learnings, remove integrations), **so that** autonomy doesn’t leave a graveyard of half-finished surfaces.  
57. **As** Jeff, **I want** Chump to **run “adversarial product review”** on its own new product drafts (security, abuse, edge cases) before external launch, **so that** real-world issues include misuse realities.  
58. **As** Jeff, **I want** Chump to **collect user-like feedback** via structured prompts (not surveys spam) on the MVP and convert it into prioritized issues, **so that** iteration is evidence-led.  
59. **As** Jeff, **I want** Chump to **align new products with defense/federal constraints** when relevant (data residency, human-in-the-loop, auditability) using your existing doc set as guardrails, **so that** ambition matches compliance reality.  
60. **As** Jeff, **I want** Chump to **publish a quarterly “what we built and why it mattered”** memo across repos it stewards, tied to episodes and metrics, **so that** autonomous creation stays accountable to outcomes, not output volume.

---

## 7. Next actions for you

1. Run **`./scripts/generate-cos-weekly-snapshot.sh`** weekly (add to launchd/cron next to other roles).  
2. Pick **Wave 2** first engineering item (W2.2 interrupt policy or W2.4 ChumpMenu approvals) and delegate to Cursor with this doc as source.  
3. When an epic ships, add a checkbox line under [ROADMAP.md](ROADMAP.md) **Product: Chief of staff** subsection (see below).
