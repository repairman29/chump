# OPERATOR HANDOFF — bus-factor mitigation (INFRA-1512)

**Status:** living doc, first cut. Owner: Jeff (current sole operator).
**Why this exists:** the operator is currently the single point of failure
for gap-store mutations, hot-path coordination decisions, the dogfood loop,
and all business decisions. Bus factor = 1. This doc is the mitigation:
enough written context that a trusted co-operator (or Jeff, post-outage) can
reconstruct state and keep the fleet moving without live tribal knowledge.

Related: [`OPERATOR_PLAYBOOK.md`](./OPERATOR_PLAYBOOK.md) (how the fleet
runs day-to-day — read that *first*, this doc covers what it doesn't: who
else can drive, and what to do when the operator is unreachable).
[`OPERATOR_RUNBOOK.md`](./OPERATOR_RUNBOOK.md) (one-time setup procedures).

---

## 1. Current operator's daily routine

Reference routine — see `OPERATOR_PLAYBOOK.md` §"Operator Onboarding" and
§"When to wake the wizard" for the mechanical steps. Summarized here for a
cold-start reader:

- **Daily/session-start:** run the MANDATORY pre-flight block from the top
  of `CLAUDE.md` (fetch, lease check, bootstrap check, auth status, farmer
  status, inbox read, gap list, freshness preamble, mission scoreboard).
- **Weekly (post-wizard-retirement cadence):** review `docs/MISSION.md`
  scoreboard, `chump gap audit-priorities`, pillar balance
  (`chump fleet brief`), and `docs/ROADMAP.md` staleness.
- **Ad hoc, triggered by signal:** respond to operator-recall pages (T1-T4
  halt-class only — see `AGENTS.md` § No-operator-escalation discipline),
  vote on open A2A consensus proposals, unstick wedged PRs the curator fleet
  couldn't self-resolve.
- **What the operator does NOT do:** hand-implement gaps the fleet can pick
  (see CLAUDE.md § Air Traffic Control — the hard line), micromanage
  individual PRs, or approve routine priority/class re-rankings (those route
  through A2A consensus, not operator fiat).

## 2. Critical decisions log

Decisions that shaped current fleet behavior and would be re-litigated by a
new operator without this context. Append new entries chronologically; do
not delete superseded ones — mark them superseded in place.

| Date | Decision | Why | Where documented |
|---|---|---|---|
| 2026-05-30 | No-operator-escalation discipline (T1-T4 only) | Prevent `AskUserQuestion` from becoming a routine decision channel; force team-consensus for non-critical calls | `AGENTS.md` |
| 2026-06-05 | A2A consensus always-on | Proposals dying at `NO_QUORUM` from silent inboxes was fleet failing to coordinate, not fleet being unopinionated | `CLAUDE.md` § A2A consensus |
| 2026-06-05 | "Feed the fleet first" — Agent-tool dispatch reserved for fleet-down / read-only / structurally-unpickable one-shots | In-session Agent dispatches cost ~38 min / 94 ptys / 106k tok each vs. worker loop shipping 85 PRs/24h | `docs/process/SUBAGENT_DISPATCH.md` |
| 2026-07-26 | Balance lever is surface-only, not manufacture — do not file gaps just to refill a "starved" pillar | Instruction to "file 1-2 gaps to refill" caused 146 self-referential gaps and drove the gap-bankruptcy incident (1,214 → 25) | `CLAUDE.md` § Mission Driver |
| 2026-08-10 | ATC (Chief-of-Staff) role: traffic-cop, never do the fleet's job for it | Hand-work by the standing loop makes the machine a more expensive babysitter, not more autonomous | `CLAUDE.md` § Air Traffic Control |
| 2026-08-22 | RIBBON-ONLY FOCUS — all non-ribbon products parked until clean-install hands-off factory ships | Operator decision to concentrate all fleet effort on the single load-bearing outcome | `docs/MISSION.md` § Ribbon-only focus |

**How to keep this current:** any time you make a fleet-wide policy call
that isn't already captured in `CLAUDE.md`/`AGENTS.md`, add a row here in
the same PR.

## 3. Escalation paths

- **T1 (irreversible third-party action), T2 (credential rotation), T3
  (operator-explicit-domain), T4 (halt-class fleet-unsafe):** the only 4
  legitimate triggers for paging the operator. Full definitions:
  `AGENTS.md` § No-operator-escalation discipline.
- **T4 detection is automated:** `scripts/dispatch/operator-recall.sh`
  (skill: `operator-recall`) checks AUTH_DEAD / COST_CAP / CI_BROKEN /
  QUEUE_STARVE and pages via `CHUMP_OPERATOR_RECALL_URL` if configured.
- **If the operator is unreachable and a T4 condition fires:** the
  co-operator (§4) is the fallback pager target. Configure a second contact
  in `CHUMP_OPERATOR_RECALL_URL` (comma-separated or a group alias) so a
  page doesn't silently go to a single inbox.
- **Non-halt-class questions:** route through `scripts/coord/broadcast.sh
  FEEDBACK kind=proposal` for team consensus, not a page to any operator.

## 4. Password / key inventory

