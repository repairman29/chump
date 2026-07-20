## Issue #21 — 2026-07-20

> Audit window: commits since 2026-07-13 (Issue #20). **39 non-cold-water commits** to `origin/main` (PRs #3160–#3224). Sandbox: fresh remote clone, chump binary build **failed** (timeout; proposed-only mode — SQLite verification of filed gaps skipped). Evidence from git log, `.chump/state.sql` (tracked versioned dump), `mcp__github__list_pull_requests`, and bash scripts. Bypass rate: **23/39 (59%) — worst ever for a high-volume cycle.** Open PRs: 1 (down from 9 in Issue #20). `wip/` branches: 390 (up from 324 in Issue #19). Critical new finding: **state.sql is 21 days stale** and missing entire domains (CREDIBLE, MISSION, RESILIENT, EFFECTIVE, ZERO-WASTE) — promoted as "canonical versioned dump" by ZERO-WASTE-020 two days ago. **Audit methodology self-correction: EVAL-094 and FLEET-053 were not in state.sql as open gaps; 10 cycles of "STILL_OPEN_INACTIVE" findings for EVAL-094 were based on the now-retired YAML store, not the canonical DB.** 4 follow-up gaps proposed (gap-reserve unavailable in sandbox — operator must file manually).

---

### Status of Prior Issues (Issue #20)

- **FIXED**: CREDIBLE-128 — AGPL relicense completed. 22 straggler MIT crates flipped, INFRA-1506 closed, LICENSE_STRATEGY.md updated, follow-up gaps INFRA-3336 (crates.io republish) and INFRA-3337 (legal review) filed.
  ```
  git log origin/main --grep='CREDIBLE-128' --oneline | grep -v cold-water
  3948c8b fix(CREDIBLE-128): complete AGPL relicense — 22 straggler MIT crates flipped, governance loop closed (#3192)
  ```

- **FIXED**: RESILIENT-169 (prior cycle: stranded PRs → sleep/wake recovery) — lid-close recovery shipped PR #3204.
  ```
  git log origin/main --grep='RESILIENT-169' --oneline | grep -v cold-water
  5e21371 feat(RESILIENT-169): sleep/wake recovery — lid-close becomes a pause, not a multi-day outage (#3204)
  ```

- **FIXED**: RESILIENT-168 (wip-branch accumulation / integrator daemon dead) — daemon revived PR #3203.
  ```
  git log origin/main --grep='RESILIENT-168' --oneline | grep -v cold-water
  6e95620 fix(RESILIENT-168): revive integrator + merge-queue daemons (#3203)
  ```
  NOTE: wip/ branch count is still growing (324→390) because the reaper creates branches but the cleanup code does not exist. Daemon health ≠ branch cleanup.

- **FIXED**: Stranded PR graveyard. 9 open PRs → 1 open PR. This is the most significant improvement across all 21 issues. The RESILIENT-160 dyld_start root cause was subsumed by the "Revival & Truth" batch which cleaned the queue via INFRA-1909 (ghost-gap reaper phase 2), CREDIBLE-154, and RESILIENT-100.

- **FIXED**: INFRA-1526 (ghost gap driving 3 duplicate PRs) — implemented via PRs #3173 and #3174 (post-rebase hunk-drop detector).
  ```
  git log origin/main --grep='INFRA-1526' --oneline | grep -v cold-water
  01fa17c fix(INFRA-1526): post-rebase hunk-drop detector + pr-auto-rebase integration (#3174)
  0af4665 fix(INFRA-1526): replace -X theirs with hunk-drop guard in wedge-recover STEP 2 (#3173)
  ```

- **METHODOLOGY CORRECTION**: EVAL-094 — **was NOT open for 10 cycles.** state.sql (canonical store) shows `status: done, closed_date: 2026-05-03, closed_pr: 909`. All prior cold-water findings tracking EVAL-094 as STILL_OPEN_INACTIVE relied on the YAML file store, which was not synchronized with state.db. The YAML store has been retired by ZERO-WASTE-020 (PR #3215, 2026-07-19). The prior finding stands on different grounds: EVAL-094's 5 acceptance criteria require a preregistration doc (`docs/eval/preregistered/EVAL-094.md`, NOT FOUND), results doc (`docs/eval/EVAL-094-results.md`, NOT FOUND), and RESEARCH_INTEGRITY.md entry (absent) — the gap appears closed without AC evidence. See Lens 4.
  ```
  # state.sql entry for EVAL-094:
  # status: done, closed_date: '2026-05-03', closed_pr: 909
  # docs/eval/preregistered/EVAL-094.md → NOT FOUND
  # docs/eval/EVAL-094-results.md → NOT FOUND
  ```

- **METHODOLOGY CORRECTION**: FLEET-053 — **NOT IN state.sql.** Cannot verify prior "open/inactive" finding from canonical store. Insufficient evidence to carry forward.

- **STILL_OPEN_INACTIVE (4 cycles)**: MISSION-043 — **NOT IN state.sql.** This gap was filed by cold-water in Issue #17 directly to YAML. YAML was never imported into state.db. YAML is now retired. MISSION-043 effectively does not exist in the canonical store. The mission failure it tracked (0 BEAST-MODE merges) is real; the gap is a ghost.
  ```
  git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
  (empty — 4 cycles, 0 impl commits; gap not in canonical store)
  ```

- **UNCHANGED (methodology)**: MISSION-010/011/012/014 ghost gaps. docs/MISSION.md cites these as "canonical mission gap IDs" and "active mission pointer." None exist in state.sql:
  ```
  python3 -c "
  c=open('.chump/state.sql').read()
  for g in ['MISSION-010','MISSION-011','MISSION-012','MISSION-014']:
      print(g, 'IN' if f'- id: {g}' in c else 'NOT IN', 'state.sql')
  "
  MISSION-010 NOT IN state.sql
  MISSION-011 NOT IN state.sql
  MISSION-012 NOT IN state.sql
  MISSION-014 NOT IN state.sql
  ```

- **WORSE (different vector)**: Bypass rate — **23/39 (59%)** this cycle. Prior two cycles were 0/6 and 0/9. The return to high-volume shipping exposed that bot-merge is structurally broken: RESILIENT-100 (re-entrancy fix) addressed only 1 of ≥6 active failure classes. See Lens 1.

- **BETTER**: P0 count trajectory unclear. state.sql shows only 6 P0s (all SWARM-*). But state.sql doesn't include CREDIBLE/MISSION/RESILIENT/EFFECTIVE domains where most P0s lived in the YAML era. The ROADMAP.md "Revival & Truth" cycle lists 4 P0s (RESILIENT-168, RESILIENT-169, EFFECTIVE-305, CREDIBLE-151) — all absent from state.sql. P0 count is unverifiable from state.sql alone; operator's state.db is the only source.

- **STILL_OPEN (prior cold-water-filed, NOT IN state.sql)**: CREDIBLE-126, RESILIENT-167, RESILIENT-160, EFFECTIVE-293, CREDIBLE-127, META-064 — all filed to YAML in prior cycles, never imported to state.db, YAML now retired. These gaps effectively do not exist in the canonical store. The conditions they tracked may persist but cannot be verified against the gap registry.

- **NO_GAP filed/proposed this cycle**: CREDIBLE-156 (state.sql staleness), CREDIBLE-157 (EVAL-094 premature closure), RESILIENT-170 (wip/ branch cleanup), META-128 (bot-merge bypass failure class census) — see Proposed Gaps below.

---

### The Looming Ghost

**[P0/High] G1 — state.sql (canonical versioned gap dump) is 21 days stale and missing entire domains; ZERO-WASTE-020 promoted it as "the tracked versioned dump" on 2026-07-19 while it contained no CREDIBLE/MISSION/RESILIENT/EFFECTIVE entries and maxed out at INFRA-501, yet commit messages this cycle reference INFRA-3298**

We are failing at the one thing ZERO-WASTE-020 promised: a canonical, git-tracked representation of the gap registry. PR #3215 retired 1625 YAML files (the only human-readable, approximately-current view) and designated `.chump/state.sql` as the tracked replacement. But state.sql:

- Was last committed on **2026-06-29** (21 days before ZERO-WASTE-020 landed on 2026-07-19)
- Contains **no gaps in CREDIBLE, MISSION, RESILIENT, EFFECTIVE, or ZERO-WASTE domains** — every gap the fleet's own docs reference for fleet health tracking is invisible
- Tops out at **INFRA-501**; this cycle's commits reference INFRA-3298 (a delta of at least 2,797 unreflected gap IDs)
- Lists the ROADMAP.md's 4 current P0s (RESILIENT-168, RESILIENT-169, EFFECTIVE-305, CREDIBLE-151) as **not present** — they don't appear in the dump at all

```bash
git log --format='%ai' -- .chump/state.sql | head -1
2026-06-29 23:50:19 +0000   ← last committed; ZERO-WASTE-020 landed 2026-07-19

python3 -c "
import re
c=open('.chump/state.sql').read()
ids=re.findall(r'^- id: INFRA-(\d+)', c, re.M)
print('INFRA max:', max(int(x) for x in ids))
" 
INFRA max: 501   ← current commits reference INFRA-3298

# Domains absent from state.sql:
for d in CREDIBLE MISSION RESILIENT EFFECTIVE; do
  python3 -c "import re; c=open('.chump/state.sql').read(); print('$d:', len(re.findall(r'^- id: $d-', c, re.M)), 'gaps')"
done
CREDIBLE: 0 gaps
MISSION: 0 gaps
RESILIENT: 0 gaps
EFFECTIVE: 0 gaps
```

The consequence: any remote agent, CI system, or cold-water audit that reads state.sql (as instructed by the docs/gaps/README.md tombstone) sees a 3-week-old registry with no tracking for fleet health, mission, or resilience gaps. The promise of a canonical versioned dump is currently void.

- evidence 1: `git log --format='%ai' -- .chump/state.sql | head -1` → `2026-06-29` (21 days before ZERO-WASTE-020)
- evidence 2: `python3 -c "import re; c=open('.chump/state.sql').read(); ids=re.findall(r'^- id: INFRA-(\d+)', c, re.M); print(max(int(x) for x in ids))"` → `501`; commits reference INFRA-3298
- evidence 3: All 4 ROADMAP.md P0 gaps (RESILIENT-168, RESILIENT-169, EFFECTIVE-305, CREDIBLE-151) absent from state.sql

*This finding is wrong if: state.sql is deliberately a partial export (e.g., only historical gaps before a cutoff date, with newer gaps tracked elsewhere). The docs/gaps/README.md tombstone states it is "the tracked, versioned dump of state.db" with no partial-export caveat.*

---

### The Opportunity Cost

**[P1/High] O1 — MISSION scoreboard ① = NO for 11th consecutive audit cycle; MISSION-010/011/012/014 ghost gaps; 39-commit cycle produced 0 BEAST-MODE-advancing commits**

We are failing to advance the mission for the eleventh consecutive audit cycle. 39 commits landed this cycle — the highest volume in this audit's history. Zero advanced the external-repo merge pipeline.

```bash
git log origin/main --since="2026-07-13" --format='%s' | grep -iv "cold-water" | \
  grep -iE "BEAST|MISSION-01[0-4]"
(empty — 0 BEAST-advancing commits)

# docs/MISSION.md scoreboard (current):
grep "today:" docs/MISSION.md
- **① THE BINARY (weekly):** Did Chump merge a zero-human-touch PR in
  BEAST-MODE this week? — *today: **NO**.*

# MISSION-010 (canonical mission gap) in state.sql:
python3 -c "c=open('.chump/state.sql').read(); print('MISSION-010 IN state.sql:', '- id: MISSION-010' in c)"
MISSION-010 IN state.sql: False
```

The ROADMAP.md's "Revival & Truth" cycle (2026-07-19 → 2026-08-16) schedules BEAST-MODE proof for Week 3 (2026-08-02). That is the right commitment. The failure this cycle is that 39 commits improved the substrate — `chumpd`, sleep/wake recovery, ChumpBar, off-laptop prep — while the scoreboard result is identical to the prior 10 cycles. Motion ≠ progress (docs/MISSION.md §Doctrine, first bullet).

- evidence 1: `git log origin/main --since="2026-07-13" --format='%s' | grep -iE "BEAST|mission-01"` → empty
- evidence 2: `grep "today:" docs/MISSION.md` → "today: **NO**" (11th consecutive NO)
- evidence 3: MISSION-010/011/012/014 not in state.sql — the mission tracking infrastructure has no canonical backing

*This finding is wrong if: BEAST-MODE PRs merged via a path not captured in repairman29/chump git log (e.g., direct push to repairman29/BEAST-MODE not visible from this sandbox). The mission-scoreboard.sh fetches BEAST-MODE directly; without gh CLI in sandbox the scoreboard cannot run, but the chump/main log has no BEAST-advancing commits.*

---

**[P2/Medium] O2 — INFRA-1909 (ghost-gap reaper phase 2) calls `chump gap ship --update-yaml` which ZERO-WASTE-020 (landed same day) made a documented no-op; the auto-reconciler's ship path silently skips the YAML step it depends on**

We are failing to sequence same-day PRs that interact. INFRA-1909 (PR #3208, landed 2026-07-19T16:04Z) added auto-reconciliation via `chump gap ship --update-yaml`. ZERO-WASTE-020 (PR #3215, landed 2026-07-19T20:17Z) deprecated `--update-yaml` as a no-op. The reaper's ship path now silently succeeds without writing a YAML file — which was its stated mechanism for marking gaps done externally.

```bash
git show a69adab --format="%B" | grep "update-yaml"
auto-runs `chump gap ship --closed-pr N --update-yaml` when one is found

git show 9f82fdf --format="%B" | grep "update-yaml"
`chump gap ship --update-yaml` (now a documented no-op)
```

The db update still fires; only the YAML step is skipped. Functional for current state but the commit body's rationale for the YAML call is now false.

- evidence 1: INFRA-1909 commit (a69adab) body cites `--update-yaml` as the mechanism
- evidence 2: ZERO-WASTE-020 commit (9f82fdf) body states `--update-yaml` is "now a documented no-op"
- evidence 3: Both PRs landed 2026-07-19, INFRA-1909 4h before ZERO-WASTE-020

*This finding is wrong if: the db-only path (without YAML write) was already the correct behavior before ZERO-WASTE-020 and the YAML flag was already a no-op for db updates. The ZERO-WASTE-020 body says "the per-file YAML write call sites" were removed from `gap ship`, implying the db write remains. If so, INFRA-1909's reaper ship is correct and the commit body's YAML mention is stale comment only.*

---

### The Complexity Trap

**[P1/High] C1 — Bot-merge bypass rate: 23/39 (59%) — worst ever for a high-volume cycle; 6 distinct failure classes identified; RESILIENT-100 addresses only 1; 5 remain active**

We are failing to merge our own work through our own tooling even as we fix that tooling. 23 of 39 non-cold-water commits carried `Bot-Merge-Bypass:` trailers this cycle. The failure classes per bypass trailer text:

```
Class A — chump binary wedge (INFRA-275): 6 occurrences
  "chump binary re-wedged 3x", "chump binary wedged (re-wedges after unwedge)"
  → NOT addressed by RESILIENT-100

Class B — CREDIBLE-154 worktree-db enqueue bug: 5 occurrences  
  "manual PR fallback per CREDIBLE-154 notes"
  → NOT addressed by RESILIENT-100 (CREDIBLE-154 fix landed as PR #3206 but worktree-db phantom-ship may persist)

Class C — claim-reconciliation 900s stall / NATS conflict: 2 occurrences
  "hung 900s in claim-reconciliation", "stalled/hung 4 consecutive times at rebase/claim"
  → NOT addressed by RESILIENT-100

Class D — session-ID mismatch (INFRA-1970): 1 occurrence
  "self-blocks on its own valid claim (INFRA-1970 guard doesn't recognize CHUMP_SESSION_ID at preflight)"
  → NOT addressed by RESILIENT-100

Class E — parent process silent death: 1 occurrence
  "bot-merge.sh's parent process died silently"
  → NOT addressed by RESILIENT-100

Class F — hot-file self-deadlock (RESILIENT-100): addressed by PR #3222
  "make hot_file_lock_acquire idempotent" — this PR itself shipped via Bot-Merge-Bypass (Class C stall)

git log origin/main --since="2026-07-13" --grep="RESILIENT-100" --oneline | grep -v cold-water
37ad6c7 fix(RESILIENT-100): bot-merge hot-file-lock re-entrant-safe + bounded wait (#3222)
# This fix's own commit carried Bot-Merge-Bypass (Class C, 900s stall)
```

The fleet is using the manual fallback path as the DEFAULT ship path. When the bypass rate exceeds 50%, the "bypass" is not an escape hatch — it is the operational normal. This cycle's 39 commits are evidence of a functional fleet, but they were built on a shipping pipeline that bypassed its own safety gates 59% of the time.

- evidence 1: `git log origin/main --since="2026-07-13" --format='COMMIT%n%b' | grep -c "Bot-Merge-Bypass:"` → 23
- evidence 2: Bypass reason taxonomy: 6 classes identified, 5 without any fix in this cycle
- evidence 3: RESILIENT-100's own commit shipped via Bot-Merge-Bypass (Class C) — the fix for bot-merge bypassed bot-merge

*This finding is wrong if: the bypass count is inflated by counting the cold-water commit or automated commits. The grep excluded `cold-water`; the count of 23 is confirmed against the 39-commit total.*

---

**[P2/Medium] C2 — wip/ stash branches grew from 324 → 390 (+66) despite RESILIENT-168 fix; stale-worktree-reaper still has no cleanup code**

We are failing to stop the wip/ branch accumulation. RESILIENT-168 was fixed (daemon revived, PR #3203). But the fix restored the daemon's ability to create wip/ stash branches on worktree reap — not the cleanup of those branches. The reaper creates them and never deletes them:

```bash
git ls-remote --heads origin | grep "refs/heads/wip/" | wc -l
390   ← was 324 in Issue #19 (+66 in 2 cycles)

git ls-remote --heads origin | wc -l
473   ← total branches; 390/473 = 82% are wip/ stash branches

grep -n "git push.*delete\|git push origin :.*wip\|prune.*wip" \
  scripts/ops/stale-worktree-reaper.sh
(empty — no cleanup code, same as Issue #19)
```

- evidence 1: `git ls-remote --heads origin | grep 'refs/heads/wip/' | wc -l` → 390 (was 324)
- evidence 2: `grep "delete.*wip\|wip.*prune" scripts/ops/stale-worktree-reaper.sh` → empty
- evidence 3: RESILIENT-168 fix commit (6e95620) body: no mention of branch cleanup

*This finding is wrong if: a separate cron or daemon prunes wip/ branches outside stale-worktree-reaper.sh. No such script found in `scripts/` search.*

---

### The Reality Check

**[P1/High] R1 — EVAL-094 closed in state.sql without AC evidence; preregistration doc, results doc, and RESEARCH_INTEGRITY.md entry all absent; 10 prior cycles of cold-water "STILL_OPEN_INACTIVE" were tracking a closed gap via a stale YAML store**

We are failing at gap closure integrity on the most important open methodology question. EVAL-094's 5 acceptance criteria require concrete artifacts that do not exist:

```bash
ls docs/eval/preregistered/EVAL-094.md
ls: cannot access 'docs/eval/preregistered/EVAL-094.md': No such file or directory
# AC2: "Preregistration doc at docs/eval/preregistered/EVAL-094.md committed before data collection" — NOT MET

ls docs/eval/EVAL-094-results.md
ls: cannot access 'docs/eval/EVAL-094-results.md': No such file or directory  
# AC4: "Wilson CI results committed to docs/eval/EVAL-094-results.md" — NOT MET

grep "EVAL-094" docs/strategy/RESEARCH_INTEGRITY.md
(no output)
# AC5: "Validated findings table in RESEARCH_INTEGRITY.md updated with result" — NOT MET

# state.sql shows:
# status: done, closed_date: '2026-05-03', closed_pr: 909
# opened_date: '2026-05-02' → closed 1 day after filing
```

There are two possible explanations: (a) PR #909 satisfied all 5 ACs and the artifact files were later deleted (no evidence of deletion found); or (b) EVAL-094 was closed prematurely without AC satisfaction. The absence of three required artifact files in the current repo favors (b). The underlying research question — whether model behavior differs under naturalized vs. evaluation framing — remains unanswered. This affects RESEARCH_INTEGRITY.md's standing claim about mechanism analysis.

The self-correction this audit owes: the prior 10 cycles of "EVAL-094 STILL_OPEN_INACTIVE" were wrong — the gap was closed. The substance of the concern (missing experiment artifacts) is real but should have been tracked as a different gap.

- evidence 1: `ls docs/eval/preregistered/EVAL-094.md` → not found; AC2 explicitly requires this file
- evidence 2: `ls docs/eval/EVAL-094-results.md` → not found; AC4 explicitly requires this file
- evidence 3: `grep "EVAL-094" docs/strategy/RESEARCH_INTEGRITY.md` → no output; AC5 requires update there

*This finding is wrong if: PR #909's tree contained these files and they were deliberately removed in a subsequent PR. `git log -- docs/eval/preregistered/EVAL-094.md` would confirm. Sandbox git history starts after PR #3000-range; full history not available.*

---

**[P2/Medium] R2 — MISSION-010 scoreboard reads "today: NO" in docs/MISSION.md but the scripted scoreboard (scripts/dev/mission-scoreboard.sh) requires gh CLI and machine-local state.db — neither available in sandbox or CI; any remote agent reading MISSION.md gets a hardcoded stale value**

We are failing to make the mission scoreboard machine-readable in a non-interactive context. docs/MISSION.md contains the literal string "today: **NO**" as a hardcoded value in the markdown. The actual scoreboard runs `scripts/dev/mission-scoreboard.sh` which requires gh CLI and live state.db. Any agent, CI check, or remote audit that reads MISSION.md gets the value from whenever the file was last hand-updated — not the current state.

```bash
grep "today:" docs/MISSION.md
- **① THE BINARY (weekly):** Did Chump merge a zero-human-touch PR in
  BEAST-MODE this week? — *today: **NO**.*

# Last commit to docs/MISSION.md:
git log --follow -1 --format='%ai %s' -- docs/MISSION.md
# (whatever the last commit was — the value is static unless manually updated)
```

- evidence 1: `grep "today:" docs/MISSION.md` → hardcoded "NO" (static, not computed)
- evidence 2: `scripts/dev/mission-scoreboard.sh` requires gh CLI (absent in sandbox and CI)
- evidence 3: MISSION.md §Doctrine: "The conductor's job is the Scoreboard, not busy-ness" — but the scoreboard can only be read by an interactive session with gh CLI

*This finding is wrong if: the scoreboard is updated automatically on each commit via a hook or workflow. No such hook found in `.github/workflows/` or `.git/hooks/`.*

---

### The Innovation Lag

**[P1/Medium] I1 — 39 commits; 0 advance the external-repo pipeline; ROADMAP Week 3 targets "BEAST-MODE proof" for 2026-08-02 — 13 days; no external-repo infrastructure exists to support it**

We are failing to build toward Week 3 while building Week 1. The "Revival & Truth" ROADMAP is well-scoped: Week 1 revive substrate, Week 2 registry truth, Week 3 BEAST-MODE proof. Week 1 shipped well. Week 3 requires `chump onboard --schedule` (INFRA-2268) and per-org key vault (INFRA-2269). Both absent from state.sql. Neither has any commits in the past 30 days:

```bash
git log origin/main --grep="INFRA-2268\|INFRA-2269" --oneline
(empty — 0 commits)

# Week 3 deadline: 2026-08-02 (13 days from today)
# BEAST-MODE merge requires: external-repo auth, overnight loop, PR-creation in foreign repo
# None of this infrastructure shipped in the 39 commits this cycle
```

The GROUND_UP_2026-07-19.md design doc (shipped PR #3205) is architecturally correct. The risk is that the "one supervisor owns everything" architecture (chumpd v0 shipped PR #3211) is Week 1 work that creates Week 3 prerequisites — but chumpd has no external-repo dispatch path yet.

External context: `chump onboard` already exists (referenced in CLAUDE.md §Bootstrap). The missing piece for BEAST-MODE proof is scheduled overnight runs and per-repo authentication, not the fundamental architecture. Week 3 is achievable if INFRA-2268/2269 are claimed immediately. If the Week 1 substrate work continues into Week 2 instead, the 2026-08-02 deadline slips and the scoreboard reads NO for cycle 12.

*This finding is wrong if: INFRA-2268 and INFRA-2269 are in the operator's state.db as in-progress gaps with active claims. state.sql (the only registry available in sandbox) doesn't reflect this.*

---

**THE ONE BIG THING:** [P0] We are failing to maintain a versioned, canonical, remote-readable gap registry. ZERO-WASTE-020 (PR #3215, 2026-07-19) made the correct architectural decision — retire 1625 YAML files and rely on `.chump/state.sql` as the git-tracked versioned dump. But state.sql was last committed 21 days before ZERO-WASTE-020 landed. The dump doesn't contain CREDIBLE, MISSION, RESILIENT, or EFFECTIVE domains. Every gap the fleet uses to track its own health — and every gap filed by prior cold-water cycles — is absent from the canonical dump. Any agent, CI system, or audit that reads state.sql (as the tombstone now instructs) sees a 3-week-old registry with no fleet-health tracking. The prior 10 cold-water cycles' findings about EVAL-094 and FLEET-053 were all based on the YAML store, which turned out to be out of sync with state.db in the opposite direction (state.db had those gaps closed while YAML showed them open). The fix for this is a single `chump gap dump` run committed to state.sql — but that command requires the chump binary and a live state.db, neither of which is available in a remote sandbox. The state.sql staleness makes the gap registry effectively unauditable by any agent without direct machine access. Gap to file: CREDIBLE-156 (see Proposed Follow-up Gaps).

---

### Proposed Follow-up Gaps (gap-reserve unavailable in sandbox — file manually)

`chump gap reserve` failed (chump binary build timed out). Operator must file these via `chump gap reserve --domain X --title '...'` on the local machine with state.db available. Use state.sql format for the YAML body; state.sql is no longer the filing path.

**CREDIBLE-156** — `CREDIBLE: state.sql versioned dump 21 days stale after ZERO-WASTE-020; entire fleet-health domains (CREDIBLE/MISSION/RESILIENT/EFFECTIVE) absent from canonical git-tracked dump`
- Priority: P0 | Effort: xs
- AC: (1) `chump gap dump` run committed to state.sql contains CREDIBLE-* entries; (2) gap domains in state.sql match gap domains referenced in the most recent 50 commits to main; (3) a launchd cron or pre-push hook ensures state.sql is updated before every push that modifies state.db
- Evidence: `git log --format='%ai' -- .chump/state.sql | head -1` → 2026-06-29; `python3 -c "c=open('.chump/state.sql').read(); print(c.count('- id: CREDIBLE-'))"` → 0; ROADMAP P0s absent from state.sql
- Falsifying condition: state.sql has been updated to include current gap registry and the dump is current within 24h

**CREDIBLE-157** — `CREDIBLE: EVAL-094 closed without AC evidence — preregistration doc, results doc, and RESEARCH_INTEGRITY.md entry all absent`
- Priority: P1 | Effort: s
- AC: (1) `docs/eval/preregistered/EVAL-094.md` exists and was committed before any data collection run; (2) `docs/eval/EVAL-094-results.md` committed with n≥100, cross-judge κ≥0.6, A/A baseline, mechanism analysis per RESEARCH_INTEGRITY.md; (3) `docs/strategy/RESEARCH_INTEGRITY.md` updated with result entry for EVAL-094
- Evidence: `ls docs/eval/preregistered/EVAL-094.md` → not found; `ls docs/eval/EVAL-094-results.md` → not found; `grep "EVAL-094" docs/strategy/RESEARCH_INTEGRITY.md` → no output
- Falsifying condition: `git log -- docs/eval/preregistered/EVAL-094.md` shows the file was committed in PR #909 and later removed via a separate PR; removal PR justifies the deletion

**RESILIENT-170** — `RESILIENT: stale-worktree-reaper creates wip/ branches but never deletes them — 390 remote branches (82% of total) are abandoned stash branches; no cleanup code exists`
- Priority: P2 | Effort: xs
- AC: (1) `scripts/ops/stale-worktree-reaper.sh` contains cleanup logic that deletes wip/ branches older than N days; (2) `git ls-remote --heads origin | grep 'refs/heads/wip/' | wc -l` decreases after the reaper's next run; (3) a new ambient event kind `wip_branch_pruned` is emitted on each deletion
- Evidence: `git ls-remote --heads origin | grep 'refs/heads/wip/' | wc -l` → 390; `grep -n "delete.*wip" scripts/ops/stale-worktree-reaper.sh` → empty
- Falsifying condition: a separate script prunes wip/ branches — `grep -r "wip.*prune\|prune.*wip\|delete.*wip" scripts/` returns non-empty

**META-128** — `META: bot-merge bypass rate 59% (23/39) this cycle — 5 of 6 failure classes have no fix in flight; the bypass path is the de facto ship path`
- Priority: P1 | Effort: m
- AC: (1) Formal census of bot-merge bypass failure classes filed in state.db with gap IDs for each; (2) bypass rate drops below 20% in the cycle following fixes for the top-3 classes; (3) ambient event `botmerge_class_census` emitted after census
- Evidence: `git log origin/main --since='2026-07-13' --format='COMMIT%n%b' | grep -c "Bot-Merge-Bypass:"` → 23; RESILIENT-100 addressed 1 of 6 identified classes; 5 classes remain: binary-wedge, worktree-db-enqueue, claim-stall, session-ID-mismatch, parent-process-death
- Falsifying condition: the 23 bypass count includes duplicates or automated commits not tied to real bot-merge attempts

<details><summary>gap-reserve failure output</summary>

```
chump binary build: timeout after 300s (cargo build --release --bin chump)
Container restarted mid-build; target/release/chump not present.
Fallback shell script (scripts/coord/gap-reserve.sh) not invoked — requires CHUMP_ALLOW_MAIN_WORKTREE=1 and gh CLI for PR creation; gh CLI absent in sandbox.
```
</details>

---

## Issue #20 — 2026-07-13

> Audit window: commits since 2026-07-06 (Issue #19). **6 commits to `origin/main`** (PRs #3189–#3190 plus 4 direct commits). Sandbox: fresh remote clone, chump binary build still in progress (proposed-only mode; SQLite verification skipped). All evidence from git log, YAML file reads, bash scripts, and mcp__github__list_pull_requests. Bypass rate: 0/6 non-cold-water commits (0% — second consecutive 0% cycle). P0 count: 78 (budget: 5, unchanged). New ghost gap IDs: CP-018, CP-019 (no YAML, this cycle's commits). **2 follow-up gaps filed: CREDIBLE-128, RESILIENT-169** (YAML files written manually; chump binary unavailable for state.db import — operator must run `chump gap import` to sync).

---

### Status of Prior Issues (Issue #19)

- **STILL_OPEN_INACTIVE (3 cycles)**: RESILIENT-160 — chump binary dyld_start inode-wedge. 9 stranded PRs cite this as root cause.
  ```
  git log origin/main --grep='RESILIENT-160' --oneline | grep -v cold-water
  (empty — 0 impl commits, 3 cycles)
  ```

- **STILL_OPEN_INACTIVE (3 cycles)**: MISSION-043 — BEAST-MODE merge loop, 0 merged. Mission scoreboard ① = NO for 10th consecutive audit cycle.
  ```
  git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
  (empty — 0 impl commits, 3 cycles)
  ```

- **STILL_OPEN_INACTIVE (10 cycles)**: EVAL-094 — naturalized-framing evaluation. 0 implementation commits ever.
  ```
  git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
  (empty — 10 cycles)
  ```

- **STILL_OPEN_INACTIVE (10 cycles)**: FLEET-053 — NATS deployment. 0 implementation commits ever.
  ```
  git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
  (empty — 10 cycles)
  ```

- **STILL_OPEN_INACTIVE (5 cycles)**: MISSION-042 — MISSION-010/011/012 ghost gap IDs. `docs/MISSION.md` still references them. `ls docs/gaps/MISSION-010.yaml` → No such file (still).
  ```
  git log origin/main --grep='MISSION-042' --oneline | grep -v cold-water
  (empty — 0 impl commits, 5 cycles)
  ```

- **STILL_OPEN_INACTIVE (3 cycles)**: EFFECTIVE-293 — 7-day silence root-cause, post-mortem AC4 unmet.
  ```
  git log origin/main --grep='EFFECTIVE-293' --oneline | grep -v cold-water
  (empty — 0 impl commits, 3 cycles)
  ```

- **STILL_OPEN_INACTIVE (2 cycles)**: CREDIBLE-126 — ghost commit hygiene tracker.
  ```
  git log origin/main --grep='CREDIBLE-126' --oneline | grep -v cold-water
  (empty — 0 impl commits, 2 cycles)
  ```
  2 more ghost gap IDs (CP-018, CP-019) shipped this cycle despite this gap being open.

- **STILL_OPEN_INACTIVE (2 cycles)**: RESILIENT-167 — bypass trailers promising follow-ups that never land.
  ```
  git log origin/main --grep='RESILIENT-167' --oneline | grep -v cold-water
  (empty — 0 impl commits, 2 cycles)
  ```

- **STILL_OPEN_INACTIVE (mention-only, 3 cycles)**: META-064 — P0 inflation fix. 1 mention-only commit (INFRA-1543 body), 0 implementation commits.
  ```
  git log origin/main --grep='META-064' --oneline | grep -v cold-water
  b3b39f0 feat(INFRA-1543): Pi mesh actions-runner provisioner...  ← mention only, not impl
  ```

- **STILL_OPEN_INACTIVE (1 cycle)**: RESILIENT-168 — wip/ branch accumulation (324 branches). 0 impl commits.
  ```
  git log origin/main --grep='RESILIENT-168' --oneline | grep -v cold-water
  (empty — 0 impl commits, 1 cycle)
  ```
  Branch count: 324 wip/ branches — unchanged from Issue #19.

- **STILL_OPEN_INACTIVE (1 cycle)**: CREDIBLE-127 — EFFECTIVE-293 post-mortem (AC4 unmet). 0 impl commits.
  ```
  git log origin/main --grep='CREDIBLE-127' --oneline | grep -v cold-water
  (empty — 0 impl commits, 1 cycle)
  ```

- **UNCHANGED**: P0 count: 78 (budget: 5, 15.6× over). Not worse, not better. META-064 (P0 inflation fix) at 0 impl commits across 3 cycles.

- **BETTER**: Bypass rate: 0% for second consecutive cycle (6 of 6 non-cold-water commits had no bypass trailer).

- **NO_GAP filed this cycle**: CREDIBLE-128 (AGPLv3 relicense shipped while INFRA-1506 open, AC3/4/5 unmet), RESILIENT-169 (9 stranded PRs, dyld_start root cause unfixed 3 cycles).

---

### The Looming Ghost

**[P1/High] G1 — AGPLv3 relicense shipped (PR #3189, 2026-07-12) while INFRA-1506 (P1, "license model decision") remains status:open with three unmet acceptance criteria; LICENSE_STRATEGY.md still reads "DECISION PENDING" and "Current license: MIT"**

We are failing at license governance. A business-critical decision — changing from MIT to AGPLv3+Apache-2.0 across 12 crates — shipped without satisfying the controlling P1 gap. Three acceptance criteria of INFRA-1506 are unmet as of this audit:

```
# AC3 unmet: "If non-MIT chosen: file follow-up gap to migrate + notify existing contributors"
grep -r "contributor.*notify\|notify.*contributor" docs/gaps/*.yaml | wc -l
0

# STATUS_STALE: LICENSE_STRATEGY.md was NOT updated after the relicense
grep "Status:\|Current license:\|Last updated:" docs/business/LICENSE_STRATEGY.md
Status: DECISION PENDING — operator sign-off required before any payment infrastructure ships
Current license: MIT
Last updated: 2026-06-22

# INFRA-1506 not closed
grep "status:" docs/gaps/INFRA-1506.yaml
  status: open

# Republish untracked
git show 56a59c9 --format='%B' | grep -i "gap\|track\|follow"
"Republish (cargo publish, needs owner token) is a separate step."  ← no gap filed
```

The commit body (56a59c9) states: "Verified: no Apache lib depends on an AGPL crate (compatible direction). Old MIT versions on crates.io keep their grant; this applies going forward. Republish (cargo publish, needs owner token) is a separate step." The republish is untracked. INFRA-1506 AC requirement "Any path: INFRA-NEW: Legal review of chosen license before INFRA-1337 ships" — no legal review gap filed.

- evidence 1: `cat docs/gaps/INFRA-1506.yaml | grep "status:"` → `status: open` (controlling P1 gap unresolved)
- evidence 2: `grep "Status:" docs/business/LICENSE_STRATEGY.md` → "DECISION PENDING" / "Current license: MIT" (stale; actual license is now AGPLv3/Apache-2.0)
- evidence 3: `git show 56a59c9 --format='%B' | grep -iE "close|resolv|INFRA-1506"` → no closure reference

*This finding is wrong if: a separate commit or PR between 2026-07-12 and 2026-07-13 closed INFRA-1506 and filed the notification gap. No such commit found in `git log origin/main --since="2026-07-06" --oneline`.*

---

### The Opportunity Cost

**[P0/Critical] O1 — MISSION-043 (BEAST-MODE merge loop): 3rd consecutive cycle inactive; scoreboard ① = NO for 10th consecutive audit; 0 mission-advancing commits this cycle**

We are failing to advance the mission for the tenth consecutive audit cycle. This cycle shipped: 2 cross-pollination doctrine docs (CP-018, CP-019), 1 AGPLv3 relicense, 1 version bump. Zero commits advance the external-repo merge pipeline.

```
git log origin/main --since="2026-07-06" --format='%s' | grep -v "cold-water"
docs(cross-pollination): add CP-019-mythseeker2-cascade-convergent
docs(cross-pollination): add CP-018-smugglers-context-pipeline
chore: minor version bump all 12 published crates for the license republish
license: relicense MIT -> AGPLv3 (apps) + Apache-2.0 (libraries)

git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
(empty — 0 impl commits, 3 cycles)
```

The pattern: this is cycle 10 of the scoreboard reading ① NO. MISSION-043 was filed in Issue #17 (2026-06-22) specifically to track "11 BEAST-MODE PRs opened, 0 merged." Three cycles later: still 0 implementation commits. The cross-pollination docs are research artifacts, not product output. The license change is an external-facing governance action but produces no product capability.

- evidence 1: `git log origin/main --since="2026-07-06" --format='%s'` → 0 BEAST-advancing commits
- evidence 2: `git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water` → empty (3 cycles)
- evidence 3: `docs/MISSION.md` scoreboard ① = NO, operative since Issue #11 per prior audit records

*This finding is wrong if: BEAST-MODE PRs merged via direct push to repairman29/BEAST-MODE not captured in chump/main. BEAST-MODE is out of scope for this session's MCP access; the git log evidence is what's available.*

---

**[P1/High] O2 — 9 open PRs stranded (8 non-Dependabot); oldest 21 days; INFRA-1526 is a ghost gap driving 3 duplicate PRs; INFRA-918 has 3 duplicate PRs after already landing on main with TODO ACs**

We are failing to merge our own PRs. 9 PRs sit open in repairman29/chump. 8 are non-Dependabot. 6 of 8 carry `Bot-Merge-Bypass:` trailers citing dyld_start wedge. RESILIENT-160 (the dyld_start fix gap) has 0 impl commits across 3 cycles — the root cause is unfixed.

```
# INFRA-1526 ghost: 3 PRs (#3163, #3173, #3174) for a gap that was never filed
ls docs/gaps/INFRA-1526.yaml
ls: cannot access 'docs/gaps/INFRA-1526.yaml': No such file or directory

# INFRA-918 triplicate after OBL: already merged once (4a028fe), 3 more PRs open
git log origin/main --grep='INFRA-918' --oneline | grep -v cold-water
4a028fe feat(INFRA-918): bot-merge rebase-before-test telemetry (#3168)
# Then 3 more PRs opened same day: #3155, #3156, #3157 — all unmerged 21 days later

# PR #3183 (INFRA-1590): opened 2026-07-05 — after CREDIBLE-146 auth fix
# Still unmerged 8 days later. A new failure class post-fix.

# RESILIENT-160: still 0 impl commits (3 cycles)
git log origin/main --grep='RESILIENT-160' --oneline | grep -v cold-water
(empty — 3 cycles)
```

- evidence 1: mcp__github__list_pull_requests → 9 open PRs, oldest #3155 (2026-06-22 = 21 days)
- evidence 2: `ls docs/gaps/INFRA-1526.yaml` → no such file (ghost gap)
- evidence 3: `git log origin/main --grep='RESILIENT-160' --oneline | grep -v cold-water` → empty (3 cycles, 0 impl commits)

*This finding is wrong if: all 9 open PRs were closed or merged between 2026-07-13 and the next audit. Checked at time of writing.*

---

### The Complexity Trap

**[P2/High] C1 — 2 more ghost gap IDs this cycle (CP-018, CP-019); 15 of 17 cross-pollination docs are "proposed" with no implementation gap; CP-001 has been proposed since 2026-05-23 (51 days) with no gap ID at all**

We are failing to convert research artifacts into actionable work. Two cross-pollination doctrine docs (CP-018 for smugglers context pipeline, CP-019 for mythseeker2 cascade) shipped this cycle with no implementation gap IDs — they reference the MINE_MANIFEST but no gap store entry. CP-001 (neural-farm gateway, proposed 2026-05-23) has had no implementation gap for 51 days.

```
# CP docs with no gap ID in body:
# CP-001: no gap ref at all (51 days since proposed)
# CP-018: no gap ref (filed today)
# CP-019: no gap ref (filed today)

# CP proposed vs shipped:
Total: 17 CP docs
Proposed/stuck: 15
Shipped: 1 (CP-008, partially)
Investigation complete: 1 (CP-002)

# Ghost IDs from commits this cycle:
git log origin/main --since='2026-07-06' --format='%s' | grep -oE '[A-Z]+-[0-9]+' | sort -u
CP-018  → ls docs/gaps/CP-018.yaml → No such file or directory
CP-019  → ls docs/gaps/CP-019.yaml → No such file or directory
```

Cross-pollination docs that propose patterns but file no implementation gap are doc-for-doc's-sake. They contribute to the CP archive (17 docs) while the implementation queue stays untouched.

- evidence 1: CP-018, CP-019 commit subjects contain gap-ID-format strings with no corresponding YAML
- evidence 2: `grep -h "Status:" docs/arsenal/cross-pollination/CP-*.md | sort | uniq -c` → 15 "proposed", 1 "shipped", 1 "complete"
- evidence 3: `grep -oE '(INFRA|META|FLEET|...)-[0-9]+' docs/arsenal/cross-pollination/CP-001-*.md` → empty (51 days, no impl gap)

*This finding is wrong if: the CP docs intentionally have no gap IDs and a separate system tracks implementation. No such system found; all other CP docs that are progressing reference gap IDs.*

---

**[P1/High] C2 — INFRA-918 gap has TODO acceptance criteria; shipped to main (PR #3168, 4a028fe); status still open; 3 duplicate PRs opened same day as the merge**

We are failing at the gap lifecycle. INFRA-918 ("bot-merge rebase-before-test telemetry") was shipped to main on 2026-06-22 (PR #3168, 4a028fe). Its AC are four TODO placeholders. Its status was never changed to shipped. Three additional PRs were then opened for the same gap the same day — the fleet's gap picker saw the gap still open, picked it three more times in parallel, and produced three duplicate implementations that have sat unmerged for 21 days.

```
cat docs/gaps/INFRA-918.yaml | grep -A6 "acceptance_criteria:"
  acceptance_criteria:
    - "TODO: what events emitted on success/failure/timeout"
    - "TODO: how cost tracked and reported to operator"
    - "TODO: failure-class taxonomy (distinguish transient vs permanent)"
    - "TODO: smoke test command to verify observability"

git log origin/main --grep='INFRA-918' --oneline | grep -v cold-water
4a028fe feat(INFRA-918): bot-merge rebase-before-test telemetry (#3168)  ← merged 2026-06-22

# 3 more open PRs for the same gap:
# PR #3155, #3156, #3157 — all opened 2026-06-22, all unmerged
```

- evidence 1: `docs/gaps/INFRA-918.yaml` → 4 TODO ACs, status: open
- evidence 2: `git log origin/main --grep='INFRA-918'` → 4a028fe (already landed)
- evidence 3: mcp__github__list_pull_requests → PRs #3155, #3156, #3157 all reference INFRA-918, all state "open"

*This finding is wrong if: the 3 open PRs are superseding the landed PR (4a028fe was reverted). No revert commit found in git log.*

---

### The Reality Check

**[P0/Critical] R1 — P0 count: 78 (budget: 5, 15.6× over); META-064 (P0 inflation fix) at 0 impl commits for 3 cycles; count has never decreased across 10 audit cycles**

We are failing at P0 budget discipline for the longest sustained stretch in this audit's history. P0 count trajectory: 74 (Issue #15) → 76 → 76 → 77 → 78 → 78. It has never decreased. META-064 (the gap tasked with fixing this) has 0 implementation commits:

```
git log origin/main --grep='META-064' --oneline | grep -v cold-water
b3b39f0e feat(INFRA-1543): Pi mesh actions-runner provisioner...  ← mention only, not impl

python3 -c "
import glob, re
p0 = [f for f in glob.glob('docs/gaps/*.yaml')
      if re.search(r'^\s*priority: P0', open(f).read(), re.M)
      and re.search(r'^\s*status: open', open(f).read(), re.M)]
print(len(p0))
"
78

# Budget ceiling per CLAUDE.md §Mission Driver: "P0 budget = 5 max."
```

78 ÷ 5 = 15.6× over budget. The enforcement mechanism (scripts/ci/test-p0-budget.sh from META-064) does not run in CI because META-064 has never shipped.

- evidence 1: YAML census → 78 open P0 gaps (confirmed with exact Python regex, not `in` substring)
- evidence 2: `git log origin/main --grep='META-064' --oneline | grep -v cold-water` → 0 impl commits (3 cycles)
- evidence 3: `CLAUDE.md §Mission Driver` reads "P0 budget = 5 max." (budget unchanged, count 15.6× over)

*This finding is wrong if: the P0 budget was relaxed via operator decision and CLAUDE.md updated. CLAUDE.md still reads "P0 budget = 5 max."*

---

### The Innovation Lag

**[P1/Medium] I1 — EVAL-094 enters 10th inactive cycle while the 15/17 CP docs it feeds remain unimplemented; the harvest-without-act pattern is now self-referential**

We are failing to close the loop between research and action. This cycle added CP-018 and CP-019 — harvesting two more external-repo patterns for future use — while 15 of 17 prior CP docs remain "proposed" with no implementation. EVAL-094 (the naturalized-framing evaluation that would validate the cognitive architecture the CP docs are meant to feed) has been inactive for 10 cycles. The harvester is running; the implementation queue is frozen.

The 2026-07-12 license change (AGPLv3) is the one outward-facing action this cycle — it reflects a business posture shift — but it was not paired with the downstream actions the strategy doc required (legal review gap, contributor notification, crates.io republish). The harvest-without-implementation pattern now applies to governance decisions too, not just technical research.

External anchor (already cited in RESEARCH_INTEGRITY.md): arXiv:2508.00943 (ICLR 2026) — 16–36% monitor-bypass on Claude-class models. Chump uses Claude-class models as both agents and judges. 10 cycles of EVAL-094 inactivity means 10 cycles without the mechanism data that RESEARCH_INTEGRITY.md §Mechanism Analysis requires before any delta >±0.05 claim.

*This finding is wrong if: EVAL-094 ran in a private fork and results are in the companion repo. No remote branch or public commit evidence of this.*

---

**THE ONE BIG THING:** [P1/compound] We are failing to merge our own work. The stranded-PR graveyard (9 open PRs, 8 non-Dependabot, oldest 21 days) is the clearest symptom of a structural failure that spans three traceable gaps: RESILIENT-160 (dyld_start wedge, 0 impl commits for 3 cycles — the mechanism that created the graveyard), INFRA-1526 (a ghost gap ID that drove 3 duplicate PRs for work that may not have been properly scoped to begin with), and INFRA-918 (already shipped to main with TODO ACs, then picked three more times and opened as 3 more duplicate PRs). The fleet wrote 6 commits to main this cycle — a license change and two CP docs — while 8 working implementations sat unmerged. The root cause (RESILIENT-160, dyld_start wedge) was filed Issue #17, has 0 implementation commits across 3 cycles, and is the stated reason for `Bot-Merge-Bypass:` trailers on 6 of the 9 open PRs. The bypass-creates-orphan pattern that RESILIENT-167 was supposed to track (also 0 impl commits, 2 cycles) is now visible in the open PR list: each bypassed push created a stranded PR that the next picker tried to re-implement. Filed RESILIENT-169 and CREDIBLE-128 this cycle. Pre-existing gap tracking the root cause: RESILIENT-160 (P1, 3 cycles inactive).

---

### Follow-up Gaps Filed

(Gap `.yaml` files written manually — chump binary build did not complete in sandbox. Operator must run `chump gap import` to sync YAML into state.db before these appear in `chump gap list`.)

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| CREDIBLE-128 | AGPLv3 relicense shipped (PR #3189) while INFRA-1506 open — AC3/4/5 unmet | P1 | s |
| RESILIENT-169 | 9 stranded PRs (oldest 21d); INFRA-1526 ghost gap; INFRA-918 triplicate; RESILIENT-160 root cause 3 cycles inactive | P1 | m |

```bash
# Verification (run after chump gap import):
ls docs/gaps/CREDIBLE-128.yaml docs/gaps/RESILIENT-169.yaml
# → both exist (written 2026-07-13)
# chump gap list --json | python3 -c "import json,sys; ids={g['id'] for g in json.load(sys.stdin)}; print({x for x in ['CREDIBLE-128','RESILIENT-169'] if x in ids})"
# → run after chump gap import to confirm state.db sync
```

Pre-existing gaps covering other findings:
- MISSION-043 (BEAST-MODE merge loop, P0, 0 impl commits — 3 cycles)
- EVAL-094 (10 cycles inactive), FLEET-053 (10 cycles inactive)
- MISSION-042 (ghost gap IDs MISSION-010/011/012, 5 cycles inactive)
- META-064 (P0 inflation fix, 0 impl commits — 3 cycles)
- CREDIBLE-126 (ghost commit hygiene, 0 impl commits — 2 cycles)
- RESILIENT-167 (bypass trailers lying, 0 impl commits — 2 cycles)
- EFFECTIVE-293 (7-day silence root-cause, AC4 unmet — 3 cycles)
- RESILIENT-160 (dyld_start wedge, 0 impl commits — 3 cycles; root cause of stranded PR graveyard)
- RESILIENT-168 (wip/ branch accumulation, 0 impl commits — 1 cycle)
- CREDIBLE-127 (post-mortem obligation, 0 impl commits — 1 cycle)

---

## Issue #19 — 2026-07-06

> Audit window: commits since 2026-06-29 (Issue #18). **9 non-cold-water commits** to `origin/main` (PRs #3175–#3187). Sandbox: fresh clone, chump binary build did not complete before evidence gathering (proposed-only mode; SQLite verification skipped). All evidence from git log, YAML file reads, and bash scripts. **Initial clone was stale — fetched after preflight revealed this.** Bypass rate: 0/9 non-cold-water commits (0% — improvement from 60% last cycle). P0 count: 78 (budget: 5, up from 77). Ghost gap IDs: 5 new this cycle (22 all-time). **2 follow-up gaps filed: RESILIENT-168, CREDIBLE-127** (YAML files written manually; chump binary unavailable for state.db import — operator must run `chump gap import` to sync).

---

### Status of Prior Issues (Issue #18)

- **STILL_OPEN_INACTIVE (2 cycles)**: RESILIENT-160 — chump binary dyld_start inode-wedge.
  ```
  git log origin/main --grep='RESILIENT-160' --oneline | grep -v cold-water
  (empty — 0 impl commits, 2 cycles)
  ```

- **STILL_OPEN_INACTIVE (2 cycles)**: MISSION-043 — BEAST-MODE merge loop, 0 merged.
  ```
  git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
  (empty — 0 impl commits, 2 cycles since filing)
  ```
  Mission scoreboard ① still NO. 9th consecutive audit cycle. No BEAST-MODE PRs merged.

- **STILL_OPEN_INACTIVE (9 cycles)**: EVAL-094 — naturalized-framing evaluation. 0 implementation commits ever.
  ```
  git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
  (empty — 9 cycles)
  ```

- **STILL_OPEN_INACTIVE (9 cycles)**: FLEET-053 — NATS deployment. 0 implementation commits ever.
  ```
  git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
  (empty — 9 cycles)
  ```

- **STILL_OPEN_INACTIVE (4 cycles)**: MISSION-042 — MISSION-010/011/012 ghost gap IDs.
  ```
  git log origin/main --grep='MISSION-042' --oneline | grep -v cold-water
  (empty — 0 impl commits, 4 cycles)
  ls docs/gaps/MISSION-010.yaml → No such file or directory (still)
  ```
  Commits still reference `MISSION-010` in commit bodies. The ghost is still the north star.

- **STILL_OPEN_INACTIVE (2 cycles)**: EFFECTIVE-293 — 7-day silence root-cause.
  ```
  git log origin/main --grep='EFFECTIVE-293' --oneline | grep -v cold-water
  (empty — 0 impl commits, 2 cycles)
  ```
  AC4 still unmet: no post-mortem filed. CREDIBLE-146 this cycle likely IS the root cause (see G1). Filed CREDIBLE-127.

- **STILL_OPEN_INACTIVE (1 cycle)**: CREDIBLE-126 — ghost commit hygiene failure tracker.
  ```
  git log origin/main --grep='CREDIBLE-126' --oneline | grep -v cold-water
  (empty — 0 impl commits, 1 cycle)
  ```
  5 more ghost gap IDs shipped this cycle despite this gap being open.

- **STILL_OPEN_INACTIVE (1 cycle)**: RESILIENT-167 — bypass trailers promising follow-ups that never land.
  ```
  git log origin/main --grep='RESILIENT-167' --oneline | grep -v cold-water
  (empty — 0 impl commits, 1 cycle)
  ```

- **WORSE**: C1 — **P0 count: 78** (was 77 Issue #18, 76 Issues #16-17, budget: 5 max). Up by 1. META-064 (P0 inflation fix) still at 0 implementation commits (1 mention-only commit in INFRA-1543).

- **BETTER**: G1 — **Bot-merge bypass rate: 0%** (0 of 9 non-cold-water commits). Down from 60% in Issue #18. This is the first 0% bypass cycle in the audit's history. Causality uncertain: may reflect CREDIBLE-146 fix unblocking auth, or simply low commit volume.

- **FIXED**: G1/Issue #18 — The 7-day fleet silence ended. The fleet resumed shipping dep bumps on 2026-06-29 and CREDIBLE fixes on 2026-07-04. The root cause (auth-status stale cache — CREDIBLE-146) was fixed this cycle. EFFECTIVE-293 AC4 (post-mortem) remains unmet.

- **NO_GAP filed this cycle**: RESILIENT-168 (wip/ remote branch accumulation, 324 branches, no cleanup mechanism).

---

### The Looming Ghost

**[P1/High] G1 — CREDIBLE-146 (auth-status stale-cache) is the probable cause of Issue #18's 7-day fleet silence — this was never documented, and EFFECTIVE-293's post-mortem AC remains unmet**

We are failing to close our own incident investigations. CREDIBLE-146 (PR #3182, 2026-07-04) fixed a 600-second TTL cache in `auth-status.sh` that served a cached BROKEN verdict blindly: "a cached BROKEN kept the farmer paging AUTH_DEAD while the oauth token was valid, silently freezing the fleet for days." The timeline matches the Issue #18 silence exactly:

```
git show ec6321f1 --format="%ai %s"
2026-06-20 17:46:09 -0500  feat(RESILIENT-086): auth-status validity probe in preflight (#3125)
  ↑ introduces 600s cache

git log origin/main --since="2026-06-22" --until="2026-07-03" --oneline | wc -l
0  ← fleet silent 11 days while cache could serve BROKEN

git show 796856bf --format="%ai %s"
2026-07-04 20:18:19 -0500  fix(CREDIBLE-146): never serve a stale/bad auth-status cache (#3182)
  ↑ fix lands; fleet resumes same day
```

EFFECTIVE-293 (Issue #18's root-cause gap) hypothesized a CI cascade but never identified the auth cache. With CREDIBLE-146 now in hand, the link is clear. Yet:

```
git log origin/main --grep='EFFECTIVE-293' --oneline | grep -v cold-water
(empty — 0 impl commits, 2 cycles open)
```

EFFECTIVE-293 AC4 — "a post-mortem commit or ambient event documents the actual root cause" — remains unmet. Filed CREDIBLE-127.

- evidence 1: `git show 796856bf --format='%B'` → "silently freezing the fleet for days" — the exact symptom of Issue #18
- evidence 2: RESILIENT-086 introduced the cache 2026-06-20; silence started 2026-06-22; CREDIBLE-146 fixed it 2026-07-04; fleet resumed same day
- evidence 3: `git log origin/main --grep='EFFECTIVE-293' --oneline | grep -v cold-water` → empty — 0 post-mortem commits in 2 cycles

*This finding is wrong if: the fleet resumed on 2026-06-29 (dep bumps) independently of CREDIBLE-146 (which landed 2026-07-04). The dep bumps are Dependabot automation — not fleet workers — and the fleet's manual work (CREDIBLE-146, CREDIBLE-149, refactors) resumed only on 2026-07-04 after the auth cache fix.*

---

### The Opportunity Cost

**[P0/Critical] O1 — MISSION scoreboard ① still NO for 9th consecutive audit cycle; MISSION-043 (P0) filed 2 cycles ago, 0 impl commits; this cycle shipped 0 BEAST-MODE-advancing commits**

We are failing to move the mission. This cycle (2026-06-29 to 2026-07-06) shipped: 3 automated dep bumps, 2 CREDIBLE auth/metric fixes, 2 internal dispatch refactors, 1 documentation doc (CODEBASE_REALITY_MAP). Zero commits advance the external-repo merge pipeline.

```
git log origin/main --since="2026-06-29" --format='%s' | grep -v "cold-water\|chore(deps)"
docs(DOC-068): CODEBASE_REALITY_MAP — cross-cutting capability synthesis for future agents
refactor(INFRA-3298): extract author-time helpers to dispatch_authoring
refactor(INFRA-3289): extract external-repo commands to dispatch_external
fix(CREDIBLE-146): never serve a stale/bad auth-status cache
fix(CREDIBLE-149): count only real leases in fleet_status

git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
(empty — 0 impl commits, 2 cycles)
```

MISSION-043 was filed in Issue #17 (2026-06-22) to track "11 BEAST-MODE PRs opened, 0 merged." Two cycles later: still 0 implementation commits, still P0, still open. The scoreboard ① reports NO for the ninth consecutive audit. The "Outward Flywheel" strategy doc (Issue #18's I1 finding — MISSION-050, still a ghost ID) describes exactly what to do. The work isn't being done.

- evidence 1: `git log origin/main --since="2026-06-29" --format='%s'` → 0 BEAST-advancing commits
- evidence 2: `git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water` → empty (2 cycles)
- evidence 3: `docs/MISSION.md` reports scoreboard ① = NO, operative since Issue #11

*This finding is wrong if: BEAST-MODE PRs merged via a path not captured in chump/main (e.g. direct push to repairman29/BEAST-MODE). The mission-scoreboard.sh script fetches BEAST-MODE directly — if that repo's auth is broken the scoreboard could false-report. Without gh CLI in sandbox, the scoreboard output cannot be verified this cycle; the git log evidence stands.*

---

**[P1/High] O2 — EVAL-094, FLEET-053: 9th consecutive cycle, 0 implementation commits**

We are failing at research credibility and distributed coordination for the ninth consecutive cycle. EVAL-094 (naturalized-framing evaluation, n=50/cell) has never run. FLEET-053 (NATS production deployment) has never been attempted. RESEARCH_INTEGRITY.md §Mechanism Analysis requires naturalized-framing results from EVAL-094 before any delta >±0.05 can be claimed; this requirement has been unfulfillable for 9 weeks.

```
git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
(empty — 9 cycles)

git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
(empty — 9 cycles)

git branch -r | grep -E "EVAL-094|FLEET-053"
(empty — no in-flight branches)
```

*This finding is wrong if: EVAL-094 or FLEET-053 work is underway in an unpushed branch or private fork. No remote branches found for either.*

---

### The Complexity Trap

**[P1/High] C1 — 5 more ghost gap IDs this cycle (22 all-time); CREDIBLE-126 (ghost hygiene gap) has 0 impl commits after 1 cycle; the ghost rate is structurally unchecked**

We are failing at basic gap hygiene for the second consecutive cycle. This cycle shipped 5 commits referencing gap IDs with no `.yaml` file and no `state.sql` entry:

```
ls docs/gaps/CREDIBLE-146.yaml  → No such file or directory
ls docs/gaps/CREDIBLE-149.yaml  → No such file or directory
ls docs/gaps/DOC-068.yaml       → No such file or directory
ls docs/gaps/INFRA-3289.yaml    → No such file or directory
ls docs/gaps/INFRA-3298.yaml    → No such file or directory
grep "CREDIBLE-146\|CREDIBLE-149\|DOC-068\|INFRA-3289\|INFRA-3298" .chump/state.sql
(empty — not in canonical store either)
```

CREDIBLE-126 was filed in Issue #18 to track exactly this. Zero implementation commits:

```
git log origin/main --grep='CREDIBLE-126' --oneline | grep -v cold-water
(empty — 0 impl commits, 1 cycle)
```

All-time ghost count: 22 gap IDs committed to main but traceable to no YAML file and no state.sql row. Ghost rate: ~5 per short cycle. The pre-commit hook validates gap IDs against the store — but only if the store has the IDs loaded. When bot-merge is bypassed or the chump binary wedges during preflight, this check fails open.

- evidence 1: `ls docs/gaps/CREDIBLE-146.yaml docs/gaps/CREDIBLE-149.yaml docs/gaps/DOC-068.yaml` → all missing
- evidence 2: `grep "CREDIBLE-146" .chump/state.sql` → empty (not in canonical store)
- evidence 3: `git log origin/main --grep='CREDIBLE-126' --oneline | grep -v cold-water` → empty (ghost hygiene gap untouched)

*This finding is wrong if: the gap store is managed exclusively in `state.db` (not exported to YAML) and state.db has these IDs. The chump binary failed to build in this sandbox; state.db is absent. state.sql (the SQL dump) does not contain these IDs.*

---

**[P2/High] C2 — 324 remote wip/ branches accumulating with no cleanup; newest from 2026-07-05; stale-worktree-reaper creates them but never deletes them**

We are failing to clean up after our own tooling. RESILIENT-029 added stash-before-reap to `scripts/ops/stale-worktree-reaper.sh` — before deleting a worktree, uncommitted work is pushed to a `wip/<gap>-<ts>` branch. This is correct. But the branches are never deleted:

```
git ls-remote --heads origin | grep "refs/heads/wip/" | wc -l
324

git ls-remote --heads origin | grep "refs/heads/wip/" | tail -1
0fb9ccd...   refs/heads/wip/unknown-1783285544
# timestamp → 2026-07-05 21:05:44 UTC

grep -n "git push.*delete\|git push origin :.*wip\|prune.*wip" scripts/ops/stale-worktree-reaper.sh
(empty — no cleanup code)

git ls-remote --heads origin | wc -l
412  ← total branches; 324/412 = 79% are abandoned stash branches
```

- evidence 1: `git ls-remote --heads origin | grep 'refs/heads/wip/' | wc -l` → 324
- evidence 2: `grep "delete.*wip\|wip.*prune" scripts/ops/stale-worktree-reaper.sh` → empty
- evidence 3: newest wip branch: 2026-07-05 21:05 UTC — fleet is actively creating them right now

Filed RESILIENT-168.

*This finding is wrong if: a separate cron script prunes wip/ branches — `grep -r "wip.*prune\|prune.*wip" scripts/` returns non-empty. Not found.*

---

### The Reality Check

**[P0/Critical] R1 — P0 count: 78 (budget: 5, 15.6× over); 76 of 78 open P0s have ZERO implementation commits; META-064 (P0 inflation fix) still has 0 impl commits after 3 cycles**

We are failing at P0 budget discipline for the longest sustained stretch in this audit's history. The P0 count has risen from 74 (Issue #15) → 76 → 76 → 77 → 78. It has never decreased. META-064 (the gap tasked with fixing this) has 0 implementation commits:

```
git log origin/main --grep='META-064' --oneline | grep -v cold-water
b3b39f0e feat(INFRA-1543): Pi mesh actions-runner provisioner...  ← mention only, not impl

# P0 audit (YAML):
python3 -c "import glob; p=[f for f in glob.glob('docs/gaps/*.yaml') if 'priority: P0' in open(f).read() and 'status: open' in open(f).read()]; print(len(p))"
78

# P0 gaps with zero impl commits:
76 of 78 (the 2 with commits are OPEN-BUT-LANDED: EVAL-125 and INFRA-1620, both same PR #3135)
```

The two P0 gaps with "impl commits" are both OBL (Open-But-Landed) from the same PR (#3135, 2026-06-20). Neither has been closed. The budget enforcement mechanism (`scripts/ci/test-p0-budget.sh`) is itself a gap in progress — it doesn't run in CI because META-064 has never shipped.

- evidence 1: YAML census → 78 open P0 gaps (budget: 5 per CLAUDE.md)
- evidence 2: 76/78 P0 gaps have zero non-cold-water git log entries
- evidence 3: `git log origin/main --grep='META-064' --oneline | grep -v cold-water` → 0 implementation commits (3 cycles since filing)

*This finding is wrong if: the P0 budget limit was relaxed by operator decision and CLAUDE.md was updated. CLAUDE.md §Mission Driver still reads "P0 budget = 5 max."*

---

**[P1/High] R2 — Fleet metrics reported 189 workers vs ~1 real (180×) for 26 days; CREDIBLE-149 fixed this but no post-mortem; all prior fleet health assessments in that window are untrustworthy**

We are failing at credible self-measurement. `fleet_status.rs` (introduced 2026-06-08, PR #3124 INFRA-774) globbed ALL `.json` files in `.chump-locks/` to count "active leases" — including 178 curator decision-log ledgers and state files that are NOT leases. The fleet dashboard, mission_grade, and fleet scaling-gate all consumed this count. The count read ~189; real active workers: ~1.

```
git show dde830ef --format="%B" | head -10
fix(CREDIBLE-149): count only real leases (expires_at) in fleet_status (#3181)
active_leases/fleet_workers_alive globbed every .chump-locks/*.json — so
178 curator decision-log ledgers + state files inflated the count ~180x
(reported 189 vs ~1 real lease). Poisoned fleet status, web dashboard,
fleet_health, mission_grade, and the scaling-gate input.

# Duration of false metrics:
git log --follow --format="%ai" -- src/fleet_status.rs | head -2
2026-07-04 14:57:32  ← fixed
2026-06-08 23:05:10  ← introduced
# 26 days of ~180x inflated fleet health data
```

The scaling-gate criteria (CLAUDE.md §Fleet scaling gate) include `fleet_workers_alive` as an input. Every scaling decision for 26 days was based on a metric 180× over reality. No post-mortem was filed. No prior cold-water issue caught this — the gap CREDIBLE-149 itself is a ghost (no YAML file).

- evidence 1: commit body states "reported 189 vs ~1 real" — 180× inflation
- evidence 2: `git log --follow --format="%ai" -- src/fleet_status.rs` → bug lived 2026-06-08 to 2026-07-04 = 26 days
- evidence 3: `CLAUDE.md §Fleet scaling gate` lists `fleet_workers_alive` as a scaling-gate input; the scaling gate is fed false data for 26 days

*This finding is wrong if: the scaling-gate never ran during this period (fleet stayed at same size). This cycle's evidence shows PR activity throughout — scaling decisions were being made.*

---

### The Innovation Lag

**[P1/Medium] I1 — EVAL-094 is now in its 9th inactive cycle while the evaluation-aware sandbagging literature it references has reached ICLR-2026 publication status; the methodology obligation is increasingly remote from best practice**

We are failing to track external evaluation methodology as it matures. The RESEARCH_INTEGRITY.md §Mechanism Analysis requirement cites arXiv:2508.00943 (ICLR 2026, "LLMs Can Covertly Sandbag on Capability Evaluations Against Chain-of-Thought Monitoring") as justification for the EVAL-094 naturalized-framing requirement. That paper is now published. The requirement remains. EVAL-094 has 0 implementation commits across 9 cycles.

`docs/strategy/EVAL_AWARE_SANDBAGGING.md` was last audited 2026-05-22. It states the risk is "partially mitigated and load-bearing-unfixed at the magnitude level." That assessment is 45 days stale. The CODEBASE_REALITY_MAP (DOC-068, shipped this cycle) documents: "the flagship external-repo loop has not met its own exit bar (≥3 merged PRs in one overnight `chump improve` run)." The gap between claimed and verified capability is the same evaluation-awareness risk EVAL-094 was supposed to measure — except now the risk includes the fleet's self-assessment of its own shipping capability (CREDIBLE-149's 180× inflation, CREDIBLE-146's stale auth cache).

External baseline (not required to web-search; citing the paper already in RESEARCH_INTEGRITY.md): arXiv:2508.00943 — 16–36% monitor-bypass on Claude-class models. Chump uses Claude-class models as both agents and judges. Nine cycles of EVAL-094 inactivity means nine cycles of mechanism claims the project cannot defend.

*This finding is wrong if: EVAL-094 ran in a private fork and results are in the private companion repo. No evidence of this. RESEARCH_INTEGRITY.md standing caveat applies: "the direction of the principal finding is stable; the magnitudes are subject to ongoing methodological scrutiny."*

---

**THE ONE BIG THING:** [P0] We are failing to measure our own fleet honestly, and we have been doing so for at least 26 days. The CREDIBLE-149 fix this cycle revealed that every fleet health dashboard, mission grade, and scaling-gate input was lying by 180× — reporting ~189 active workers while ~1 was real — from 2026-06-08 through 2026-07-04. The CREDIBLE-146 fix, also this cycle, revealed that the auth-status probe cached BROKEN verdicts for 10 minutes and served them blindly, which is the probable cause of Issue #18's 7-day fleet silence. Both gaps are ghost IDs (no YAML, no state.sql entry). Both fixes shipped without post-mortems. The CODEBASE_REALITY_MAP (DOC-068) itself says: "the fleet has gone silently dark for days while every dashboard read 'healthy.'" That is not a historical observation — it describes Issue #18. The fixes landed this cycle. The post-mortems did not. EFFECTIVE-293 (root-cause gap) and CREDIBLE-127 (post-mortem obligation) both have 0 implementation commits. The mission scoreboard reads ① NO for the ninth consecutive cycle. The issue is not that the fleet cannot ship — it shipped 9 commits this cycle with 0 bypasses, the cleanest bypass rate ever. The issue is that the fleet cannot honestly measure whether what it ships is working. Gap ID for the measurement failure: CREDIBLE-127.

---

### Follow-up Gaps Filed

(Gap `.yaml` files written manually — chump binary unavailable for `state.db` import. Operator must run `chump gap import` to sync YAML into state.db before these appear in `chump gap list`.)

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| RESILIENT-168 | RESILIENT: stale-worktree-reaper creates wip/ branches but never deletes them — 324 remote branches accumulating | P2 | xs |
| CREDIBLE-127 | CREDIBLE: EFFECTIVE-293 root cause identified (CREDIBLE-146 auth cache) but post-mortem never filed — AC4 unmet | P1 | xs |

```
# Verification (run after chump gap import):
ls docs/gaps/RESILIENT-168.yaml docs/gaps/CREDIBLE-127.yaml
# → both exist (verified at write time)
# chump gap list --json | python3 -c "import json,sys; ids={g['id'] for g in json.load(sys.stdin)}; print({x for x in ['RESILIENT-168','CREDIBLE-127'] if x in ids})"
# → run after chump gap import to confirm state.db sync
```

Pre-existing gaps covering other findings:
- MISSION-043 (BEAST-MODE merge loop, P0/m, 0 impl commits — 2 cycles)
- EVAL-094 (9 cycles inactive), FLEET-053 (9 cycles inactive)
- MISSION-042 (ghost gap IDs MISSION-010/011/012, 4 cycles inactive)
- META-064 (P0 inflation fix, 0 impl commits — 3 cycles)
- CREDIBLE-126 (ghost commit hygiene, 0 impl commits — 1 cycle)
- RESILIENT-167 (bypass trailers lying, 0 impl commits — 1 cycle)
- EFFECTIVE-293 (7-day silence root-cause, AC4 unmet — 2 cycles)
- RESILIENT-160 (dyld_start wedge, 0 impl commits — 2 cycles)

---

## Issue #18 — 2026-06-29

> Audit window: commits since 2026-06-22 (Issue #17). **5 commits to `origin/main`** (PRs #3168–#3172), all on 2026-06-22 — then **zero commits for 7 days**. Sandbox: fresh worktree on main, chump binary not built (cargo still running). All evidence from git log, YAML file reads, and bash scripts. Bypass rate: 3/5 non-cold-water commits (60%). P0 count: 77 (budget: 5). 4 ghost gap IDs shipped. **3 follow-up gaps filed: CREDIBLE-126, RESILIENT-167, EFFECTIVE-293** (gap YAML files written manually; chump binary unavailable for state.db import — operator must run `chump gap import` to sync).

---

### Status of Prior Issues (Issue #17)

- **STILL_OPEN_INACTIVE (1 cycle)**: RESILIENT-160 — chump binary dyld_start inode-wedge. `git log origin/main --grep='RESILIENT-160' --oneline | grep -v cold-water` → empty. Gap filed but no implementation.
- **STILL_OPEN_INACTIVE (1 cycle)**: MISSION-043 — 11 BEAST-MODE PRs opened, 0 merged. `git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water` → empty. Mission scoreboard ① still NO, 0 BEAST merges last 7d.
- **WORSE**: G1 — **Bot-merge bypass rate: 60%** this cycle (3 of 5 non-cold-water commits). Previously 12.5% (Issue #17), 43% (Issue #16). **All-time high rate for a short cycle.** New failure class: INFRA-1434 (title-similarity blocking bot-merge preflight). No gap filed for INFRA-1434 despite bypass trailer promising "follow-up filed."
  ```
  git log origin/main --since="2026-06-22" --format='%B' | grep 'Bot-Merge-Bypass:'
  Bot-Merge-Bypass: bot-merge silent-wedged on its preflight chump-gap-import (INFRA-1434 title-similarity blocked CREDIBLE-144/145 re-import → fatal exit)
  Bot-Merge-Bypass: bot-merge.sh wedged on chump binary (self-heal failed twice); using CHUMP_BYPASS_BOT_MERGE=1 operator recovery path
  Bot-Merge-Bypass: chump binary persistently wedged by concurrent background cargo build
  ```
- **STILL_OPEN_INACTIVE (8 cycles)**: EVAL-094 — naturalized-framing evaluation. `git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water` → empty. `git branch -r | grep EVAL-094` → empty.
- **STILL_OPEN_INACTIVE (8 cycles)**: FLEET-053 — NATS deployment. `git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water` → empty.
- **STILL_OPEN_INACTIVE (3 cycles)**: MISSION-042 — ghost gap IDs MISSION-010/011/012. `git log origin/main --grep='MISSION-042' --oneline | grep -v cold-water` → empty. `docs/MISSION.md` still references `MISSION-010`, `MISSION-011`, `MISSION-012` as authoritative gap IDs; none exist in `docs/gaps/`.
- **WORSE**: C1 — P0 count: **77** (budget: 5, was 76 Issue #17, 76 Issue #16, 74 Issue #15). META-064 (P0 inflation fix) still has only 1 non-impl commit.
- **PERSISTS**: OBL count: **19** open-but-landed gaps including RESILIENT-135, EVAL-125, INFRA-1620 (fixed in #3135), INFRA-918, INFRA-1543, META-064, and 13 others.
- **CREDIBLE-125**: No public strategic watchpoint doc. `docs/strategy/OUTWARD_FLYWHEEL_2026-06-22.md` added (META-298/#3169) but CREDIBLE-125 gap remains open, 0 impl commits.

---

### The Looming Ghost

**[P0/Critical] G1 — 7-day total fleet silence: 0 commits to main from 2026-06-23 through 2026-06-29, following a 60% bypass rate on the 5 commits that did ship**

We are failing at basic fleet continuity. Since 2026-06-22 at 16:35 UTC-5 (commit `7b97da6`, fix(CREDIBLE-144)), there have been **zero commits to `origin/main` for 7 consecutive days**. The mission scoreboard reports "last merge 911m ago" and verdict "STALLED."

```
git log origin/main --since="2026-06-23" --oneline
(empty — 7 days of silence)

bash scripts/dev/mission-scoreboard.sh
→ ① THE BINARY: ❌ NO (BEAST merges last 7d: 0)
→ ④ Fleet liveness: last merge 911m ago
→ VERDICT: 🔴 STALLED — no merge in 911m
```

The 5 commits that did ship on 2026-06-22 had a 60% bypass rate — the highest short-cycle bypass rate observed. Three distinct chump binary wedge failure classes appeared: (1) `CHUMP_BYPASS_BOT_MERGE=1` operator recovery after self-heal failed twice, (2) title-similarity blocking bot-merge preflight import (`INFRA-1434` — never filed despite trailer promise), (3) concurrent background cargo build persistently wedging the binary. The fleet shipped 5 commits and then went silent. No recovery visible.

- evidence 1: `git log origin/main --since="2026-06-23" --oneline` → empty (7 days silence)
- evidence 2: `bash scripts/dev/mission-scoreboard.sh` → STALLED, 911m since last merge, ① NO
- evidence 3: 3 of 5 non-cold-water commits carried `Bot-Merge-Bypass:` trailers — 60% rate, all-time highest for any short cycle

*This finding is wrong if: commits exist on a branch being prepared for merge but not yet landed — `git log origin/main` would miss them. No merged PRs exist on origin/main after 2026-06-22; the finding stands against that surface.*

---

### The Opportunity Cost

**[P0/Critical] O1 — MISSION-043 (merge-confirmation loop) filed 1 cycle ago, 0 impl commits; mission scoreboard ① still NO for 8th consecutive cycle; BEAST-MODE PR count unknown but mission metric unchanged**

We are failing to advance the mission for the eighth consecutive audit cycle. MISSION-043 was filed in Issue #17 (2026-06-22) specifically to track the "11 BEAST-MODE PRs, 0 merged" failure. Seven days later: 0 implementation commits, mission scoreboard unchanged.

```
git log origin/main --grep='MISSION-043' --oneline | grep -v cold-water
(empty — 0 impl commits, 1 cycle)

bash scripts/dev/mission-scoreboard.sh
→ ① THE BINARY: ❌ NO (BEAST merges last 7d: 0)
→ VERDICT: 🔴 STALLED
```

The fleet spent this cycle (2026-06-22) shipping: a Pi mesh actions-runner provisioner for Linux ARM64 (INFRA-1543), bot-merge rebase telemetry (INFRA-918), an Outward Flywheel strategy doc (META-298), a CREDIBLE-061 fixture seeding fix, and a RESILIENT-166 unregistered-artifact hotfix. None of these advance ①. The Pi mesh provisioner actively cost the fleet via an 80-minute merge stall when it shipped two unregistered artifacts that broke CI gates fleet-wide. The strategy doc is roadmap writing, not product output.

- evidence 1: scoreboard ① NO, 0 BEAST merges, 911m stalled
- evidence 2: MISSION-043 gap `status: open, priority: P0, impl_commits=0` (7 days after filing)
- evidence 3: 5 commits shipped this cycle, 0 reference BEAST-MODE or MISSION-043

*This finding is wrong if: BEAST-MODE PRs merged via a different mechanism (direct push, API merge) not captured by the scoreboard's `gh pr list` query. The scoreboard fetches `repairman29/BEAST-MODE` directly — if that repo's auth is broken, the scoreboard could false-report. The 7-day main silence corroborates the stalled reading.*

---

**[P1/High] O2 — EVAL-094, FLEET-053: 8th consecutive cycle, 0 implementation commits, no in-flight branches**

We are failing at research credibility and distributed coordination for the eighth consecutive cycle. EVAL-094 (naturalized-framing evaluation, n=50/cell) has never run. FLEET-053 (NATS production deployment) has never been attempted. Both appear in this audit since Issue #11.

```
git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
(empty — 8 cycles)

git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
(empty — 8 cycles)

git branch -r | grep -E "EVAL-094|FLEET-053"
(empty — no in-flight branches)
```

*This finding is wrong if: EVAL-094 or FLEET-053 work is underway in an unpushed branch. No remote branches found.*

---

### The Complexity Trap

**[P0/Critical] C1 — 4 PRs this cycle shipped referencing gap IDs that have no `.yaml` file: CREDIBLE-144, RESILIENT-166, META-298, MISSION-050 — all 4 are "ghost gap IDs"**

We are failing at the most basic gap-tracking discipline: every commit this cycle either used a bypass trailer or referenced a gap ID that doesn't exist in `docs/gaps/`. All 4 non-cold-water, non-bypass commits in this cycle reference ghost gap IDs.

```
ls docs/gaps/CREDIBLE-144.yaml → No such file
ls docs/gaps/RESILIENT-166.yaml → No such file
ls docs/gaps/META-298.yaml → No such file
ls docs/gaps/MISSION-050.yaml → No such file

git log origin/main --grep="CREDIBLE-144" --oneline | grep -v cold-water
7b97da6 fix(CREDIBLE-144): harden CREDIBLE-061 fixture seeding — retry 3x...

git log origin/main --grep="RESILIENT-166" --oneline | grep -v cold-water
64908eb fix(RESILIENT-166): fix #3170's two unregistered artifacts...

git log origin/main --grep="META-298" --oneline | grep -v cold-water
09861e8 docs(META-298): add Outward Flywheel roadmap (MISSION-050) + link...

git log origin/main --grep="MISSION-050" --oneline | grep -v cold-water
09861e8 docs(META-298): add Outward Flywheel roadmap (MISSION-050) + link...
```

Additionally, `INFRA-1434` was explicitly promised in a bypass trailer as "filed as a follow-up" and does not exist:
```
git log origin/main --format='%B' | grep 'INFRA-1434'
→ INFRA-1434 title-similarity blocked CREDIBLE-144/145 re-import → fatal exit; ... Import-wedge filed as a follow-up.
ls docs/gaps/INFRA-1434.yaml → No such file
```

The fleet is shipping commits, bypassing bot-merge, and promising follow-up gaps — none of which land. The gap store is losing coherence with what the fleet actually shipped.

- evidence 1: `ls docs/gaps/CREDIBLE-144.yaml` → not found; commit 7b97da6 in main
- evidence 2: `ls docs/gaps/RESILIENT-166.yaml` → not found; commit 64908eb in main
- evidence 3: `ls docs/gaps/INFRA-1434.yaml` → not found; promised "filed as follow-up" in bypass trailer of commit 7b97da6

*This finding is wrong if: the gap store is managed in `state.db` only and the `.yaml` files are generated exports. Commit messages reference `docs/gaps/*.yaml` as canonical; `gap reserve` creates `.yaml` files; the pre-commit hook validates gap IDs against the store. If the `.yaml` files are authoritative — which the codebase treats them as — all 4 are missing.*

---

### The Reality Check

**[P1/High] R1 — P0 count: 77 (budget: 5, 15× over); INFRA-1543 (Pi mesh provisioner) shipped with Bot-Merge-Bypass AND introduced 80-minute fleet-wide merge stall — bypassing bot-merge is bypassing the CI artifact-gate that would have caught the unregistered event kind**

We are failing to connect the bypass discipline to CI integrity. The INFRA-1543 Pi mesh provisioner used `Bot-Merge-Bypass: bot-merge.sh wedged on chump binary` to ship. Bot-merge includes a pre-merge artifact check. By bypassing, the PR skipped that check. The result: `install-self-hosted-runner-pi.sh` emitted `kind=pi_runner_installed` (not in `EVENT_REGISTRY.yaml`) and was absent from the install manifest. Both failures were caught only after the PR merged — by which point every subsequent PR queued against a CI that was now red.

```
git show b3b39f0 --format="%B" | grep "Bot-Merge-Bypass:"
Bot-Merge-Bypass: bot-merge.sh wedged on chump binary (self-heal failed twice)

git show 64908eb --format="%B" | head -10
fix(RESILIENT-166): fix #3170's two unregistered artifacts — unblock audit-shard(2) + pr-hygiene fleet-wide (#3172)
#3170 (Pi mesh runner provisioner) merged with two artifacts no gate allowlisted,
turning audit-shard(2) + pr-hygiene RED on every fresh PR -> fleet-wide merge stall (0 merges/80min)
```

P0 count: 77. Budget: 5. Cycle-over-cycle: 74 → 76 → 76 → 77. META-064 (P0 inflation fix gap) has 1 commit — a gap file, not an implementation.

```
ls docs/gaps/META-064.yaml → exists; status: open, priority: P1
git log origin/main --grep='META-064' --oneline | grep -v cold-water
(1 commit: the gap file itself — not an implementation)
```

- evidence 1: P0 count = 77 from YAML census; budget = 5 from CLAUDE.md `P0 budget = 5 max`
- evidence 2: INFRA-1543 bypass → RESILIENT-166 hotfix → commit confirms "0 merges/80min" stall
- evidence 3: META-064 gap `status: open` with 0 impl commits for 3 audit cycles

*This finding is wrong if: the 80-minute stall was a CI infrastructure failure unrelated to the bot-merge bypass. Commit 64908eb explicitly attributes the stall to the two unregistered artifacts introduced by #3170, which bypassed bot-merge.*

---

### The Innovation Lag

**[P1/High] I1 — The "Outward Flywheel" strategy doc (META-298, 2026-06-22) is the fleet writing a new roadmap for how to move the mission. The mission metric hasn't moved in 8 cycles. Writing a new theory of change is not a substitute for executing the existing one.**

We are failing to distinguish strategy production from strategy execution. PR #3169 (docs(META-298)) added `docs/strategy/OUTWARD_FLYWHEEL_2026-06-22.md` — 116 lines describing a "discovery-driven roadmap" for MISSION-010. The roadmap calls for running `chump improve` outward on real repos, then fixing "foundation-first (3→2→1: substrate → outward-loop → work-mix)." The commit body credits Claude Opus 4.8 (1M context).

```
git show 09861e8 --stat
docs/ROADMAP.md  | 1 +
docs/strategy/OUTWARD_FLYWHEEL_2026-06-22.md | 116 +
```

The fleet now has: `ROADMAP.md`, `ROADMAP_MARCUS.md`, `ROADMAP_BACKLOG.md`, `INTEGRATION_CYCLE_2026-05-29.md`, `DISK_AWARE_FLEET_2026-05-29.md`, `OUTWARD_FLYWHEEL_2026-06-22.md`, `STRATEGIC_MEMO_2026Q2.md` (moved to private). Six public strategy documents. Zero BEAST-MODE PRs merged. The correlation is not coincidence — the fleet defaults to producing strategy artifacts when it cannot move the mission metric. Strategy production is observable, satisfying, and safe. Mission execution is not.

The MISSION-050 reference in the new roadmap doc itself has no gap file. It is a strategy document that files a gap that doesn't exist, describing work that references prior gaps (MISSION-010, MISSION-011, MISSION-012) that also don't exist.

```
ls docs/gaps/MISSION-050.yaml → No such file
ls docs/gaps/MISSION-010.yaml → No such file
```

*This finding is wrong if: strategy-doc production is itself the acceptance criterion for MISSION-014. `docs/MISSION.md` says the Scoreboard is "the one honest measure" — "if a day's work didn't move it, it didn't count."*

---

**THE ONE BIG THING:** [P0] We are failing to keep the fleet alive. The cycle ended with 0 commits to main for 7 days — not a BEAST-MODE stall, but a total fleet shutdown. The 5 commits that shipped before the silence had a 60% bypass rate. The bypass that shipped INFRA-1543 (Pi mesh provisioner) caused an 80-minute CI stall that may explain the silence: every queued PR was blocked on red CI gates, and with the chump binary wedging on every bot-merge attempt, no worker could clear the queue. The fleet wrote a new Outward Flywheel strategy document while the queue burned. The mission scoreboard reads ① NO for the 8th consecutive cycle. Four of the five commits this cycle reference gap IDs with no `.yaml` files — the fleet is losing track of what it has and hasn't shipped. Filed CREDIBLE-126 (4 ghost gap IDs shipped without `.yaml` files), RESILIENT-167 (INFRA-1434 bypass-promised follow-up never filed), and EFFECTIVE-293 (7-day silence root-cause investigation).

---

### Follow-up Gaps Filed

(Gap `.yaml` files written manually — chump binary unavailable for `state.db` import. Operator must run `chump gap import` to sync YAML into state.db before these appear in `chump gap list`.)

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| CREDIBLE-126 | CREDIBLE: 4 commits shipped this cycle referencing gap IDs with no .yaml file — ghost commit hygiene failure | P1 | xs |
| RESILIENT-167 | RESILIENT: INFRA-1434 promised "filed as follow-up" in bypass trailer — never filed; bypass trailers are lying | P1 | xs |
| EFFECTIVE-293 | EFFECTIVE: 7-day main-branch silence (2026-06-23–2026-06-29) — root-cause and fleet restart | P0 | s |

```
# Verification (run after chump gap import):
ls docs/gaps/CREDIBLE-126.yaml docs/gaps/RESILIENT-167.yaml docs/gaps/EFFECTIVE-293.yaml
# → all three exist (verified at write time)
# chump gap list --json | python3 -c "import json,sys; ids={g['id'] for g in json.load(sys.stdin)}; print({x for x in ['CREDIBLE-126','RESILIENT-167','EFFECTIVE-293'] if x in ids})"
# → run after chump gap import to confirm state.db sync
```

Pre-existing gaps covering other findings: MISSION-043 (BEAST-MODE merge loop, P0/m, 0 impl commits), RESILIENT-160 (dyld_start wedge, P1/s, 0 impl commits), EVAL-094 (8 cycles inactive), FLEET-053 (8 cycles inactive), MISSION-042 (ghost gap IDs MISSION-010/011/012, 3 cycles inactive), META-064 (P0 inflation, 0 impl commits), INFRA-1610 (OBL structural fix, 0 impl commits).


---

## Issue #17 — 2026-06-22

> Audit window: commits since 2026-06-15 (Issue #16). 32 commits to `origin/main` (PRs #3127–#3164). Sandbox: local worktree on main, chump shim present but binary unavailable (shim could not locate real chump binary). Auth broken (`auth-status.sh` exits non-zero: no credentials found). Bootstrap incomplete: 12 missing daemons, 24 manifest-missing. All evidence from git + YAML file reads + bash scripts. 3 follow-up gaps filed: RESILIENT-160, MISSION-043, CREDIBLE-125.

---

### Status of Prior Issues (Issue #16)

- **FIXED**: INFRA-1620 (PWA app.js SyntaxError) — PR #3135 (`6469a73`) shipped 2026-06-20. `node --check web/v2/app.js` returns exit 0. Gap still `status: open` (OPEN-BUT-LANDED — not closed), but the 7-week syntax error is repaired.
  ```
  git log origin/main --grep='INFRA-1620' --oneline
  6469a739 fix(INFRA-1620): restore PWA app.js — reassemble 5 truncated view classes (#3135)
  cat docs/gaps/INFRA-1620.yaml | grep 'status:'
    status: open   ← gap closure still pending
  ```

- **BETTER**: G1 — **Bot-Merge-Bypass rate: 12.5%** this cycle (4 of 32 commits). Down from 31% post-RESILIENT-135, down from 43% at Issue #16. All 4 bypasses this cycle are a NEW failure class: chump binary wedge at `dyld_start`. This is a different root cause than RESILIENT-135.
  ```
  git log origin/main --since='2026-06-15' --format='%B' | grep -c 'Bot-Merge-Bypass:'
  4
  git log origin/main --since='2026-06-15' --oneline | wc -l
  32
  git log origin/main --since='2026-06-15' --format='%B' | grep 'Bot-Merge-Bypass:'
  Bot-Merge-Bypass: chump binary wedge in dyld_start prevents bot-merge.sh from running; doc-only PR, safe to push directly
  Bot-Merge-Bypass: chump binary wedges on every bot-merge invocation (INFRA-1399 pattern); unwedge + immediate re-wedge cycle
  Bot-Merge-Bypass: bot-merge.sh blocked by recurring chump binary wedge (inode dyld_start hang)
  Bot-Merge-Bypass: bot-merge.sh wedged chump binary twice; using manual ship fallback
  ```

- **STILL_OPEN_INACTIVE (7 cycles)**: EVAL-094 — naturalized-framing evaluation. 0 implementation commits ever.
  ```
  git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
  (empty)
  ```

- **STILL_OPEN_INACTIVE (7 cycles)**: FLEET-053 — NATS deployment. 0 implementation commits ever.
  ```
  git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
  (empty)
  ```

- **STILL_OPEN_INACTIVE (2 cycles)**: MISSION-042 — MISSION-010/011/012 ghost gap IDs. Filed Issue #16. 0 implementation commits.
  ```
  git log origin/main --grep='MISSION-042' --oneline | grep -v cold-water
  (empty)
  ls docs/gaps/MISSION-010.yaml docs/gaps/MISSION-011.yaml docs/gaps/MISSION-012.yaml
  → all: No such file or directory
  ```

- **STILL_OPEN_INACTIVE (2 cycles)**: META-274 — CREDIBLE-122 fix merged, gap not closed, e2e orphaned. 0 implementation commits.
  ```
  git log origin/main --grep='META-274' --oneline | grep -v cold-water
  (empty)
  cat docs/gaps/CREDIBLE-122.yaml | grep 'status:'
    status: open
  ```

- **STILL_OPEN_INACTIVE (2 cycles)**: CREDIBLE-124 — INFRA-821 silently fixed, gap still open. 0 implementation commits.
  ```
  git log origin/main --grep='CREDIBLE-124' --oneline | grep -v cold-water
  (empty)
  ```

- **FIXED_BUT_NOT_CLOSED**: EFFECTIVE-112 — private repo clone auth. `src/onboard.rs` now has `x-access-token` injection (landed under INFRA-1612, commit `72d9d8b`, 2026-06-08). Gap EFFECTIVE-112 still `status: open` — never closed despite the fix landing.
  ```
  grep 'x-access-token' src/onboard.rs → line 1078: format!("https://x-access-token:{token}@{rest}")
  git log origin/main --grep='EFFECTIVE-112' --oneline | grep -v cold-water
  (empty — fix landed under INFRA-1612)
  cat docs/gaps/EFFECTIVE-112.yaml | grep 'status:'
    status: open
  ```

- **STILL_OPEN_ACTIVE**: RESILIENT-131 (autonomous completion rate). 0 new commits this cycle beyond gap file.
  ```
  git log origin/main --since='2026-06-15' --grep='RESILIENT-131' --oneline | grep -v cold-water
  (empty)
  ```

- **WORSE**: P0 count: **76** (unchanged from Issue #16, budget: 5 max). Still 15× budget.

---

### The Looming Ghost

**[P0/Critical] G1 — chump binary wedge at dyld_start is the new dominant bot-merge blocker: 4 of 4 bypasses this cycle reference "INFRA-1399 pattern" but no gap with that ID exists**

We are failing to track our own failure modes. Every bypass this cycle is identical: the chump binary wedges in `dyld_start` on each `bot-merge.sh` invocation, self-heals once via `CHUMP_DOCTOR_FORCE=1`, then immediately re-wedges. The commit trailers reference "INFRA-1399 pattern" as the named failure class. There is no `docs/gaps/INFRA-1399.yaml`. No gap. No acceptance criteria. No owner. The bypass trailers confirm this pattern exists, has a name, is recurring, and costs operator time every occurrence — but the fleet has no pickable work to eliminate it.

```
find docs/gaps -name 'INFRA-1399.yaml'
(empty — gap does not exist)

git log origin/main --since='2026-06-15' --format='%B' | grep 'Bot-Merge-Bypass:.*dyld\|Bot-Merge-Bypass:.*wedge'
Bot-Merge-Bypass: chump binary wedge in dyld_start prevents bot-merge.sh from running
Bot-Merge-Bypass: chump binary wedges on every bot-merge invocation (INFRA-1399 pattern)
Bot-Merge-Bypass: bot-merge.sh blocked by recurring chump binary wedge (inode dyld_start hang)
Bot-Merge-Bypass: bot-merge.sh wedged chump binary twice; using manual ship fallback

grep -rl 'dyld_start' docs/gaps/
(empty)
```

INFRA-1218 (binary unwedge rename, P3, done) is the nearest gap — but it was a cosmetic rename of `chump-doctor.sh`, not a fix to the inode-busy deadlock. INFRA-275 is absent from the gap store entirely. The chump binary wedge at `dyld_start` is a recurring fleet-stopping bug with no filed gap and no assigned owner — a NO_GAP finding. Filed RESILIENT-160.

*This finding is wrong if: a gap for the dyld_start inode-busy deadlock exists under a different ID not found by `grep -rl 'dyld_start' docs/gaps/`. Not found.*

---

### The Opportunity Cost

**[P0/Critical] O1 — 11 BEAST-MODE PRs opened by the fleet, 0 merged: three weeks of mission-gap shipping (MISSION-046/047/048/EFFECTIVE-288/291) has not moved ① off NO**

We are failing to move the mission. MISSION-046 (external_repo routing), MISSION-047 (haiku picker bypass), MISSION-048 (sonnet for m+ gaps), EFFECTIVE-288 (GREEN-FIRST), and EFFECTIVE-291 (stale clone refresh) all shipped this cycle — legitimate fixes to legitimate problems. And yet:

```
bash scripts/dev/mission-scoreboard.sh
→ ① THE BINARY: ❌ NO (BEAST merges last 7d: 0)
→ ④ Fleet liveness: last merge 906m ago
→ VERDICT: 🔴 STALLED

git log origin/main --format='%B' | grep -o 'BEAST PR[s]* #[0-9/#]*'
BEAST PRs #10/#11
```

At least 11 PRs were opened on repairman29/BEAST-MODE. None merged. EFFECTIVE-291's commit message (`2026-06-22: BEAST PRs #10/#11 based on a February commit, failing gates already fixed on real main`) explains why: the fleet's external clone was months stale — branches based on a February HEAD failed gates that had since been fixed on the actual BEAST-MODE main. EFFECTIVE-291 fixes the stale-clone problem, but the 11 stranded PRs are not retroactively fixed. Each was a wasted cycle.

The scoreboard ① has been NO for every cycle this audit has run. Three MISSION-* gaps shipped this week routing and model-selecting for BEAST-MODE work — but the metric is still zero. The fleet cannot declare victory on mechanism changes while the output measure is unchanged.

- evidence: `mission-scoreboard.sh` → ① NO, 0 BEAST merges, STALLED
- evidence: EFFECTIVE-291 commit body: "BEAST PRs #10/#11 based on a February commit"
- evidence: 3 MISSION-* PRs + 2 EFFECTIVE-* PRs shipped this cycle to unblock BEAST; scoreboard unchanged

*This finding is wrong if: BEAST-MODE PRs merged in the last 7 days and the scoreboard script is reading the wrong repo. The scoreboard fetches `repairman29/BEAST-MODE` directly via `gh` — `mission-scoreboard.sh` output is the ground truth.*

---

**[P1/High] O2 — EVAL-094, FLEET-053: 7th consecutive cycle, 0 implementation commits**

We are failing at research credibility and distributed coordination for the seventh consecutive cycle. EVAL-094 (naturalized-framing evaluation, n=50/cell) has never run. FLEET-053 (NATS production deployment) has never been attempted. Both have been in this review since Issue #11. The research-integrity concern (RESEARCH_INTEGRITY.md §Mechanism Analysis: "any delta >±0.05 must cite a paired naturalized-framing comparison from the EVAL-094 result set") is unaddressed for the seventh week running.

```
git log origin/main --grep='EVAL-094' --oneline | grep -v cold-water
(empty — 7 cycles)

git log origin/main --grep='FLEET-053' --oneline | grep -v cold-water
(empty — 7 cycles)
```

*This finding is wrong if: EVAL-094 or FLEET-053 have implementation commits in an unmerged branch. `git branch -r | xargs git log --grep=EVAL-094 --oneline` was not run — downgrade to STALE if branches found.*

---

### The Complexity Trap

**[P1/High] C1 — OPEN-BUT-LANDED count: 18; including INFRA-1620 (FIXED this cycle), EFFECTIVE-112 (FIXED under wrong gap ID), and RESILIENT-135 (fix merged weeks ago) — the gap-close ritual is systematically failing**

We are failing at closing what we ship. 18 gaps are `status: open` in the gap store despite having implementation commits on main. The structural fix (INFRA-1610) still has 0 implementation commits (unchanged from Issue #16, checked: `git log origin/main --grep='INFRA-1610' --oneline | grep -v cold-water` → empty). The gap-close step is an afterthought in the ship pipeline, not a gate.

```
# OBL scan (excl. cold-water chore commits):
OPEN-BUT-LANDED: 18 gaps
  INFRA-705: 3 impl commits
  INFRA-1658: 3 impl commits
  INFRA-1620: 1 impl commit (FIXED this cycle — gap unclosed)
  RESILIENT-135: 1 impl commit (FIXED weeks ago — gap unclosed)
  EFFECTIVE-112: 0 direct commits (FIXED under INFRA-1612 — gap never closed)
  INFRA-1506: 1 impl commit
  INFRA-1511: 1 impl commit
  ... (13 more)

git log origin/main --grep='INFRA-1610' --oneline | grep -v cold-water
(empty — structural fix still 0 commits, Issue #16 same result)
```

The P0 budget is 76 (budget: 5, now in the 15th× range since Issue #12). META-064 (P0 inflation fix) still 0 commits — `git log origin/main --grep='META-064' --oneline | grep -v cold-water` → empty.

*This finding is wrong if: the gap-close step is intentionally deferred and INFRA-1610 is scheduled for the next cycle. No such scheduling found.*

---

### The Reality Check

**[P1/Medium] R1 — Fleet shipped 5 MISSION-* mechanism PRs this cycle; the mission metric is unchanged; MISSION-042 (ghost gap IDs MISSION-010/011/012) is still open, filed last cycle, 0 commits**

We are failing at credible mission tracking. Commits reference `MISSION-010` as the canonical gap in subject lines ("Unblocks BEAST-MODE (MISSION-010)") — but `docs/gaps/MISSION-010.yaml` still does not exist. MISSION-042 was filed last cycle to surface exactly this problem. It has 0 implementation commits.

```
ls docs/gaps/MISSION-010.yaml docs/gaps/MISSION-011.yaml docs/gaps/MISSION-012.yaml
→ all: No such file or directory

git log origin/main --grep='MISSION-042' --oneline | grep -v cold-water
(empty — 0 implementation commits, 1 cycle stale)

# Commits referencing a non-existent gap this cycle:
grep 'MISSION-010' → feat(MISSION-046): "Unblocks BEAST-MODE (MISSION-010)"
                  → feat(EFFECTIVE-288): "Unblocks BEAST-MODE (MISSION-010)"
```

Three commits this cycle invoke MISSION-010 as the authoritative gap ID for the mission proof. The gap does not exist in the store. The fleet is referencing a ghost as its north star in commit subjects. Filed MISSION-043.

STRATEGIC_MEMO_2026Q2.md has been moved to `chump-proprietary` (private). The public doc is a tombstone. No linked public gap for its former recommendations was found.

*This finding is wrong if: MISSION-010 exists in a private gap store not reflected in docs/gaps/. No such architecture is documented.*

---

### The Innovation Lag

**[P1/Medium] I1 — The fleet's entire external-repo strategy is "chump improve opens PRs" but 11 PRs on BEAST-MODE prove the strategy accumulates stranded PRs, not merged ones**

We are failing to validate the external-repo strategy against the only metric that matters. The fleet's theory of change for the mission is: (1) route external_repo gaps to `chump improve`, (2) `chump improve` opens PRs on BEAST-MODE, (3) PRs merge. Steps 1 and 2 now work — MISSION-046/047/048/EFFECTIVE-288/291 all shipped this cycle to fix routing, picker starvation, stale clones, and model selection. Step 3 has never happened. 11 PRs opened, 0 merged.

The stranded-PR failure mode is structural, not incidental: the fleet has no GREEN-FIRST backpressure that says "stop opening new PRs until existing ones merge." EFFECTIVE-288 (GREEN-FIRST) partially addresses this — it forces a CI-fix pick when ≥2 PRs share a failing gate. But it fires after the damage is already 11 PRs deep, and it doesn't close the stranded PRs.

External benchmarks relevant to this gap (as of 2026-06-22): OpenHands (AllHands AI) published evaluation results showing their SWE-bench agent achieves ~26% resolve rate on real repo PRs. Devin reports ~13%. The Chump BEAST-MODE resolve rate is 0/11 = 0%. The gap is not that AI agents fail to open PRs — it's that Chump's pipeline has no merge-confirmation loop. Source: https://www.swebench.com (accessed 2026-06-22 — SWE-bench leaderboard).

STRATEGIC_MEMO_2026Q2.md was the document for tracking field movements. It has been moved to private. There is no linked public strategic watchpoint document and no gap filed to maintain external positioning. Filed CREDIBLE-125.

*This finding is wrong if: BEAST-MODE PRs have merged but the scoreboard script is broken. `bash scripts/dev/mission-scoreboard.sh` → ① NO, 0 merges is the scoreboard's own output.*

---

**THE ONE BIG THING:** [P0] We are failing to merge anything on BEAST-MODE. The fleet spent the entire audit cycle shipping five mechanism PRs — picker routing, model selection, stale-clone refresh, GREEN-FIRST CI checks — and opened at least 11 PRs on repairman29/BEAST-MODE. Zero merged. The mission scoreboard reads ① NO for the seventh consecutive audit cycle. MISSION-042 (filed last cycle to fix ghost gap IDs MISSION-010/011/012) has 0 implementation commits — the fleet still references MISSION-010 as the canonical gap in commit subjects while that gap does not exist in the store. The mechanism work is real and necessary. But mechanism work that doesn't move ① is infrastructure spending with no product return. Filed MISSION-043 to track the merge-gap specifically; the gap is not "open more PRs" — it is "close the first one."

---

### Follow-up Gaps Filed

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| RESILIENT-160 | RESILIENT: chump binary dyld_start inode-wedge has no gap — "INFRA-1399 pattern" referenced in 4 bypass trailers with no filed gap or AC | P1 | s |
| MISSION-043 | MISSION: 11 BEAST-MODE PRs opened, 0 merged — fleet has no merge-confirmation loop or stranded-PR backpressure | P0 | m |
| CREDIBLE-125 | CREDIBLE: no public strategic watchpoint doc after STRATEGIC_MEMO_2026Q2 moved to private; no linked gap for external positioning | P2 | xs |

Pre-existing gaps covering remaining findings: EVAL-094 (7 cycles inactive), FLEET-053 (7 cycles inactive), MISSION-042 (ghost gap IDs, 1 cycle inactive), META-274 (CREDIBLE-122 unclosed, 1 cycle inactive), CREDIBLE-124 (INFRA-821 unclosed, 1 cycle inactive), INFRA-1610 (OBL structural fix, 0 commits), META-064 (P0 inflation, 0 commits), EFFECTIVE-112 (OPEN-BUT-LANDED under INFRA-1612).

```
verification:
  ls docs/gaps/RESILIENT-160.yaml → exists
  ls docs/gaps/MISSION-043.yaml → exists
  ls docs/gaps/CREDIBLE-125.yaml → exists
```

---

## Issue #16 — 2026-06-15

> Audit window: commits since 2026-06-08 (Issue #15). 21 commits to `origin/main` (PRs #3103–#3124). Sandbox: fresh clone, chump binary built from source (14 min), ran successfully. `gap-doctor.py doctor` now passes cleanly — **INFRA-821 silently fixed** (auto_seed_if_empty in GapStore, no stand-alone commit), though gap still status:open (filed CREDIBLE-124). `chump gap list --json` returns 715 open gaps, 76 P0. 3 follow-up gaps filed: MISSION-042, META-274, CREDIBLE-124. `gh` CLI unavailable; GitHub MCP not used (all evidence from git + YAML + state.db).

---

### Status of Prior Issues (Issue #15)

- **WORSE**: G1 — **Bot-Merge-Bypass rate: 43%** since Issue #15 (9 of 21 commits). All-time rate: 66% (33 of 50). Root cause RESILIENT-135 (timeout death-spiral) shipped as PR #3109 — bypass rate post-fix is 31% (4 of 13 commits). Pipeline is less dead but still failing. RESILIENT-131 (autonomous completion rate ≈ 0) still open, P1, 1 commit (gap file only).
  ```
  git log origin/main --since='2026-06-08' --format='%B' | grep -c 'Bot-Merge-Bypass:'
  9
  git log origin/main --since='2026-06-08' --oneline | wc -l
  21
  git log origin/main --format='%B' | grep -c 'Bot-Merge-Bypass:'
  33   (all-time 50 commits)
  # Post-RESILIENT-135-fix rate: 4/13 = 31%
  ```
- **PARTIALLY_FIXED (OPEN-BUT-LANDED)**: G2 — CREDIBLE-122 fix PR fbe4d11 merged 2026-06-07. But gap still `status: open`. And test-a2a-consensus-e2e.sh is NOT in CI. `feedback.jsonl` has 0 events on fresh clone. Filed META-274.
  ```
  grep 'status:' docs/gaps/CREDIBLE-122.yaml → status: open
  grep -r 'test-a2a-consensus-e2e' .github/workflows/ → (no matches)
  cat .chump-locks/feedback.jsonl → (no file)
  ```
- **SILENTLY_FIXED (OPEN-BUT-LANDED)**: O1 — INFRA-821 state.db auto-seed: crates/chump-gap-store/src/lib.rs:635 added `auto_seed_if_empty()` — `chump gap list` auto-imports from docs/gaps/ on first run. `gap-doctor.py doctor` now completes cleanly (975 rows in state.db). Gap still `status: open`. Filed CREDIBLE-124.
  ```
  python3 scripts/coord/gap-doctor.py doctor → Total gaps in DB: 975 / Total drift entries: 0
  grep 'status:' docs/gaps/INFRA-821.yaml → status: open
  # Fix tag: "[gap-list] state.db is empty — auto-importing from docs/gaps/ (INFRA-821)"
  # appears in crates/chump-gap-store/src/lib.rs:635 but not in any standalone commit
  ```
- **BETTER**: O2 — OPEN-BUT-LANDED count: **23** (was 34 in Issue #15). Still significant: INFRA-2744 has 12 impl commits but status:open; RESILIENT-135 has 1 impl commit (its own fix PR) but status:open. INFRA-1610 (structural OBL fix gap) still 0 impl commits.
  ```
  OBL scan (excl. cold-water chore): 23 (was 34 in Issue #15)
  git log origin/main --grep='INFRA-1610' --oneline → (empty)
  ```
- **WORSE**: C1 — P0 count: **76** (was 74, budget: 5). 72 of 76 have zero implementation commits. META-064 (P0 inflation fix gap) still 0 commits.
  ```
  find docs/gaps -name '*.yaml' | xargs grep -l 'status: open' | xargs grep -l 'priority: P0' | wc -l
  76
  # 72/76 with 0 impl commits (excl. cold-water chore)
  git log origin/main --grep='META-064' --oneline → (empty)
  ```
- **PARTIALLY_FIXED**: G1-old — RESILIENT-135 (timeout death-spiral root cause of autonomous completion ≈ 0) fixed in PR #3109. But gap still `status: open` (OPEN-BUT-LANDED). Post-fix bypass rate 31% — better but not 0.
  ```
  git show 7ad6a2c --format='%s' → fix(RESILIENT-135): worker timeout death-spiral...
  grep 'status:' docs/gaps/RESILIENT-135.yaml → status: open
  ```
- **STILL_OPEN_INACTIVE (6 cycles)**: INFRA-1620 — PWA SyntaxError at line 2244. Confirmed live.
  ```
  node --check web/v2/app.js → SyntaxError: Unexpected identifier 'ChumpViewFleetHealth' at line 2244
  git log origin/main --grep='INFRA-1620' --oneline → (cold-water chore only)
  ```
- **STILL_OPEN_INACTIVE (6 cycles)**: EVAL-094 — naturalized-framing evaluation. 0 commits.
  ```
  git log origin/main --grep='EVAL-094' --oneline → (cold-water chore only)
  ```
- **STILL_OPEN_INACTIVE (6 cycles)**: FLEET-053 — NATS deployment. 0 commits.
  ```
  git log origin/main --grep='FLEET-053' --oneline → (cold-water chore only)
  ```
- **STILL_OPEN (first raised)**: CREDIBLE-123 — Prohibited Claims gate gaps (EVAL-043/035/042/041/030) still ALL MISSING.
  ```
  ls docs/gaps/EVAL-043.yaml docs/gaps/EVAL-035.yaml docs/gaps/EVAL-042.yaml docs/gaps/EVAL-041.yaml docs/gaps/EVAL-030.yaml
  → all: No such file or directory
  ```
- **FIXED**: META-273 — RED_LETTER bundling defect. Issue #15 commit (807aa75) is a standalone `chore(cold-water)` commit, not bundled into an unrelated PR. Fixed for this cycle. META-273 gap still open (fix must hold for 3+ cycles).

---

### The Looming Ghost

**[P0/High] G1 — Autonomous ship pipeline: bypass rate dropped from 90% to 43%, but still failing. RESILIENT-135 fix was real; the remaining bypasses trace to three distinct new failure classes**

We are failing at building a reliable autonomous ship pipeline. The RESILIENT-135 fix (worker timeout death-spiral) was genuine — it identified a bug where consecutive xs-gap compounding collapsed the claude -p budget to 0s, explaining why "autonomous completion ≈ 0." The fix landed. The post-fix bypass rate is 31%. That is better than 90%, but still means 1 in 3 ships requires a human hand.

The 4 post-fix bypasses break into distinct failure classes:
1. **Claim collision**: "bot-merge.sh failed with live-claim collision" — concurrent workers race on the same gap (INFRA-2744 state.db vs .chump-locks JSON split-brain; 12 commits, still open)
2. **Cargo fmt stall**: "bot-merge stalled after cargo fmt step (INFRA-1399)" — pre-merge fmt check hangs under fleet load
3. **Gap already shipped**: "gap already shipped, just updating local state" — state synchronization lag after another worker merged
4. **Manual gap closure**: "implementation already merged; gap closure-only commit" — gap closure committed manually

Classes 1 and 2 are root causes that remain unpatched. Class 3 reveals a race where multiple workers claim after a gap ships. Class 4 is manual overhead.

- evidence: `git log origin/main --since='2026-06-08T19:19:16' --format='%B' | grep 'Bot-Merge-Bypass:'` → 4 bypasses in 13 post-fix commits (31%)
- evidence: INFRA-2744.yaml `status: open` with 12 referencing commits — the JSON-vs-state.db split-brain was noted as "shipped" in INFRA-2744.notes on 2026-06-05 but gap never closed
- evidence: RESILIENT-131.yaml still `status: open, priority: P1` — overall autonomous completion AC ("at least one gap goes claim→implement→CI-green→merge with NO human/Opus/bypass intervention") is unmet

*This finding is wrong if: every post-fix bypass was from a documentation-only or gap-closure commit (not Rust/test code), which would indicate autonomous Rust shipping is now 0% bypass. Not observed — three of the 4 bypass commits are non-doc PRs.*

---

**[P0/High] G2 — MISSION-010/011/012 are ghost gap IDs: the mission's canonical gap, picker mechanism, and THE MULTIPLIER are referenced by name in docs/MISSION.md but do not exist in the gap store or git history — the mission has no pickable gaps tracking its own completion**

We are failing at credible mission tracking. `docs/MISSION.md` declares three foundational gap IDs as authoritative:

```
"Canonical mission gap: MISSION-010" (zero-human-touch fleet, proven on BEAST-MODE)
"The picker (MISSION-011) reads ACTIVE_MISSION"
"Current multiplier: MISSION-012 (self-deploy). Metric: manual deploy steps per ship = 0."
"Filed as MISSION-014."
```

None exist:
```
ls docs/gaps/MISSION-010.yaml → No such file or directory
ls docs/gaps/MISSION-011.yaml → No such file or directory
ls docs/gaps/MISSION-012.yaml → No such file or directory
ls docs/gaps/MISSION-014.yaml → No such file or directory

python3 -c "
import sqlite3
conn = sqlite3.connect('.chump/state.db')
r = conn.execute(\"SELECT id FROM gaps WHERE id IN ('MISSION-010','MISSION-011','MISSION-012','MISSION-014')\").fetchall()
print(r)
" → []
```

The gap store jumps from MISSION-006 directly to MISSION-029. MISSION-007 through MISSION-028 are all absent. The 4 mission IDs that docs/MISSION.md declares as the operative proof targets are headless: nothing in the fleet picks them, nothing tracks their completion, and the mission scoreboard's ① binary ("zero-human-touch PR merged in BEAST-MODE this week? NO") has no actionable gap assigned to closing that binary to YES.

MISSION-029 corroborates: `"MISSION: picker doesn't actually read ACTIVE_MISSION env var — docs/MISSION.md says it does, src/ grep finds zero refs"` — confirming that MISSION-011's promised feature (picker reads ACTIVE_MISSION) was never implemented.

Filed MISSION-042.

- evidence: `ls docs/gaps/MISSION-010.yaml docs/gaps/MISSION-011.yaml docs/gaps/MISSION-012.yaml docs/gaps/MISSION-014.yaml` → all absent
- evidence: `python3 -c "sqlite3 state.db SELECT id WHERE id IN ..."` → empty
- evidence: MISSION-029.yaml description: "grep -rn ACTIVE_MISSION src/ returns zero matches"
- evidence: `bash scripts/dev/mission-scoreboard.sh` → "① THE BINARY: ❌ NO (BEAST merges last 7d: 0)"

*This finding is wrong if: MISSION-010 through MISSION-014 exist in a private `chump-proprietary` or sub-module not checked into this repo, and the gap store used by the fleet reads from that location. No such note in docs/MISSION.md.*

---

### The Opportunity Cost

**[P1/High] O1 — EFFECTIVE-112 (chump can't clone private repos) has 0 implementation commits after 6+ weeks: it is a P0 gap and the entry gate to the canonical mission proof**

We are failing to unblock the mission's only concrete proof. EFFECTIVE-112 (`chump onboard` fails on private repos with "Password authentication is not supported") blocks every step of the BEAST-MODE proof:

```
cat docs/gaps/EFFECTIVE-112.yaml | grep 'status:\|priority:' → status: open / priority: P0
git log origin/main --grep='EFFECTIVE-112' --oneline → (empty — 0 implementation commits)
```

The gap was filed 2026-06-03 (7+ weeks ago when counting from project inception, verified via description "VERIFIED 2026-06-03 by RUNNING it"). The fix is a 10-line change in `src/onboard.rs`: inject `https://x-access-token:$GH_TOKEN@github.com/...` into the clone URL. The effort tag is `s`. BEAST-MODE is private. The fleet cannot clone it. MISSION-010 (which doesn't exist as a gap — see G2) would depend on this being fixed first.

The mission scoreboard explicitly says ① is NO and cites MISSION-012 (self-deploy, also a ghost gap) as "THE MULTIPLIER." Even if self-deploy landed, the fleet can't reach BEAST-MODE to deploy anything.

- evidence: `cat docs/gaps/EFFECTIVE-112.yaml` → `status: open, priority: P0, effort: s`
- evidence: `git log origin/main --grep='EFFECTIVE-112' --oneline` → empty
- evidence: `bash scripts/dev/mission-scoreboard.sh` → `① ❌ NO (BEAST merges last 7d: 0)`
- evidence: EFFECTIVE-112.yaml description: "VERIFIED 2026-06-03 by RUNNING it: `chump onboard https://github.com/repairman29/BEAST-MODE` fails at clone with 'git clone exited exit status: 128'"

*This finding is wrong if: BEAST-MODE has since been made public (no such update in EFFECTIVE-112.yaml or any commit message), OR EFFECTIVE-112 was fixed under a different gap ID (grep of all commits for "private repo clone" or "onboard.rs auth" returns nothing).*

---

**[P1/High] O2 — EVAL-094, FLEET-053, INFRA-1620: 6th consecutive cycle, 0 implementation commits each. The first two are research validity gaps; the third is a public-facing syntax error**

We are failing at research credibility and basic code hygiene for the sixth consecutive cycle.

```
git log origin/main --grep='EVAL-094' --oneline → (cold-water chore only)
git log origin/main --grep='FLEET-053' --oneline → (cold-water chore only)
git log origin/main --grep='INFRA-1620' --oneline → (cold-water chore only)
node --check web/v2/app.js
→ SyntaxError: Unexpected identifier 'ChumpViewFleetHealth' at line 2244
```

EVAL-094 (naturalized-framing evaluation): docs/strategy/EVAL_AWARE_SANDBAGGING.md publicly states "the magnitude of every reported delta is at risk of inflation or deflation by evaluation-context confounding." RESEARCH_INTEGRITY.md §Required Methodology Standards: "Mechanism analysis for any delta > ±0.05 must explicitly consider evaluation-awareness as a candidate mechanism, and must cite either (a) a paired naturalized-framing comparison from the RESEARCH-026 / EVAL-094 result set." No such citation exists anywhere in the project — and EVAL-094 has never run (0 commits, 6 cycles).

INFRA-1620: The public-facing PWA (web/v2/app.js) has had a syntax error since 2026-05-14 (41 days, confirmed this cycle). The North Star describes it as the product's front door. It does not parse.

*This finding is wrong if: EVAL-094, FLEET-053, or INFRA-1620 have implementation commits in a branch not yet merged to main — `git branch -r | xargs git log --grep=<ID> --oneline` returns matches.*

---

### The Complexity Trap

**[P1/High] C1 — P0 count: 76 (was 74, budget 5): 72 of 76 have zero implementation commits; INFRA-1610 (OBL fix) and META-064 (P0 budget fix) are themselves inactive**

We are failing at the most basic property of a priority system for the sixth consecutive cycle. The gap that should fix P0 inflation (META-064) has 0 implementation commits. The gap that should fix OPEN-BUT-LANDED systematically (INFRA-1610) has 0 implementation commits. Neither is being worked.

```
find docs/gaps -name '*.yaml' | xargs grep -l 'status: open' | xargs grep -l 'priority: P0' | wc -l
76

git log origin/main --grep='META-064' --oneline → (empty)
git log origin/main --grep='INFRA-1610' --oneline → (empty)
```

The P0 domain breakdown: 56 INFRA, 8 META, 5 RESILIENT, 4 MISSION, 1 FLEET, 1 EVAL, 1 EFFECTIVE. The 4 active P0s (with ≥1 impl commits): INFRA-2188, MISSION-041, RESILIENT-118, RESILIENT-135. RESILIENT-135 is OPEN-BUT-LANDED (fix merged, gap not closed).

- evidence: `find docs/gaps ... | wc -l` → 76
- evidence: `git log origin/main --grep='META-064' --oneline` → empty (6 cycles)
- evidence: Issue trend: #12: 20 → #13: 29 → #14: 66 → #15: 74 → #16: 76

*This finding is wrong if: more than 5 of the 76 P0 gaps are deliberate "always-P0" tracking artifacts per a written operator policy defining a different budget. No such policy found.*

---

### The Reality Check

**[P1/Medium] R1 — CREDIBLE-122 is OPEN-BUT-LANDED: fix PR merged, gap not closed, end-to-end test orphaned from CI — the A2A consensus fix is unverified in any gate**

We are failing at closing what we fix. CREDIBLE-122 fix (deliberator tally seam repair) merged in PR fbe4d11. But:

1. `grep 'status:' docs/gaps/CREDIBLE-122.yaml` → `status: open` (gap not closed)
2. `grep -r 'test-a2a-consensus-e2e' .github/workflows/` → (no matches)
3. `feedback.jsonl` on a fresh clone: 0 events, 0 consensus_result events

The test-a2a-consensus-e2e.sh script exists at `scripts/ci/test-a2a-consensus-e2e.sh` but has never been wired into any CI workflow. The fix was described as making the deliberator "can now tally real votes" — but there is no gate that exercises the real vote path (chump vote → deliberator tick → consensus_result) rather than a synthetic fixture.

Filed META-274.

- evidence: `grep 'status:' docs/gaps/CREDIBLE-122.yaml` → `status: open`
- evidence: `grep -r 'test-a2a-consensus-e2e' .github/workflows/` → empty
- evidence: `cat .chump-locks/feedback.jsonl` → file absent (0 events)

*This finding is wrong if: a workflow other than the CI files in .github/workflows/ runs the e2e test (e.g. a Makefile target or scheduled job) — none found in the repo.*

---

### The Innovation Lag

**[P1/High] I1 — The BEAST-MODE mission proof has never been attempted: EFFECTIVE-112 blocks the entry gate, MISSION-010 doesn't exist as a gap, and the scoreboard shows 0 zero-human-touch merges**

We are failing to make progress toward the project's stated reason for existing.

```
bash scripts/dev/mission-scoreboard.sh
→ ① THE BINARY: ❌ NO (BEAST merges last 7d: 0)
→ VERDICT: 🔴 STALLED
```

Three layers of blocking:
1. **Entry gate broken**: `chump onboard` can't clone private repos (EFFECTIVE-112, P0, s effort, 0 commits, 6+ weeks)
2. **Mission tracker headless**: MISSION-010 (the canonical proof gap) doesn't exist; no gap in the fleet tracks "BEAST-MODE PR merged with zero human touch" as pickable work
3. **Picker broken**: MISSION-029 confirms the picker doesn't actually read ACTIVE_MISSION; mission-linked gaps don't get priority preference despite MISSION.md claiming they do

The mission scoreboard runs (MISSION-037 shipped), but it reports a signal with no actuator: there's no pickable gap in the fleet that closes ① to YES. The three fixes needed are all either P0-with-0-commits (EFFECTIVE-112) or ghost gaps (MISSION-010/012) or unimplemented doctrine (MISSION-011 picker, per MISSION-029).

- evidence: `bash scripts/dev/mission-scoreboard.sh` → STALLED, ① NO, 0 BEAST merges
- evidence: `ls docs/gaps/MISSION-010.yaml` → No such file
- evidence: `git log origin/main --grep='EFFECTIVE-112' --oneline` → empty
- evidence: MISSION-029.yaml: "grep -rn ACTIVE_MISSION src/ returns zero matches"

*This finding is wrong if: BEAST-MODE was worked in the last 7 days from a repo where this sandbox's git fetch is blocked. Sandbox git fetch retrieved 21 commits; the scoreboard's own "0 BEAST merges" output is the ground truth.*

---

**THE ONE BIG THING:** [P0] We are failing to have a mission. docs/MISSION.md is the "one honest measure" of whether Chump is moving. It names MISSION-010 as the canonical proof, MISSION-012 as "THE MULTIPLIER," and MISSION-011 as the picker mechanism. None of these gap IDs exist. MISSION-029 reveals the picker doesn't read ACTIVE_MISSION. EFFECTIVE-112 (P0, s, 0 commits) blocks even reading BEAST-MODE. The RESILIENT-135 fix reduced bypass rate from 90% to 31% — real progress — but the fleet is now shipping at 31% bypass on Chump's own infrastructure gaps. The gap store has 76 open P0s (budget: 5), the PWA has been syntactically broken for 41 days, and the mission's own tracking artifacts are missing. The project is most precisely described as: well-instrumented fleet shipping fixes to its own fleet infrastructure, with no pickable gap assigned to the mission outcome the fleet was built to achieve. Filed MISSION-042 to start this chain.

---

### Follow-up Gaps Filed

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| MISSION-042 | MISSION-010/011/012 are ghost gap IDs — mission's own tracking is headless | P1 | s |
| META-274 | CREDIBLE-122 fix merged, gap not closed, e2e test orphaned from CI | P1 | s |
| CREDIBLE-124 | INFRA-821 silently fixed but gap still open — state discrepancy | P1 | xs |

Pre-existing gaps covering remaining findings: EFFECTIVE-112, INFRA-1620, EVAL-094, FLEET-053, META-064, INFRA-1610, CREDIBLE-122, CREDIBLE-123, RESILIENT-131, INFRA-2744, MISSION-029.

```
ls docs/gaps/MISSION-042.yaml → exists
ls docs/gaps/META-274.yaml → exists
ls docs/gaps/CREDIBLE-124.yaml → exists

git log origin/main --grep='MISSION-042' --oneline → (absent — new this cycle)
git log origin/main --grep='META-274' --oneline → (absent — new this cycle)
git log origin/main --grep='CREDIBLE-124' --oneline → (absent — new this cycle)
```

---

## Issue #15 — 2026-06-08

> Audit window: commits since 2026-06-01 (Issue #14). 50 commits to `origin/main` (PRs #3063–#3102). Sandbox: fresh clone. `gap-doctor.py doctor` crashed with `no such table: gaps` on entry — **INFRA-821 confirmed live for the fifth consecutive cycle** (zero commits ever). `chump` binary still building from source at write time — **proposed-only mode**; SQLite verification deferred. `gh` CLI unavailable; GitHub MCP tools used for PR queries. 3 gap YAML files filed (CREDIBLE-123, META-273, EVAL-125) using manually-verified clean IDs (all confirmed absent from git history and docs/gaps/).

---

### Status of Prior Issues (Issue #14)

- **WORSE**: G1 — P0 count: **74** open P0 gaps (was 66, budget: 5 max). 69/74 have zero implementation commits.
  ```
  find docs/gaps -name '*.yaml' | xargs grep -l 'status: open' | xargs grep -l 'priority: P0' | wc -l
  74
  ```
- **PARTIALLY_FIXED**: G2 — RED_LETTER stranded. Issue #14 reached origin/main, but bundled inside unrelated commit `145c129` ("feat(EFFECTIVE-028): broadcast.sh --reply-to") on 2026-06-04. INFRA-2385 (the gap-reserve git-history-blind fix gap filed in Issue #14) is NOT in origin/main. META-272 (root-cause fix gap) has 0 implementation commits. The same bundling anti-pattern repeated a third time.
  ```
  git log origin/main -- docs/audits/RED_LETTER.md --format='%h %ad %s' --date=short | head -1
  145c129 2026-06-04 feat(EFFECTIVE-028): broadcast.sh --reply-to / corr_id threading
  ls docs/gaps/INFRA-2385.yaml → No such file or directory
  git log origin/main --grep='META-272' --oneline → (empty)
  ```
- **STILL_OPEN_INACTIVE (5 cycles)**: O1 — INFRA-821 state.db bootstrap crash. Confirmed live this cycle (5th). `python3 scripts/coord/gap-doctor.py doctor` → `sqlite3.OperationalError: no such table: gaps`. Zero commits ever.
  ```
  git log origin/main --grep='INFRA-821' --oneline → (empty)
  python3 scripts/coord/gap-doctor.py doctor → sqlite3.OperationalError: no such table: gaps
  ```
- **BETTER**: O2 — OPEN-BUT-LANDED count: **34** (was 123). Structural fix INFRA-1610 still has 0 implementation commits but normal gap closure activity reduced the count.
  ```
  OBL scan: 34 (was 123 in Issue #14)
  git log origin/main --grep='INFRA-1610' --oneline → (empty)
  ```
- **WORSE**: C1 — P0 budget inflation continues: **74** (was 66, +12%). INFRA-1611 (opened_date backfill) and INFRA-822 (TODO ACs) both at 0 commits, 5 cycles.
  ```
  git log origin/main --grep='INFRA-1611' --oneline → (empty, 5 cycles)
  git log origin/main --grep='INFRA-822' --oneline → (empty, 5 cycles)
  opened_date missing: 685/713 open gaps (96.1%)
  TODO ACs: 142 open gaps (was 139)
  ```
- **STILL_OPEN_INACTIVE (5 cycles)**: INFRA-1620 — PWA app.js SyntaxError at line 2244. Confirmed live this cycle.
  ```
  node --check web/v2/app.js → SyntaxError: Unexpected identifier 'ChumpViewFleetHealth' at line 2244
  git log origin/main --grep='INFRA-1620' --oneline → (empty)
  ```
- **STILL_OPEN_INACTIVE (5 cycles)**: FLEET-053 — NATS deployment gap.
  ```
  git log origin/main --grep='FLEET-053' --oneline → (empty)
  ```
- **STILL_OPEN_INACTIVE (5 cycles)**: EVAL-094 — naturalized-framing evaluation.
  ```
  git log origin/main --grep='EVAL-094' --oneline → (empty)
  ```
- **STILL_OPEN_INACTIVE (5 cycles)**: EVAL-102 / INFRA-824 — corrected eval protocol.
  ```
  git log origin/main --grep='EVAL-102' --oneline → (empty)
  git log origin/main --grep='INFRA-824' --oneline → (empty)
  ```
- **NO_GAP → filed this cycle**: CREDIBLE-123 (Prohibited Claims table cites 5 non-existent gate gaps), META-273 (RED_LETTER bundling defect recurred), EVAL-125 (PWA SyntaxError escalation gap).

---

### The Looming Ghost

**[P0/High] G1 — The autonomous ship pipeline is dead: 90% Bot-Merge-Bypass rate, 45 of 50 commits since June 1**

We are failing at the foundational promise of a self-operating fleet. The canonical ship pipeline (`bot-merge.sh --auto-merge`) was bypassed in 45 of 50 commits merged to `origin/main` since 2026-06-01 (90% bypass rate). The two most common bypass reasons are "fleet stopped (AUTONOMY_LEVEL=0)" and "INFRA-2744 re-claim split" — meaning either the fleet is intentionally stopped or the bot-merge re-claim mechanism is broken.

```
git log origin/main --since='2026-06-01' --format='%B' | grep -c 'Bot-Merge-Bypass:'
45

git log origin/main --since='2026-06-01' --oneline | wc -l
50

# Sample bypass trailers:
Bot-Merge-Bypass: fleet stopped (AUTONOMY_LEVEL=0)
Bot-Merge-Bypass: INFRA-2744 re-claim split; manual ship needed
Bot-Merge-Bypass: bot-merge import failed due to title-similarity block on CI; 4 pre-existing auth test failures on main unrelated to this PR
Bot-Merge-Bypass: today's established direct-ship path; bot-merge silent-wedge ~50% hit rate (VOA-002)
```

RESILIENT-131 (filed 2026-06-07, 0 implementation commits) confirms: autonomous end-to-end completion rate ≈ 0. The L6 supervision gaps (RESILIENT-058, 059, 060) are marked `done` but have zero git commits and zero load-bearing wiring (confirmed by notes added to each gap: "FACADE FLAG: marked done but NOT load-bearing").

```
cat docs/gaps/RESILIENT-058.yaml | grep 'status:\|FACADE'
  status: done
  [2026-06-08T02:15:16Z] FACADE FLAG (verified 2026-06-08): marked done but NOT load-bearing

git log origin/main --grep='RESILIENT-058' --oneline → (empty, 0 commits)
git log origin/main --grep='RESILIENT-059' --oneline → (empty, 0 commits)
git log origin/main --grep='RESILIENT-060' --oneline → (empty, 0 commits)
```

- evidence: `git log origin/main --since='2026-06-01' --format='%B' | grep -c 'Bot-Merge-Bypass:'` → 45/50 (90%)
- evidence: RESILIENT-131.yaml: "autonomous claim→ship completion rate ≈ 0"; RESILIENT-058/059/060 FACADE flags, 0 commits
- evidence: INFRA-2744.yaml: bot-merge re-claim reads `.chump-locks/*.json` but `chump claim` writes only to `state.db` — the re-claim mechanism has a structural data-source mismatch

*This finding is wrong if: a git log scan shows Bot-Merge-Bypass trailers are from doc-only or operator-directed commits, and Rust/test-touching commits ship cleanly via bot-merge. Not observed — bypass trailers appear on Rust PRs (e.g. RESILIENT-115, RESILIENT-118, CREDIBLE-107).*

---

**[P1/High] G2 — consensus_result was 0 across ALL fleet history; CREDIBLE-122 is still open despite PR #3099 claiming to fix it; and 57 proposals broadcast over 24 days with 0 verdicts**

We are failing at A2A coordination: the mechanism we committed to mandating (INFRA-2515, operator decision 2026-06-05) had never emitted a single `consensus_result` in the project's entire history. PR #3099 (CREDIBLE-122 fix, 2026-06-07) claims to repair the tally seam, but the gap `CREDIBLE-122` remains `status: open`, and the end-to-end test `test-a2a-consensus-e2e.sh` (which tests the real `chump vote` path rather than hand-written fixtures) is not wired into CI.

```
# consensus_result events in feedback.jsonl:
cat .chump-locks/feedback.jsonl | python3 -c "
import sys,json; lines=[json.loads(l) for l in sys.stdin if l.strip()]
print(len([e for e in lines if e.get('kind')=='consensus_result']))
"
0

# The 3-day sequence:
# 2026-06-05: INFRA-2515 shipped claiming A2A is always-on (PR #3096)
# 2026-06-07: CREDIBLE-122 filed + PR #3099 merged claiming deliberator fixed
# 2026-06-08: CREDIBLE-122 still status: open; test not in CI

grep -r 'test-a2a-consensus-e2e' .github/workflows/ → (no matches)

grep '^  status:' docs/gaps/CREDIBLE-122.yaml | head -1
  status: open

# DOC-067 (2026-06-08) explicitly acknowledges:
# "The A2A consensus layer had emitted 0 consensus_result events fleet-wide, ever,
#  despite ~49 done A2A gaps and 57 proposals broadcast over 24 days."
```

The CLAUDE.md declares A2A consensus "always-on and mandatory" (INFRA-2515). If consensus_result was structurally impossible, every vote cast under that mandate was a ritual with no effect.

- evidence: `grep -c '"kind":"consensus_result"' .chump-locks/feedback.jsonl` → 0 (live, 2026-06-08)
- evidence: CREDIBLE-122.yaml `status: open`; `git log origin/main --grep='CREDIBLE-122'` → 1 commit (the fix PR); gap not closed
- evidence: `grep -r 'test-a2a-consensus-e2e' .github/workflows/` → no matches (real path test not in CI)

*This finding is wrong if: a new `feedback.jsonl` or `ambient.jsonl` on origin/main shows consensus_result events with timestamps after 2026-06-07 PR #3099 merge.*

---

### The Opportunity Cost

**[P1/High] O1 — INFRA-821: state.db crash on fresh clone, 5 consecutive cycles, zero commits**

We are failing to fix the defect that breaks every fresh-clone workflow. `gap-doctor.py doctor` crashes with `sqlite3.OperationalError: no such table: gaps` on every fresh clone. This is the fifth consecutive Cold Water cycle with this finding and zero implementation commits.

```
python3 scripts/coord/gap-doctor.py doctor
→ sqlite3.OperationalError: no such table: gaps
  File "scripts/coord/gap-doctor.py", line 224, in load_db_status
  cur = conn.execute("SELECT COUNT(*) FROM gaps ...")

git log origin/main --grep='INFRA-821' --oneline → (empty, 0 commits)
ls -la .chump/.chump/state.db → 0-byte file (no schema)
```

- evidence: live crash 2026-06-08 (5th cycle)
- evidence: `git log origin/main --grep='INFRA-821' --oneline` → empty (5 cycles, zero commits)
- evidence: `.chump/state.db` is a 0-byte file on fresh clone; sqlite3 tables never created

*This finding is wrong if: `chump fleet bootstrap --check` populates state.db schema before gap-doctor runs — not observed in this or any prior cycle.*

---

### The Complexity Trap

**[P1/High] C1 — Prohibited Claims table in RESEARCH_INTEGRITY.md cites 5 non-existent gate gaps: the guard has no teeth**

We are failing at research credibility governance. `docs/process/RESEARCH_INTEGRITY.md` contains a Prohibited Claims table where each prohibition is gated on a "Supporting gap." Five of those supporting gaps do not exist as YAML files or in the gap store:

```
# Supporting gaps cited in Prohibited Claims table:
ls docs/gaps/EVAL-043.yaml → No such file
ls docs/gaps/EVAL-035.yaml → No such file
ls docs/gaps/EVAL-042.yaml → No such file
ls docs/gaps/EVAL-041.yaml → No such file
ls docs/gaps/EVAL-030.yaml → No such file

find docs/gaps -name 'EVAL-*' | sort
docs/gaps/EVAL-094.yaml
docs/gaps/EVAL-101.yaml
docs/gaps/EVAL-102.yaml
docs/gaps/EVAL-103.yaml
docs/gaps/EVAL-124.yaml
```

The pre-commit mechanism-kappa advisory hook (RESEARCH_INTEGRITY.md §Required Methodology Standards) cannot block on a gap ID that doesn't resolve. Any agent can commit "neuromodulation is a net positive" and no automated gate will fire.

- evidence: `ls docs/gaps/EVAL-043.yaml docs/gaps/EVAL-035.yaml docs/gaps/EVAL-042.yaml docs/gaps/EVAL-041.yaml docs/gaps/EVAL-030.yaml` → all absent (2026-06-08)
- evidence: `find docs/gaps -name 'EVAL-*'` → 5 EVAL files, none matching the 5 Prohibited Claims gate IDs
- evidence: RESEARCH_INTEGRITY.md "Prohibited Claims" table: each row's "Supporting gap" column contains a non-existent gap ID

*This finding is wrong if: EVAL-043/035/042/041/030 exist in a separate `docs/gaps/closed/` or private `chump-proprietary` store and the public table is intentionally stale — no such note appears in RESEARCH_INTEGRITY.md.*

---

**[P2/High] C2 — P0 count: 74 open P0 gaps (budget: 5); 69/74 have zero implementation commits; WORSE for 3 cycles**

We are failing at the most basic property of a priority system for the fifth consecutive cycle. The P0 budget is 5; the actual count is 74. 69 of 74 have zero git commits. The fix gap (META-064) has zero implementation commits for 4 cycles while the P0 count grew 20→29→66→74.

```
find docs/gaps -name '*.yaml' | xargs grep -l 'status: open' | xargs grep -l 'priority: P0' | wc -l
74

git log origin/main --grep='META-064' --oneline → (empty, 4 cycles)

# 5 P0 gaps with the most commits:
MISSION-041: 2 commits
INFRA-2188: 1 commit
[remaining 69: 0 commits each]
```

- evidence: `find docs/gaps -name '*.yaml' | xargs grep -l 'status: open' | xargs grep -l 'priority: P0' | wc -l` → 74
- evidence: git-log scan: 69/74 open P0 gaps have 0 implementation commits
- evidence: trend: Issue #12: 20 → #13: 29 → #14: 66 → #15: 74 (WORSE every cycle)

*This finding is wrong if: the majority of the 74 P0 gaps are intentional parallel-track items where "P0" has a project-specific meaning other than "highest priority, blocks all else"; no such policy documented.*

---

### The Reality Check

**[P1/High] R1 — EVAL-094 null: 5 cycles, 0 commits; EVAL_AWARE_SANDBAGGING.md publicly states every reported magnitude is at risk**

We are failing at research credibility. `docs/strategy/EVAL_AWARE_SANDBAGGING.md` (owner_gap: EVAL-094) states: *"the magnitude of every reported delta is at risk of inflation or deflation by evaluation-context confounding."* The gap that would resolve this risk (EVAL-094) has been open for 5 Cold Water cycles with zero implementation commits.

```
git log origin/main --grep='EVAL-094' --oneline → (empty, 5 cycles)
git log origin/main --grep='EVAL-102' --oneline → (empty, 5 cycles)
git log origin/main --grep='INFRA-824' --oneline → (empty, 5 cycles)

cat docs/strategy/EVAL_AWARE_SANDBAGGING.md | grep -A2 'magnitude'
→ "the magnitude of every reported delta is at risk of inflation or deflation
   by evaluation-context confounding"
```

External evidence base cited in EVAL-094 description: arXiv:2508.00943 (ICLR 2026): 16–36% monitor-bypass on Claude-class models — the exact configuration Chump uses for both agents-under-test and judges.

- evidence: `git log origin/main --grep='EVAL-094' --oneline` → empty (5 cycles)
- evidence: `docs/strategy/EVAL_AWARE_SANDBAGGING.md` line 40-44: public acknowledgment all magnitudes at risk
- evidence: docs/process/RESEARCH_INTEGRITY.md: mechanism claims with |Δ|>0.05 must cite EVAL-094 result or naturalized-framing justification — no such citation exists anywhere in the project

*This finding is wrong if: EVAL-094 is actively running in chump-proprietary with results pending publication; no such note in EVAL-094.yaml.*

---

### The Innovation Lag

**[P1/Medium] I1 — A2A demand-side orphaned: DOC-067 synthesis committed but EFFECTIVE-229 and L1-L5 demand-side gaps have no implementations; ProtocolBench warns against lock-in at this stage**

We are failing to act on our own research. DOC-067 (2026-06-08) synthesizes the 2026 frontier and identifies three highest-impact changes, the second of which ("The inbox-drain gate must be the harness's job") has no implementation commit. EFFECTIVE-229 was referenced in the DOC-067 document as "newly filed" but does not exist as a gap file.

```
ls docs/gaps/EFFECTIVE-229.yaml → No such file or directory
git log origin/main --grep='EFFECTIVE-229' --oneline → (empty)

# DOC-067 references: "EFFECTIVE-229 (newly filed)" for response-required tracking
# But the file was never committed to origin/main
```

External signal: ProtocolBench (arXiv evaluating A2A/ACP/ANP/Agora, 2026) explicitly cautions against "prematurely standardizing evaluation processes on a single protocol" at this stage of agent-coordination evolution — the Chump A2A master plan commits to a 7-layer architecture before the demand-side is proven. The risk is architectural lock-in to a coordination stack whose demand side has never been exercised (per A2A_MASTER_PLAN_2026-06-03.md: "Chump's A2A is a fully-built publish bus with zero subscribers").

Source: https://arxiv.org/pdf/2510.17149 ("Which LLM Multi-Agent Protocol to Choose?") — ProtocolBench evaluation, 2026.

- evidence: `ls docs/gaps/EFFECTIVE-229.yaml` → No such file (referenced in DOC-067 as "newly filed")
- evidence: `git log origin/main --grep='EFFECTIVE-229' --oneline` → empty
- evidence: docs/design/A2A_MASTER_PLAN_2026-06-03.md §0: "Chump's A2A is a fully-built publish bus with zero subscribers"

*This finding is wrong if: EFFECTIVE-229 was filed under a different ID or is tracked in chump-proprietary; a search of all gap YAML files for the title keywords "response-required" or "inbox-drain" returns a match.*

---

**THE ONE BIG THING:** [P0] RESILIENT-131 — We are failing at the project's stated reason for existing. Chump's value proposition is an autonomous agent that ships work. The fleet's autonomous end-to-end completion rate is approximately zero: 45 of 50 commits to `origin/main` since June 1 carried a `Bot-Merge-Bypass` trailer, the canonical ship pipeline (bot-merge.sh) is broken by a state.db vs. JSON lease split-brain (INFRA-2744), and the three "done" L6 resilience gaps (RESILIENT-058/059/060) are facade-flagged as non-load-bearing with zero git commits. RESILIENT-131 (filed 2026-06-07) documents this with three verification points: (A) CREDIBLE-107 PR sat BLOCKED on its own CI for 2 days before a human merged it; (B) RESILIENT-100 worker died mid-task with 1 uncommitted file, lease expired, worktree leaked; (C) 0 `gap_supervisor_escalated` events ever, despite RESILIENT-058 promising them. The project is writing doctrine about how the fleet should coordinate while the fleet ships nothing autonomously. Every other finding in this report — the P0 inflation, the consensus_result void, the eval validity caveats — is secondary to the fact that the automation the project is building does not automate. This is flagged for the first time as a single finding (prior issues split it across G1/O2/C2). Filed as RESILIENT-131. Zero implementation commits.

---

### Follow-up Gaps Filed

CREDIBLE-123, META-273, EVAL-125 were written to docs/gaps/ in this session.
Gap-reserve unavailable (chump binary still building at write time — proposed-only mode).

Verification (YAML presence confirmed; SQLite verification deferred — chump build incomplete):
```
ls docs/gaps/CREDIBLE-123.yaml → exists
ls docs/gaps/META-273.yaml → exists
ls docs/gaps/EVAL-125.yaml → exists

# IDs verified clean (no git history collision, no prior file):
git log origin/main --grep='CREDIBLE-123' --oneline → (empty)
git log origin/main --grep='META-273' --oneline → (empty)
git log origin/main --grep='EVAL-125' --oneline → (empty)
```

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| CREDIBLE-123 | Prohibited Claims table cites 5 non-existent gate gaps | P1 | s |
| META-273 | RED_LETTER Issues bundled into unrelated commit (3rd recurrence); INFRA-2385 not on main | P1 | s |
| EVAL-125 | PWA app.js SyntaxError escalation (5th cycle) | P0 | s |

Pre-existing gaps covering remaining findings: INFRA-821, META-064, INFRA-1610, INFRA-1611, INFRA-822, EVAL-094, EVAL-102, INFRA-824, FLEET-053, INFRA-1620, META-272, CREDIBLE-122, RESILIENT-131, INFRA-2744.

---

