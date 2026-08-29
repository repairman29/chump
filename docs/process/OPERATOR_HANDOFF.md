# Operator Handoff — bus-factor mitigation (INFRA-1512)

**Purpose:** the fleet's coordination model (A2A consensus, no-operator-escalation
discipline, ATC/Chief-of-Staff role) already keeps day-to-day operation off the
operator's desk. What's *not* yet covered is the SPOF case: Jeff is unreachable
for an extended period (days, not minutes) and someone else — a trusted
co-operator, or Jeff-from-the-future after a long gap — needs to pick the fleet
back up cold. This doc is that pickup point. It is a **pointer document**: each
section links to the canonical source rather than duplicating it, so it can't
drift out of sync the way a standalone copy would.

---

## 1. Daily-routine doc

The operator's actual day-to-day loop is documented in full in
[`docs/process/OPERATOR_PLAYBOOK.md`](./OPERATOR_PLAYBOOK.md) — read that first,
this section is just the pointer + the parts specific to *handoff* framing.

- **Steady state (post wizard-retirement):** weekly cadence — check
  `bash scripts/dev/mission-scoreboard.sh`, skim `chump gap audit-priorities`,
  vote on any open `FEEDBACK kind=proposal` in the operator inbox
  (`scripts/coord/chump-inbox.sh read`). See OPERATOR_PLAYBOOK.md §1 "The
  Hierarchy" for who's doing what without the operator in the loop.
