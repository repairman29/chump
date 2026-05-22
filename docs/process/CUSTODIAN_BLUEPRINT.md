---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-22
---

# Repository Custodian Blueprint

> A reusable framework for taking an unmapped codebase from "raw" to "self-driving."
> Chump is the worked example in each section — what each phase looks like when it lands.

## Why this exists

Every long-lived repo accumulates two kinds of debt: **structural** (code, schemas, abstractions) and **operational** (the rituals and enforcement that keep structural debt from compounding). Most custodian work over-indexes on structural cleanup and under-indexes on enforcement — the framework looks good in docs and rots in practice.

This blueprint targets both. Each phase has an artifact checklist *and* an enforcement test.

---

## Phase 1 — Custodian & Librarian (Discover, Clean, Organize)

**Mission:** make the repo intuitive to an outside observer in under 30 seconds.

### Questions to ask first

1. Can a stranger find the mission, hard rules, and entry point in one read?
2. Is work tracked in a single canonical registry — queryable, machine-readable, source-of-truth?
3. Are shared-state locations, secrets paths, and exclusions documented and protected?
4. What files SHOULD NOT be committed, and is that enforced (not just documented)?

### Artifacts to produce

| Artifact | Purpose | Chump example |
|---|---|---|
| `README.md` | 5-min orient + install + quickstart | `Chump/README.md` — "Try Chump in 5 minutes" with brew tap + ollama path |
| `AGENTS.md` (LF spec) | Canonical agent rules across all harnesses | `Chump/AGENTS.md` |
| Harness overlay | Per-harness mechanics (paths, OAUTH, hooks) | `Chump/CLAUDE.md` overlays AGENTS.md |
| Gap/work registry | Single source of work-in-flight | `chump gap` (SQLite + YAML mirrors), 650+ records |
| Process docs root | Discoverable detail behind links | `docs/process/` (70 files, all linked from CLAUDE.md/AGENTS.md) |
| Hard-rules block | Do/don't list at top of agent docs | CLAUDE.md "Hard rules" section |
| `.gitignore` + exclusion contract | Enforce no-commit zones | `proprietary/` excluded + manual rule in CLAUDE.md |

### Enforcement test

Run a **cold-clone test**: clone the repo, read only top-level + entry doc. Can you describe what the project does, the first command to run, and what NOT to touch — without grepping? If not, the librarian work isn't done.

### Chump's current state (Phase 1)

✓ README, AGENTS.md, CLAUDE.md, AGENTS.md/CLAUDE.md split clean.
✓ `chump gap` is the canonical registry with audit + dedup + triage commands.
✓ 70 process docs linked progressively.
⚠ **Enforcement leak**: 200+ uncommitted YAML modifications in the main worktree at any given moment because background mutators write to `docs/gaps/*.yaml` without an enforced commit cadence. Symptom: `git status` is permanent noise; "is this file my edit or a sibling agent's?" is ambiguous.

---

## Phase 2 — Architect & Analyst (Deconstruct, Fit, Value)

**Mission:** answer *what*, *how*, and *why* for every load-bearing component.

### Questions to ask first

1. What are the major modules and their entry points? Where do they cross boundaries?
2. What is the data flow — which writes to which store, and what events emit?
3. What is the canonical source-of-truth for each kind of state?
4. Which dependencies are load-bearing and which are decoration?

### Artifacts to produce

| Artifact | Purpose | Chump example |
|---|---|---|
| Topology map | ASCII/mermaid showing modules + flows | `docs/design/A2A_ROADMAP.md` (6-layer mapping) |
| Event/observability schema | Typed registry of every event kind | `docs/observability/EVENT_REGISTRY.yaml` |
| Per-domain design doc | One per major feature area | `docs/process/CANONICAL_STATE_CONTRACT.md`, `HARNESS_CONTRACT.md`, `AGENT_API.md` |
| Script taxonomy | Entry point per task | `scripts/README.md` + `scripts/coord/README.md` |
| SLO definitions | What "healthy" means, numerically | `docs/process/FLEET_SLOS.md` + `chump health --slo-check` |
| Lessons retrospectives | Why we did this differently | `docs/syntheses/` |