**Do not store credentials, tokens, or key material in this repo or in
git history under any circumstances.** The canonical inventory lives in
1Password (or the org's equivalent vault) under a "Chump fleet" vault/tag.
This section documents *what* must be inventoried there, not the values:

- GitHub PATs / GitHub App private keys (`chump-critical`, `chump-background`
  installations — see `OPERATOR_RUNBOOK.md` INFRA-1076)
- `ANTHROPIC_API_KEY` / Claude Code OAuth token source (macOS Keychain entry
  `Claude Code-credentials` — see `CLAUDE.md` § Auth modes)
- `CHUMP_OPERATOR_RECALL_URL` webhook/paging endpoint credentials
- SSH deploy keys (`SSH_KEY_PATH` per `CLAUDE.md` § GitHub credentials for
  agents)
- Any smee.io tunnel / webhook receiver secrets (`docs/process/OPERATOR_PLAYBOOK.md`
  §7.5 Local Infrastructure)
- NATS broker credentials (`CHUMP_NATS_URL`), if the push tier is enabled

**Action item for the operator:** confirm each of the above has a live
1Password entry with the co-operator (§5) granted read access, and that the
entry's notes field links back to the doc section above that explains what
it's for.

## 5. Co-operators

**Status: not yet identified — this is the open item blocking AC #2-4.**

1-2 trusted co-operators (can be paid contractors) need to be identified who
can pick up fleet operation if the primary operator is unreachable for an
extended period. Candidate criteria:

- Comfortable reading `CLAUDE.md` + `AGENTS.md` + `OPERATOR_PLAYBOOK.md`
  cold and operating the curator fleet without live guidance.
- Has (or can be granted) the 1Password vault access from §4.
- Understands the no-operator-escalation discipline well enough to *not*
  over-page during a shadow week.

This section is intentionally left as a placeholder rather than populated
with a guess — operator identity is a business decision outside agent
authority. Once named, record here: name, contact, granted-access date,
scope (full operator vs. specific lane).

## 6. Cross-training plan (paired-week shadowing)

Once a co-operator is identified (§5):

1. **Week 1 — observe.** Co-operator reads `OPERATOR_PLAYBOOK.md` end to
   end, then shadows one full daily routine (§1) live alongside the
   primary operator: pre-flight, inbox triage, A2A vote pass, any T1-T4
   response if one occurs naturally during the week.
2. **Week 1, second half — drive with review.** Co-operator runs the daily
   routine themselves; primary operator reviews decisions after the fact
   (not live-blocking) and adds any gaps found back into this doc.
3. **Exit criteria for "trained":** co-operator has independently run
   pre-flight, triaged at least one operator-recall-class signal (real or
   drilled), and voted on at least 3 A2A consensus proposals without
   primary-operator prompting.

## 7. Failure-mode runbook

What to do if the primary operator is unreachable and a decision can't
wait for the quarterly drill cadence to validate readiness:

1. **Confirm it's actually T1-T4, not routine.** Re-read `AGENTS.md` §
   No-operator-escalation discipline. If it doesn't match one of the 4
   triggers, it can wait or route through A2A consensus instead.
2. **Check the automated detectors first.** `chump fleet doctor`,
   `scripts/dispatch/operator-recall.sh --check-only` — these tell you
   whether the fleet has already self-diagnosed the condition.
3. **If AUTH_DEAD:** see `CLAUDE.md` § Auth modes — verify the OAuth
   refresher daemon (`launchctl list | grep com.chump.oauth-refresh`) and
   fall back to `CHUMP_AUTH_MODE=api-key` with a 1Password-sourced key if
   the subscription path is dead.
4. **If CI_BROKEN / trunk red:** dispatch or invoke the `ci-audit` /
   `shepherd` curator lane (or their skills) rather than hand-fixing —
   see CLAUDE.md § Air Traffic Control for why hand-fixing is the
   anti-pattern here.
5. **If QUEUE_STARVE:** check `docs/ROADMAP.md` for the current outcome
   set before filing new gaps — don't manufacture busywork (§2 2026-07-26
   decision).
6. **If genuinely stuck and no playbook applies:** this is itself a T4
   condition (no-playbook halt-class) — page per §3.
7. **Log the incident.** Whatever the resolution, add a row to §2 if it
   changes future fleet behavior, so the next reader doesn't rediscover it
   live.

## 8. Quarterly bus-factor drill

**Not yet run — first drill pending co-operator identification (§5).**

Cadence: quarterly, once a co-operator exists. Format:

1. Primary operator goes fully unreachable (no Slack, no pages answered)
   for 48h, by prior agreement with the co-operator.
2. Co-operator runs the fleet solo using only this doc + `OPERATOR_PLAYBOOK.md`
   + `AGENTS.md`/`CLAUDE.md` — no live tribal knowledge.
3. Track: any T1-T4 pages that fired, any decision the co-operator was
   unsure how to make, any doc gap discovered.
4. Debrief within 1 week: update this doc (especially §2 and §7) with
   whatever the drill exposed. A drill that changes nothing in this doc
   either means the doc is complete or the drill wasn't stressful enough —
   treat a no-diff drill as a signal to check which.

**Drill log:** (append one row per drill once they start running)

| Date | Co-operator | Duration | Issues found | Doc updates made |
|---|---|---|---|---|
| — | — | — | — | — |