- **Pre-retirement / active-loop days:** the ATC role (`CLAUDE.md` → "Air
  Traffic Control — the Chief-of-Staff role") is the standing loop a
  co-operator would run: scan health (ship-rate, disk, auth, wedges, stuck
  PRs, orphaned leases), revive/unstick, feed the fleet, escalate only
  through the quiet gate. That section is the closest thing to an
  "if you had to run today's loop" script.
- **Session start ritual any operator or co-operator should run:** the
  MANDATORY pre-flight block in `CLAUDE.md` (`git fetch`, lease check,
  `chump-fleet-bootstrap.sh --check`, `auth-status.sh`, `chump farmer status`,
  inbox read, `freshness-preamble.sh`, `mission-scoreboard.sh`).

## 2. Critical decisions log

There is no separate decisions log to keep in sync — operator decisions are
recorded **inline, at the point of use**, tagged `operator decision` (or
`operator-decision-of-record`) with a date, directly in the doc that the
decision governs. This means the log never goes stale relative to the rule it
records.

Pull the current list at any time:

```bash
grep -rn "operator decision" CLAUDE.md AGENTS.md docs/ | sort
```

Load-bearing entries as of this writing (verify against the grep above before
trusting this list — it will drift):

- **Ribbon-only focus** (`docs/MISSION.md`, `CLAUDE.md`, 2026-08-22) — all
  products except the factory ribbon-cut are parked; MISSION-010 is the
  singular focus.
- **Air Traffic Control role** (`CLAUDE.md`, 2026-08-10) — the standing Opus
  loop is Chief-of-Staff, not a worker; "dogfood forevermore."
- **No-operator-escalation discipline** (`AGENTS.md` §"No-operator-escalation
  discipline", 2026-05-30) — team consensus is default; only T1-T4 triggers
  page the operator (see §3 below).
- **A2A consensus always-on** (`CLAUDE.md`, `AGENTS.md`, INFRA-2515,
  2026-06-05) — the coordination layer must never be disabled.

A co-operator picking up cold should read every line the grep above returns —
it's the fastest way to reconstruct *why* the fleet behaves the way it does,
without re-deriving it from first principles.

## 3. Escalation paths

Canonical source: `AGENTS.md` → "No-operator-escalation discipline
(operator-decision-of-record 2026-05-30)". Full text there; summary for
handoff purposes:

**Default channel is team consensus** (`FEEDBACK kind=proposal` →
`chump vote` → deliberator tally), not paging a human. A co-operator stepping
in should *not* expect to be paged for routine decisions — that's by design.

**The only 4 legitimate triggers for operator/co-operator escalation:**

| Code | Trigger |
|------|---------|
| T1 | Irreversible third-party action with no consensus mandate (prod deploy beyond chump, financial spend, external comms to partners/customers/lawyers) |
| T2 | Credential rotation requiring hands-on-keyboard (see §4 below) |
| T3 | Operator-explicit-domain decisions (legal/license, partnership pitches, pricing, public branding) |
| T4 | Halt-class fleet condition where consensus itself is unsafe (trunk-RED + auth-storm + queue-starve simultaneously; deliberator down; broadcast.sh broken) |

**Escalation surfaces a co-operator needs to know about, in priority order:**

1. `scripts/dispatch/operator-recall.sh` — T4 halt-class detector; `--check-only`
   to probe without paging. This is the only automated page path.
2. `scripts/coord/chump-inbox.sh read` — peer DM inbox; broadcasts route here
   before escalating further.
3. Direct contact with Jeff — reserved for T1/T2/T3, i.e. things no amount of
   fleet automation can resolve because they require a human decision or a
   credential only the operator holds.

If none of T1-T4 apply, the correct action is `scripts/coord/broadcast.sh
--to <session-id> FEEDBACK kind=proposal ...`, not a page.

## 4. Password / key inventory

**Do not commit credential values to this repo, ever — not even here.**

Canonical secret storage is **1Password**, not git. This section is a
*pointer/index*, not the inventory itself — if you're a co-operator standing
this up for the first time, get 1Password vault access from Jeff (T2-class:
this itself requires hands-on-keyboard handoff) and expect to find:

- GitHub tokens (`GH_TOKEN` / `GITHUB_TOKEN`) — see `CLAUDE.md` → "GitHub
  credentials for agents (INFRA-AGENT-CREDS)" for the two auth modes
  (implicit keyring vs. explicit env var) this feeds.
- `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` — see `CLAUDE.md` →
  "Auth modes (INFRA-622)"; on macOS the standing refresher daemon
  (`scripts/coord/oauth-token-refresh.sh`, `launchd/com.chump.oauth-refresh.plist`)
  reads the OS keychain, not 1Password directly — but the keychain entry
  itself (`Claude Code-credentials`) is provisioned from a 1Password-held
  credential.
- SSH keys for git push access (`~/.ssh/`).
- Any R2 / object-storage tokens referenced in `docs/process/CANONICAL_SERVICES.md`.
- Cloud/hosting credentials for whatever is currently live for the ribbon
  (check `docs/MISSION.md` for current infra pointers — these change as the
  ribbon target evolves).

**Verifying nothing has leaked into git:** `git log --all -p | grep -iE
'BEGIN (RSA|OPENSSH|PRIVATE)|ghp_|sk-ant-'` before onboarding a new
co-operator to a clone of this repo. If this rule is ever violated, rotation
is mandatory (T2) — don't just delete the commit.

## 5. Failure-mode runbook — operator (SPOF) unreachable

**What keeps running with zero operator input** (by design, per the
no-escalation discipline above): the standing curator loops, A2A consensus
voting, auto-merge on green PRs, the farmer's daemon-revival logic, and
`operator-recall.sh`'s T4 halt-class detection. A short (hours-to-low-days)
operator absence should be invisible to the fleet.

**What degrades or halts, and the co-operator action for each:**

| Failure mode | Symptom | Co-operator action |
|---|---|---|
| T1/T2/T3 decision queued, nobody to answer it | `operator_escalation` events pile up in `ambient.jsonl`; a proposal sits at `NO_QUORUM` past grace window | Triage the queue by trigger code. T3 (business/legal/pricing) genuinely waits for Jeff — don't guess. T2 (credential rotation) needs whoever holds 1Password access — see §4. T1 (irreversible third-party) — hold, do not act unilaterally. |
| Auth exhausted, no rotation available | `auth-status.sh` exits 2; `chump farmer status` RED | This is T2 — needs 1Password access (§4). Without it, new claims stop (`chump claim` / `chump gap reserve` refuse) but the farmer's own recovery still routes around dead workers; nothing is lost, just paused. |
| T4 halt-class condition fires | `operator-recall.sh` pages / `kind=operator_recall` in ambient | Follow `docs/process/SHIP_ASSIST_PLAYBOOK.md` wedge taxonomy; this is the one case built to page even a co-operator automatically. |
| Fleet-scale back-off trigger hit (`CLAUDE.md` → "Fleet scaling gate") | `fleet_wedge`, `silent_agent` cluster, waste rate > 30% | Follow the rollback procedure in that section — kill excess workers, release orphaned leases, log `fleet_scale_change`. No operator judgment call needed, it's mechanical. |
| Nobody present at all for a long stretch (weeks+) | Queue silently drains to zero pickable P0/P1 gaps (`QUEUE_STARVE`, T4) | `operator-recall.sh` catches this after 24h; a co-operator's job is then to re-seed work per `CLAUDE.md` → "Mission Driver" (re-read `docs/ROADMAP.md`, file gaps that trace to a real outcome). |

**First 15 minutes for a co-operator taking over cold:**

```bash
git fetch origin main --quiet && git status
bash scripts/coord/auth-status.sh
chump farmer status
bash scripts/dispatch/operator-recall.sh --check-only
scripts/coord/chump-inbox.sh read --no-advance
bash scripts/dev/mission-scoreboard.sh
chump gap audit-priorities
```

This is the same MANDATORY pre-flight every session already runs
(`CLAUDE.md`) — a co-operator doesn't need a separate onboarding script,
just the standing one, read with fresh eyes.

---

## 6. Co-operator program (tracked, not yet executed)

AC items 2-4 of INFRA-1512 (identify 1-2 trusted co-operators, paired-week
shadowing, quarterly 48h bus-factor drill) are **organizational decisions the
operator makes, not something an agent can unilaterally execute** — per the
T3 trigger above ("operator-explicit-domain decisions"), *who* gets
trusted-co-operator access is squarely Jeff's call, not the fleet's.

This doc makes the mechanism ready (sections 1-5 above are everything a
co-operator needs once named). What's still open, tracked here so it isn't
lost:

- [ ] **Identify 1-2 trusted co-operators.** Candidates + selection are an
  operator decision — not fleet-dispatchable.
- [ ] **Paired-week shadowing.** Once a co-operator is named, schedule a week
  where they run the pre-flight + ATC loop above alongside Jeff.
- [ ] **Quarterly 48h bus-factor drill.** Co-operator runs the fleet solo for
  48h while Jeff is deliberately unreachable; retro afterward feeds back into
  this doc (update whichever section broke first).

Next quarterly drill date and drill retro notes should be appended below this
line once the first co-operator is named:

<!-- drill log — append entries below, do not rewrite history -->