### Enforcement test

Pick a random event kind from production logs (`ambient.jsonl`, structured logs, etc.). Can you find:
- Its schema in the event registry?
- The script/module that emits it?
- The downstream consumer?

In a healthy repo this takes <60 seconds. If grep alone isn't enough, the architect work isn't done.

### Chump's current state (Phase 2)

✓ EVENT_REGISTRY.yaml exists; schema-consistency CI test enforces it.
✓ Each feature area has a design doc.
✓ SLOs are explicit and machine-checkable.
⚠ **Enforcement leak**: SLO breaches emit to ambient.jsonl but operator visibility is buried in noise (e.g. `slo_breach severity:high L2-SLO-2 waste 118%` appears today but no escalation fired — the breach was visible only when manually tailing the stream).

---

## Phase 3 — Educator & Evangelist (Inspire, Message, Market)

**Mission:** move a stranger from "what is this" to "I shipped a working extension" in 5 minutes.

### Questions to ask first

1. Can a new operator install + first-run in under 5 minutes? Is that time measured by CI, not memory?
2. Is the voice authentic — engineers' language, not buzzwords?
3. Are hidden gems (powerful features new users miss) curated, not just available?
4. Is there a friction log — recording where new users actually got stuck?

### Artifacts to produce

| Artifact | Purpose | Chump example |
|---|---|---|
| 5-minute quickstart | Top of README, copy-pasteable | `README.md` "Try Chump in 5 minutes" |
| `ONBOARDING.md` | Step-by-step, friction-aware | `docs/process/ONBOARDING.md` (with FTUE measurement) |
| `ONBOARDING_FRICTION_LOG.md` | What real users tripped on | `docs/process/ONBOARDING_FRICTION_LOG.md` |
| `USER_GUIDE.md` | Progressive depth — beyond quickstart | `docs/USER_GUIDE.md`, `docs/PWA_USER_GUIDE.md` |
| Offline/local-LLM path | For privacy/sovereignty users | `docs/QUICKSTART_OFFLINE.md` |
| Role-specific agent docs | If multi-agent | `docs/agents/RESEARCH_PRIVACY.md` |
| Hidden-gems showcase | Curated highlights | (gap — see anti-patterns below) |

### Enforcement test

Run a **fresh-machine FTUE measurement** monthly. From `brew install` to "first useful action," how many seconds? Above 5 minutes is the line; above 20 minutes is a red letter.

### Chump's current state (Phase 3)

✓ README + ONBOARDING + QUICKSTART_OFFLINE all exist and link cleanly.
✓ FTUE is measured (`docs/audits/ftue-verifications/`).
⚠ **Hidden-gems gap**: no curated "you didn't know Chump could do this" doc. Discoverability is via grep over 70 process docs. New users miss `chump-coord watch`, `chump gap consolidate`, `chump revert`, the GUI PWA, etc.

---

## Phase 4 — Systematizer (The Loop That Keeps the Other Three Honest)

**Mission:** extract the reusable schema and the meta-loop that audits the framework itself.

### The reusable checklist

When applying this blueprint to a new repo, work top-to-bottom in **one focused pass per phase**. Resist the urge to ping-pong — each phase produces inputs the next consumes.

**Phase 1 (Librarian) — 1-3 days for a medium repo:**
- [ ] README.md with 5-min quickstart
- [ ] AGENTS.md / CLAUDE.md (or equivalent)
- [ ] Hard-rules block surfaced in entry doc
- [ ] Work registry (canonical, queryable, mutation API)
- [ ] `proprietary/` (or equivalent) exclusion enforced

**Phase 2 (Architect) — 2-5 days:**
- [ ] Topology map for major flows
- [ ] Event/observability schema (typed)
- [ ] Per-domain design docs
- [ ] Script/tool taxonomy with entry points
- [ ] SLO definitions + machine-checker command

