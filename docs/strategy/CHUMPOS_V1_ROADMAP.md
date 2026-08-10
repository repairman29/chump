---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
---

# ChumpOS V1 — delivery roadmap (DOC-074)

> **Plan of record** for shipping a publishable ChumpOS V1. Sibling of
> [COTG_READINESS_BACKLOG.md](./COTG_READINESS_BACKLOG.md) (the North Star),
> [CHUMP_FRONT_DOOR.md](./CHUMP_FRONT_DOOR.md) (how it meets work), and
> [CHUMPBENCH.md](./CHUMPBENCH.md) (the proving ground).
> **Filed:** 2026-07-29. Driven by a self-paced delivery loop. Go slow to go fast.

## 1. What V1 is (one sentence)

**A scoped vision becomes a verified, delivered tool with minimal human touches — reliably,
on a bounded class of work, and publishable.** Not "anyone with any vision" (that's the COTG
North Star). V1 is the first version where the loop *closes* and we can *count* it.

## 2. What we learned the hard way (the honest state this roadmap answers)

- **The hands are built** — reliability floor (typed FSM, deterministic ceremony, edit-verify,
  durable resume), self-heal, provenance stamp, ChumpBench proving ground. Real, merged.
- **Capability is scope-bound, not skill-bound** — the drills proved it: chump writes *real
  code* when the task is precise + scoped (nailed the coloringbook wire-up at 2 and 20 files);
  it drowns on vague-prompt + huge-repo; and it **cannot self-verify** (shipped a buggy test
  three times, reporting "done as requested"). The coloringbook run opened a clean, trailered,
  zero-touch PR that delivered **nothing** (a 4-line stub) and passed "verify."
- **The judgment organ now has a working intent lens (2026-08-03).** The spirit judge
  (CREDIBLE-192) asks *"does this change GENUINELY achieve the intent?"* — grounded by the
  acceptance result + fuller intent so it stops false-STUB-ing real fixes (CREDIBLE-195), and
  diffing the lap's actual commit range not `base…HEAD` so it isn't blind on --implement laps
  (CREDIBLE-194). A do-nothing PR is **no longer** indistinguishable from delivery: the
  coloringbook-style 4-line stub would now score STUB, not "verify." Advisory today (shown,
  not gated); the keystone is landing it as a gate (CREDIBLE-191 panel).
