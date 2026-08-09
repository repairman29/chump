# RFC — the ship gate: point the consensus machine at the decision we make forty times a day

**Status:** Draft — decisions marked ⬜ are the operator's
**Date:** 2026-08-09
**Related:** [RFC-agent-governance.md](RFC-agent-governance.md), `crates/chump-coord/src/consensus.rs`, `.claude/agents/deliberator.md`, RELEASE_CHECKLIST.md (the release-auditor gate), RESILIENT-256 / RESILIENT-267 (the reaper incidents this is written from)

## Problem

Chump has a fleet consensus machine. It is not a sketch — `crates/chump-coord/src/consensus.rs`
models `Vote{Approve, Abort, Timeout}`, `ConsensusDecision{Proceed, Abort, Inconclusive}`,
`ConsensusRecord::finalize`, and carries tests named `quorum_loss_is_inconclusive` and
`timeout_doesnt_count_toward_quorum`. Someone thought carefully about how voting fails.

It has a tally curator. `.claude/agents/deliberator.md` reads accumulated `kind=vote`
events, emits `kind=consensus_result`, and **escalates NO_QUORUM to the operator after a
24h grace window**. The human-in-the-loop path is built and wired.

It has twenty advisors under `.claude/agents/` — `fresh-eyes`, `ci-audit`,
`curator-opus-historian`, `curator-opus-architecture-coach`, `quartermaster`,
`observability`, and the rest.

**`DecisionType` has four variants: `EscalationRequired`, `ResourceCritical`,
`NetworkPartitionRecovery`, `FleetScaleChange`. None of them is "should this ship."**

So the fleet can hold a vote about scaling itself, and cannot hold one about the decision
it makes several dozen times a day. The one advisor that *is* a mandatory gate — the
release-auditor, per CLAUDE.md, "no exceptions" — fires at **release**, which is the
moment a NO-GO is most expensive and least actionable.

Operator's diagnosis, 2026-08-09: *"the advisors lack a chain — this is where the votes
should come — along the way we should be passing these spiritual gates."*

That is the whole problem in one sentence. Twenty advisors, all pull-based, none
sequenced into the path work actually travels.

## What went wrong on 2026-08-09 (the evidence base)

This RFC is written from a single session that produced five instances. None was a
judgement call. **Every one was a false factual assertion that read well.**

| what shipped | the claim | the truth |
|---|---|---|
| chump#3532 comment | "`shared-key: ci-audit` … NOTHING EVER WROTE … **verified** against the live cache list" | five such caches existed, 207MB each, restoring in 11-13s. The claim came from reading 8 of 16 entries. |
| stale-worktree-reaper | `reason: "branch merged into origin/main"` | the branch had **zero commits** and had never merged anything. Deleted a live worktree 35 min after creation, twice in one hour. |
| holler `schema.sql` | `security_invoker = true` | production had it **false** for four days; the entire inbox was publicly readable. The repo file said the right thing the whole time. |
| this session's CI monitor | "ALL GREEN" | the run had not started. Zero pending was read as settled. |
| RESILIENT-267 | cited gap ID `RESILIENT-263` in seven places | that ID belongs to an unrelated gap. The number was invented, not reserved. |

Two more from the same day are shape-identical: a `plutil`-valid plist naming a binary a
reaper had deleted (curator, dead 12 days, both log files empty), and `olive/emit.ts`
never checking `res.ok` — four call sites, zero rows ever written, nothing logged.

**The common shape is not bad judgement. It is an unchecked assertion presented with a
receipt.** A `file:line` citation, a "verified", a green check. Each made the claim *more*
believable, not less.

## Proposal

### 1. Votes are per-CLAIM, not per-PR

The advisor's job is not taste. It is **claim verification**: extract every factual
assertion from the diff, the commit body and the PR description, and check each one.

`"NOTHING EVER WROTE this cache key"` is checkable in one command. So is
`"security_invoker = true"`, and `"the branch merged"`, and `"all checks green"`. A
reviewer with taste would have approved all five of the above. A reviewer required to
*run the claim* would have failed all five.

This also makes the gate mechanical enough to be worth automating, which "is this a good
change" never is.

### 2. A vote without a receipt does not count

This is the load-bearing rule and the one most likely to be dropped.

On 2026-08-09 four different agents — including the one writing this — asserted false
things with complete conviction. **A vote among confidently-wrong advisors is louder
wrongness, not better judgement.** Three of them would have approved #3532's comment,
because it read well.

