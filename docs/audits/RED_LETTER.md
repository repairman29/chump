## Issue #12 — 2026-05-18

> Audit window: commits since 2026-05-11 (Issue #11). 50 commits to `origin/main`.
> Sandbox: fresh clone. `gap-doctor.py doctor` crashed with `no such table: gaps` on entry — INFRA-821 confirmed live today. `chump gap import` run manually; state.db seeded with 538 gaps (2 blocked by similarity). `chump` binary built from source (v0.1.2, 8afa2e9).

---

### Status of Prior Issues (Issue #11)

- **STILL_OPEN_INACTIVE**: G1 (INFRA-821, state.db empty on fresh clone) — 0 commits since 2026-05-11. Confirmed again today: `gap-doctor.py doctor` → `sqlite3.OperationalError: no such table: gaps`.
  ```
  git log origin/main --grep='INFRA-821' --oneline
  (no output)
  ```
- **FIXED_BUT_REPLACED**: G2 (17 vague AC gaps, INFRA-822) — INFRA-1599/PR#2267 reduced to 1 vague gap (CREDIBLE-013). But INFRA-1599 itself remains `status: open` (OPEN-BUT-LANDED).
- **CONTESTED**: O1 (INFRA-721 fleet brief, stated inactive in Issue #11) — `docs/gaps/INFRA-721.yaml` was added in PR #2225 (2026-05-16) with `status: done, closed_pr: 1302` baked in from creation. No commits reference INFRA-721. Retroactive registration, not verifiable closure. Classification: CONTESTED pending evidence that PR #1302 actually implemented the feature.
  ```
  git log origin/main --grep='INFRA-721' --oneline
  (no output)
  git show b257cb3 -- docs/gaps/INFRA-721.yaml | head -5
  # new file, status: done already set — retroactive registration
  ```
- **STILL_OPEN_INACTIVE**: O2 (Review-as-Handoff sub-gaps) — INFRA-770(0 commits), INFRA-773(0 commits), INFRA-774(1 commit). INFRA-771 marked done. INFRA-772(1 commit). Mixed; 3 of 5 remaining sub-gaps have zero implementation commits.
- **FIXED**: C1 (ZERO-WASTE pillar starvation) — ZERO-WASTE now has 44 open gaps. Resolved.
- **WORSE**: C2 (shipped-but-not-closed gaps) — Issue #11 noted 3; canonical scan today: **99 OPEN-BUT-LANDED** gaps (12 P0, 61 P1). 33x regression.
  ```
  python3 scan of chump gap list --json vs git log: OPEN-BUT-LANDED count: 99
  ```
- **STILL_OPEN_INACTIVE**: R1 (INFRA-824, EVAL-101 protocol deviation re-run) — 0 commits. EVAL-102 also filed and has 0 commits.
  ```
  git log origin/main --grep='INFRA-824' --oneline
  (no output)
  git log origin/main --grep='EVAL-102' --oneline
  (no output)
  ```
- **STILL_OPEN_INACTIVE**: FLEET-053 (NATS deployment incomplete, P0, filed 2026-05-12 by Cold Water) — 0 commits in 6 days.
  ```
  git log origin/main --grep='FLEET-053' --oneline
  (no output)
  ```
- **NO_GAP → filed this cycle**: INFRA-1611 (486/540 gaps missing opened_date), DOC-050 (CHUMP_TO_CHAMP.md privacy violation), RESEARCH-001 (phantom EVAL-094/RESEARCH-026 IDs).

---

### The Looming Ghost

**[P0/High] G1 — P0 budget blown 4x: priority signal has been destroyed**

We are failing at P0 budget discipline. `chump gap audit-priorities` returns 20 open P0 gaps against a hard CLAUDE.md limit of 5. Of the 20, 12 are OPEN-BUT-LANDED (have git commits but are not closed). The signal that separates "true unblocker" from "feature request someone was excited about" no longer exists.

```
chump gap audit-priorities (2026-05-18):
P0 open gaps: 20 (CLAUDE.md budget: 5 max)

Selected P0s with commits (OPEN-BUT-LANDED — likely done, not closed):
  INFRA-1534: 16 commits (last 2026-05-16) — self-hosted runners
  INFRA-1541:  2 commits (last 2026-05-16) — AC coverage gate
  INFRA-1542:  2 commits (last 2026-05-16) — CI Phase 2 heavy jobs
  INFRA-1532:  1 commit  (last 2026-05-16) — bot-merge self-watchdog
  INFRA-1528:  1 commit  (last 2026-05-16) — auto-merge-armer
  ... 7 more P0s with 1 commit each

P0s with zero implementation commits:
  FLEET-053   — NATS deployment (Cold Water filed 2026-05-12; 6 days, 0 commits)
  INFRA-1075  — PWA touch target size
  INFRA-1326  — orphan-PR-closer health check
  INFRA-1327  — lease auto-extend for live PRs
  INFRA-1472  — disk_critical reaper threshold
  INFRA-1518  — bootstrap Merge Queue enforcement
  INFRA-1522  — required-check health gate
  INFRA-1525  — pr-rebase-daemon circuit-breaker
```

Additionally, all 20 P0s report "(0d old)" in `chump gap audit-priorities` because state.db is populated at import time and 486/540 gaps (90%) have no `opened_date` YAML field. The age column is therefore useless — see Complexity Trap G2.

- evidence: `chump gap list --status open --json` (canonical), 2026-05-18 sandbox
- evidence: `CLAUDE.md §Mission Driver §4`: "P0 budget = 5 max. Reserve P0 for true unblockers"
- evidence: python git-log scan: 12 of 20 P0s are OPEN-BUT-LANDED with ≥1 commits

*This finding is wrong if: `chump gap list --json` on a fully-seeded state.db with real opened_date values returns <6 P0s once OPEN-BUT-LANDED are triaged.*

---

**[P1/High] G2 — INFRA-1237 (EVENT_REGISTRY drift): 22 unregistered + 88 orphan event kinds; observability floor is compromised**

We are failing at ambient observability. INFRA-1237 (P0, open) documents 22 event kinds emitted daily by production scripts that are not in EVENT_REGISTRY.yaml, and 88 registered kinds that nothing emits. One commit (2026-05-16) touched event-registry-reserved.txt but did not run the full drift audit specified in INFRA-1237's AC.

```
git log origin/main --grep='INFRA-1237' --oneline
cd953ed feat(INFRA-1363): CREDIBLE — orchestrate session-summary ambient emit (#2109)
# (not an INFRA-1237 implementation commit)

cat docs/gaps/INFRA-1237.yaml | grep 'status:\|commits'
  status: open   # confirmed P0/open
```

CLAUDE.md MANDATORY preflight says "watch for `lease_overlap`, `silent_agent`, `edit_burst`..." — these are in the 88-orphan bucket or the 22-unregistered bucket. The fleet cannot be trusted to have caught those events this week.

- evidence: `docs/gaps/INFRA-1237.yaml` description: "22 emit-without-register kinds + 88 register-without-emit orphans"
- evidence: `git log --grep='INFRA-1237'` → 0 implementation commits
- evidence: `scripts/ci/test-event-registry-coverage.sh` (INFRA-1237 AC item 1) does not exist: `ls scripts/ci/test-event-registry-coverage.sh` → not found

*This finding is wrong if: `scripts/ci/test-event-registry-coverage.sh` was added and passes (it would appear in `scripts/ci/`; confirmed absent).*

---

### The Opportunity Cost

**[P0/High] O1 — FLEET-053 (NATS deployment incomplete): STILL_OPEN_INACTIVE, P0, filed by Cold Water 6 days ago**

We are failing at acting on Cold Water findings. FLEET-053 was filed 2026-05-12 with P0 priority because the NATS subscription path introduced by FLEET-017 (PR #629) has never been deployed: `CHUMP_NATS_URL` is unset, Cold Water sandboxes observe the jsonl fallback path, and the fleet cannot verify whether the push-routing tier is live. Six days later, zero commits reference FLEET-053.

```
git log origin/main --grep='FLEET-053' --oneline
(no output)

cat docs/gaps/FLEET-053.yaml
  status: open
  priority: P0
  opened_date: '2026-05-12'
```

- evidence: canonical `chump gap list --json`: FLEET-053 P0/open, age=6d
- evidence: `git log origin/main --grep='FLEET-053' --oneline` → empty
- evidence: `docs/gaps/FLEET-053.yaml:opened_date: 2026-05-12` — 6 days stale

*This finding is wrong if: CHUMP_NATS_URL is set in the deployment environment and the Cold Water sandbox simply lacks the env var (plausible; FLEET-053 should document the deployment verification step).*

---

**[P1/High] O2 — 99 OPEN-BUT-LANDED gaps: gap closure regressed 33x since Issue #11**

We are failing at closing work after it ships. Issue #11 (2026-05-11) noted 3 shipped-but-not-closed gaps as a finding (C2). Seven days later, the canonical scan returns 99 OPEN-BUT-LANDED gaps — 12 at P0 priority.

```
python3 scan (chump gap list --json vs git log, 2026-05-18):
  OPEN-BUT-LANDED count: 99
  By priority: P0=12, P1=61, P2=24, P3=2

Top P0 OPEN-BUT-LANDED:
  INFRA-1534: 16 commits — self-hosted GitHub Actions runners
  INFRA-1541:  2 commits — pre-merge AC coverage gate
  INFRA-1542:  2 commits — CI Phase 2 heavy jobs
```

bot-merge.sh does call `chump gap ship --update-yaml` (line 2553), but 7 Bot-Merge-Bypass uses in 7 days skipped that path:
```
git log origin/main --since='2026-05-11' --format='%B' | grep 'Bot-Merge-Bypass'
Bot-Merge-Bypass: bot-merge silent >30s after spawn (INFRA-1399 known issue)...
Bot-Merge-Bypass: bot-merge.sh stalled silently with no output (known INFRA-1399)...
[5 more; all citing INFRA-1399]
```

- evidence: python git-log scan returning 99 OPEN-BUT-LANDED
- evidence: `git log --grep='Bot-Merge-Bypass'` — 7 in 7 days
- evidence: Issue #11 C2 finding noted 3 open-but-landed; current count is 99 (33x regression)

*This finding is wrong if: the 99 gaps are intentional multi-phase gaps where first sub-phase shipped but full AC is not yet met; requires per-gap manual verification.*

---

### The Complexity Trap

**[P1/High] C1 — 486/540 gaps (90%) have no `opened_date`: P0 aging census is non-functional**

We are failing at gap metadata hygiene. 486 of 540 gap YAML files have no `opened_date` field. `chump gap audit-priorities` computes age from state.db `created_at` (which is set at import time), so all 20 P0 gaps report "(0d old)" after a fresh `chump gap import`. The CLAUDE.md Mission Driver's P0-aging enforcement is institutionally blind.

```
python3 -c "
import yaml, glob
gaps = []; [gaps.extend(yaml.safe_load(open(f).read()) if isinstance(yaml.safe_load(open(f).read()), list)
  else [yaml.safe_load(open(f).read())]) for f in glob.glob('docs/gaps/*.yaml')]
no_date = [g for g in gaps if not g.get('opened_date')]
print(f'Without opened_date: {len(no_date)}/{len(gaps)}')
"
# Output: Without opened_date: 486/540

chump gap audit-priorities | grep 'FLEET-053\|INFRA-1534'
# Output: FLEET-053 — ... (0d old)
#         INFRA-1534 — ... (0d old)
```

FLEET-053 is 6 days old and shows "(0d old)". INFRA-1534 has 16 commits and was filed months ago; it also shows "(0d old)". The audit is returning the same age for a newly filed P0 and a chronically stale one.

- evidence: python scan: 486/540 no opened_date
- evidence: `chump gap audit-priorities` output: all 20 P0s show "(0d old)"
- evidence: CLAUDE.md Mission Driver: "If any P0 stuck > 7 days → PM flag" — metric is undefined without date

*This finding is wrong if: `chump gap show <ID>` reveals state.db carries a real creation timestamp independent of YAML `opened_date` (not observed; state.db was freshly populated via import which sets created_at to now).*

---

### The Reality Check

**[P1/High] R1 — CHUMP_TO_CHAMP.md publicly discloses specific deltas, model names, and n-values in direct violation of RESEARCH_INTEGRITY.md:28-29**

We are failing at research data privacy. `docs/strategy/CHUMP_TO_CHAMP.md` — a public file — contains specific empirical results that `docs/process/RESEARCH_INTEGRITY.md` explicitly prohibits from appearing in public documents.

```
# From docs/strategy/CHUMP_TO_CHAMP.md lines 52-56:
| Lessons block increases fake-tool-call emission |
  +0.14 pp mean hallucination delta (n=100 per cell, 3 fixtures) | Statistically established |
| Effect present across model tiers |
  haiku-4-5: +0.13–0.16; opus-4-5: +0.23–0.40 (reflection cell) | Multi-model confirmed |
| qwen2.5:14b shows +0.10 pass-rate delta | v1 harness, n=20 | Preliminary |

# From docs/process/RESEARCH_INTEGRITY.md:28-29:
"Do not state magnitudes, model names, or per-eval IDs in public docs,
 PRs, or external communications."

# CHUMP_TO_CHAMP.md:
last_audited: 2026-04-25  # not audited since the privacy directive
```

Three independent evidence points:
1. `CHUMP_TO_CHAMP.md:52` contains "+0.14 pp mean hallucination delta" and "n=100" — numeric magnitudes
2. `CHUMP_TO_CHAMP.md:53` contains "haiku-4-5" and "opus-4-5" — model names
3. `RESEARCH_INTEGRITY.md:28-29` prohibits exactly this

*This finding is wrong if: RESEARCH_INTEGRITY.md has an explicit carve-out permitting CHUMP_TO_CHAMP.md to retain these specifics — no such carve-out found after full review of RESEARCH_INTEGRITY.md.*

---

**[P1/Medium] R2 — EVAL-094 and RESEARCH-026 are phantom gap IDs required by RESEARCH_INTEGRITY.md for eval-awareness mechanism claims**

We are failing at making our own methodology enforceable. `docs/process/RESEARCH_INTEGRITY.md:87-97` requires that mechanism analysis with |Δ|>0.05 cite the EVAL-094 or RESEARCH-026 result set for the naturalized-framing comparison. Neither gap exists in the public registry.

```
find docs/gaps -name 'EVAL-094*'
(no output)

find docs/gaps -name 'RESEARCH-026*'
(no output)

chump gap list --json | python3 -c "import json,sys; print([g['id'] for g in json.load(sys.stdin) if g['id'] in ['EVAL-094','RESEARCH-026']])"
[]

# RESEARCH_INTEGRITY.md:90:
"must cite either (a) a paired naturalized-framing comparison from the
 RESEARCH-026 / EVAL-094 result set on the same fixture class"
```

The eval-awareness mandate (requiring sandbagging controls on all frontier-model evals — directly relevant since Chump uses Claude as both agent and judge) names a specific gap that every mechanism claim must clear. That gap does not exist. Any agent or reviewer trying to comply with RESEARCH_INTEGRITY.md §4 cannot, because the required prior work has no tracking entry.

- evidence: `find docs/gaps -name 'EVAL-094*'` → empty
- evidence: `find docs/gaps -name 'RESEARCH-026*'` → empty  
- evidence: `chump gap list --json`: neither ID present in canonical store

*This finding is wrong if: EVAL-094 and RESEARCH-026 are tracked in `chump-proprietary` and the public RESEARCH_INTEGRITY.md reference is intentionally pointing off-repo.*

---

### The Innovation Lag

**[P1/Medium] I1 — EVAL-102 (EVAL-101 corrected protocol re-run) has zero commits: cognition stack remains unvalidated for a second cycle**

We are failing at measuring whether the things we ship actually work. EVAL-102 was filed in Issue #11 (2026-05-11) as the corrected re-run of EVAL-101 (which ran on the wrong model at 40% of the required sample size). Seven days later, zero commits reference EVAL-102.

```
git log origin/main --grep='EVAL-102' --oneline
(no output)
```

External context: The industry standard for agentic benchmarks has hardened since Issue #11. [SWE-bench Verified](https://www.swebench.com) and its successors now require reproduced multi-judge evaluations with naturalized prompts as the baseline for credibility claims. Chump's claim is that a cognitive architecture running on local hardware can match frontier API calls — a claim that requires at minimum the n=50/cell, dual-judge, deviation-locked eval that EVAL-102 specifies. Until that runs, every new cognitive-architecture PR shipped is building on an unmeasured foundation.

The strategic memo (STRATEGIC_MEMO_2026Q2.md) that CLAUDE.md cites for innovation-lag anchoring has been moved to `chump-proprietary` ("This document has been moved to a private repository"). The public CLAUDE.md still references it. This is a documentation integrity failure — the reference is broken.

- evidence: `git log origin/main --grep='EVAL-102' --oneline` → empty
- evidence: `head -5 docs/strategy/STRATEGIC_MEMO_2026Q2.md` → "This document has been moved to a private repository"
- evidence: CLAUDE.md §Innovation Lag references STRATEGIC_MEMO_2026Q2.md as a first-read anchor; that file is now inaccessible

*This finding is wrong if: EVAL-102 is running in a private environment with results committed to `chump-proprietary` and a summary landing in public docs soon.*

---

**THE ONE BIG THING:** [P0] META-064 — We are failing at the most basic property of a priority system: P0 means something. It currently does not. `chump gap audit-priorities` returns 20 open P0 gaps against a hard CLAUDE.md budget of 5. Twelve of those 20 are OPEN-BUT-LANDED — they have git commits, the work shipped, but nobody ran `chump gap ship`. The remaining 8 have zero implementation commits, including FLEET-053 (NATS deployment, filed by Cold Water 6 days ago) and INFRA-1075 (a mobile button touch target), which have identical P0 priority. The fleet workers pick from this pool and cannot tell the difference between a genuine blocker and a stale registration. Every routing decision made by every agent this week was made against a corrupted signal. The P0 bucket must be triaged to ≤5 genuine unblockers — with OPEN-BUT-LANDED P0s closed and zero-commit P0s reviewed for downgrade — before the priority system can be trusted again. Flagged in Issue #11 (C2) as 3 open-but-landed gaps; it is now 99. The trend is the finding.

---

### Follow-up Gaps Filed

All 5 gaps verified: YAML file present AND `chump gap list --json` confirms in state.db.

| Gap ID | Title | Priority | Effort |
|---|---|---|---|
| META-064 | ZERO-WASTE: P0 budget blown 4x — triage and close OPEN-BUT-LANDED P0s to restore priority signal | P1 | s |
| INFRA-1610 | ZERO-WASTE: 99 OPEN-BUT-LANDED gaps — chump gap ship not called after merge; regression from 3→99 since Issue #11 | P1 | m |
| DOC-050 | CREDIBLE: CHUMP_TO_CHAMP.md publishes prohibited deltas/model-names/n-values — violates RESEARCH_INTEGRITY.md:28-29 | P1 | xs |
| RESEARCH-001 | CREDIBLE: EVAL-094 and RESEARCH-026 are phantom IDs cited in RESEARCH_INTEGRITY.md eval-awareness mandate | P1 | s |
| INFRA-1611 | ZERO-WASTE: 486/540 gaps missing opened_date — P0 aging census blind; audit-priorities age column useless | P1 | s |

---

## Issue #11 — 2026-05-11

> Audit window: commits since 2026-04-27 (prior issue date). 51 commits to `origin/main`.
> Sandbox: fresh clone, no ambient stream, no lease state. `chump gap import` run manually to populate state.db (itself a finding — see Looming Ghost).
> Prior RED_LETTER content (Issues #1–#10) was moved to `chump-proprietary` on 2026-04-28. This issue resumes the public audit record.

### Status of Prior Issues

Issue #8 and #9 raised through the private window are not directly verifiable in this sandbox. Based on public doc references:

- `CLAUDE_GOTCHAS.md:395` cites **Issue #9** (raw-YAML-edit rate 66% under advisory mode → flipped to blocking). Status: **FIXED** — `scripts/ci/test-raw-yaml-guard.sh` exists, CLAUDE_GOTCHAS confirms blocking mode active as of 2026-05-02.
- `EXPERT_REVIEW_PANEL.md:111` cites **Issue #4** credibility debt. Status: **STILL_OPEN_ACTIVE** — EVAL-101 was the attempt to address it this cycle; see Reality Check below for why that attempt failed.
- `INTEGRITY_AUDIT_1_GAP_CLOSURE.md` (audit of Issues #1–4) cites PRODUCT-009 false closure pattern. Status: **STILL_OPEN_ACTIVE** — the structural pattern recurs: INFRA-816, CREDIBLE-013, INFRA-817 all shipped this cycle but remain `status: open` (evidence: `docs/gaps/INFRA-816.yaml:4`, `docs/gaps/CREDIBLE-013.yaml:status: open`, `docs/gaps/INFRA-817.yaml:status: open`).

---

### The Looming Ghost

**Finding G1 — state.db is empty by default; chump gap list returns [] on fresh clone.**

Severity: HIGH | Confidence: VERIFIED (command output included)

```
# Observed 2026-05-11 in fresh sandbox:
python3 -c "
import sqlite3
conn = sqlite3.connect('/home/user/chump/.chump/state.db')
for t in ['gaps','leases','intents']:
    print(t, conn.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0])
"
# Output:
# gaps 0
# leases 0
# intents 0

chump gap list --json
# Output: []
```

`chump gap import` (without `--yaml` flag) inserts all 155 gaps. With `--yaml <abs-path>` it silently inserts 0. CLAUDE.md preflight step 6 is `chump gap list --status open`. In a fresh sandbox this returns `[]` and misleads any operator or agent into thinking the queue is empty. INFRA-538 (state.db recovery path, P1, open, `docs/gaps/INFRA-538.yaml`) and INFRA-766 (state-drift detector, P1, open, `docs/gaps/INFRA-766.yaml`) both address aspects of this — but neither addresses the bootstrap problem.

```
git log origin/main --grep='INFRA-538' --oneline
# (no output)
git log origin/main --grep='INFRA-766' --oneline
# (no output)
```

Zero commits to either gap. The two-store problem (state.db vs docs/gaps/*.yaml) is acknowledged but not fixed.

This finding is wrong if: `chump start` or `chump init` auto-runs gap import on a fresh DB (check `src/orchestrate.rs` or startup path).

---

**Finding G2 — 17 open P1/P2 gaps have empty acceptance_criteria; `chump gap audit-priorities` exits 1 every run.**

Severity: MEDIUM | Confidence: VERIFIED (command output included)

```
chump gap audit-priorities
# Exit code: 1
# "FAIL: 17 vague (no AC) pickable gap(s)"
# Affected P1 gaps include: CREDIBLE-013, INFRA-650, INFRA-765, INFRA-766, INFRA-778,
# INFRA-780, INFRA-785, INFRA-786, INFRA-770, INFRA-771, INFRA-772, INFRA-773, INFRA-774,
# META-051, EFFECTIVE-007, INFRA-777, INFRA-784
```

The CLAUDE.md pre-ship checklist says `chump gap audit-priorities` must exit 0. It currently exits 1 on every invocation. The gap-reserve.sh boilerplate injects `TODO:` placeholder AC on every new gap filed by agents, and those placeholders are not getting replaced before the gap is picked.

This finding is wrong if: `chump gap audit-priorities` has been patched to treat description-in-title as AC (check `src/main.rs` audit-priorities logic).

---

### The Opportunity Cost

**Finding O1 — INFRA-721 (P0, open) has zero commits in 30 days.**

Severity: HIGH | Confidence: VERIFIED

```
git log origin/main --grep='INFRA-721' --oneline --since='30 days ago'
# (no output)
git log origin/main --grep='fleet brief\|fleet-brief' --oneline --since='30 days ago'
# acf8f23 feat(FLEET-045): picker domain-bias — deprioritize INFRA when >80% of last 10 ships (#1401)
```

INFRA-721 (`docs/gaps/INFRA-721.yaml`) is the sole open P0 gap: "EFFECTIVE: chump fleet brief on SessionStart — operator gets 60s briefing instead of having to ask 'is anything stuck'." It is fleet-pickable (effort=m, no blocking deps), yet zero work has landed. The P0 budget is 5 max per CLAUDE.md; having the only P0 sit untouched while 51 commits ship is the definition of the wrong thing getting prioritized.

We are failing at executing against our own P0 priority signal.

This finding is wrong if: INFRA-721 work is in flight under a different gap ID or branch name not matching `INFRA-721`.

---

**Finding O2 — Review-as-Handoff feature (INFRA-768) shipped sub-gap 1 only; sub-gaps 2–6 have zero commits.**

Severity: MEDIUM | Confidence: VERIFIED

```
git log origin/main --grep='INFRA-770\|INFRA-771\|INFRA-772\|INFRA-773\|INFRA-774' --oneline --since='30 days ago'
# (no output)
git log origin/main --grep='Review-as-Handoff' --oneline --since='30 days ago'
# 84585c0 INFRA-769: Review-as-Handoff comment template linter (#1427)
```

INFRA-769 (sub-gap 1/6, comment template) shipped 2026-05-08. Sub-gaps 2–6 (ACL, author re-engagement loop, review daemon, telemetry, smoke test) are all P1 open with zero movement. The feature is useless without sub-gaps 3/4 (the daemon and re-engagement loop). A framework that can lint comments but cannot respond to them has zero operational value. We are failing at delivering the Review-as-Handoff feature beyond its scaffolding.

This finding is wrong if: sub-gaps 2–6 are in active PRs not yet merged as of 2026-05-11.

---

### The Complexity Trap

**Finding C1 — EFFECTIVE dominates the pickable pool at 57%; ZERO-WASTE has 1 pickable gap (3%).**

Severity: MEDIUM | Confidence: VERIFIED (canonical `chump gap list --json` data)

```python
# From chump gap list --json (155 gaps, 61 open, 37 P0/P1 xs|s|m):
Pickable by pillar:
  EFFECTIVE:  21 gaps (57%)
  RESILIENT:  8 gaps (22%)
  CREDIBLE:   4 gaps (11%)
  ZERO-WASTE: 1 gap  (3%)   # INFRA-650 — has empty AC, audit-priorities flags it as vague
  MISSION:    1 gap  (3%)
  untagged:   2 gaps (5%)
```

CLAUDE.md Mission Driver rule: "If any pillar < 2 pickable, file 1-2 gaps to refill." ZERO-WASTE has 1 gap and it is flagged as vague (empty AC). The effective ZERO-WASTE pickable count is 0. The fleet is failing at the self-correction the Mission Driver was designed to enforce.

This finding is wrong if: INFRA-650's title-embedded AC (the description mentions `src/fleet_resize.rs` etc.) is counted as valid AC by `audit-priorities` — verify by checking the specific AC check logic.

---

**Finding C2 — Three shipped gaps remain `status: open` in YAML; bot-merge.sh does not auto-close.**

Severity: MEDIUM | Confidence: VERIFIED (file contents + git log)

Evidence:
- `docs/gaps/INFRA-816.yaml:4` → `status: open`; `git log --grep='INFRA-816'` → commit `1ea226b fix(infra-816)` on 2026-05-10 merged as PR #1437. Fix is in `.github/workflows/release-plz.yml`.
- `docs/gaps/CREDIBLE-013.yaml` → `status: open`; commit `e811ab4 CREDIBLE-013: CI failure triage` on 2026-05-10 as PR #1431. `scripts/ci/triage-test-failure.sh` shipped.
- `docs/gaps/INFRA-817.yaml` → `status: open`; commit `4f4beb2 fix(e2e): update PWA v2 test selectors` on 2026-05-11 (today) claims "Closes INFRA-817" in PR #1442 body.

The `chump gap ship <ID> --update-yaml` step is manual-only. Bot-merge.sh does not call it. Each gap requires the filing agent to explicitly close it after merge — and this step is being skipped repeatedly.

This finding is wrong if: the three gaps above are genuinely still open (i.e., the closing commit did not fully satisfy all AC — verify against each gap's AC list).

---

### The Reality Check

**Finding R1 — EVAL-101 closed with four unresolved RESEARCH_INTEGRITY.md violations; null result is unreliable.**

Severity: HIGH | Confidence: VERIFIED (3 independent evidence points)

This is a P1 finding. Three independent evidence points:

1. **Wrong model.** Preregistration (`docs/eval/preregistered/EVAL-101.md:§3`) specifies agent under test as `claude-sonnet-4-20250514` (Anthropic API). Result document (`docs/eval/EVAL-101-cognition-ab-2026-05-10.md`) states: "Model: Qwen 2.5 14b via Ollama (local)." The Deviations section of the preregistration reads "(none yet)."

2. **Wrong n.** `RESEARCH_INTEGRITY.md:§1` states: "Minimum n=50 per cell for directional signal; n=100 for ship-or-cut decisions." EVAL-101 ran n=20 per cell. The gap AC (`docs/gaps/EVAL-101.yaml`) lists "20 tasks × 3 cells = 60 trials" — the gap itself baked in the underpowered design.

3. **Cell C skipped + no LLM judge.** The result doc states "Cell C (padding) skipped due to Ollama timeout." `RESEARCH_INTEGRITY.md:§6` prohibits structural-scoring-only runs: "LLM-judge scorer required." The result used structural property checks only (no haiku, no gpt-4o-mini cross-judge as preregistered). The INFRA-079 pre-commit guard (`scripts/git-hooks/pre-commit:§ cross-judge audit`) requires `cross_judge_audit:` or `single_judge_waived:` in the gap YAML — neither field is present in `docs/gaps/EVAL-101.yaml`.

The cognition stack (reflections, lessons, neuromodulation) shipped on faith and remains unvalidated. The "null result" cannot be dispositive because it measured the wrong agent on an underpowered fixture without the required controls. We are failing at the Credible pillar's core mandate: measuring whether the things we ship actually work.

This finding is wrong if: the pre-commit hook CHUMP_CROSS_JUDGE_CHECK was explicitly bypassed in the merge commit with a justification trailer (check `git log b9a9c18 --format=%B` for bypass markers beyond `Test-Gate-Bypass: pre-existing flake`).

---

### The Innovation Lag

**Finding I1 — Industry is converging on heterogeneous model routing and benchmark-verified coordination; Chump measures neither.**

External source (2026-05-11): Per [Agentic Benchmarks 2026: Tool Use, Browsing, Computer Use — BenchLM.ai](https://benchlm.ai/agentic), the industry has converged on structured agentic benchmarks with reproducible multi-agent coordination metrics. Separately, enterprise deployments show a 37% gap between lab benchmark scores and real-world deployment performance, with 50x cost variation for similar accuracy. The CooperBench benchmark evaluates 600+ collaborative coding tasks specifically for multi-agent coordination quality.

Chump's positioning is that a cognitive architecture (reflections, lessons, neuromodulation) running on local hardware outperforms stateless frontier API calls. EVAL-101 was the attempt to validate this. It failed to produce a reliable measurement. Meanwhile, the gap pool shows EFFECTIVE at 57% and CREDIBLE at 11% — the project is building features faster than it is validating them. Industry benchmarks now routinely quantify the model-routing and coordination quality dimensions Chump claims as strengths; Chump has no published numbers on either.

We are failing at producing the credible, reproducible evidence that would distinguish Chump from competitor claims.

This finding is wrong if: a cross-judge evaluation at n≥50 with the correct agent model is in flight under an open EVAL-* gap.

---

**THE ONE BIG THING:** [P1] INFRA-824 — We are failing at research credibility. EVAL-101 — the only systematic measurement of whether the cognition stack (reflections, lessons, neuromodulation) actually improves agent outcomes — ran on the wrong model (Qwen 2.5 14b instead of preregistered claude-sonnet-4), at a third of the required sample size (n=20 vs. required n=50), omitted the confound-control cell (Cell C), used structural scoring only (prohibited by RESEARCH_INTEGRITY.md §6 when LLM judges were preregistered), and documented no deviations in the preregistration. The result was filed as a null result and the gap closed. The cognition stack — reflections, lessons, semantic ranking, neuromodulation — comprises dozens of shipped PRs and thousands of lines of Rust. All of it is currently faith-based. The null result cannot be cited as evidence that the stack fails, and cannot be cited as evidence that it succeeds. The Credible pillar has zero validated findings from this cycle. Every new cognitive-architecture gap filed without re-running the eval continues this compounding deficit.

---

### Follow-up Gaps Filed

All five gaps verified via `chump gap list --json` after import (155 total, 61 open).

| Gap ID | Pillar | Priority | Effort | Title |
|---|---|---|---|---|
| INFRA-824 | CREDIBLE | P1 | m | EVAL-101 protocol deviation — re-run required with correct model/n/controls |
| INFRA-820 | ZERO-WASTE | P1 | s | Pillar starvation — ZERO-WASTE at 1 pickable gap; refill pool |
| INFRA-821 | RESILIENT | P1 | s | state.db empty on fresh clone — chump gap list returns [] until manual import |
| INFRA-822 | ZERO-WASTE | P1 | s | 17 open P1/P2 gaps have empty AC — unpickable in practice |
| INFRA-823 | ZERO-WASTE | P1 | s | bot-merge.sh does not auto-close gap YAML; shipped-but-not-closed gaps accumulate |

Gap files written to `docs/gaps/INFRA-{819,820,821,822,823}.yaml`.

---

# Document moved

**This document has been moved to a private repository.**

Validated empirical findings, per-eval result writeups, research process logs,
faculty-status tables, and architectural docs that restate specific deltas /
n-values / model tiers are tracked in `chump-proprietary` (private,
need-to-know) rather than scraped from a public repo.

The eval **methodology** (Wilson confidence intervals, A/A controls,
preregistration discipline, judge composition rules) remains public — see
`docs/process/RESEARCH_INTEGRITY.md`.

Contact the project owner for access.