- **The integrity layer is now proven (2026-08-02).** A live rescue lap *false-greened and
  pushed junk to a real repo's main*; that caught, reverted, and drove a hardening pass that is
  merged and demonstrated live: honest, check-specific acceptance (CREDIBLE-186 — can't
  false-green), PR-green scoring + a pre-merge gate (EFFECTIVE-350 — can't pollute main),
  comprehension-before-action (EFFECTIVE-349 — the agent gets the real failure log), and a
  deterministic, self-contained rescue track (CREDIBLE-187). Full-suite heat: **5/6 green,
  100% zero-touch**; the one miss was a python-3.14 harness bug, not a capability failure.
- **The judge is trustworthy and the reliability instrument is live + a first fix is proven
  (2026-08-03).** Beyond the integrity layer: the spirit judge now *sees* --implement laps
  (CREDIBLE-194) and *judges them correctly* (CREDIBLE-195, proven STUB→GENUINE on a genuine
  fix). The bench captures the agent-run's effort — `tool_calls` + `hit_iteration_cap` in the
  scorecard (CREDIBLE-190) — so agent-loop flails are legible, not hidden behind wall-clock.
  First reliability fix, measured: a STOP-WHEN-DONE nudge on the --implement prompt flipped
  `hit_iteration_cap` true→false, `tool_calls` 30→7, wall-clock **1909s→288s (~6.6×)**, with
  correctness held (EFFECTIVE-352). *Position: honest V1, entering V1.5.*
- **The self-improving loop is real as primitives, not yet proven as one closed loop.** Intake,
  run, classify-failure, decompose, provision-tools, escalate, budget/page all exist — scattered
  across ~8 files. The drills prove *run job → succeed*; they do **not** yet prove *job exceeds
  capability → adapt or stop cleanly*. That is the V1.5 → V2 bridge (§4b).

## 3. Discovery: the judgment organ is mostly BUILT (wire + strengthen, don't reinvent)

A discovery pass (9-agent workflow, 2026-07-29) found the pieces already exist:
- **`src/pr_ac_coverage.rs`** (`chump pr ac-coverage`, INFRA-1541) — `check_coverage(bullet,
  diff, commit_text)` grades each acceptance-criterion against the diff; already wired into CI
  via `scripts/ci/test-ac-coverage-gate.sh`.
- **`src/verify/` engine** (CREDIBLE-155) — a new gate rule is 3 edits; `VerifyContext` already
  carries `gap_id` + parsed diff + commit message; runs at pre-commit/commit-msg/**ci** stages.
- **`GapStore::get(gap_id).acceptance_criteria`** — AC text is fetchable in-process.

**So the coloringbook stub passed because the improve loop's verify-merge never calls the
AC-coverage gate, and the repo had no CI.** The keystone is: **wire AC-coverage into the
improve/merge gate, harden it from heuristic → real judge, and make AC-writing gap-specific**
(today `chump gap reserve` emits generic boilerplate, not checkable AC).

## 4. V1 acceptance — publishes only when all six are true

1. **Judgment** — no unverified change merges; the AC-checker gates every merge on the delivery
   path (not just CI). A stub cannot pass.
2. **Precision** — tasks are scoped small + precise: comprehension picks the files, decomposition
   sizes them, AC is gap-specific + checkable.
3. **Clean house** — Chump keeps its *own* main clean: PRs auto-rebased, verified, merged fast;
   stuck ones **fixed, not closed**.
4. **Proven deep** — the test harness shows verified delivery with a *falling* human-touches-per-
   lap across the ladder: **drills → real repos → user stories → mock customers.**
5. **Delivered** — ≥1 real **vision → tool → in someone's hands** lap completes (E5).
6. **Honest** — measured by the zero-touch metric + ChumpBench scorecard; every claim carries a
   receipt.

## 4b. The self-improving job loop + the version ladder (the architecture V1 acceptance rolls up into)

> Shareable map (flow chart + honest real/partial/missing status + ladder + branch-proving
> tracks): **[ChumpOS — The Self-Improving Job Loop](https://claude.ai/code/artifact/d08efb63-24ca-48e9-abc3-d85d729c75a1)**.
> Grounded against the codebase 2026-08-02, not memory.

**The loop (what the whole OS is built to be).** Give ChumpOS a job → run it on a repo → if it
can't succeed, adapt (decompose the work / acquire a missing capability / escalate) → and when a
budget expires, park and page a human. Mapped to what runs today:

| Stage | Real component | Status |
|---|---|---|
| Job intake | `execute_gap.rs`, `improve::run`, gaps in `state.db` | **real** |
| Run & succeed? | `drive_task_directed` + honest acceptance (hardened this session) | **real** |
| Classify failure | `failure_catalog.rs` | partial |
| Decompose → retry | `auto_decompose_if_complex`, `chump gap decompose` | partial |
| Acquire capability → retry | `ensure_provisioned` — installs *known* CLIs only | **weakest** (self-extending is aspirational) |
| Escalate / page human | `hitl_escalation.rs`, `operator-recall.sh`, T1–T4 | partial |
| Act on human input | A2A consensus (`chump vote`), `intervention_watchdog` | partial |
| Pause / move fleet at scale | INFRA-518 scale gate + back-off triggers | runbook, not an API |

**The version ladder — the proving progression** (realness synthetic→real, difficulty easy→open,
autonomy verified→gated→hands-off). This sits *over* the capability phases (0–5) in
[`docs/ROADMAP.md`](../ROADMAP.md): it says how we *know* a phase is real.

| Rung | Done means | Metric |
|---|---|---|
| **V1** — honest machinery | runs a drill hands-off, scores it truthfully, ships safely | ✅ 5/6 heat green, 100% zero-touch (2026-08-02) |
| **V1.5** — reliable + every branch fires | full suite green ×3 consecutive heats **and** each loop branch proven to fire | 3× consecutive full-suite green + 4 branch-proving tracks pass — 🔜 **in progress (2026-08-03)**: judge trustworthy (192/194/195), reliability instrument live (190) + first fix proven ~6.6× (352); still need the 3× green streak + the 4 branch-proving tracks (decompose scoped: CREDIBLE-196) |
| **V2** — real work, human-gated | real problems in your repos; real fixes; human approves before landing | 5 real deliverables, human-approved, honestly scored |
| **V2.5** — real work, autonomous landing | lands real fixes hands-off (the MISSION-010 dream) | N autonomous real merges that *survive* |
| **V3 / COTG** | a non-technical person's vision → a finished honest tool in their hands | 1 real person · 1 real tool · shipped & used |

**The four architecture questions (settle before building resource-heavy) → V2 contracts:**
(1) *how a job is given* → a job-intake schema; (2) *how/when humans are paged* → explicit
budget→page thresholds, each testable; (3) *how we act on human input* → a pause→inject→resume
path that provably changes the job; (4) *pause/move the fleet at scale* → a real control-plane
API, not the INFRA-518 runbook.

## 5. Workstreams (sequenced — keystone first)

| # | Workstream | First increment | Reuses |
|---|---|---|---|
| **WS1** | **Judgment organ** | extract `check_coverage` → shared lib; add a **ci-stage verify rule** that reads gap AC (`GapStore::get`) + delegates to it; wire it into improve verify-merge so a merge is refused unless AC is covered | `pr_ac_coverage`, `verify/`, `chump-gap-store` |
| **WS2** | **Scoping / decomposition** | AC-writer that emits **gap-specific checkable** AC at reserve (not boilerplate); comprehension-picks-the-files for a scoped task | `gap decompose`, comprehension organs |
| **WS3** | **Self-management janitor** | RESILIENT-208 — dispatch `chump agent-run` to FIX a stuck PR (rebase/clippy/conflict), re-verify via WS1, merge; never close real work | `pr_rescue.rs`, `agent-run`, bot-merge |
| **WS4** | **Deep test harness** | graduated drills curriculum (`chumpbench/drills/`) + real repos + **user stories + mock customers**, every lap graded by WS1's checker. **V1.5 bridge: 4 branch-proving tracks** that deliberately exceed the agent so each loop branch (§4b) is forced to fire deterministically — `too-hard→decompose`, `missing-tool→acquire`, `impossible→escalate`, `budget→page` (assert sub-jobs / capability-acquired / clean-escalation-no-storm / operator-paged-at-threshold) | ChumpBench runner, the drills, `seed_break` |
| **WS5** | **Delivery last-mile (E5)** | deploy a verified result to a usable surface (URL/app), user-language hand-off | COTG-5.x |
| **WS6** | **Publish V1** | release-auditor gate → the full public release | RELEASE_CHECKLIST, GIVEAWAY_SOP |

**Bucket-GO line (CREDIBLE-206).** RELEASE_CHECKLIST's release-auditor gate
must read [`docs/VENDOR_LEDGER.md`](../VENDOR_LEDGER.md) before any surface
enters WS6 — every free/trial dependency the surface touches needs a
VERIFIED (not assumed) at-limit-behavior row in that ledger. A surface with
an ASSUMED row is not bucket-GO.

**Throughout:** productize relentlessly (each friction becomes a tool) and **dogfood** even more
relentlessly (run `chump preflight`, ship via `bot-merge.sh`, no `--no-verify` / gate bypass —
we cannot ask the OS to be reliable while routing around its reliability).

## 6. How it's driven

A self-paced delivery **loop**: every cycle produces exactly **one small, green, shippable
increment**, dogfooded through the real pipeline, keeps the PR queue on main + clean, and reports
with receipts. Small + green + fast is not a nicety — a moving trunk punishes big, slow PRs
(hard-won this session). Build order follows §5: judgment organ first, because it is what makes
scaling agents *safe* instead of a stub factory.

**The one number that means "V1 is real": human-touches-per-verified-lap, trending to zero,
across drills → real repos → mock customers.** Not CI-green. Not a merged PR. A tool that
does what was asked, delivered, with no one having to reach in.
