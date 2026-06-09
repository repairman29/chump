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

