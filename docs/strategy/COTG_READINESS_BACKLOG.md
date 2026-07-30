# COTG — ChumpOS Outta The Gate: the readiness backlog

> **What this is.** The full, grounded backlog to take ChumpOS from "the foundry
> works" to "the living stack is in real people's hands." Outcome: **COTG**.
> Every gap below carries full acceptance criteria and a pillar. This document is
> the canonical design; the filed gaps are the actionable queue.
>
> **Read the mission first:** [MISSION.md](../MISSION.md) (North Star + Goals),
> `FIRST_MATE.md` (workspace root — why any of this exists),
> [ROADMAP.md § the ChumpOS arc](./../ROADMAP.md).

---

## 1. The target — one step past today's North Star

Today's North Star (MISSION.md): *"A **solo developer** — even offline, on local
LLMs — can build and ship real software while the fleet does the hands-on work."*

**COTG extends it by one decisive step:** the user is no longer a developer.

> **A person who cannot write software — who does not know what a PR, a branch, a
> test, or a deploy is — brings only a plain-language vision of a real problem in
> their life. ChumpOS returns a finished, honest tool, in their hands. They never
> see a line of code.**

This is not a new mission. It is the **done-state of the ChumpOS arc** ("anyone
points it at a real problem, walks away, and gets a finished, honest tool") made
literal for the person the whole empire is *for*: not the builder, the
**user** — the one eating on a budget, the one whose software is rotting, the
citizen following the money. They have always had the vision (the real problem).
What they lack is the ability to build. COTG is ChumpOS supplying everything but
the vision.

**The line that governs this backlog (FIRST_MATE.md):** *a tool that's
unfinished, untold, or untrue solves nobody's problem.* COTG is the machine that
guarantees finished + told + true, from a vision, with no human in the loop.

---

## 2. Who uses ChumpOS (and what their mission is)

The COTG user is defined by two facts: **they have a real-life mission, and they
cannot build software.** Grounded in the living stack (FIRST_MATE.md):

| Persona | Their vision (in their words) | What they must NEVER need to do |
|---|---|---|
| **The budget cook** | "Help me feed my kids well for less, and warn me before I overspend." | Know what an API, a database, or a deploy is. |
| **The software-rot victim** | "My little business tool keeps breaking. Keep it alive without me hiring anyone." | Read a stack trace or a CI log. |
| **The citizen** | "Show me where my town's money actually goes." | Understand scraping, hosting, or data pipelines. |
| **The small operator** | "I have an idea for a tool my community needs. Make it real." | Write a spec, a ticket, or a line of code. |

**Their mission is their problem, stated plainly.** ChumpOS's job is to treat
that sentence as the whole input — clarify it kindly, decide honestly whether
it's worth building, build it, prove it works, and hand it over. Everything
between the vision and the working tool is the OS's job, and the OS must do it
*flawlessly*, because the user cannot check the OS's work — they don't know how.

**This raises the reliability bar past "impressive demo."** When the user cannot
audit the output, "mostly works" is indistinguishable from "broken" to them, and
"looks done" is a lie they can't detect. COTG is therefore as much an **honesty**
program as a capability program.

---

## 3. How this backlog was derived (receipts, not vibes)

The method is the meta-principle of COTG itself: **every human intervention is a
defect in autonomy.** This backlog was mined from a single real session
(2026-07-28/29) by cataloguing every place a human had to step in. Each became a
gap. This is the same loop the OS must eventually run on *itself* (Epic 2). The
receipts:

- Three armed PRs sat on **deterministic 1-line CI failures** (debt-ceiling,
  undocumented env var) — the OS had the information to self-heal and didn't.
- A **merge-order hazard** (two PRs bumping the same ceiling → broken trunk)
  needed a human to notice and coordinate.
- The external flywheel's **last mile failed**: the agent edited but never
  shipped; the strong model produced *malformed JSON* it couldn't detect.
- **Running infrastructure had no source in git** (the armed-pr-rebaser) — the OS
  ran code it could not reproduce or reason about.
- The **scoreboard over-claimed** ("zero-touch" that was human-in-loop; a Phase
  marked done with an open tail).

Nothing below is manufactured to fill a pillar. Every gap traces to a receipt
above or to a concrete requirement of the persona journey in §2.

---

## 4. The measure

COTG inherits the mission Scoreboard and adds the falsifiable COTG gate:

- **Inherited:** scoreboard ① (zero-touch PR merged in an external repo) must be
  **YES, repeatably** — today it is NO.
- **COTG gate (new):** run one end-to-end **vision → working tool** cycle on a
  real living-stack problem and count **human software-interventions = 0**. Not
  "few." Zero. A single ceiling-bump, a single "the agent didn't open the PR,"
  a single "clean the decks" is a failing run.
- **Honesty invariant:** every "done" the OS reports to the user must be
  verified, not assumed (Epic 3). A COTG run that ships a tool the user can't
  actually use is a *worse* failure than one that halts honestly.

---

## 5. The epics

Sequencing is deliberate (see §6): **you cannot be a wise architect on top of an
unreliable executor, and you cannot deliver to a non-technical user on top of an
untrustworthy one.** Reliability (E1) and self-healing (E2) are the floor;
honest verification (E3) is the load-bearing wall; wisdom (E4) and delivery
(E5)/stewardship (E6) are what the user actually experiences. E0 is the front
door; **ES (Sourcing Intelligence) sits even before it — nothing builds until we
know it doesn't already exist.**

---

### EPIC S — Sourcing Intelligence (know what exists before building)

*Why (mission):* "own your tools, don't rent your mind" cuts both ways — reinvent
nothing that's commodity, own everything that's a moat. Before the Vision Contract
even reaches a build, the OS must resolve a target against what already exists —
here, in our arsenal, and in the world — and decide finish / harvest / source /
build. **Proven necessary by the 2026-07-29 discovery scan (§5.5), which caught 14
already-built capabilities we had filed as "build."** Today the pieces exist (dedup,
harvester, contract-scan, the organs) but are not composed, and there is nothing for
half-done-and-why or world-scale prior art.

**COTG-S.1 — EFFECTIVE: sourcing resolver (repo → arsenal → world, before building)** [INFRA-3508]
- AC1: Before the Flow builds a target, resolve it in three tiers and return
  DONE-HERE / HALF-DONE-HERE / EXISTS-IN-ARSENAL / EXISTS-IN-WORLD / NOT-FOUND with
  receipts (file:line / repo / package+stars): (1) this repo via the comprehension
  organs (structural completeness, NOT keyword-dedup); (2) our arsenal via the
  harvester (76-repo catalog); (3) the open-source world (crates.io/npm/GitHub).
- AC2: Wired AHEAD of implement so the Flow never builds what a tiered search already
  found — the productized version of the manual discovery scan.
- AC3: Test — a capability that exists in repo/arsenal/a well-known crate resolves to
  the right tier with a receipt; a genuinely novel one returns NOT-FOUND.
- Pillar: EFFECTIVE. Priority: P1. (Gates E1 — nothing builds before sourcing says BUILD.)

**COTG-S.2 — CREDIBLE: stall diagnosis (detect half-done AND why it stalled)** [INFRA-3509]
- AC1: For a HALF-DONE-HERE verdict, diagnose completeness (built vs AC) AND why it
  stalled — wire the PROVENANCE organ (git-blame why) + TRACES + PR/issue history
  (abandoned branch, failing test, gated scope). Return "X% done, stalled because Y."
- AC2: So the fleet finishes intelligently rather than rebuilding on a corpse or
  shipping the broken half — today's dedup is binary done/not-done.
- AC3: Test — a fixture half-done feature is reported with a completeness % + a correct
  stall reason drawn from git/PR history.
- Pillar: CREDIBLE. Priority: P2.

**COTG-S.3 — CREDIBLE: the build-vs-source decision (own-vs-rent, logged)** [INFRA-3510]
- AC1: Given S.1/S.2, decide FINISH / HARVEST / SOURCE / BUILD, encoding "own your
  tools, don't rent your mind": commodity substrate (resilience/HTTP/parsing) → SOURCE
  (you'd only rent it anyway); a moat / a user's living-stack tool → BUILD (reinventing
  that wheel is the point — no landlord can enclose it); partial → FINISH.
- AC2: Inputs — supply-chain/dep risk, license compatibility with the protective posture
  (AGPL/Apache/FSL), maintenance burden, integration-vs-build cost. Decision + rationale
  logged/auditable. Precedent: the resilience-library call (don't build, cockatiel/LiteLLM
  own it).
- AC3: Test — a commodity capability decides SOURCE, a moat decides BUILD, a partial
  decides FINISH, each with a logged rationale.
- Pillar: CREDIBLE. Priority: P2.

**COTG-S.4 — EFFECTIVE: wire the organs into dedup (structural completeness, not keyword)** [INFRA-3511]
- AC1: improve's dedup (Stage 2) skips work by commit/PR keyword match; augment/replace
  with the organs' structural completeness (actually wired + reachable, not "a commit
  mentions it"). Cheap wiring — the organs exist.
- AC2: Prevents the exact discovery failure — a built-but-not-wired thing falsely
  deduped as done.
- AC3: Test — a built-but-not-wired capability is NOT falsely deduped; a complete one is.
- Pillar: EFFECTIVE. Priority: P2.

---

### EPIC 0 — The Vision Contract (the non-technical front door)

*Why (mission):* makes the North Star reachable by someone who cannot write a
spec. Guards "built → finished" by refusing to start work that shouldn't exist
(the evidence-before-build rule).

**COTG-0.1 — EFFECTIVE: conversational vision intake (plain language → scoped outcome)**
- AC1: A user can enter a free-text problem ("help me feed my kids well for less")
  through a single surface and receive, without any software vocabulary, a
  plain-language restatement of what ChumpOS understood + the 1–3 clarifying
  questions it needs answered. Builds on `chump bootstrap` (INFRA-2265) and
  `chump ingest`, but the surface must accept ambiguity, not a spec.
- AC2: The dialogue terminates in a structured **outcome** row (`chump outcome
  create`) with a DoD written in the user's terms, plus an internal technical
  decomposition intent — the user never sees the latter.
- AC3: A test drives 3 vague living-stack visions end-to-end to a scoped outcome
  with zero software terms surfaced to the user; a golden-transcript assertion
  fails if any PR/branch/CI/test/deploy jargon leaks to the user channel.
- Pillar: EFFECTIVE. Priority: P1.

**COTG-0.2 — CREDIBLE: honest go / no-go on a user's vision (evidence-before-build)**
- AC1: Before any build starts, the OS runs a go/no-go that returns one of GO /
  NO-GO / NEEDS-NARROWING, each with a plain-language reason the user can
  understand ("a free tool already does this well" → NO-GO with the alternative;
  "this needs data we can't legally get" → NO-GO with why).
- AC2: NO-GO is a first-class, non-apologetic outcome — the OS is graded on
  *correct* NO-GOs, mirroring the portfolio go/no-go discipline (6 NO-GOs prove
  the gate works). A NO-GO records the reasoning so it is auditable.
- AC3: Test: a fixture of visions with known verdicts (at least 2 GO, 2 NO-GO,
  1 NEEDS-NARROWING) is classified correctly; the gate refuses to start fleet
  work on a NO-GO vision.
- Pillar: CREDIBLE. Priority: P1.

**COTG-0.3 — EFFECTIVE: vision → MVP scope negotiation (smallest honest first tool)**
- AC1: For a GO vision, the OS proposes the smallest first version that delivers
  real value ("first I'll build the part that warns you before you overspend;
  the receipt-scanning comes next"), in plain language, and gets a yes/adjust.
- AC2: The negotiated MVP becomes the first roadmap slice under the vision's
  outcome; later phases are recorded but not started (no overbuild — guards the
  33-kill-repos failure mode).
- AC3: Test: an over-broad vision is narrowed to an MVP whose scope is provably a
  strict subset, and the phased remainder is persisted, not built.
- Pillar: EFFECTIVE. Priority: P2.

---

### EPIC 1 — Flawless Execution (never storm, never half-ship, never lose work)

*Why (mission):* Goal 2 (Self-heal) at the execution altitude, and the direct
lesson of the session's live runs. This is the floor everything else stands on.

**COTG-1.1 — EFFECTIVE: typed Flow state machine for gap execution (the kernel ABI)**
- AC1: A gap's execution is modeled as an explicit typed state machine (Rust
  enum + typed state struct + serde) with named states (e.g. Picked → Comprehended
  → Implemented → Verified → Shipped) and typed transitions — the CrewAI-Flows
  borrow, landing MISSION-067's kernel ABI. Aligns with / supersedes **EFFECTIVE-326**.
- AC2: External-repo execution (`improve`/`execute_gap`) is the first consumer:
  its ad-hoc pick→dedup→implement→verify→ship stages become explicit Flow states.
- AC3: Illegal transitions are rejected at compile time or with a typed error at
  runtime (no silent skip of Verify). Test: a Flow that tries to reach Shipped
  without Verified fails.
- Pillar: EFFECTIVE. Priority: P1. (Umbrella; decompose at claim time.)

**COTG-1.2 — EFFECTIVE: deterministic ceremony (agent edits; the OS ships)**
- AC1: The implement-agent's ONLY responsibility is to edit files. Commit → push
  → PR-open is performed deterministically by `improve.rs`/the Flow, not the
  agent. Directly fixes the session finding: both weak and strong models edited
  but did not complete the git/PR ceremony.
- AC2: The ExternalRepoContract prompt is rewritten to instruct edit-only; the
  deterministic ship stage detects changed files, commits with the `Chump-Agent`
  trailer + gap context, pushes the per-agent-worktree branch, opens the PR, and
  extracts the URL — backend-agnostic.
- AC3: Test: a stub agent that ONLY edits a file (never runs git) still results
  in a pushed branch + a PR URL via the deterministic path. A stub that makes no
  change results in an honest "no change" outcome, not a phantom PR.
- Pillar: EFFECTIVE. Priority: P1.

**COTG-1.3 — CREDIBLE: pre-commit edit-verification gate (destructive + validity)**
- AC1: Before the deterministic ceremony commits an agent's edit, a gate rejects
  (a) **destructive** edits — a tracked file whose deletions vastly exceed
  insertions / whole-file clobber (the free-tier finding), and (b) **invalid**
  edits — a changed file that no longer parses for its type (the strong-model
  malformed-`package.json` finding: JSON/TOML/YAML validity at minimum).
- AC2: A rejected edit does NOT commit; it emits a typed failure the Flow can
  route to retry-with-guidance or escalate — never a silent bad PR.
- AC3: Test: the exact two session failures (330→12-line clobber; `devDependencies`
  nested inside `scripts`) are both caught by the gate; a legitimate 3-line
  surgical edit passes.
- Pillar: CREDIBLE. Priority: P1.

**COTG-1.4 — RESILIENT: durable / resumable gap execution (journal; crash → resume)**
- AC1: Each in-flight gap is a journaled workflow (SQLite/Postgres-native, no new
  infra — the DBOS-style borrow from the A2A master plan L6). A crash mid-execution
  resumes from the last committed state instead of re-claiming from scratch or
  losing the worktree (the session's "leave the worktree on failure → work lost"
  gap is the missing journal).
- AC2: Resume is idempotent — re-running a partially-completed Flow does not
  double-commit, double-push, or re-open a PR.
- AC3: Test: kill a Flow after Implemented-but-before-Shipped; on restart it
  resumes at Verify, not at Pick, and ships exactly one PR.
- Pillar: RESILIENT. Priority: P1.

**COTG-1.5 — RESILIENT: supervision-tree escalation (catch storms on cycle 4, not 30)**
- AC1: A per-gap restart-intensity policy distinguishes transient (retry) from
  systematic (mark blocked + escalate) failures; a gap that makes no successful
  progress for N cycles is escalated, not looped. Directly addresses the
  "3 consecutive tool batches storming" abort and the historical retry-storm class.
- AC2: A fleet-level supervisor pauses pickup + runs a health check on
  >M escalations in a window (the A2A L6 supervision-tree borrow).
- AC3: Test: a synthetic storming agent is escalated within N cycles; a genuinely
  transient failure (one flaky call then success) is NOT escalated.
- Pillar: RESILIENT. Priority: P2.

**COTG-1.6 — EFFECTIVE: task-fit model/capability selection (right tool for the job)**
- AC1: The execution Flow selects the provider/model class by task difficulty,
  not a fixed default: hard external implementation biases to the strong
  (`opus`-class, e.g. gemini-2.5-pro) cascade slot; trivial mechanical edits use
  cheap tiers. Grounded in the session: free-tier stormed, `CHUMP_PREFERRED_MODEL_CLASS=opus`
  produced a surgical edit. Never defaults to the claude CLI (Principle 0).
- AC2: The selection is recorded per gap for later quality attribution (which
  class ships vs storms), feeding the picker's class-success ratings.
- AC3: Test: a gap tagged hard-implementation selects a strong-class provider; a
  gap tagged mechanical selects a cheap one; the choice is logged.
- Pillar: EFFECTIVE. Priority: P2.

---

### EPIC 2 — Self-Healing Autonomy (every human touch becomes a capability)

*Why (mission):* Goal 5 (Zero-touch loop → 0). This epic is the COTG derivation
method turned into a running organ.

**COTG-2.1 — RESILIENT: operator-intervention watchdog (log every human touch as a defect)**
- AC1: The OS records every human intervention in the fleet (a manual push, a
  manual merge, a manual gate-fix, a manual deck-clean, a manual claim) as a typed
  `autonomy_defect` event with enough context to reproduce what the human did.
- AC2: Each defect is auto-triaged into a class (deterministic-gate-failure,
  coordination, ceremony-gap, infra-drift, …) and, where the class is known-
  healable, files a self-healing gap tagged to COTG.
- AC3: Test: a simulated manual gate-fix emits an `autonomy_defect`, is classed,
  and produces a candidate gap; the intervention count is queryable as a metric.
- Pillar: RESILIENT. Priority: P1.

**COTG-2.2 — RESILIENT: deterministic CI-gate self-heal (fix the OS's own 1-line failures)**
- AC1: For the deterministic gate-failure classes proven this session — bypass-var
  debt-ceiling over by N (bump with a reasoned entry), undocumented env var (add
  to `env-vars-internal.txt`), unregistered ambient kind (add to `EVENT_REGISTRY.yaml`),
  install-manifest gaps — the OS detects the failure on an armed PR and applies the
  canonical fix in a throwaway worktree, then re-pushes. Never force-pushes a
  broken state (mirrors the armed-pr-rebaser safety).
- AC2: Each auto-fix carries the appropriate audited bypass/reason trailer; a
  class it doesn't recognise is escalated, not guessed.
- AC3: Test: a PR failing each known class is auto-healed to green; an unknown
  failure is flagged, not silently touched.
- Pillar: RESILIENT. Priority: P1.

**COTG-2.3 — RESILIENT: cross-PR coordination / merge-order hazard detection**
- AC1: Before arming PRs that touch a shared ratchet/manifest/counter (e.g. the
  bypass-var ceiling, an allowlist count), the OS detects the interaction and
  coordinates the fix so trunk stays green regardless of merge order — the exact
  hazard a human caught this session (two PRs → 237 each → 238 real).
- AC2: The coordination is automatic (compute the cumulative value; write it
  identically across the interacting PRs) or, if ambiguous, escalated with the
  specific conflict named.
- AC3: Test: two synthetic PRs each +1 on a shared counter are coordinated so
  post-both-merge trunk passes; a single PR is untouched.
- Pillar: RESILIENT. Priority: P2.

**COTG-2.4 — EFFECTIVE: reactive coordination bus (react to events; stop polling)**
- AC1: Fleet coordination reacts to typed domain events (`pr.merged` → ship next,
  `test.failed` → route to self-heal, `deploy.done` → notify) over the existing
  NATS substrate instead of polling — the A2A L5 event-sourcing borrow; turns on
  `CHUMP_A2A_LAYER`. Replaces the polling watchers a human/agent runs by hand.
- AC2: Offline-degrades cleanly to the pull loop (state.db stays source of truth).
- AC3: Test: a `pr.merged` event triggers the next ship with no poll loop; with
  NATS off, the pull path still works.
- Pillar: EFFECTIVE. Priority: P2.

**COTG-2.5 — RESILIENT: no-untracked-running-infra guard (reproducible fleet)**
- AC1: A gate/daemon detects any launchd/systemd job in the fleet whose script is
  not committed to the repo (the armed-pr-rebaser finding) and flags it as an
  autonomy_defect with the file path. The OS never depends on code it cannot
  reproduce from git.
- AC2: The check is runnable in CI (inspect installed plists vs tracked scripts)
  and in the session preflight.
- AC3: Test: an untracked running daemon is detected; a properly committed one
  passes.
- Pillar: RESILIENT. Priority: P2.

---

### EPIC 3 — Honest Verification (green ≠ works; done means done)

*Why (mission):* the "true" in built→finished→told→true. For a user who cannot
audit the OS, honesty is load-bearing. This is where the OS earns the right to
say "done" to someone who has to trust it.

**COTG-3.1 — CREDIBLE: outcome-level verification (does the shipped thing SOLVE the problem?)**
- AC1: Before reporting a tool "done" to the user, the OS verifies the *outcome*,
  not the build: the deployed surface actually performs the user's stated task,
  observed live (browser/API/CLI, per the preview verification doctrine), not
  merely CI-green. "Green ≠ works" is enforced at the delivery boundary.
- AC2: The verification is expressed against the vision's DoD (Epic 0) in the
  user's terms ("before-overspend warning fires on a test overspend"), and fails
  closed — an unverifiable outcome is reported as not-done.
- AC3: Test: a tool that is CI-green but does not perform its DoD task is
  correctly reported not-done; one that performs it is reported done with the
  observed proof.
- Pillar: CREDIBLE. Priority: P1.

**COTG-3.2 — CREDIBLE: anti-over-claim watchdog (umbrella-done ≠ actually-done)**
- AC1: The OS refuses to report a milestone/phase/outcome "done" while its tail is
  open — the Phase-0-marked-done-with-open-tail finding. A "done" claim is checked
  against the actual state of its children/DoD, and downgraded to "closed with N
  open tail items" when they exist.
- AC2: Applied to the scoreboard and to any user-facing "your tool is ready"
  claim.
- AC3: Test: a phase with an open tail item is not reported as cleanly done; a
  genuinely complete one is.
- Pillar: CREDIBLE. Priority: P2.

**COTG-3.3 — CREDIBLE: verified zero-touch provenance (prove autonomy, don't assume it)**
- AC1: Any "zero-touch" / autonomy claim is verified by the `Chump-Agent` commit
  trailer, not merely by counting merges — the scoreboard-over-claim finding
  (INFRA-3479). Human-co-authored merges are reported separately.
- AC2: The COTG intervention-count metric (§4) is computed from real provenance:
  a merge without the agent trailer counts as a human intervention.
- AC3: Test: a human-co-authored merge is classified non-zero-touch; an
  agent-trailered one counts as zero-touch.
- Pillar: CREDIBLE. Priority: P2. (Extends INFRA-3479.)

**COTG-3.4 — CREDIBLE: test-depth honesty at the delivery boundary**
- AC1: The OS never reports "tested" without a depth tier (smoke / happy-path /
  edge / adversarial) and named gaps — extends the existing test-depth doctrine to
  the user-facing "your tool is tested" claim, so a happy-path-only tool is never
  told to the user as robust.
- AC2: The depth claim is stored with the tool and surfaced honestly in the trust
  panel (Epic 6).
- AC3: Test: a happy-path-only suite cannot be reported as "covered" to the user.
- Pillar: CREDIBLE. Priority: P3.

---

### EPIC 4 — Wise Architect & Innovation (choose right, invent, reflect, compound)

*Why (mission):* the "wise architect" question. Today the OS is wired with
guardrails (don't-be-foolish) but few generators (be-brilliant). This epic adds
the generators — carefully, above a reliable floor.

**COTG-4.1 — EFFECTIVE: divergent solve for hard gaps (N approaches → judge → synthesize)**
- AC1: For gaps above a difficulty threshold, the OS generates N independent
  approaches (different angles), scores them with adversarial judges, and
  synthesizes from the winner — the innovation loop, borrowed from the review
  workflows and applied to *solving*, not just reviewing.
- AC2: Bounded by a budget law (Σ child budget ≤ parent — A2A L3) so divergence
  never multiplies burn without a ceiling.
- AC3: Test: a hard gap produces ≥N scored approaches and a synthesized result;
  a trivial gap skips divergence (cost discipline).
- Pillar: EFFECTIVE. Priority: P2.

**COTG-4.2 — CREDIBLE: the do → reflect loop (the OS reviews its own work like a human would)**
- AC1: After executing, the OS runs a reflection pass applying the honesty checks
  a human applies by hand: reality-check (did the outcome the belief predicts
  actually happen?), durable-fix (did I fix the cause or hide it?), anti-over-claim.
  Every intervention I made this session was a reflection the OS could not do for
  itself — this closes that.
- AC2: Reflection findings feed back as new gaps or as blocks on a false "done."
- AC3: Test: a band-aid fix is caught by the reflect loop and flagged; a durable
  fix passes.
- Pillar: CREDIBLE. Priority: P2.

**COTG-4.3 — EFFECTIVE: strategic comprehension (architect altitude, not just repo altitude)**
- AC1: The comprehension-first loop is extended from "comprehend the repo before
  touching it" to "comprehend the *mission/strategy* before choosing work" — the
  OS can answer "is this the right thing, what does best look like, what am I
  missing?" against the outcome, not just the code. Builds on the organs +
  comprehension-first loop.
- AC2: Surfaced at planning/pick time, so the fleet biases toward the
  highest-leverage mission move, not the most-available gap.
- AC3: Test: given a queue and an outcome, the OS's recommended next work is the
  one that most advances the outcome, with a stated rationale.
- Pillar: EFFECTIVE. Priority: P3.

**COTG-4.4 — RESILIENT: compounding memory (this run makes the next run smarter)**
- AC1: Lessons from a session (the receipts, the fixes, the failure classes) are
  captured into the lessons-store/memory such that a later session automatically
  benefits — the OS does not re-derive what it already learned. Ties the
  auto-memory + lessons-injection mechanisms into the execution Flow.
- AC2: A demonstrated lesson (e.g. "strong-class model for hard external edits")
  measurably changes a later run's behavior without a human re-teaching it.
- AC3: Test: injecting a prior lesson changes model selection / approach on a
  matching later gap.
- Pillar: RESILIENT. Priority: P3.

---

### EPIC 5 — Delivery to Real Hands (a tool, not a repo; in the user's language)

*Why (mission):* Goal 1 (Self-deploy) + "in their hands" + the whole point of the
living stack. A merged PR the user can't use is not a delivered tool.

**COTG-5.1 — EFFECTIVE: auto-deploy to a usable surface (URL/app, never a repo)**
- **Revised 2026-07-29 (operator directive): split into stage + promote, not one
  deploy step.** As originally written, AC2 verified the same surface handed to
  the user — meaning a broken agent output could be visible mid-verification, or
  the surface could drift between "verified" and "handed off." Fix: verification
  (COTG-3.1) runs against an ephemeral, per-lap **stage** surface; only a passing
  stage is **promoted** — an atomic, deterministic flip — to what the user
  actually receives.
- AC1: A shipped tool is automatically deployed to an **ephemeral, per-lap stage
  surface** — not the customer-facing URL yet — the non-technical user never sees
  this step. Extends self-deploy (MISSION-012) from "binary current" to
  "user-facing surface live," but the first surface built is disposable, matching
  the same isolation pattern Chump already uses per-gap (a worktree per claim).
- AC2: COTG-3.1's outcome-verification runs against the **stage** surface, not the
  final one. Only after it passes does a **promote** step — atomic, deterministic,
  no re-build — flip the verified artifact to the customer-facing surface. The
  user is handed the link only after promote, never before.
- AC3: Test: a shipped tool deploys to a stage surface, passes its DoD check
  there, and only then promotes; a tool that fails its DoD check on stage never
  reaches the customer-facing surface. A second test: promote is a flip of the
  already-verified artifact, not a fresh build (no drift between what was
  verified and what shipped).
- AC4 (build-vs-source, per COTG-S.3): this is commodity substrate, not a moat —
  source it. Hosted case: wrap an existing preview-deployment mechanism (e.g.
  Vercel's per-PR preview + promote-to-prod flip) rather than building one.
  Self-hosted / air-gapped case: a minimal git-push-to-live-URL pattern (e.g.
  Dokku's detect-build-run loop) or an agent-sandbox-with-exposed-port pattern
  (e.g. e2b, Apache-2.0, self-hostable) — both are narrow, vendorable patterns,
  not full platforms to adopt wholesale. Graft the pattern; don't rent the infra
  for customers who can't use hosted infra.
- Pillar: EFFECTIVE. Priority: P1.
- **Reality check (2026-07-29 grounding pass):** the "preview verification
  doctrine" this AC used to cite does not exist as a real document — it appeared
  only inside this file's own text. Removed the phantom citation. The closest
  real analog is `docs/process/EXTERNAL_GOLDEN_PATH.md`'s health-check pattern,
  which checks liveness, not outcome — COTG-3.1 (AC2 above) is the doctrine that
  actually needs to be written, once it ships.

**COTG-5.2 — EFFECTIVE: fleet-state → user-language translation (never show PRs/CI)**
- AC1: All user-facing communication is in the user's terms: "your budget tracker
  can now warn you before you overspend," never "PR #123 merged, CI green." A
  translation layer maps fleet/git/CI state to outcome-language milestones.
- AC2: A guard asserts no software jargon (PR/branch/commit/CI/deploy/test/repo)
  ever reaches the user channel; internal channels are unaffected.
- AC3: Test: a full build cycle's user-facing transcript contains zero software
  terms and accurately reflects real progress.
- Pillar: EFFECTIVE. Priority: P2.

**COTG-5.3 — CREDIBLE: honest completion hand-off (told, and true)**
- AC1: The "your tool is ready" message is sent only after outcome-verification
  (3.1) passes, and states plainly what the tool does, what it does NOT yet do
  (the phased remainder from 0.3), and how to use it — guarding "built → finished
  → told."
- AC2: If verification fails, the user is told honestly what's not working and
  what happens next — never a false "done."
- AC3: Test: hand-off is blocked on a failed DoD check; on success it includes
  the does/doesn't-yet honestly.
- Pillar: CREDIBLE. Priority: P2.

---

### EPIC 6 — Trust & Stewardship (honest status, cost, maintenance, ownership)

*Why (mission):* "protected so no landlord can enclose them" (FIRST_MATE.md +
LICENSING.md), plus keeping the tool alive without the user. Trust is what makes
a non-technical user hand over their real problem.

**COTG-6.1 — CREDIBLE: the trust panel (what works, what's pending, what it costs)**
- AC1: The user has a plain-language status surface: what their tool does today,
  what's being worked on, its honest test-depth (3.4), and what running it costs
  — no dashboards, no metrics jargon.
- AC2: The panel never over-claims (ties to 3.2); "working" means outcome-verified.
- AC3: Test: the panel reflects the real state of a tool including an honest
  "not-yet" for unbuilt phases.
- Pillar: CREDIBLE. Priority: P3.

**COTG-6.2 — RESILIENT: self-maintaining deployed tools (keep it alive without the user)**
- AC1: A delivered tool's own breakages (dependency rot, a failing deploy, a
  broken integration) are detected and self-healed by the OS — directly serving
  the software-rot-victim persona. The user is told, in their language, only when
  action is genuinely needed.
- AC2: Maintenance actions are held to the same verification bar (a "fixed" claim
  is outcome-verified).
- AC3: Test: a simulated dependency break in a delivered tool is self-healed and
  the tool passes its DoD again, with an honest user note.
- Pillar: RESILIENT. Priority: P3.

**COTG-6.3 — CREDIBLE: ownership & non-enclosure guarantees (the tool is theirs)**
- AC1: Every delivered tool carries the protective license posture (LICENSING.md:
  apps → AGPLv3, substrate → Apache-2.0) and the revoke-before-publish security
  gate is enforced before anything the user's tool exposes goes public — so a
  tool built for a person cannot be quietly enclosed or leak their secrets.
- AC2: The security/secret sweep + liveness verification runs as a release gate on
  every user tool (mirrors the portfolio remediation discipline).
- AC3: Test: a tool with a live secret cannot be published to the user's surface;
  a clean one can.
- Pillar: CREDIBLE. Priority: P3.

---

## 5.5 Discovery (2026-07-29) — what already exists

A read-across-the-746k-LOC scan mapped all 28 gaps (plus ES) against existing code
BEFORE any construction. Headline: **the COTG floor is mostly already built — it just
isn't wired.** ~14 gaps are 40–90% done; the genuinely greenfield half is delivery to a
human (E5) — Chump's pipeline ends at a merged PR and has **no concept of a *delivered
tool*** distinct from one. Each gap now carries its verdict as a `DISCOVERY …` note
(FINISH-at-file vs BUILD). Load-bearing findings:

- **Built-but-not-wired (finish, don't rebuild):** COTG-1.1 (`src/autonomy_fsm.rs` is a
  complete typestate FSM, instantiated as a dead `_fsm`); COTG-1.2 (`crates/chump-ship`
  is a deterministic ship engine, internal-only — the exact fix for the live last-mile
  failure); COTG-1.6 (`improve.rs` hardcodes `claude-sonnet-4-5` — a Principle-0
  violation — while `provider_cascade` already honors `CHUMP_PREFERRED_MODEL_CLASS`);
  COTG-2.4 (reactive-bus transport complete, reactions absent); COTG-3.3 (the
  `Chump-Agent` trailer is emitted on every commit; the scoreboard just counts raw merges).
- **Exists richer than described (adopt/close):** COTG-4.4 compounding memory (capture +
  per-directive adoption grading + A/B ranking).
- **Genuinely greenfield (real build):** all of E5 (5.1/5.2/5.3), 6.2, plus 3.1 the live
  outcome-verification gate that everything user-facing depends on.
- **The consolidation point:** `src/improve.rs` + `src/execute_gap.rs` (the external Flow)
  is the natural home for the entire Wave-A floor (1.1/1.2/1.3/1.4/1.6) — five gaps in one
  subsystem, and today the least-wired part.

## 5.6 Discovery round 2 (2026-07-29, operator-directed) — remaining epics + E5 grafts

A second discovery pass covered what §5.5 didn't: the rest of Epic 1/2/4, plus a real
graft search (arsenal + this repo + OSS prior art) for the genuinely-greenfield E5/RESCUE/
E0.0/3.1 pieces. Ground rule applied both times: a file existing is not evidence of
wiring — verified against the live claim→implement→ship path, not just source presence.

**Remaining Epic 1/2/4 gaps:**

| Gap | Verdict | Receipt | Remaining work |
|---|---|---|---|
| 1.3 edit-verify gate | PARTIAL | `verify_staged_edit()` (`src/improve.rs:977`) wired on initial ship (`:1073`), NOT on `fix_pr`/`remediate_held` remediation path — tracked by the already-open `INFRA-3516` (P1) | route remediation commits through the same gate |
| 1.4 durable/resumable exec | DONE (narrow) | checkpoint/resume in `src/improve.rs:1168-1199,281-297` matches AC exactly | `src/execute_gap.rs` has zero checkpoint refs — the non-`improve` path has no journal at all |
| 1.5 supervision-tree escalation | PARTIAL, likely dead | `gap-supervisor.sh`/`fleet-supervisor.sh` exist, tested in isolation, but **nothing in the live claim/retry loop calls them**; daemons not installed on this box; 0 `gap_supervisor_escalated` events ever, despite a prior gap (RESILIENT-131) claiming it was made load-bearing | wire the call from the real retry loop + install the daemons |
| 2.1 intervention watchdog | DONE (capability), manual-only | `src/intervention_watchdog.rs` (787 lines) fully implements classify/scan/emit/file, all ACs tested | never invoked by any coordination loop — cron/manual `--apply` only |
| 2.2 gate self-heal | PARTIAL | `src/pr_rescue.rs` `Classification` covers 3 of 5 named classes (orphan-allowlist, env-var, debt-ceiling); no handler for unregistered-ambient-kind or install-manifest gaps | finish the 2 missing arms (already correctly scoped by §6 below) |
| 2.3 merge-order hazard | NOT-FOUND | zero grep hits for cross-PR shared-ratchet coordination | genuine build |
| 2.5 untracked-infra guard | NOT-FOUND | `infra-watcher-loop.sh` checks plist health, not plist-vs-git-tracked | genuine build |
| 4.1 divergent solve | NOT-FOUND | zero hits for N-candidate-generate/judge/synthesize on *solving* (review-side patterns exist, not solve-side) | genuine build |
| 4.2 do→reflect loop | PARTIAL, not wired | `src/reflection.rs`/`reflection_db.rs` (real, LLM-assisted) but every caller is eval-harness grading — zero refs from `improve.rs`/`execute_gap.rs` | wire a post-execution pass into the live pipeline |

**E5 / RESCUE / E0.0 / 3.1 graft findings:**

| Gap | Verdict | Graft source | Note |
|---|---|---|---|
| 5.1 deploy-to-surface | NOT-FOUND here / EXISTS-IN-ARSENAL+WORLD | 6+ of Jeff's own repos already deploy via Vercel (`ai-gm-service`, `coloringbook`, `beast-mode-website`) using a proven `vercel.json` shape; self-hosted options: Dokku (minimal git-push-to-URL), e2b (self-hostable agent sandbox, Apache-2.0) | see revised AC (above, this doc) for the stage/promote split this graft feeds into |
| 5.2 user-language translation | NOT-FOUND, no reuse candidate | — | genuine build |
| 5.3 honest hand-off | NOT-FOUND (thin) | `src/intervention_watchdog.rs`'s `Chump-Agent` trailer parsing + `zero_touch_streak()` is the truth-primitive to compose over | build the message layer, not the truth-checks |
| RESCUE diagnosis | DONE-HERE, via an uncataloged dependency | `src/comprehend_tool.rs` shells to a `comprehend` binary built from `~/Projects/almanac` — **`almanac` is not in `docs/arsenal/GLOBAL_ARSENAL.json`**, a live gap in the harvester's own 2026-05-25 (stale) catalog | catalog `almanac`; translate its technical output to plain language for the user flow |
| RESCUE fix/actuation | NOT-FOUND | `src/paramedic.rs` (2154 lines, INFRA-1375) is real but Chump-repo-specific — fix vocabulary hardcoded to Chump's own CI gates | generalize the fix-dispatch beyond Chump's own gates |
| E0.0 front-door router | NOT-FOUND (the 5 modes) / DONE-HERE (skeleton) | `src/intent_parser.rs` (828 lines, merged, live via `chump orchestrate`) is the exact right shape — typed enum + pattern-match + LLM-fallback + ambient emit — just has zero `CREATE`/`IMPROVE`/`RESCUE`/`COMPREHEND`/`INGEST` variants today | clone the shape, swap the enum, add the missing confidence+confirm step (front-door AC1/AC2, absent from both existing parsers) |
| 3.1 outcome verification | DONE-HERE (live-observation primitive, previously uncited) / NOT-FOUND (the gate) | `src/browser.rs` + `src/browser_tool.rs` (COMP-005b, 741 lines) — wired `browser` tool, `navigate`/`screenshot` actions, gated by `CHUMP_BROWSER_AUTOAPPROVE` | wire browser output against a DoD assertion as a blocking gate — that composition, not new browser capability, is 3.1's real remaining scope |

**Correction to a front-door claim:** `CHUMP_FRONT_DOOR.md`'s reuse map listed "guarded ceremony (INFRA-3516)" as already-shipped. Verified against current main: `INFRA-3516` is still `status: open` (P1) — it's the fix for the 1.3 remediation-path hole above. Corrected in that doc.

**OSS prior-art, narrow patterns only (not framework adoption, per NORTH_STAR "own your tools"):**
- Deploy-to-URL: well-covered (Dokku, e2b, WebContainers/StackBlitz as reference UX).
- Outcome verification against a live URL: **genuinely weak coverage in the wild** — closest match is GUISpector (arXiv 2510.04791, research-stage, not adopted tooling), plus Playwright's MCP-driven browser-agent test tools (production-grade but built for generating test suites, not one-shot judging). Chump would be credibly first-to-solve-well here, not late-to-adopt.
- Intent routing + confirm-back: well-covered (`semantic-router` for embed+threshold classification, Rasa's two-stage-fallback pattern for the confirm/rephrase UX) — clean grafts, small libraries not frameworks.

## 6. Sequencing — REVISED by the discovery (§5.5)

The floor before the ceiling — and most of the floor is *wiring existing code*, not
building. Order:

0. **ES first (the gate):** COTG-S.4 (organs-in-dedup, cheap) + S.1 (sourcing resolver),
   so nothing below rebuilds what exists; S.2/S.3 follow.
1. **The measure, then the floor cluster:** COTG-3.3 (parse the `Chump-Agent` trailer in
   the scoreboard — tiny, and it makes the COTG §4 measure real) → the **`improve.rs`
   floor cluster** 1.1 (thread the FSM) + 1.2 (route edits into `chump-ship`) + 1.6
   (cascade; kill the hardcoded model) — all wiring, and together they fix the exact live
   failure (storm / no-ceremony / wrong-model). Then 1.3 edit-verify (small build) + 1.4
   durable-exec (extend the already-wired checkpoint/resume).
2. **Close the zero-touch loop:** 2.1 intervention-watchdog + 2.2 gate self-heal (finish
   `pr_rescue`'s 2 missing arms) + 2.4 reactive reactions + 2.3/2.5, then the honesty
   watchdogs 3.2 (roadmap tail-rollup) with 3.3 already landed.
3. **Build the greenfield delivery lifecycle (the real construction):** 3.1 live outcome
   verification (the gate) → 5.1 deploy-to-surface → 5.3 hand-off → 5.2 translation →
   6.1 trust panel. *This half does not exist yet.*
4. **Wisdom & stewardship:** 4.1–4.3 (4.4 already done), 6.2 external-tool self-heal, 6.3
   enforced non-enclosure gate.

The COTG gate (§4) is measurable only after 3.1 + 5.1 exist — until there is a *delivered
tool* to verify, a zero-intervention vision→tool run cannot be scored.

## 7. The meta-principle (why this backlog eventually writes itself)

COTG is achieved when the OS runs Epic 2's loop on itself: **every human
intervention is a defect it logs, classes, and closes.** This document is the
first, hand-run pass of that loop. When 2.1 ships, the OS mines its own
interventions the way this backlog mined a session — and the distance to
zero-touch becomes a number the OS drives down on its own. That is what "wired to
be a wise architect" means concretely: not that it never fails, but that every
failure teaches it, and it never needs the same human twice.