**Phase 3 (Educator) — 1-3 days:**
- [ ] 5-min quickstart at top of README
- [ ] ONBOARDING.md with friction log
- [ ] USER_GUIDE.md (progressive depth)
- [ ] Offline / privacy variant if applicable
- [ ] Hidden-gems curated showcase

**Phase 4 (Systematizer) — ongoing:**
- [ ] Health-check command (this blueprint's enforcement tests, automated)
- [ ] Audit cadence (weekly/monthly)
- [ ] Lessons-retro doc per major incident

**Phase 5 (CI/CD Gatekeeper) — 1-2 weeks per gate:**
- [ ] Structural-drift PR gate (new module/service → docs entry required)
- [ ] Inline docs-drift drafter (review-bot suggests the doc to write)
- [ ] DRY-line auto-reviewer (similarity check + Rust-first-style scope gates)
- [ ] Audit-logged bypass trailer (escape hatches that don't rot)

**Phase 6 (Federated Network) — multi-week, only if org has 2+ repos:**
- [ ] Cross-repo topology manifest (`<tool> federate scan` writes a JSON map)
- [ ] Federated discovery hub (one site listing all blueprint-following repos)
- [ ] `repo-init` template engine (Day-1 scaffolding with Phase 1-4 baked in)

### The meta-loop

Run a **quarterly custodian audit**: walk the enforcement test in each phase. Surface enforcement leaks. File gaps for each. The framework is healthy if every enforcement test passes within a 30-second sweep; unhealthy if any test requires grep, multi-file reads, or memory.

---

## Phase 5 — CI/CD Gatekeeper (Continuous Custodianship)

**Mission:** turn the blueprint from a one-time audit into a continuous PR-time quality gate. Phase 4's quarterly audit catches drift after the fact; Phase 5 prevents it from landing.

### Questions to ask first

1. Which Phase 1–4 enforcement tests can be automated as PR gates?
2. When a gate fails, can it suggest the fix inline (review comment with draft text) rather than just block?
3. Are bypass mechanisms audit-logged so escape hatches don't rot into "the gate everyone disables"?

### Artifacts to produce

| Artifact | Purpose | Chump example |
|---|---|---|
| Structural-drift gate | Fail PRs that add modules/services without docs entries | INFRA-1675 (planned) — `scripts/ci/test-architectural-drift-gate.sh` |
| Inline docs-drift drafter | Auto-suggest the doc to write (review comment, not just refusal) | INFRA-1676 (planned) — `.github/workflows/docs-drift-drafter.yml` |
| DRY-line auto-reviewer | Reject duplicate utilities/scripts at PR time | Partial — META-063 (no dupes), META-064 (Rust-first), META-065 (curator auto-prioritization), INFRA-1149 (title similarity) |
| Audit-logged bypass trailer | Allow escape hatches that don't rot | `Rust-First-Bypass:` trailer already in use; pattern to replicate |

### Enforcement test

Open a PR that adds `scripts/coord/foo.sh` with no corresponding `docs/process/` entry. Does CI fail with an actionable message naming the missing doc? Does the same PR with a one-line `docs/process/foo.md` pass? Does the bypass trailer work and end up in an audit log queryable later?

If the answer to any is "no," Phase 5 isn't enforcing yet — it's just documented.

### Chump's current state (Phase 5)

✓ 35 CI lanes exist; CREDIBLE-001 shellcheck + gaps-integrity + pr-hygiene + audit-required all enforce code/structure correctness.
✓ META-063/064/065 cluster + INFRA-1149 similarity check cover the DRY-line partially.
⚠ **No structural-drift gate yet** — adding a new `scripts/coord/*.sh` doesn't fail CI even with zero docs. Tracked: INFRA-1675.
⚠ **No inline docs-drift drafter** — the gate would refuse without suggesting; INFRA-1146 (roadmap drift inject) proves the pattern is feasible. Tracked: INFRA-1676.

---

## Phase 6 — Federated Network (Scaling the Blueprint)

**Mission:** turn one well-curated repo into a network effect across an org. The blueprint's value compounds when applied to siblings; a single curated repo is an island.

### Questions to ask first

1. Which other repos in the org should adopt this blueprint?
2. Where do they intersect (shared scripts, shared deployment, shared on-call)?
3. Can a single discovery hub aggregate utility-vectors across all of them?
4. Can a `repo-init` command make Phases 1–4 free for Day 1 of any new project?

### Artifacts to produce

| Artifact | Purpose | Chump example |
|---|---|---|
| Cross-repo topology manifest | Macro-map of org's software ecosystem | INFRA-1677 (planned) — `chump federate scan` writing `docs/federation/topology.json` |
| Federated discovery hub | One site listing all blueprint-following repos with utility-vectors | INFRA-1678 (planned) — promote `repairman29.github.io/chump` from docs-from-this-repo to docs-from-org |
| `repo-init` template engine | Day-1 scaffolding with Phase 1–4 baked in | INFRA-1679 (planned) — `chump repo-init <name>` |

### Enforcement test

A new engineer joins an adjacent repo (not Chump itself). Measure time-to-first-meaningful-contribution. With `repo-init` and the federated hub, they should get a working AGENTS.md, gap registry, ONBOARDING, and ROADMAP on Day 1 by running one command. Without them, they grep Stack Overflow.

A second test: pick a Chump-pattern repo other than Chump itself. Run the Phase 1–4 enforcement tests against it. Does it pass? If not, Phase 6 hasn't actually propagated the framework — it's only printed it on the discovery hub.

### Chump's current state (Phase 6)

⚠ **No federation manifest yet.** `repairman29` org has at least three Chump-pattern repos (Chump itself, `repairman29/homebrew-chump` tap, PWA repo per INFRA-1015) but no manifest binds them. Tracked: INFRA-1677.
⚠ **`repairman29.github.io/chump` is single-repo docs.** Phase 6 promotes it. Tracked: INFRA-1678.
⚠ **No `repo-init` command.** `chump init` scaffolds operator state (`~/.chump/`), not project state. The highest-leverage Phase 6 deliverable — turns the blueprint into a one-shot scaffolder. Tracked: INFRA-1679.

---

## Anti-patterns (lessons from Chump's own failure modes)

### 1. Treating "framework lands" as the finish line

The framework is the prerequisite, not the deliverable. Chump has all four phases' artifacts; what leaks is enforcement — daemons failing silently, duplicate gaps slipping past similarity checks, stale local checkouts running stale hooks. **Allocate at least 50% of custodian-work hours to enforcement instrumentation, not to writing more docs.**

### 2. Similarity dedup ≠ duplicate prevention

Chump's `chump gap reserve` runs Jaccard similarity (warn @ 0.65, block @ 0.85). Two gaps filed today (INFRA-1664 vs INFRA-1666) covered the same bug — same fix needed, same file — but slipped past because of pillar-tag prefix difference and verb variation ("disambiguate" vs "filter"). **Pair the dedup check with a "filed in last 14 days touching this file" prompt to operators**, not just title similarity.

### 3. Background daemons failing silently

Chump's `opus-curator` emitted `exit_code 5` every 10 minutes for hours; the daemon wrapper logged but did not alert. The pattern: `set -euo pipefail` + a downstream mutating call that fails silently to the operator. **All scheduled daemons should emit a `*_error` event kind with structured failure-class, not just rely on exit code visibility.**

### 4. Stale local checkout running stale tooling

A custodian session that starts with stale `git fetch` state will diagnose phantom bugs that were already fixed upstream. The custodian's pre-flight must include not just `git fetch && git status` but also `git log main..origin/main` — what shipped while I was away. **Inspect upstream-ahead before filing any "I just found this bug" gap.**

### 5. Generic prompts vs. mature codebases

Applying a "discover and clean this unmapped repo" prompt to a mature, heavily-curated codebase produces redundant audits and duplicate filings (this audit was a textbook example). For mature repos, **flip the prompt to "extract the framework using this as the worked example."** The deliverable becomes the blueprint, not yet-another-cleanup.

### 6. Doc volume without indexing

Chump has 70 process docs. The entry doc (CLAUDE.md) links to ~12 of them. The other 58 are discoverable only via grep. **Every process doc should be linked from at least one entry doc**, or be marked archive/lessons (not canonical guidance).

### 7. CI gates that lint syntax but not architecture

Chump's 35 CI lanes enforce code-correctness (shellcheck, cargo-test, clippy, audit-required, gaps-integrity, pr-hygiene). They do NOT enforce "did you add a new tool and forget to document it" — a PR adding `scripts/coord/foo.sh` with no `docs/process/foo.md` passes today. Code stays clean, docs decay. **Phase 5 gates close this loop** by treating documentation as part of the diff under review, not a separate quarterly audit.

### 8. Single-repo curation that doesn't compose across an org

A well-curated single repo creates an island. Engineers joining adjacent repos in the same org (Chump itself, `homebrew-chump` tap, the PWA repo) get no benefit from the artifacts you built. The blueprint's structural-layout victories live entirely in this repo's `docs/process/`. **Phase 6 makes the framework reusable**: a federated hub publishes the artifacts cross-repo, and `repo-init` ensures the structural layout is the default on Day 1, not a thing you have to remember.

---

## How to apply this blueprint to a new repo

1. **Skim the new repo for ~30 minutes.** Note what exists at each phase. Don't write anything yet.
2. **Score each phase 1-5** on artifact completeness and enforcement health.
3. **Pick the lowest-scoring phase first.** Resist the urge to do all four — the lowest phase blocks the rest.
4. **Run the enforcement test** for that phase against the current state. Surface 3-5 concrete failures.
5. **File those as work-registry items.** One PR per item, atomic, intent-focused.
6. **Repeat at the next-lowest phase.**

This is read-only assessment first, then targeted action. Do not start by writing docs — start by measuring whether existing docs hold up to their enforcement tests.

---

## Related Chump docs

- [AGENTS.md](../../AGENTS.md) — canonical agent rules
- [CLAUDE.md](../../CLAUDE.md) — Claude Code overlay
- [FLEET_SLOS.md](FLEET_SLOS.md) — SLO definitions
- [CLAUDE_GOTCHAS.md](CLAUDE_GOTCHAS.md) — operational hazards
- [ONBOARDING.md](ONBOARDING.md) — Phase 3 worked example
- [EVENT_REGISTRY.yaml](../observability/EVENT_REGISTRY.yaml) — Phase 2 observability schema

## Implementation gaps (Phase 5 + Phase 6)

- [INFRA-1675](../gaps/INFRA-1675.yaml) — Phase 5.1 structural-drift CI gate
- [INFRA-1676](../gaps/INFRA-1676.yaml) — Phase 5.2 docs-drift auto-drafter
- [INFRA-1677](../gaps/INFRA-1677.yaml) — Phase 6.1 cross-repo topology mapper
- [INFRA-1678](../gaps/INFRA-1678.yaml) — Phase 6.2 federated discovery hub
- [INFRA-1679](../gaps/INFRA-1679.yaml) — Phase 6.3 `chump repo-init` template engine

## Provenance

**2026-05-22 (initial, Phases 1-4).** Authored during a custodian-prompt session against Chump itself. The session surfaced 3 real fleet bugs (INFRA-1666 superseded as duplicate of INFRA-1664, INFRA-1667 opus-curator daemon failure, INFRA-1668 oauth-token-critical missing) and concluded that Chump's custodian framework is mature — the gap is enforcement. The anti-patterns section is the actual deliverable; the phase checklists exist to make the anti-patterns concrete.

**2026-05-22 (extension, Phases 5+6).** Same session, evening. Operator extended the original prompt with two additional phases — CI/CD Gatekeeper (continuous custodianship at PR time) and Federated Network (scaling the blueprint across an org). Phase 5 documents the gates that would prevent the drift Phases 1-4 audit catches after the fact. Phase 6 turns the blueprint from a how-to-doc into an executable scaffolder via `repo-init`. Both phases are framework-only here; implementation is tracked in INFRA-1675 through INFRA-1679 above.
