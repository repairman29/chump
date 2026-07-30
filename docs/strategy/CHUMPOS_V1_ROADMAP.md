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
- **The judgment organ is the keystone gap** — nothing checks whether a change satisfies the
  intent, so a do-nothing PR is indistinguishable from delivery.

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

## 5. Workstreams (sequenced — keystone first)

| # | Workstream | First increment | Reuses |
|---|---|---|---|
| **WS1** | **Judgment organ** | extract `check_coverage` → shared lib; add a **ci-stage verify rule** that reads gap AC (`GapStore::get`) + delegates to it; wire it into improve verify-merge so a merge is refused unless AC is covered | `pr_ac_coverage`, `verify/`, `chump-gap-store` |
| **WS2** | **Scoping / decomposition** | AC-writer that emits **gap-specific checkable** AC at reserve (not boilerplate); comprehension-picks-the-files for a scoped task | `gap decompose`, comprehension organs |
| **WS3** | **Self-management janitor** | RESILIENT-208 — dispatch `chump agent-run` to FIX a stuck PR (rebase/clippy/conflict), re-verify via WS1, merge; never close real work | `pr_rescue.rs`, `agent-run`, bot-merge |
| **WS4** | **Deep test harness** | graduated drills curriculum (`chumpbench/drills/`) + real repos + **user stories + mock customers**, every lap graded by WS1's checker | ChumpBench runner, the drills |
| **WS5** | **Delivery last-mile (E5)** | deploy a verified result to a usable surface (URL/app), user-language hand-off | COTG-5.x |
| **WS6** | **Publish V1** | release-auditor gate → the full public release | RELEASE_CHECKLIST, GIVEAWAY_SOP |

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