So: an `Approve` must cite the command it ran and that command's output, in the same
shape the gap-reserve evidence gate already demands (COMMAND, OUTPUT, THEORY, ALT). A
receipt-less vote is treated exactly as `Vote::Timeout` already is — **it does not count
toward quorum**. That behaviour exists in the machine today and needs no new code.

### 3. Quorum scales with irreversibility, not with size

A doc typo needs no vote. A one-line change to a reaper that deletes worktrees needs
three skeptics, because that exact change already cost 574 unrecoverable lines.

Proposed tiers ⬜ (operator sets the thresholds):

| tier | examples | quorum |
|---|---|---|
| trivial | docs, comments, test-only | none — existing gates suffice |
| ordinary | feature code, non-destructive scripts | 1 receipt-bearing advisor |
| destructive | anything that deletes, reaps, force-pushes, rewrites history, or writes user-scope config | 3, and `Inconclusive` blocks |
| outward | anything a stranger will see | release-auditor as today, unchanged |

`ConsensusDecision::Inconclusive` → deliberator → operator after 24h is the existing
escalation and needs no new path.

### 4. The gates go ALONG the path, not at the end

Four checkpoints, each with prior art and each with a 2026-08-09 miss:

| gate | question | what it would have caught |
|---|---|---|
| **reserve** | is this already in the bank? | RESILIENT-099 was `status=done` and described the reaper bug exactly. A duplicate was filed anyway. |
| **claim** | is anyone already touching these files? | #3532 and #3534 edited `audit.yml` simultaneously. `almanac_prs --touching` now answers this in one call. |
| **pre-merge** | does every claim in this PR hold? | the "verified" that wasn't |
| **post-merge** | did the promised effect actually happen? | EFFECTIVE-420 owed a measured receipt; it exists only because someone went back for it unprompted |

The post-merge gate is the one with no prior art at all, and it is where "we shipped it"
silently becomes "it worked."

## Cheapest first move

**Do not build a fifth thing. Connect four built things.**

1. Add `DecisionType::ShipDecision { pr: u64, tier: Tier }` to `consensus.rs`
2. Have `bot-merge` request a vote before arming, for the `destructive` tier only
3. Reuse the deliberator's tally and its NO_QUORUM → operator escalation unchanged
4. Point three existing advisors at it — `fresh-eyes`, `ci-audit`, `curator-opus-historian`
   — with the receipt rule as their discipline

Scope it to the destructive tier first. That is where the day's real damage happened, it
is a small fraction of PRs, and it makes the blast radius of a bad gate small.

## What this must not become

**A rubber stamp.** If advisors approve without receipts, this adds latency and a false
sense of safety — strictly worse than no gate, because a green vote is itself a claim
that will then be trusted. The receipt rule is not decoration; without it, do not ship
this.

**A merge-rate tax.** Audit's floor is already 284s per PR after a 40% improvement
(EFFECTIVE-420). If the ship gate adds minutes to every merge it will be bypassed within
a week, and the bypass will become the path. Destructive-tier-only keeps it off the
common path.

**Another confidently-wrong check.** The day this RFC documents also produced: a reaper
that named zero conflict files while correctly detecting a conflict, a `--sort` that tied
and silently discarded the newest work, and `yaml.safe_load` accepting a workflow GitHub
rejects. A ship gate that reports "no objections" when it has not actually looked would
be the largest instance of the very pattern it exists to stop. **It must distinguish
"checked and clean" from "did not check" in its output, every time.**

## Decisions for the operator

⬜ Tier thresholds — is 3 the right quorum for destructive, or 2?
⬜ Does `Inconclusive` block the merge, or only annotate it?
⬜ Which three advisors sit on the destructive panel?
⬜ Post-merge verification: build it now, or land the pre-merge gate first and measure?
⬜ Should a receipt-less `Approve` be silently discarded (as `Timeout` is today), or
   reported back to the advisor as a rejected vote? The second is louder and slower.

## Open questions

- Where do votes live? `kind=vote` in ambient is the existing convention, but PR-scoped
  votes may want to be PR comments so the receipt is visible to a human reading GitHub.
- How does this interact with the merge queue? A vote that resolves after the queue has
  moved on is worse than no vote.
- Advisors are LLM agents and will sometimes fabricate a receipt. The tier-3 panel should
  disagree by construction — different lenses, not three runs of the same prompt — which
  is the pattern the adversarial-verify workflows already use.
