# Operator Handoff — bus-factor mitigation (INFRA-1512)

**Problem:** Jeff (Owner/Founder, `docs/process/ROLE_REGISTRY.md` "Board /
Chairman" row) is the current single point of failure for gap-store
mutations, hot-path coordination calls, the dogfood loop, and every business
decision. Bus factor = 1. This doc is the mitigation: what a co-operator
needs to know to run the fleet if Jeff is unreachable, and the plan to get
a real second operator in place rather than just a document.

This is a **living runbook**, not a one-time artifact — update it whenever
the daily routine, escalation paths, or credential locations change.

---

## 1. Current operator's daily routine

A co-operator picking this up cold should expect the following cadence
(see `docs/process/OPERATOR_PLAYBOOK.md` for the full fleet architecture):

- **Session start (any cadence, daily-to-weekly today):**
  - `bash scripts/coord/freshness-preamble.sh` — is the checkout fresh?
  - `bash scripts/dev/mission-scoreboard.sh` — did yesterday move the
    Scoreboard in `docs/MISSION.md`? If not, that's the first thing to
    diagnose, not a new gap to file.
  - `chump fleet doctor` / `scripts/coord/fleet-doctor-strict.sh` — 7
    health invariants, exits non-zero if anything is broken.
  - `scripts/coord/chump-inbox.sh read --no-advance` — peer DMs and
    proposals waiting on a vote (`chump vote <corr_id> +1|-1|0 --reason`).
- **Ongoing (while present):** triage stuck PRs (shepherd lane), keep the
  P0 budget ≤ 5 (`chump gap audit-priorities`), route routine decisions
  through `FEEDBACK kind=proposal` consensus rather than deciding
  unilaterally (`AGENTS.md` → No-operator-escalation discipline).
  Everything else is delegated to curator/orchestrator sessions per
  `docs/process/OPERATOR_PLAYBOOK.md` §1 — the operator's job is strategy
  and unblocking, not doing curator work by hand.
- **Weekly:** re-read `docs/ROADMAP.md`, check pillar balance
  (`chump fleet brief`), rate surprising gap outcomes
  (`chump gap rate <ID> <1-5>`).

## 2. Critical decisions log

Decisions that require operator judgment (not delegable to a curator vote)
and where the precedent lives:

| Decision class | Where the call gets made | Precedent / doc |
|---|---|---|
| Mission focus (what "done" means) | `docs/MISSION.md` | Ribbon-only focus, 2026-08-22 |
| Fleet scale-up/down | `docs/process/CLAUDE_GOTCHAS.md` scale gate, or this file's §5 | `docs/syntheses/fleet-scaling-2026-05-06.md` |
| Priority/class re-ranking | A2A consensus proposal, never unilateral | "A2A consensus is always-on", CLAUDE.md |
| Halt-class fleet-unsafe (T4) | Operator page via `scripts/dispatch/operator-recall.sh` | `AGENTS.md` No-operator-escalation |
| License / partnership calls | external-collab curator drafts, operator decides | `curator-opus-external-collab` lane |
| CLAUDE.md / AGENTS.md doctrine edits | Operator authority only | see curator lane boundaries throughout `.claude/agents/*.md` |

If a co-operator hits a decision not in this table, default to **the
quiet gate**: broadcast `FEEDBACK kind=proposal` and let consensus decide,
rather than guessing at what Jeff would do.

## 3. Escalation paths

- **T1–T4 triggers** (irreversible third-party action, credential
  rotation, operator-explicit-domain, halt-class fleet-unsafe) are the
  *only* legitimate reasons to interrupt the operator — see `AGENTS.md` →
  No-operator-escalation discipline. Everything else routes through A2A
  consensus (`scripts/coord/broadcast.sh --to <session> WARN "..."`).
- **Halt-class detection:** `scripts/dispatch/operator-recall.sh
  --check-only` (AUTH_DEAD / COST_CAP / CI_BROKEN / QUEUE_STARVE). This is
  the mechanical trigger for "page the human" — a co-operator should run
  this before deciding an outage is bad enough to page Jeff.
- **If Jeff is unreachable and a T1–T4 condition fires:** the co-operator
  *is* the escalation path for that window (see §5 drill). Act using the
  same authority Jeff would — this doc plus `docs/process/ROLE_REGISTRY.md`
  define the scope of that authority; don't improvise new doctrine.

## 4. Password / key inventory

**Credentials are never stored in this repo.** This section is a pointer,
not an inventory — actual secrets live in 1Password / macOS Keychain per
`docs/process/CHUMP_FLEET_BOT_SETUP.md` and `docs/process/ADD_A_FLEET_NODE.md`.

| Credential | Location | Notes |
|---|---|---|
| GitHub PAT (`chump-fleet-bot`) | 1Password vault item "chump-fleet-bot" (or macOS Keychain `chump-fleet-bot-pat`) | `docs/process/CHUMP_FLEET_BOT_SETUP.md` |
| Claude Code OAuth token | macOS Keychain `Claude Code-credentials`, refreshed by `com.chump.oauth-refresh` launchd job | `CLAUDE.md` → Auth modes |
| `ANTHROPIC_API_KEY` | 1Password, injected via env at session start | `CLAUDE.md` → Auth modes |
| SSH keys for fleet nodes | Operator's `~/.ssh/`, authorized per-box | `docs/process/ADD_A_FLEET_NODE.md` |
| Any partnership / license credentials | 1Password, external-collab lane | `curator-opus-external-collab` |

A co-operator needs a 1Password vault invite (read access to the relevant
items above) and an authorized SSH key on the fleet boxes **before** a bus
event, not during one — provisioning happens as part of §5 shadowing, not
as an emergency step.

## 5. Failure-mode runbook

If the operator is unreachable:

1. Run `scripts/dispatch/operator-recall.sh --check-only` — confirm
   whether a halt-class condition is actually active (don't act on a
   detector firing alone; see `docs/process/SHEPHERD_LOOP_PLAYBOOK.md`
   Pattern 14, verify-before-alarm).
2. If nothing halt-class is active: the fleet is designed to run
   unattended (`docs/process/OPERATOR_PLAYBOOK.md` — curators + workers
   keep shipping without operator presence). Do nothing beyond normal
   co-operator monitoring.
3. If something T1-T4-class is active: the co-operator acts using §2/§3
   above as the decision frame, and logs the decision + rationale to
   `ambient.jsonl` (`kind=operator_handoff_action`) so Jeff has a full
   record on return. Do not silently make the call.
4. On Jeff's return: co-operator walks Jeff through every decision made
   during the window, using the ambient log as the receipt.

---

## Co-operator program (AC 2–4)

This doc alone does not fix bus factor 1 — a document nobody has read
under pressure is not mitigation. The remaining acceptance criteria are a
program, not a one-shot task:

- **AC2 — identify 1-2 trusted co-operators.** Open operator decision, not
  something the fleet can pick for itself (hiring/trust is a T3
  operator-explicit-domain call). Tracked as a follow-up: candidates
  should have prior exposure to the codebase (contractor or existing
  curator-adjacent contributor) and be willing to commit to the shadow
  week in AC3. **Status: not yet identified — this is the actual
  blocking step**, everything below depends on it.
- **AC3 — paired-week shadowing.** Once a candidate is identified: one
  calendar week where the co-operator runs the daily routine in §1
  alongside Jeff, reviews at least one real decision from the §2 table
  live, and gets provisioned per §4 (1Password vault invite + SSH key)
  during the week, not after.
- **AC4 — quarterly bus-factor drill.** Once AC2/AC3 are done: co-operator
  runs the fleet solo for 48h while Jeff is deliberately unreachable
  (phone off, no Slack). Success criteria: no T1-T4 event mishandled, no
  unattended halt-class condition left unactioned >1h, and a written
  retro comparing what the co-operator did against what this doc says to
  do — feeding back into this file's edits. First drill should be
  scheduled as soon as AC3 completes; cadence thereafter is quarterly.

**Why this gap ships as a doc-only PR:** AC2-4 require real humans
(identifying, scheduling, and running a 48h drill with a person) that no
amount of code changes this session. The doc capturing routine +
decisions + escalation + credential pointers is the load-bearing
prerequisite — a co-operator can't shadow effectively without it. AC2-4
are called out explicitly above as the next concrete steps rather than
left implicit, so this isn't just a paper mitigation.
