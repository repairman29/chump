# Wizard Strategic Backlog

**Purpose.** Durable surface for "what should the wizard do during loop slack?"
Each `/loop` iter has ~60–300s of wait between PR-pulse cycles. Without a
backlog, that time leaks into chat-text strategy or low-leverage polish.
This file is the ranked work-list the wizard pulls from when pulse returns
HEALTHY or "waiting on curators."

**Discipline.**
1. At each loop iter where pulse is HEALTHY or curators have ack-pending dispatches, read this file's top item.
2. If the top item has a concrete next-action ≤3 commands, execute it.
3. After ship: cross off the item, append any new items discovered.
4. Operator can `git log -p docs/process/WIZARD_STRATEGIC_BACKLOG.md --since=8h` to see what strategic work landed this session.

**Filed under** META-095 (the doc itself), part of the Ring-3 wizard-retirement program (META-090 endpoint).

---

## Section 1 — HIGHEST: Retirement work (ends the wizard role)

These ship → the wizard becomes redundant. Highest leverage by definition.

### [active] INFRA-1898 — pulse consumer daemon
- **Leverage.** Tails `ambient.jsonl` for `kind=pr_oversight_snapshot verdict=WEDGED|SATURATED`; auto-DMs the lane curator; auto-pages operator only on operator-recall conditions. Replaces ~half of the wizard's pulse-and-dispatch work.
- **Next action.**
  - `chump claim INFRA-1898` → worktree
  - Write `scripts/coord/pulse-consumer.sh` (tail-follow ambient.jsonl, regex match, broadcast.sh DM lane-owner per verdict)
  - Write `scripts/ci/test-pulse-consumer.sh` (synth ambient line → assert broadcast sent within N s)
- **Done.** Daemon installed via launchd, smoke green, fires DM on synthetic WEDGED event within 30s.

### META-088 — Oracle refresh cron
- **Leverage.** 4-hourly Opus burst that re-contemplates `docs/process/THE_PATH.md` against current state.db; writes fresh ranked program. Removes the wizard's manual re-ranking job.
- **Next action.**
  - `chump claim META-088` → worktree
  - Write `scripts/coord/oracle-refresh.sh` (calls Opus via cascade with the THE_PATH.md template + current `chump gap list --status open --json` digest)
  - Install launchd plist `setup/install-oracle-refresh-launchd.sh`
- **Done.** Cron fires every 4h; appends `kind=oracle_refresh` to ambient with new program hash; THE_PATH.md updated.

### META-090 — chump fleet autopilot (umbrella endpoint)
- **Leverage.** Single CLI: `chump fleet autopilot` runs the full operator playbook as one daemon set (pulse + dispatch + rescue + rank + repeat). When this lands, wizard role is *operator-optional*.
- **Blocked-on.** INFRA-1880 (CHUMP_SESSION_ID auto-export), INFRA-1898 (pulse consumer), META-088 (Oracle refresh). Don't start scaffolding until ≥2 of those land.
- **Next action.** Wait. Track unblock progress.

---

## Section 2 — HIGH: Command durability (4th-ring artifacts)

Captures discipline so future wizard sessions don't repeat mistakes.

### Promote `/tmp/take-both-resolve.py` → `scripts/dev/take-both-resolve.py`
- **Leverage.** Recurring tool — used twice today to mass-rescue 7 PRs. Currently lives only in `/tmp`, dies with the shell. Needs to be a checked-in script with a smoke test.
- **Next action.**
  - Worktree + `scripts/dev/take-both-resolve.py` (copy with proper shebang + docstring)
  - `scripts/ci/test-take-both-resolver.sh` (synthetic conflict file → assert markers stripped, both sides kept)
  - Document in `scripts/dev/README.md` under "Mass-rescue helpers"
- **Done.** Tool in repo, smoke green, OPERATOR_PLAYBOOK.md references it as the canonical take-both pattern.

### OPERATOR_PLAYBOOK.md — append "Curator-disengagement antipattern" section
- **Leverage.** Today's catch (operator: "you're letting them off the hook") needs to be captured as a durable warning. Without it, the next wizard session starts the same hoarding pattern.
- **Next action.**
  - Worktree + append §"Anti-pattern: Wizard hoards work from curators" to docs/process/OPERATOR_PLAYBOOK.md
  - Include: the symptom (curator inbox stays empty), the cause (solo-rescue faster than dispatch), the fix (consistent DISPATCH format → re-ping → re-ping → escalate; never absorb back)
- **Done.** Section merged.

### 6 curator-lane briefs (1 per role)
- **Leverage.** Fresh curator sessions currently need wizard hand-holding to know their lane (target = EFFECTIVE, handoff = ZERO-WASTE preflight, etc.). 6 short docs (≤30 lines each) would let curators self-orient in 30s.
- **Next action.** Worktree + `docs/process/CURATOR_LANE_BRIEFS/{target,handoff,ci-audit,shepherd,decompose,md-links}.md` — each with: pillar focus, typical gap patterns, escalation matrix, link to OPERATOR_PLAYBOOK §command-pattern.
- **Done.** 6 files in repo, INFRA-1908 curator-wake helper prints the brief path in its bootstrap template.

---

## Section 3 — MEDIUM: Preventer gaps + PM hygiene (Ring 1 ship)

### Pillar inventory check (per-iter)
- **Leverage.** META-046 PM hat. If a pillar drops below 2 pickable, file 1-2 refill gaps. Today: ZERO-WASTE=9 in pickable pool (last fleet brief) — healthy.
- **Next action.** `chump gap list --status open --json | jq` group-by-pillar; if any < 2, file refill gaps.
- **Done.** Every pillar has ≥2 pickable gaps; no pillar > 50% of pool.

### Gap registry audit (per-session)
- **Leverage.** `chump gap audit-priorities` catches P0 inflation, vague AC, stale-P0, ghost references. Prevents waste before it ships.
- **Next action.** `chump gap audit-priorities --json` → if non-zero exit, fix the surfaced issues.
- **Done.** Audit exits 0.

### File preventer follow-up for INFRA-1916
- **Leverage.** Today's keystone (INFRA-1916) noted in its AC: "Follow-up gap to migrate test-pillar-dashboard.sh off the legacy element." That follow-up isn't filed yet. Without it, the hidden-widget hack persists indefinitely.
- **Next action.** `chump gap reserve --domain INFRA --title "ZERO-WASTE: migrate test-pillar-dashboard.sh §4 off legacy <chump-pillar-health> element to status-footer pillar-grades slot — removes the INFRA-1916 hidden-widget hack"`
- **Done.** Gap filed with AC.

---

## Section 4 — LOW / SKIP

Explicit anti-list. If tempted, stop.

- ❌ **Solo-rescuing curator-assigned PRs.** 4th-ring violation. Re-ping instead.
- ❌ **Filing gaps without concrete AC.** Operator's pet peeve; gap becomes unpickable.
- ❌ **Cleanup-batch PRs.** Ship-and-stitch rule. Atomic only.
- ❌ **Yet-another-fleet-meta gap when fleet is healthy.** Planet-vs-pebble.
- ❌ **Long prose docs the operator won't read.** This file is intentionally bullet-dense.
- ❌ **Re-running pulse mid-cron-cycle.** Cron does it. Pulse is cheap but the cumulative GraphQL load matters.
- ❌ **Polishing formatting / re-reading just-read files.** Pure waste.

---

## Changelog

- 2026-05-24 14:55Z — META-095 filed; initial 4-section structure with 9 items.
