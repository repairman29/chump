---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Team of Agents — Canonical Multi-Agent Workflow for Chump

Distilled from session 2026-04-19, when 8 sibling agents shipped 7 PRs in
parallel with 0 stranded work and the strategic backlog grew from ~167 gaps
to 215. This document is the playbook for adding more agents safely.

## The contract

Every Chump agent operates under this contract:

1. **One agent, one worktree, one gap, one PR.** No exceptions. If the work
   needs to span multiple gaps, that's multiple agents.
2. **Read the registry first.** `gaps.yaml` is the source of truth for what
   to do. If it isn't gap'd, it doesn't get worked on.
3. **Claim before writing.** `scripts/coord/gap-claim.sh <GAP-ID>` writes a lease
   file. Other agents see the claim instantly and won't collide.
4. **Atomic delivery.** Finish all work in the worktree. One commit (or a
   small handful). One push. PR opens with auto-merge armed. **Never push
   to that branch again.** If a fix is needed, open a new PR via a fresh
   worktree.
5. **Escalate, don't die.** If you get stuck, emit an `ALERT
   kind=escalation` to `ambient.jsonl` so a human can pick up the thread.
   Don't push broken code or time out silently.

These are not aspirations. They are tooling-enforced or documented as gaps
to enforce them shortly.

## The workflow (canonical)

```
                     ┌───────────────────────────┐
                     │   gaps.yaml (registry)    │
                     │  215 entries, append-only │
                     └─────────────┬─────────────┘
                                   │
                                   ▼
              ┌───────────────────────────────────┐
              │   musher dispatch (PR #113 +      │
              │   INFRA-DISPATCH-POLICY filed)    │
              │   picks next gap by priority +    │
              │   dependencies + capacity +       │
              │   affinity                        │
              └─────────────┬─────────────────────┘
                            │ spawn N agents in parallel
                            ▼
              ┌──────────────┬──────────────┬──────────────┐
              ▼              ▼              ▼              ▼
        agent-1 worktree  agent-2 worktree  ...     agent-N worktree
        gap-claim.sh      gap-claim.sh              gap-claim.sh
        (writes lease)    (writes lease)            (writes lease)
              │              │                            │
              │  shared awareness via:                    │
              │   .chump-locks/<sid>.json (lease state)  │
              │   ambient.jsonl (event broadcast)         │
              │   chump-coord NATS (real-time, Phase 1)   │
              │                                            │
        do work in       do work in                do work in
        worktree         worktree                  worktree
        (single push     (single push              (single push
         when done)       when done)                when done)
              │              │                            │
              ▼              ▼                            ▼
        bot-merge.sh     bot-merge.sh              bot-merge.sh
        (rebase + push   (atomic — opens PR        (atomic — opens PR
         + arm           with auto-merge           with auto-merge
         auto-merge)     armed at creation)        armed at creation)
              │              │                            │
              ▼              ▼                            ▼
        code-reviewer    code-reviewer              code-reviewer
        agent reviews    agent reviews              agent reviews
        if src/* PR      if src/* PR                if src/* PR
        (INFRA-AGENT-    (INFRA-AGENT-              (INFRA-AGENT-
         CODEREVIEW)      CODEREVIEW)                CODEREVIEW)
              │              │                            │
              ▼              ▼                            ▼
        GitHub merge queue (INFRA-MERGE-QUEUE filed) serializes
        the auto-merges, rebasing each onto current main atomically.
        Zero "BEHIND" surprises. Zero squash-eats-commits.
              │
              ▼
        stale-pr-reaper.sh (hourly cron, shipped) auto-closes any
        PRs whose gaps somehow landed on main without merging.

        stale-worktree-reaper (INFRA-WORKTREE-REAPER filed) auto-cleans
        worktrees whose branches merged on origin.

        heartbeat-watcher (INFRA-HEARTBEAT-WATCHER filed) restarts
        silent long-running agents from --resume checkpoint.

        cost-ceiling guard (INFRA-COST-CEILING filed) caps per-session
        cloud spend.
```

Jeff's role in this picture: **architecture-decision-gate, NOT merge-gate.**
Auto-merge ships routine work. Code-reviewer agent ships routine src/
changes. Escalations come to Jeff only when an agent is genuinely stuck or
when a substantive architectural call needs a human.

## What's shipped today, what's filed, what's missing

### Shipped (validated by today's session)

- `docs/gaps.yaml` registry (215 entries, append-only convention)
- `scripts/coord/gap-claim.sh` — lease-file mutex for gap-level claims
- `scripts/coord/gap-preflight.sh` — local lease + done-status check, no network
- `scripts/coord/chump-commit.sh` — wrapper that resets cross-agent staging drift
- `scripts/coord/bot-merge.sh` — ship pipeline (rebase, fmt, clippy, test, push,
  open PR, arm auto-merge)
- `scripts/ops/stale-pr-reaper.sh` — hourly cron auto-closes PRs whose gaps
  landed on main
- 5 pre-commit guards (lease-collision, stomp-warn, gaps.yaml discipline,
  gap-ID hijack, cargo-check)
- pre-push hook (gap-preflight gate)
- `chump-coord` crate Phase 1 (NATS atomic gap claims, PR #116)
- musher multi-agent dispatcher (PR #113, basic spawn)
- harvest-synthesis-lessons (PR #125) — reflection accumulation

### Filed in backlog (the team-of-agents infra build-out)

| Gap | What it adds |
|---|---|
| INFRA-MERGE-QUEUE (P1) | GitHub merge queue serializes auto-merges atomically |
| INFRA-PUSH-LOCK (P1) | Pre-push hook blocks pushes to PRs with auto-merge armed |
| INFRA-FILE-LEASE (P2) | Wire up empty `paths` field for file-level mutex |
| INFRA-BOT-MERGE-LOCK (P2) | bot-merge.sh marks shipped; chump-commit.sh refuses commits after |
| INFRA-WORKTREE-REAPER (P3) | Auto-clean worktrees whose branches merged |
| INFRA-WORKTREE-PATH-CASE (P3) | Guard for case-mismatch in worktree paths |
| INFRA-AGENT-ESCALATION (P2) | Formal escalation when agent stuck |
| INFRA-DISPATCH-POLICY (P2) | musher capacity-aware, priority-ordered, dependency-aware |
| INFRA-EXPERIMENT-CHECKPOINT (P3) | Versioned harness state per A/B sweep |
| INFRA-COST-CEILING (P2) | Per-session cloud spend cap |
| **INFRA-AGENT-CODEREVIEW (P1)** | code-reviewer agent in loop for src/* PRs |
| INFRA-HEARTBEAT-WATCHER (P3) | Liveness daemon restarts silent sweeps |
| MEM-006 (P2) | Lessons loaded at agent spawn (closes the learning loop) |
| COMP-014 (P2) | Cost ledger fix (broken across all providers, not just Together) |

Combined, these are roughly **3-4 weeks of focused infra work** to fully
automate the team-of-agents pattern. After that, Jeff intervenes only on
substantive architecture / strategy.

### Productized curator roles (META-097 — shipped/filed/missing)

The role-scoped fleet (META-074, 2026-05-23) introduced five named Opus
curators (target / ci-audit / handoff / shepherd / decompose), one per
hot-file cluster. Each role gets productized as a triplet:

- `.claude/agents/<role>.md` — subagent definition (discipline + lane scope)
- `.claude/skills/<role>/SKILL.md` — user-invocable slash command (thin wrapper)
- `scripts/coord/<role>-loop.sh` — the harness-neutral CLI (capability)

Status table (2026-05-24):

| Role | Agent | Skill | Script | Status |
|---|---|---|---|---|
| target | ✅ shipped | ✅ shipped | ⏳ filed (INFRA-1917) | shipped |
| handoff | ✅ shipped | ✅ shipped | ✅ shipped (INFRA-1922) | **shipped** |
| shepherd | ⏳ filed | ⏳ filed | ⏳ filed | filed |
| ci-audit | ✅ shipped | ✅ shipped | ✅ shipped (INFRA-1923) | **shipped** |
| decompose | ⏳ filed | ⏳ filed | ⏳ filed | filed |
| md-links | ✅ shipped | ✅ shipped | ✅ shipped (INFRA-1925) | **shipped** |

The 5 self-contributed acceptance-criteria per role live at
[`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md).

### Missing (not even gap'd)

- **A "dispatch the Q3 plan" recipe** — would walk RESEARCH_PLAN_2026Q3.md
  Sprint 1 gaps and dispatch them in dependency order. Could be a Recipe
  (COMP-008) once that ships.
- **Cross-agent test-fixture isolation** — when two agents run sweeps
  simultaneously they share `logs/ab/` namespace. Today this is fine
  because tags are unique-per-agent, but at scale needs convention.
- **Cost ledger reconciliation against provider dashboards** — beyond
  COMP-014's "fix the recording", we should periodically reconcile against
  Anthropic's actual billing to catch ledger drift.

## Canonical agent roster — single source of truth

**Last verified: 2026-06-01** (INFRA-1576). This table is the authoritative
list of every agent defined in `.claude/agents/*.md`, plus `shepherd` (a role
with loop scripts but no agent doc yet). It supersedes the two 2026-05-24
snapshots above. Productization pattern (`.claude/README.md`): capability in
`scripts/coord/<role>-loop.sh`, adapters in `.claude/`. Any harness invokes the
loop the same way.

**Legend:** ✅ wired (agent doc + skill + loop CLI) · ◐ partial (some wiring;
gaps remain) · ○ **doc-only** (a dispatchable subagent definition with *no*
skill, loop, cron, or CLAUDE.md/AGENTS.md reference — i.e. shelfware risk).

| Role | Status | Skill | Loop CLI | Notes |
|---|---|---|---|---|
| decompose | ✅ wired | ✅ | `decompose-loop.sh` | gap-slicing (INFRA-1924) |
| target | ✅ wired | ✅ | `target-loop.sh` | demo-target lane (INFRA-1918) |
| ci-audit | ✅ wired | ✅ | `ci-audit-loop.sh` | CI/test-gate (INFRA-1923) |
| handoff | ✅ wired | ✅ | `handoff-loop.sh` | typed-handoff (INFRA-1922) |
| md-links | ✅ wired | ✅ | `md-links-loop.sh` | docs link integrity (INFRA-1925) |
| fresh-eyes | ◐ partial | ✅ | `fresh-eyes-loop.sh` | self-consistency mirror (META-132); roster/ci/bootstrap wiring follow-up |
| external-collab | ◐ partial | ✅ | `external-collab-loop.sh` | not yet in CLAUDE.md/AGENTS.md roster |
| infra-watcher | ◐ partial | ✅ | `infra-watcher-loop.sh` | substrate SRE; not in CLAUDE.md/AGENTS.md |
| observability | ◐ partial | ✅ | `observability-loop.sh` | telemetry tuning; not in CLAUDE.md/TEAM |
| deliberator | ◐ partial | ✅ | `deliberator-loop.sh` | vote tally; not in CLAUDE.md/TEAM |
| harvester | ◐ partial | ✅ | (uses `scripts/arsenal/harvest.sh`) | fleet cartographer; no `*-loop.sh` |
| shepherd | ◐ partial | filed | `opus-shepherd-triage.sh` + siblings | PR rescue; **no `.claude/agents/shepherd.md`** |
| orchestrator | ◐ partial | — | (wizard role, inline) | in AGENTS.md; no skill/loop |
| quartermaster | ○ **doc-only** | — | — | **anti-shelfware role — itself shelfware** (META-205) |
| curator-opus-historian | ○ **doc-only** | — | — | lessons-learned curator (added 05-29) |
| curator-opus-roadmap-keeper | ○ **doc-only** | — | — | roadmap-priority curator (05-29) |
| curator-opus-scout | ○ **doc-only** | — | — | external-repo first-touch (05-29) |
| curator-opus-context-keeper | ○ **doc-only** | — | — | external-repo persistent memory (05-29) |
| curator-opus-architecture-coach | ○ **doc-only** | — | — | arch-fit rating (05-30) |
| curator-opus-incident-commander | ○ **doc-only** | — | — | trunk-red incident coordination (05-30) |
| curator-opus-velocity-tracker | ○ **doc-only** | — | — | velocity-metrics curator (05-30) |

**Shelfware audit (2026-06-01):** 8 of 21 roles are `○ doc-only` — defined as
dispatchable subagents but with no skill, loop, cron, or CLAUDE.md/AGENTS.md
reference. Nothing tells an operator they exist or when to use them, and most
have no executable behind them. Ironically `quartermaster` — the role whose
literal job is to *prevent* shelfware — is one of them, which is why this drift
went uncaught. Each needs a real-vs-speculative call: **wire** it (skill + loop
+ roster, the way `fresh-eyes` was done under META-132) or **prune** it.
Tracked under META-127 (curator-suite umbrella).

**Recurrence guard (filed follow-up):** a CI / pre-commit check that every
`.claude/agents/*.md` appears in this roster — so shelfware-by-omission becomes
mechanically impossible, the same closed-loop discipline as the event-registry
coverage gate. INFERRED AC sources for the wired roles live in
[`../process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md).

## Anti-patterns (learned the hard way)

| Anti-pattern | Cost when it happens | Mitigation |
|---|---|---|
| Auto-merge on a PR you keep pushing to | PR #52 lost 11 commits | INFRA-PUSH-LOCK + atomic-PR discipline |
| Direct push to main | Broke Cargo.lock twice (per strategic memo) | Branch protection + INFRA-MERGE-QUEUE |
| `--no-verify` to bypass guards | Half the duplicate-work incidents per memo | Guards that auto-fix instead of fail-loud where possible |
| Silent agent failure | EVAL-026 in-flight queue cascade-died on Together DNS outage | Hardened retry to 7 attempts at 2-128s + INFRA-HEARTBEAT-WATCHER |
| Manual squash-merge as the bottleneck | Today: Jeff watching every PR | INFRA-MERGE-QUEUE + INFRA-AGENT-CODEREVIEW |
| Worktrees accumulating | 9 stale today, manually cleaned 9→2 | INFRA-WORKTREE-REAPER |
| cwd drift in Bash sessions | Files written to wrong path multiple times today | Always `cd /full/path && ...` in commands |

## Five rules (the short version)

1. **Every unit of work is a gap entry with acceptance criteria.** If it
   isn't gap'd, it doesn't get done.
2. **Worktree per gap, branch per worktree, PR per branch.** Three-layer
   isolation. Auto-reaper handles cleanup.
3. **Atomic PR.** One push, never touched again. Auto-merge fires safely.
4. **Code-reviewer agent gates src/* changes.** Routine code ships
   automatically; substantive code escalates.
5. **Eval-driven sequencing.** Every fix has a measurement. Every
   measurement opens the next gap.

## How to add yourself as a new agent

1. Open the right Chump worktree:
   ```bash
   cd /Users/jeffadkins/Projects/Chump
   git fetch origin main --quiet
   git worktree add .claude/worktrees/<your-codename> -b claude/<your-codename> origin/main
   cd .claude/worktrees/<your-codename>
   ```
2. Read the mandatory pre-flight (per CLAUDE.md):
   ```bash
   ls .chump-locks/*.json 2>/dev/null
   tail -30 .chump-locks/ambient.jsonl
   grep -A3 "status: open" docs/gaps.yaml | head -40
   ```
3. Pick a gap that matches your priority + skill, ideally with no unresolved
   `depends_on` entries:
   ```bash
   scripts/coord/gap-preflight.sh <GAP-ID>
   scripts/coord/gap-claim.sh <GAP-ID>
   ```
4. Do the work. Test it. Lint it. Read the gap's acceptance criteria
   carefully — meet them all.
5. Ship via bot-merge.sh:
   ```bash
   scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
   ```
6. **Stop pushing to the branch.** If a fix is needed, open a new gap or
   amend the existing gap entry as a separate PR.

That's the canonical workflow. Today, it requires some manual gluing
because INFRA-MERGE-QUEUE / INFRA-AGENT-CODEREVIEW / INFRA-PUSH-LOCK aren't
shipped yet. After they ship, the workflow is fully automated above the
"do the work" step.

## Cross-references

- `CLAUDE.md` — session rules (every agent reads this on startup)
- `docs/process/AGENT_COORDINATION.md` — full coordination system spec
- `docs/research/RESEARCH_PLAN_2026Q3.md` — what we're building this quarter
- `docs/STRATEGY_VS_GOOSE.md` — competitive positioning
- `docs/architecture/CHUMP_FACULTY_MAP.md` — what's tested vs untested
- `docs/blog/2026-XX-2000-trials-on-a-local-agent.md` — public narrative
- `docs/gaps.yaml` — the registry (read-only for inspiration; append-only
  for new gaps)
