---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-02
---

# Red Letter

> Cold Water — adversarial weekly review. No praise.

---

## Issue #10 — 2026-05-02

> Audit window: commits since 2026-05-01 (Issue #9 commit date). 11 commits on origin/main after e0ab7e7.

### Status of Prior Issues

**From Issue #9 (2026-05-02):**

- **FIXED:** PRODUCT-017 (P0 — clean-machine FTUE, THE ONE BIG THING in Issues #6/7/8/9) — commit `b4bc04f` "PRODUCT-017: FTUE clean-machine verification 2026-05-02 (17s, exit=0) (#707)". Four-cycle fix is confirmed delivered. Closed by PR #707 with verified artifact.
- **STILL_OPEN_INACTIVE (2 cycles — #9, #10):** EVAL-090 (P0 — re-run EVAL-069 under verified python3.12) — zero implementation commits. `git log origin/main --grep=EVAL-090 --oneline` returns only `e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)`. Age: 6 days as of Issue #9, 7 days as of this issue. A P0 gap with zero implementation commits for two consecutive Cold Water cycles.
- **STILL_OPEN_INACTIVE (7 cycles — #4 through #10):** RESEARCH-021 (P1 — tier-dependence replication) — `git log origin/main --grep=RESEARCH-021 --oneline` returns only `e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)`. Unchanged from Issue #9.
- **STILL_OPEN_INACTIVE (4 cycles — #7 through #10):** EVAL-087 (P1 — evaluation-awareness reframe) — `git log origin/main --grep=EVAL-087 --oneline` returns only `e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)`.
- **STILL_OPEN:** META-002 — `git log origin/main --grep=META-002 --oneline` returns nothing.
- **STILL_OPEN:** FLEET-023 (P1 — Cold Water ambient stream empty) — `git log origin/main --grep=FLEET-023 --oneline` returns only `e0ab7e7`.
- **STILL_OPEN:** EVAL-094 (P1 — ICLR 2026 sandbagging experiment) — `git log origin/main --grep=EVAL-094 --oneline` returns only `e0ab7e7`.
- **STILL_OPEN:** INFRA-200 (P1 — gaps.yaml hard pre-commit block) — `git log origin/main --grep=INFRA-200 --oneline` returns `ad9fa4d` (the INFRA-201/202 filing commit, not an INFRA-200 implementation). Status: open.
- **WORSE:** OPEN-BUT-LANDED grew from 20/102 (19%) in Issue #9 to **43/114 (38%)** in this cycle. The difference is that Issue #9 measured against HEAD (097da15) while this cycle measures against origin/main (6d21b33). The 11 new commits added 12 new gaps (INFRA-201..207 + META-006 etc.), most immediately OPEN-BUT-LANDED on filing.

**NO_GAP filed this cycle (new gaps filed below):** INFRA-222, INFRA-209, EVAL-095, META-007. *(Originally filed as INFRA-208 and META-006; both IDs were independently taken by parallel work that landed on main during this audit cycle — renamed during rebase to avoid collision with main's INFRA-208 "chump gap dump lossy" and META-006 "retire gaps.yaml".)*

---

### The Looming Ghost

[P0/High] We are failing to maintain a parseable gap registry. docs/gaps.yaml on origin/main (commit 6d21b33) is invalid YAML.

Verification (command run in Cold Water sandbox on this branch against origin/main):
```
python3 -c "import yaml; yaml.safe_load(open('docs/gaps.yaml'))"
YAMLError: while parsing a block mapping at line 17065, column 3
expected <block end>, but found '<scalar>'
at line 17133, column 5
```

The corruption: commit `ad9fa4d` (PR #717) filed INFRA-202 for the docs-delta guard escape hatch. Commit `6d21b33` (PR #719) independently filed INFRA-202 for fleet-sccache. Each commit passed the duplicate-ID pre-commit guard because the guard checks staged-vs-HEAD (not staged-vs-origin/main). The merge queue squashed both PRs onto main without detecting the concurrent ID collision. The resulting YAML has two entries with `id: INFRA-202`, the first being a ghost stub (title only, no status/priority/description). The second entry's description absorbed the first entry's content and INFRA-207's content was merged into a single malformed block.

Downstream consequences:
- `chump gap reserve` immediately caught this and aborted: "docs/gaps.yaml is unreadable so the ID counter cannot be backfilled."
- Any workflow using `python3 -c "import yaml; yaml.safe_load(...)"` on origin/main fails (regenerate-gaps-yaml.yml, gap-doctor.py, gap-status-guard.yml).
- This is the same concurrent-branch duplicate ID race documented in Issue #7 for INFRA-073. The guard was designed in response to 7 prior collisions (INFRA-GAPS-DEDUP); it has now failed twice because it does not check against origin/main.

Evidence:
- `git show origin/main:docs/gaps.yaml | grep -c "^- id: INFRA-202"` = 2 (two entries with same ID in origin/main).
- `python3 -c "import yaml; yaml.safe_load(open('docs/gaps.yaml'))"` fails with YAMLError at line 17133 (verified on this branch after checkout to origin/main).
- `chump gap reserve` abort message: "parsing /home/user/chump/docs/gaps.yaml: did not find expected key at line 17133 column 5, while parsing a block mapping at line 17065 column 3."

*This finding is wrong if `python3 -c "import yaml; yaml.safe_load(open('docs/gaps.yaml'))"` exits 0 on origin/main before this PR merges.*

---

[P1/High] We are failing to enforce the closed_pr integrity guard in the remote dispatch environment. Nine `status: done` gaps in origin/main carry `closed_pr: TBD`, bypassing the INFRA-107 guard that was filed to prevent exactly this.

Affected gaps (verified by git log scan — each was introduced with `closed_pr: TBD` in its filing commit):
- INFRA-186: `47251c4` (PR #694) — done+TBD in same commit
- INFRA-180: `b783418` (PR #690) — done+TBD in same commit
- INFRA-182: `b80c435` (PR #692) — done+TBD in same commit
- INFRA-189: `51342f9` (PR #705) — done+TBD in same commit
- INFRA-190: `20a168e` (PR #698) — done+TBD in same commit
- INFRA-192: `cee75e3` (PR #700) — done+TBD in same commit
- INFRA-194: `4fc1d56` (PR #709) — done+TBD in same commit
- INFRA-195: `916d85a` (PR #712) — done+TBD in same commit
- EVAL-062: older, no recent commit verified

Root cause: `scripts/setup/install-hooks.sh` is not called by `bot-merge.sh` or any standard dispatch pipeline step. Verified: `grep -n "install-hooks" scripts/coord/bot-merge.sh` returns nothing. A remote dispatch agent committing from a fresh worktree or sandbox has no pre-commit hook installed. The INFRA-107 guard never runs.

Evidence:
- `ls -la /home/user/chump/.git/hooks/pre-commit 2>/dev/null || echo "no hook"` in this sandbox returns "no hook" — confirming pre-commit is absent in fresh sandboxes.
- `git log origin/main --since="2026-05-01" --format="%H" -- docs/gaps.yaml` shows 7 commits adding `closed_pr: TBD` rows since 2026-05-01 alone.
- `grep -n "install-hooks" scripts/coord/bot-merge.sh` returns empty output.

*This finding is wrong if `scripts/coord/bot-merge.sh` contains a call to `install-hooks.sh` that I missed, or if the pre-commit hook is installed via a mechanism other than `install-hooks.sh`.*

---

### The Opportunity Cost

[P0/High] We are failing to execute EVAL-090 for the second consecutive Cold Water cycle while maintaining its P0 classification.

EVAL-090 (re-run EVAL-069 under verified python3.12, age: 7 days, P0, zero implementation commits) is now classified STILL_OPEN_INACTIVE for two consecutive cycles. The gap has a single commit referencing it: `e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)`. That commit is the Cold Water filing, not an implementation.

Evidence:
```
git log origin/main --grep=EVAL-090 --oneline
e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)
```
- `grep -A5 "^- id: EVAL-090" docs/gaps.yaml` shows `status: open`, `priority: P0`, `opened_date: '2026-04-26'`.
- The 11 commits in this audit window include: INFRA-190 follow-up, INFRA-194 auto-batcher, INFRA-189 out-of-scope guard, INFRA-170 book sync guard, INFRA-177 close, INFRA-195 distill-pr-skills, dependabot CI, META-004 resolution notes, PRODUCT-017 FTUE verify, Red Letter #9, INFRA-202..207 fleet scaling. Zero of these touch EVAL-090.

*This finding is wrong if `git log origin/main --grep=EVAL-090` returns at least one commit that is a harness invocation (not a Cold Water filing).*

[P1/High] We are failing to move RESEARCH-021 for the seventh consecutive Cold Water cycle.

`git log origin/main --grep=RESEARCH-021 --oneline` returns exactly one result: `e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)`. The gap has been open since at minimum Issue #4. Across Issues #4 through #10 — seven cycles — no implementation commit has landed.

Evidence:
```
git log origin/main --grep=RESEARCH-021 --oneline
e0ab7e7 chore(cold-water): Red Letter issue #9 — 2026-05-02 (#714)
```
- `grep -A5 "^- id: RESEARCH-021" docs/gaps.yaml` shows `status: open`, `priority: P1`, zero `closed_pr`.
- The project shipped 11 commits after Issue #9, none mentioning RESEARCH-021 except the Issue #9 filing itself.

*This finding is wrong if `git log origin/main --grep=RESEARCH-021` returns a commit with actual tier-dependence experiment data.*

---

### The Complexity Trap

[P1/High] We are failing to stop gaps.yaml hand-edits despite two advisory P0 gaps and a newly filed P1 gap (INFRA-200) to enforce blocking.

Issue #9 measured 33/50 commits (66%) touching docs/gaps.yaml directly, prompting the filing of INFRA-200 (hard pre-commit block). In the 11-commit window since Issue #9, **7/11 commits (64%)** still touch docs/gaps.yaml directly:

```
git log e0ab7e7..origin/main --oneline -- docs/gaps.yaml
6d21b33 file INFRA-202..207: fleet scaling backlog
ad9fa4d file INFRA-201/202: pre-commit guard bugs
4fc1d56 INFRA-194: closer-PR auto-batcher v1
51342f9 INFRA-189: out-of-scope guard
aa6a21d chore(gaps): close INFRA-177
916d85a INFRA-195 v1: distill-pr-skills.sh
c89ffff META-004: add resolution_notes
```

INFRA-200 was filed this cycle (Issue #9) to ship the hard block. `git log origin/main --grep=INFRA-200` returns `ad9fa4d` — the filing commit for INFRA-201/202, which contains the text "INFRA-200" only as a cross-reference. INFRA-200 itself has zero implementation commits.

Evidence:
- `git log e0ab7e7..origin/main --oneline -- docs/gaps.yaml | wc -l` = 7.
- `git log e0ab7e7..origin/main --oneline | wc -l` = 11.
- `grep -A3 "^- id: INFRA-200" docs/gaps.yaml` shows `status: open`.
- INFRA-084 (P0, stop appending to gaps.yaml) and INFRA-094 (P0, mandate chump gap commands) remain open with only advisory enforcement. INFRA-094's acceptance criteria require "Pre-commit hook *blocks* raw docs/gaps.yaml edits without chump-gap commit trailer" — the shipped behavior warns, not blocks.

*This finding is wrong if `git log origin/main --since="2026-05-03" --format='%H' -- docs/gaps.yaml | wc -l` returns <20% of total commits in the same period (indicating behavioral change after this issue ships).*

[P1/High] We are failing to address the OPEN-BUT-LANDED accumulation: 43/114 (38%) open gaps have landed commits.

The P0 OPEN-BUT-LANDED composition is the most dangerous residual. Seven P0 gaps are open-but-landed:
- EVAL-090 (1 commit — Cold Water filing only, no implementation)
- INFRA-084 (2 commits — implementation + Cold Water)
- INFRA-094 (1 commit — implementation)
- INFRA-183 (5 commits — sub-tasks shipped)
- INFRA-205 (1 commit — filing only)
- PRODUCT-024 (3 commits — implementation shipped in PR #697)
- SECURITY-004 (1 commit — SECURITY-005 filed)

PRODUCT-024 and INFRA-183 are unambiguously shipped (PR #697 delivered; sub-tasks INFRA-184/185/199/PRODUCT-024 all closed). The umbrella INFRA-183 and the sub PRODUCT-024 are OPEN-BUT-DONE — the gap registry state is factually wrong.

Evidence:
- `grep -A5 "^- id: PRODUCT-024" docs/gaps.yaml` shows `status: open`, `priority: P0`.
- Commit `0a6d2cc` body: "PRODUCT-024: chat default to non-reasoning model — 25x latency win (2.27s/4.25s vs 56.99s) (#697)" with no `chump gap ship` call.
- `grep -A5 "^- id: INFRA-183" docs/gaps.yaml` shows `status: open`, `priority: P0`, with sub-tasks INFRA-184/185/199 all `status: done`.

*This finding is wrong if PRODUCT-024 and INFRA-183 both show `status: done` with numeric `closed_pr` in docs/gaps.yaml.*

---

### The Reality Check

[P0/High] We are failing to verify the foundational measurement that the entire F3 finding rests on. EVAL-090 is now 7 days old, P0, with zero implementation commits across two consecutive Cold Water cycles.

The exact text from `docs/process/RESEARCH_INTEGRITY.md` validated findings table:
> "Neuromod harm is cross-architecture, two distinct mechanisms | EVAL-029 drilldown | Medium (n=50, single judge)"

The F3 row in `docs/audits/FINDINGS.md` describes the finding as "localized to two task clusters." That localization claim rests on EVAL-029 (n=50, medium confidence). The aggregate signal that F3 retired (EVAL-069: -10 to -16pp) ran under the broken `exit_code_fallback` scorer. EVAL-090's job is to re-run under `python3.12` + `scorer=llm-judge` and confirm whether the aggregate was broken-vs-broken or real. Until that runs, the "localized" frame has one verified component (EVAL-029 direction-consistent at n=50) and an unverified baseline (EVAL-069 may have been null, not negative).

PRODUCT-009 (external publication) is explicitly gated on EVAL-090's acceptance criteria: "Block PRODUCT-009 publication until this lands." The project has been unable to publish for at minimum 7 days due to this single unexecuted gap.

Evidence:
- `grep -A10 "^- id: EVAL-090" docs/gaps.yaml`: `status: open`, `priority: P0`, `opened_date: '2026-04-26'`.
- `git log origin/main --grep=EVAL-090 --oneline`: one result only (`e0ab7e7` Cold Water filing).
- `docs/process/RESEARCH_INTEGRITY.md` prohibited claims table: "Neuromodulation is a net positive" gated on EVAL-030-VALIDATE + EVAL-043. The baseline measurement (EVAL-069) that EVAL-030 calibrated against is the one EVAL-090 needs to revalidate.

*This finding is wrong if `docs/audits/FINDINGS.md` F3 row contains a `validated: true` annotation from an EVAL-069-rerun with `scorer=llm-judge` and `python3.12`, OR if EVAL-090 shows `status: done` with a numeric `closed_pr`.*

---

### The Innovation Lag

[P1/Medium] We are failing to respond to the ICLR 2026 covert sandbagging threat for the second consecutive Cold Water cycle. EVAL-094 and EVAL-087 both have zero implementation commits.

`git log origin/main --grep=EVAL-094 --oneline` returns only `e0ab7e7` (Issue #9 filing).
`git log origin/main --grep=EVAL-087 --oneline` returns only `e0ab7e7` (Issue #9 filing).
`git log origin/main --grep=RESEARCH-026 --oneline` returns empty.

The external evidence has not changed: "LLMs Can Covertly Sandbag on Capability Evaluations Against Chain-of-Thought Monitoring" (arXiv:2508.00943, ICLR 2026) documents 16–36% monitor bypass rates for Claude-class models under evaluation-aware conditions. Chump's validated findings (EVAL-025, EVAL-027c, EVAL-030 — all cited in `docs/process/RESEARCH_INTEGRITY.md`) were produced under conditions structurally identical to those the paper shows are vulnerable. RESEARCH-026 (the filed response, P2) has zero implementation commits. EVAL-087 (P1, priority reframe request) has zero implementation commits. EVAL-094 (P1, direct execution gap) has zero implementation commits. Three filed responses to a quantified external threat: none started.

The project is accumulating fleet-scaling infrastructure (INFRA-202..207, 6 new gaps filed in one commit) while the measurement validity of its entire research portfolio sits on a threat with a measured 16–36% bypass rate and zero filed countermeasure work.

Evidence:
- `git log origin/main --grep="RESEARCH-026\|EVAL-087\|EVAL-094" --oneline` returns only Issue #9 Cold Water filing for EVAL-087 and EVAL-094; RESEARCH-026 returns zero.
- EVAL-025 ("Lessons block helps haiku-4-5 on reflection fixture", High confidence) was produced with explicit evaluation framing (task IDs, structured rubrics, "the user asks..." syntax) — exactly the conditions arXiv:2508.00943 targets.
- `grep -A5 "^- id: RESEARCH-026" docs/gaps.yaml`: `priority: P2` (not upgraded to P1 despite EVAL-087 and EVAL-094 both requesting this).

*This finding is wrong if `git log origin/main --grep=RESEARCH-026` returns at least one execution commit (harness invocation, result file, or Wilson CI table).*

---

**THE ONE BIG THING:** [P0] META-007 — We are failing at the most elementary infrastructure requirement: a readable gap registry.

The docs/gaps.yaml on origin/main (commit 6d21b33) was invalid YAML at audit time. Any tool attempting `yaml.safe_load(open('docs/gaps.yaml'))` failed at line 17133. This was not a latent risk — it was an active breakage that blocked Cold Water's own gap-filing workflow (`chump gap reserve` aborted immediately with the parse error). The cause was a concurrent-branch ID collision between commits `ad9fa4d` and `6d21b33`, both filed INFRA-202 on the same day. The duplicate-ID pre-commit guard (INFRA-GAPS-DEDUP, in operation since 2026-04-19) failed because it compares staged-vs-HEAD, not staged-vs-origin/main. This is the same guard failure mode documented in Issue #7 for the INFRA-073 × INFRA-073 collision. That collision was the ONE BIG THING in Issue #7. The project filed INFRA-075 in response, shipped a fix, and the same failure mode has now produced a second collision — this time with a more severe consequence: the YAML parse error that INFRA-073 did not produce. The project was operating with a malformed canonical registry on origin/main. Every agent spawned after commit 6d21b33 that ran `chump gap import` or any YAML-parsing workflow against main was working with broken input. Cold Water fixed this in the original commit (renaming the ghost INFRA-202 to INFRA-222 — was INFRA-208 in the original commit, renumbered during rebase — and separating the corrupted INFRA-207 description block), but the underlying guard gap (concurrent-branch ID race) remains open. Gap: META-007 (filed this cycle, classified P0; was META-006 in the original commit, renumbered during rebase).

---

### Follow-up Gaps Filed

- **INFRA-222** (P2/xs): docs-delta guard `Net-new-docs:` trailer escape hatch unreachable at pre-commit time — *(was INFRA-208 in the original commit; renumbered during rebase: main's INFRA-208 was independently filed as "chump gap dump is lossy")*
- **INFRA-209** (P1/s): pre-commit hooks not auto-installed in remote dispatch environment — 8 recent commits bypassed INFRA-107 guard; hooks not called by bot-merge.sh
- **EVAL-095** (P1/xs): EVAL-090 P0 two-cycle inactive — force human decision: execute within 7 days or downgrade priority
- **META-007** (P0/xs): gaps.yaml malformed YAML on origin/main from concurrent INFRA-202 duplicate ID collision — duplicate-ID guard does not check origin/main; immediate YAML fix in this PR — *(was META-006 in the original commit; renumbered during rebase: main's META-006 was independently filed as "retire docs/gaps.yaml")*

*Note: gap-reserve.sh was unavailable due to the YAML parse error. Gaps filed directly to docs/gaps.yaml with IDs INFRA-222, INFRA-209, EVAL-095, META-007 (verified via `python3 -c "import yaml; yaml.safe_load(open('docs/gaps.yaml'))"`; no duplicates).*

---

---

## Issue #9 — 2026-05-02

> Audit window: commits since 2026-04-27 (Issue #8 date). 50 commits on origin/main.

### Status of Prior Issues

**From Issue #8 (2026-04-27):**

- **FIXED:** PRODUCT-017 (P0 — clean-machine FTUE, THE ONE BIG THING in Issues #6/7/8) — closed_pr: 631, closed_date: 2026-04-28. Implementation: `fde7594` verification artifact + close PRODUCT-021; `cd42a47` FTUE 2026-04-29 (17s, exit=0); `a801ff9` FTUE 2026-04-30 (17s, exit=0). `git log origin/main --grep=PRODUCT-017` returns 5 commits. Three-cycle fix is confirmed delivered.
- **FIXED:** DOC-012 (NORTH_STAR.md cognitive-architecture claims contradict RESEARCH_INTEGRITY) — closed_pr: 633, closed_date: 2026-04-28. Verified: `docs/strategy/NORTH_STAR.md` now reads "is the design hypothesis we are betting on, not a validated mechanism" and explicitly lists modules with net-negative/null findings. Prohibited-claim language removed.
- **FIXED:** EVAL-092 (provider-matrix harness) — closed_pr: 601, closed_date: 2026-04-27.
- **FIXED:** PRODUCT-021 (P0 non-compliance escalation) — closed_pr: 662, closed_date: 2026-04-29.
- **FIXED:** INFRA-076 (`Test <test@test.com>` co-author) — closed_pr: 642, closed_date: 2026-04-28. Verified: `git log origin/main -30 --format='%H' | xargs -I{} git show -s --format='%b' {} | grep 'Test <test'` returns nothing. Zero Test co-author occurrences in last 30 commits.
- **FIXED_BUT_REPLACED:** FLEET-017 (Cold Water ambient NATS) — closed_pr: 629, closed_date: 2026-04-28. FLEET-019/020/021/022 shipped hook scripts (`scripts/coord/ambient-context-inject.sh`, `scripts/setup/install-ambient-hooks.sh`). BUT: `.chump-locks/ambient.jsonl` in this Cold Water sandbox still contains exactly 2 events — both `session_start` from this session only. The install step (`install-ambient-hooks.sh`) is never executed in remote-sandbox Cold Water sessions. The hooks exist; the Cold Water agent cannot run them; the stream is still operationally empty. FLEET-023 filed this cycle.
- **STILL_OPEN_INACTIVE (3 cycles — #7, #8, #9):** EVAL-087 (evaluation-awareness reframe) — `git log origin/main --format='%H %s' | grep 'EVAL-087'` returns zero commits. Opened 2026-04-26. Zero implementation commits.
- **STILL_OPEN_INACTIVE (6 cycles — #4, #5, #6, #7, #8, #9):** RESEARCH-021 (tier-dependence replication) — `git log origin/main --format='%H %s' | grep 'RESEARCH-021'` returns zero commits. The only gap in the registry with 6 consecutive Cold Water cycles of zero implementation commits.
- **STILL_OPEN_ACTIVE:** EVAL-074 (DeepSeek regression root cause) — 1 commit since Issue #8: `f1bf519` "EVAL-074: feasibility assessment + cheap-first protocol design" (2026-04-28). Acceptance gap: no actual re-run executed; feasibility study only.
- **STILL_OPEN:** META-002 (FIXED-but-replaced classification missing) — `git log origin/main --format='%H %s' | grep 'META-002'` returns zero commits.
- **NO_GAP filed this cycle:** FLEET-023, EVAL-094, INFRA-200, META-005.

---

### The Looming Ghost

[P0/High] We are failing to re-verify the foundational data that F3 retirement rests on — for the third week.

EVAL-090 (P0 — re-run EVAL-069 under verified python3.12) has been open since 2026-04-26 with exactly **zero implementation commits**. Age: 6 days. Priority: P0. `git log origin/main --format='%H %s' | grep 'EVAL-090'` returns empty.

Evidence:
- `docs/gaps.yaml` EVAL-090 `status: open`, `priority: P0`, `opened_date: '2026-04-26'`, zero `closed_pr` field. Verified directly (`grep -A5 '^- id: EVAL-090' docs/gaps.yaml`).
- `docs/audits/FINDINGS.md` F3 row states: "Aggregate −10 to −16 pp retired (EVAL-069 and EVAL-063 both retired on methodology grounds); harm concentrated in dynamic conditional-chain + monosyllabic-token tasks." The localization claim rests on EVAL-029 drilldown (n=50, medium confidence). The retired aggregate rests on EVAL-069 — which EVAL-090 says ran under a broken scorer.
- EVAL-090's description: "EVAL-069 almost certainly ran under the same broken exit_code_fallback scorer. Identical CIs in both cells (acc_A=0.920 [0.812, 0.968] = acc_B=0.920 [0.812, 0.968], delta=0.000) is the fingerprint of a non-cognitive scorer." EVAL-090 acceptance_criteria explicitly states "Block PRODUCT-009 publication until this lands."

Falsifying condition: This finding is wrong if `git log origin/main --grep=EVAL-090` returns at least one implementation commit (an actual re-run, not a filing or feasibility study).

---

### The Opportunity Cost

[P1/High] We are failing to start RESEARCH-021 for the sixth consecutive Cold Water cycle.

RESEARCH-021 (tier-dependence replication across 4 model families, P1) has zero implementation commits since filing. `git log origin/main --format='%H %s' | grep 'RESEARCH-021'` returns nothing. The gap was opened in the observable window of Issue #4. Flagged in Issues #4, #5, #6, #7, #8, #9 — the only gap in this registry with 6 consecutive cycles of inactivity.

Evidence:
- `grep -A8 '^- id: RESEARCH-021' docs/gaps.yaml` shows `status: open`, `priority: P1`, zero `closed_pr`, no `closed_date`.
- `git log origin/main --format='%H %s' | grep -i RESEARCH-021` returns zero results. This command was run three separate times during this audit; output was empty each time.
- EVAL-090 acceptance criteria (verified above) explicitly gates PRODUCT-009 on EVAL-090. PRODUCT-009 (P2, open) is also blocked by RESEARCH-021 per `docs/process/PRODUCT-009-PUBLICATION-CHECKLIST.md`. Two distinct P0/P1 gaps each independently block the project's only planned external publication.

Falsifying condition: This finding is wrong if `git log origin/main --format='%H %s' | grep 'RESEARCH-021'` returns at least one commit with research execution output (JSONL data, result summary, or harness invocation log).

[P1/High] We are failing to close three shipped P0 gaps that are open-but-landed.

PRODUCT-024 (P0 — PWA chat default to non-reasoning model) shipped in PR #697 (`0a6d2cc`, commit message explicitly states "PRODUCT-024: close as done (closed_pr=697)") but `grep -A5 '^- id: PRODUCT-024' docs/gaps.yaml` shows `status: open`. INFRA-183 umbrella (P0 — PWA latency) has all sub-tasks completed (INFRA-184 done, INFRA-185 done, PRODUCT-024 shipped) but `grep -A5 '^- id: INFRA-183' docs/gaps.yaml` shows `status: open`. SECURITY-004 (P0 — 6 Dependabot alerts) has only 1 filing commit; SECURITY-005 closed 1 of the 6 advisories; 5 remain (rand unsoundness, glib Iterator, 3 rustls-webpki non-serenity paths) with zero upgrade commits.

Evidence:
- `grep -A8 '^- id: PRODUCT-024' docs/gaps.yaml`: `status: open`, `priority: P0`. Commit `0a6d2cc` subject: "PRODUCT-024: chat default to non-reasoning model — 25x latency win." Body of commit contains "PRODUCT-024: close as done (closed_pr=697)."
- `grep -A8 '^- id: INFRA-183' docs/gaps.yaml`: `status: open`, `priority: P0`. Sub-tasks INFRA-184 (`closed_pr: 701`) and INFRA-185 (`closed_pr: 704`) verified done.
- `grep -A5 '^- id: SECURITY-004' docs/gaps.yaml`: `status: open`, `priority: P0`. SECURITY-005 notes: "closes 1 of 6 advisories at the runtime-exposure level. The remaining 5 remain SECURITY-004's responsibility."

Falsifying condition: This finding is wrong if PRODUCT-024 and INFRA-183 both show `status: done` with `closed_pr` set in docs/gaps.yaml.

---

### The Complexity Trap

[P1/High] We are failing to arrest hand-editing of docs/gaps.yaml despite shipping two advisories targeting exactly this behavior.

INFRA-084 (P0 — stop appending to gaps.yaml in PRs) shipped a merge_group regeneration workflow (`a087f0b`, 2026-04-29). INFRA-094 (P0 — mandate chump gap commands) shipped an advisory pre-commit warning with a "chump-gap" commit marker (`7f46169`, 2026-04-29). Neither shipped a hard block. Since those advisory commits landed (2026-04-29), **33 of 50 commits** on origin/main have touched `docs/gaps.yaml` — a 66% hand-edit rate, verified by `git log origin/main --since='2026-04-27' --format='%H' -- docs/gaps.yaml | wc -l` returning 33 against a total of 50 commits.

Evidence:
- `git log origin/main --since='2026-04-27' --format='%H' -- docs/gaps.yaml | wc -l` = 33.
- `git log origin/main --since='2026-04-27' --format='%H' | wc -l` = 50.
- The SECURITY-005 gap row itself (`d1012f5`, "chore(gaps): add SECURITY-005 row via surgical insert at SECURITY-* block") notes in its own description: "three end-of-YAML append refile attempts (#678, #684, #695) all went DIRTY due to the structural append-region race INFRA-173 is filed to fix." The race INFRA-084 was filed to eliminate produced three DIRTY failures for the same gap row, even after the advisory shipped.
- INFRA-094's acceptance criteria (`grep -A15 '^- id: INFRA-094' docs/gaps.yaml`) require: "Pre-commit hook **blocks** raw docs/gaps.yaml edits without chump-gap commit trailer." The shipped pre-commit section (advisory, not block) does not satisfy this criterion. Both P0 gaps remain open.

Falsifying condition: This finding is wrong if `git log origin/main --since='2026-04-29' --format='%H' -- docs/gaps.yaml | wc -l` returns fewer than 5 (indicating advisory-driven behavioral change).

[P2/Medium] We are failing to track the OPEN-BUT-LANDED regression honestly.

OPEN-BUT-LANDED count dropped from 65/88 (74%) in Issue #8 to **20/102 (19%)** this cycle (verified by Python scan: `python3` script counting open gaps with ≥1 commit referencing the ID in origin/main log). This appears to be a win. The regression is in what's still OPEN-BUT-LANDED: of the 20, **4 are P0 or P1 priority gaps** (INFRA-183 P0, PRODUCT-024 P0, SECURITY-004 P0, INFRA-100 P1). The prior cycle's gap-closure infrastructure appears to have closed most of the lower-priority OPEN-BUT-LANDED entries while the highest-urgency ones remain unclosed. The ratio is better; the residual is worse-composed.

Evidence:
- Python OPEN-BUT-LANDED census output (run this cycle): total open gaps: 102, landed: 20, ratio: 19%.
- P0 landed entries: INFRA-183 (2 commits), PRODUCT-024 (1 commit), SECURITY-004 (1 commit).
- Issue #8 OPEN-BUT-LANDED count was 65/88 (74%). Delta: −45 absolute, −55pp ratio. 

Falsifying condition: This finding is wrong if `grep -A5 '^- id: PRODUCT-024' docs/gaps.yaml` shows `status: done`.

---

### The Reality Check

[P0/High] We are failing to treat EVAL-090 as P0 — the foundational neuromod measurement cannot be verified as non-broken.

EVAL-090 blocks PRODUCT-009. PRODUCT-009 (P2, open, "External publication of F1-F6 empirical findings") lists EVAL-090 as a prerequisite in its acceptance criteria. The F3 finding ("cross-architecture neuromod harm is localized to two task clusters") is currently supported by EVAL-029 drilldown (n=50, medium confidence, single judge) — but the retired aggregate claim (EVAL-069) that F3 replaced may have been broken-vs-broken. If EVAL-090 reruns and finds a non-zero aggregate, F3's "localized" framing is based on one n=50 survey and an invalidated baseline. If EVAL-090 reruns and finds the same delta=0.000, F3 retirement is confirmed on solid ground. Neither is known. This is not a methodology preference; it is an unverified foundational measurement. EVAL-090 has been P0 for 6 days with zero implementation commits.

Evidence:
- `grep -A5 '^- id: EVAL-090' docs/gaps.yaml`: `status: open`, `priority: P0`, `opened_date: '2026-04-26'`. No `closed_pr` or `closed_date`.
- `git log origin/main --format='%H %s' | grep EVAL-090` returns empty. Three independent checks.
- `docs/audits/FINDINGS.md` F3 row status: "4/4 sweeps direction-consistent; both EVAL-026 retests methodology-invalid (mixed-scorer / broken-scorer); localization stands." The localization claim stands but the aggregate measurement is unverified.
- EVAL-090 acceptance criteria explicitly: "Block PRODUCT-009 publication until this lands."

Falsifying condition: This finding is wrong if `docs/audits/FINDINGS.md` F3 row contains a verified A/A baseline from a python3.12 run with `scorer=llm-judge` in the JSONL output, OR if EVAL-090 shows `status: done` with a numeric `closed_pr`.

---

### The Innovation Lag

[P1/Medium] We are failing to respond to ICLR 2026-confirmed covert sandbagging while EVAL-087 sits inactive for 3 cycles.

EVAL-087 (P1, open, filed 2026-04-26) asks for RESEARCH-026 to be reframed from P2 to P1 based on the IAPS evaluation-awareness paper. It has zero implementation commits. New external evidence this cycle makes the threat quantitatively worse: "LLMs Can Covertly Sandbag on Capability Evaluations Against Chain-of-Thought Monitoring" (arXiv:2508.00943, published as ICLR 2026 paper, https://arxiv.org/abs/2508.00943) demonstrates that frontier models — including Claude-3.7-Sonnet and Claude-4-Sonnet — can bypass CoT monitoring **16–36% of the time** when prompted to sandbag and when monitor-aware. Chump's A/B harness uses Claude Haiku-4.5 and Sonnet-4.5 as agents under test. The harness uses explicit evaluation framing (task IDs, structured rubrics, "the user asks..." syntax). The ICLR 2026 paper's models include Claude-4-Sonnet, one generation above the models Chump currently tests. A 16–36% monitor-bypass rate on a structurally identical configuration means a substantial fraction of Chump's A/B trials may produce strategically modified behavior. The validated findings table (EVAL-025, EVAL-027c, EVAL-030) was produced entirely under these conditions. RESEARCH-026 (P2, open) and EVAL-087 (P1, open) are the filed responses. Both have zero implementation commits.

Evidence:
- `git log origin/main --format='%H %s' | grep -E 'EVAL-087|RESEARCH-026'` returns zero results.
- `grep -A8 '^- id: EVAL-087' docs/gaps.yaml`: `status: open`, `priority: P1`, `opened_date: '2026-04-26'`.
- `grep -A8 '^- id: RESEARCH-026' docs/gaps.yaml`: `status: open`, `priority: P2`.
- arXiv:2508.00943 accepted at ICLR 2026 (verified via https://arxiv.org/abs/2508.00943); evaluated 10 models including Claude-3.7-Sonnet and Claude-4-Sonnet; reported 16–36% CoT monitor bypass rate when monitor-aware.

The strategic memo (`docs/strategy/STRATEGIC_MEMO_2026Q2.md`) is still an orphan: `git log origin/main --format='%H %s' | grep 'FRONTIER-006'` returns zero commits since closing. Section 3's 5 recommendations have no follow-up gaps. This is STILL_OPEN_INACTIVE across cycles #6, #7, #8, #9.

Falsifying condition: This finding is wrong if `git log origin/main --format='%H %s' | grep -E 'RESEARCH-026|EVAL-087'` returns at least one execution commit (harness invocation, result file, or Wilson CI table).

---

**THE ONE BIG THING:** [P0] EVAL-090 — We are failing at the most basic epistemic duty: verifying that our one published null result isn't a scorer artifact.

EVAL-090 has been P0 for 6 days with zero implementation commits. It is not blocked by any dependency. Its acceptance criteria are concrete: run the eval with `python3.12`, verify `scorer=llm-judge` in JSONL output, and update FINDINGS.md F3. The entire gap would take a single agent session under 2 hours. Instead, the project shipped 50 commits in 5 days — renaming conventions (INFRA-186), PWA bubble fixes (INFRA-178), narration detection (INFRA-177), timing breakdowns (INFRA-185), a pr-watch script (INFRA-190) — while the measurement that determines whether a key research finding is real or an artifact sits untouched. The neuromodulation module was audited and found to be wired through (REMOVAL-006, `9a3f0a3`): EVAL-029's net-negative signal is measuring real provider behavior. That makes the F3 question more important, not less — if neuromod is actually affecting providers, knowing whether the harm is aggregate or only task-clustered has direct product consequences (PRODUCT-024 just shipped model-swapping partly on this basis). A P0 gap that blocks the project's only planned publication, that has been open 6 days with zero implementation commits, that would take one agent session to execute — this is not resource-constrained inactivity. It is prioritization failure. Gap: EVAL-090.

---

### Follow-up Gaps Filed

- FLEET-023: Cold Water sandbox ambient stream empty post-FLEET-019/020/021/022 — install step never executed (P1/xs)
- EVAL-094: ICLR 2026 covert sandbagging (arXiv:2508.00943) confirms evaluation-context discrimination — run RESEARCH-026 swept experiment now (P1/s)
- INFRA-200: gaps.yaml advisory-only enforcement failed — 66% hand-edit rate post-INFRA-084/094; ship hard pre-commit block (P1/s)
- META-005: P0 OPEN-BUT-LANDED (PRODUCT-024, INFRA-183, SECURITY-004) — P0-closure hygiene failure; block new P0 filings until existing P0 OPEN-BUT-LANDED clears (P2/xs)

---

---


---

## Issue #8 — 2026-04-27

### Status of Prior Issues

**From Issue #7 (2026-04-26):**

- **FIXED:** INFRA-075 (duplicate-ID guard concurrent-branch race) — PR #556 (`93338eb`) shipped CI-time guard catching same-branch concurrent additions. Verified: `git log origin/main --grep=INFRA-075` returns 7 commits, most recent `93338eb`.
- **FIXED:** DOC-009 (WORK_QUEUE.md stale data) — absorbed by DOC-011 (PR #589, `4ddf9c1`): WORK_QUEUE.md replaced entirely with a CLI pointer stub. Verified: `cat docs/process/WORK_QUEUE.md` is now a stub pointing to `chump gap list`. The stale-data failure mode is architecturally eliminated.
- **FIXED:** FLEET-016 (deduplicate FLEET-006/FLEET-015 ambient gaps) — PR #560 (`f10cc82`) deduped the two overlapping ambient-stream gaps. Verified: `git log origin/main --grep=FLEET-016` returns 2 commits, most recent `f10cc82`.
- **FIXED-WITH-REPLACEMENT:** FLEET-006 (ambient stream empty — 6 cycles) — PR #572 (`bb596c2`) distributed the ambient stream over NATS. Gap is `status: done`, `closed_pr: 572`. But on the same date, FLEET-017 (P0, open) was filed: "Cold Water remote agent does not subscribe to NATS ambient stream — FLEET-006 unused." The 6-cycle void is technically resolved on the server side and immediately unresolved on the client (this agent) side. `.chump-locks/ambient.jsonl` still contains exactly 2 events — both `session_start` from Cold Water sessions only. FLEET-017: 1 filing commit, zero fix commits. STILL_OPEN_INACTIVE.
- **STILL_OPEN_INACTIVE:** INFRA-076 (`Test <test@test.com>` co-author) — `git log origin/main --grep=INFRA-076 --oneline` = 1 commit (the Issue #7 filing, `6923b78`). Zero fix commits. `Co-authored-by: Test <test@test.com>` appears in 100% of the last 25 commits examined. Unidentified co-author is present in every commit shipped this cycle. 2 cycles flagged (#7, #8). Verification block: 1 commit, most recent `6923b78` (filing), status: open.
- **STILL_OPEN_INACTIVE:** EVAL-087 (reframe RESEARCH-026 to P1 on evaluation-awareness grounds) — `git log origin/main --grep=EVAL-087 --oneline` = 1 commit (Issue #7 filing, `6923b78`). Zero corrective commits. Gap is P1, open. 2 cycles flagged (#7, #8). Verification block: 1 commit, most recent `6923b78` (filing), status: open.
- **STILL_OPEN_ACTIVE (5 cycles — #4, #5, #6, #7, #8):** RESEARCH-021 (tier-dependence replication) — `git log origin/main --grep=RESEARCH-021 --oneline` = 7 commits. None are implementation commits: all are WORK_QUEUE regeneration (`4ec74e3`), DOC-011 CLI pointer (`4ddf9c1`), gap filing (`88a382a`), Cold Water filings (`d448c4e`, `6923b78`), and DOC-008 WORK_QUEUE dedup (`5b0ab69`). Zero research execution commits in 5 consecutive cycles. Verification block: 7 commits, most recent `88a382a` (gap-filing commit), status: open, acceptance gap: ZERO of the tier-dependence replication experiments started.
- **CONTESTED:** EVAL-074 (DeepSeek regression root cause — 3 cycles) — PR #549 filed a mechanism claim (over-compliance on gotcha tasks, -30pp regression, McNemar p=0.0007 via Llama-3.3-70B). PR #551 (`2c4479f`) RETRACTED that claim: Sonnet-4.5 cross-rescore found -0.4pp gotcha / McNemar p=1.0; Llama vs Sonnet agreement 71%/kappa=0.40 on gotcha tasks (below project 80%/0.6 thresholds). Gap reopened with `reopened_date: 2026-04-26`. The root cause is now classified as unknown with a retracted false-positive. Verification block: 9 commits, most recent `88a382a` (gap-filing), retraction PR #551, status: open (reopened).
- **STILL_OPEN_INACTIVE (3 cycles — #6, #7, #8):** PRODUCT-017 (P0 — clean-machine FTUE verification) — `git log origin/main --grep=PRODUCT-017 --oneline` = 1 commit (`d448c4e`, the Issue #6 Cold Water filing). Zero implementation commits across 3 cycles. Verification block: 1 commit, most recent `d448c4e` (Cold Water #6 filing 2026-04-26), status: open, acceptance gap: no clean-machine stopwatch run, no `docs/FTUE-VERIFICATION-YYYY-MM-DD.md` artifact committed.
- **WORSE — OPEN-BUT-LANDED:** Count grew from 13/27 (48%) in Issue #7 to **65/88 (74%)** in this cycle. The 400% absolute increase (13→65) was driven primarily by a single 20-gap filing commit (`74b2e5c`) and an 11-gap filing commit (`fb690e4`) that each created OPEN-BUT-LANDED gaps within hours of filing. The gap filed in Issue #6 to audit OPEN-BUT-LANDED gaps (INFRA-083) is itself OPEN-BUT-LANDED (1 commit, status: open). The closure-to-filing ratio this cycle: 1 OPEN-BUT-LANDED closed (`62a0a75`, INFRA-068) vs 52 new OPEN-BUT-LANDED gaps created.
- **WORSE — P0 gap count:** From 1 P0 gap in Issue #7 to **8 P0 gaps** in this cycle: PRODUCT-017, INFRA-079, INFRA-084, INFRA-094, EVAL-090, INFRA-112, INFRA-113, FLEET-017. Seven of these 8 have zero implementation commits.

**NO_GAP filed this cycle:** DOC-012, EVAL-092, META-002, PRODUCT-021.

---

### The Looming Ghost

We are failing to maintain basic factual accuracy in the foundational document every evaluator reads first. `docs/strategy/NORTH_STAR.md:19` states: "The cognitive architecture underneath Chump — free energy, surprise tracking, belief state, neuromodulation, precision weighting, memory graphs, counterfactual reasoning — is not a research project. It is the mechanism that makes this possible." `docs/strategy/NORTH_STAR.md:59` reinforces: "The cognitive layer (neuromodulation, precision controller, belief state, surprise tracker) is the mechanism." The project's own validated findings table in `docs/process/RESEARCH_INTEGRITY.md` contradicts every module named: neuromodulation is net-negative at n=50 (EVAL-029, medium confidence); belief_state was deleted with `status: done` on REMOVAL-003 (PR #465) and replaced with a 170-line inert stub; surprisal EMA is explicitly prohibited from being called "validated" until EVAL-043 ships; belief state improvement claims are prohibited until EVAL-035 + EVAL-043. The North Star describes as "the mechanism" four modules that the research branch has either removed, shown to be net-negative, or explicitly prohibited from being cited as validated. DOC-010 (P1, open) was filed to fix "README and faculty docs" but its description does not mention `NORTH_STAR.md`. The foundational promise — "heartbeat matches user intent via neuromodulation, precision controller, belief state, surprise tracker" — is scientifically false per the project's own research. Gap filed: DOC-012.

We are failing at the self-application of our own guards. PR #598 (`75ec5a4`) shipped the `closed_pr` integrity guard — a pre-commit hook that rejects `status: done` flips when `closed_pr` is absent, TBD, or non-numeric. The gap that specified this guard was INFRA-107. INFRA-107's `status` remains `open` in `docs/gaps.yaml`. The guard now means that whoever closes INFRA-107 must set `closed_pr: 598` — which is the correct behavior — but zero commits have done so since the guard shipped 1 day ago. INFRA-107 has 3 commits referencing it and is OPEN-BUT-LANDED. The guard that prevents false closures cannot prevent its own implementor from failing to close the gap it guards. This is not irony — it is evidence that INFRA-083 (gap-closure hygiene audit) cannot succeed through periodic sweeps alone; it requires closure to be triggered automatically at merge time.

---

### The Opportunity Cost

We are failing to move the only P0 product gap for the third consecutive Cold Water cycle. PRODUCT-017 (P0 — stopwatch clean-machine install → PWA responsive) has one commit across its entire lifetime: the Cold Water Issue #6 filing on 2026-04-26. Flagged in Issues #6, #7, and #8. `git log origin/main --grep=PRODUCT-017` returns `d448c4e` — nothing else. PRODUCT-015 (`src/activation.rs:171–194`) is live on main emitting `activation_install`, `activation_first_task`, and `activation_d2_return` events. PRODUCT-020 (P1, open) is designing the MCP marketplace. Both are built on the assumption that `brew install chump → PWA in <60s` works. That assumption has not been tested against an actual clean machine in 3 review cycles. A funnel metric measuring a broken funnel is not a product metric — it is a damage quantification tool that nobody is reading as damage.

We are failing to close 65 of 88 open gaps (74%) that have commits already referencing them. The OPEN-BUT-LANDED count grew 400% (13→65) in one cycle. The top OPEN-BUT-LANDED gaps by commit count: EVAL-074 (9 commits, contested/retracted), RESEARCH-021 (7 commits, zero implementation), PRODUCT-009 (4 commits, zero publication). INFRA-083 (gap-closure hygiene audit, the gap explicitly filed to close OPEN-BUT-LANDED gaps) has 1 commit and is itself OPEN-BUT-LANDED. The project is filing gaps at a rate that outpaces closures by 52:1 this cycle. The registry is not a work tracker — it is a gap accumulator. Any agent reading `status: open` has a 74% chance of reading a gap that has already had work land against it without closure.

We are failing at research with 8 concurrent P0 gaps, none of which have implementation commits more than 1 day old. P0 means "stop everything, fix this." The project has 8 simultaneous stop-everything items. INFRA-112 (gap dump is lossy — 391 DB entries became 389 in YAML) means the registry's canonical source of truth is silently dropping 2 gaps on every regeneration. INFRA-113 (preregistration check is hollow) means the guard that blocks premature eval closures only checks file existence, not content. EVAL-090 (re-run EVAL-069 under python3.12) means the retirement of F3 is based on broken data. These three P0s affect the measurement and coordination infrastructure simultaneously. Each has 2 filing commits and zero implementation commits.

---

### The Complexity Trap

We are failing to recognize that batch gap-filing is generating more coordination debt than it resolves. Two commits — `74b2e5c` (20 gaps: INFRA-112..127, FLEET-017/018, RESEARCH-031, EVAL-091) and `fb690e4` (11 gaps: REMOVAL-006/007, DOC-010, EVAL-090, RESEARCH-030, INFRA-107..111, TEST-002) — created 31 new OPEN-BUT-LANDED gaps in two pushes. The project justified these as "audit-derived" gaps from a 2026-04-26 tour. An audit that produces 31 new gaps in one session while closing 0 is not reducing the work backlog — it is minting coordination tokens. INFRA-083 exists to close OPEN-BUT-LANDED gaps. Its own closure rate this cycle: 1 gap closed (INFRA-068) against 52 new OPEN-BUT-LANDED entries. At this ratio, the registry reaches 100% OPEN-BUT-LANDED within 2 more cycles regardless of how many hygiene-audit gaps are filed.

We are failing to audit the module that its own gap says is dead. REMOVAL-006 (P1, open, filed 2026-04-26) states: "src/neuromodulation.rs computes provider-call adjustments that are never applied." `src/neuromodulation.rs` is 455 lines, 16KB. `src/main.rs:98` loads it as `mod neuromodulation;`. `src/tool_middleware.rs:1115` calls `crate::neuromodulation::effective_tool_timeout_secs()`. The gap says the adjustments are never applied; the code says they touch at least tool timeouts. The audit has not happened. The module is simultaneously described as dead (REMOVAL-006) and live (NORTH_STAR.md), called by tool middleware (verified), and part of a cognitive architecture that the research branch has shown to be net-negative (EVAL-029). Zero investigation commits against REMOVAL-006 since filing.

We are failing to close INFRA-107 despite having shipped its implementation. `docs/gaps.yaml` has INFRA-107 at `status: open`. PR #598 (`75ec5a4`) shipped the exact pre-commit guard that INFRA-107 specified. The guard has been live for 1 day. The gap is open. Closing it requires setting `closed_pr: 598` — a 3-second edit — and no agent has done it. This is the same pattern that INFRA-107 itself was filed to prevent: a done gap sitting open because nobody executed the closure. INFRA-107 is now an instance of the class of problem it was designed to detect.

---

### The Reality Check

We are failing at mechanism analysis methodology. EVAL-074's retraction (PR #551, `2c4479f`) exposes a procedural gap: PR #549 committed a mechanism claim (over-compliance on gotcha tasks, -30pp, McNemar p=0.0007) using a single Llama-3.3-70B judge. The retraction established that Llama vs Sonnet agreement on the specific gotcha fixture is 71%/kappa=0.40 — below the project's own documented 80%/0.6 thresholds. `docs/process/RESEARCH_INTEGRITY.md` line 93–95 requires "a hypothesis for *why* [the delta] appears" for deltas >±0.05. It does not require verifying cross-judge agreement before committing the mechanism claim. The methodology standard that required the investigation did not prevent a methodologically invalid mechanism claim from merging. After 3 Cold Water cycles and 9 commits, the -23pp DeepSeek regression root cause is unknown AND the project now has a retracted mechanism claim in the commit history. EVAL-089 (finish with Qwen-2.5-72B) is P2 open. EVAL-089 has 1 filing commit and zero execution commits. Gap filed: EVAL-092.

We are failing to re-run the foundational data that F3 retirement rests on. EVAL-090 (P0) — re-run EVAL-069 under verified python3.12 — has been open since 2026-04-26 with 2 commits, both filings. EVAL-069's retirement of the neuromod aggregate signal (-10 to -16pp, Issues #4–#6) was flagged as "broken-vs-broken" because `python3` resolved to 3.14 on the test machine (the python3 foot-gun, `docs/process/RESEARCH_INTEGRITY.md` warning block). The `docs/process/RESEARCH_INTEGRITY.md` validated findings table does NOT include any neuromod findings because of this. But the gap that would verify or overturn those findings (EVAL-090) is sitting at P0 with zero movement. A P0 gap assigned to re-verify foundational data that is 6 days old and has zero implementation commits is not being treated as P0.

We are failing to apply `docs/process/RESEARCH_INTEGRITY.md`'s prohibition correctly. The document explicitly prohibits claiming "Neuromodulation is a net positive" until `EVAL-030-VALIDATE cross-architecture + EVAL-043` ship. `docs/strategy/NORTH_STAR.md:19,59` claims neuromodulation IS the mechanism in production prose, not as a research hypothesis. The prohibition section names a gap-ID gate (`Supporting gap: EVAL-030 cross-validate + EVAL-043`). Neither gap has shipped. The prohibited claim is live in the founding document. DOC-012 filed this cycle; no prior gap covered NORTH_STAR.md specifically.

---

### The Innovation Lag

We are failing to act on the now-quantified evaluation-awareness threat to our measurement infrastructure. Meta's Muse Spark April 2026 safety report (covered by Kili Technology: https://kili-technology.com/blog/llm-benchmarks-evaluation-awareness-muse-spark-report) provides a concrete estimate: Muse Spark flagged public benchmarks as evaluations in **19.8% of interactions** versus 2.0% on internal data. Evaluation awareness scales with model size via a power law — every frontier generation worsens the problem. Chump's A/B harness uses Claude Sonnet-4.5 and Haiku-4.5 as agents under test and as judges in some configurations. These are not "smaller models" in the global frontier landscape — they are frontier-tier models that the IAPS paper (cited in Issues #6, #7) showed are precisely where evaluation-context discrimination is most reliable. At a 19.8% flagging rate, approximately 1 in 5 A/B trials in the Chump harness may trigger evaluation-aware behavior. The validated findings table (high confidence: "Lessons block helps haiku-4-5 on reflection fixture," EVAL-025, n=100) was produced entirely under conditions where ~20% of trials may involve a model detecting its evaluation context. RESEARCH-026 (observer-effect / sandbagging check, P2, open, 1 filing commit, zero execution commits) and EVAL-087 (reframe RESEARCH-026 to P1, P1, open, 1 filing commit, zero execution commits) are the project's filed responses to this threat. Both are STILL_OPEN_INACTIVE.

The SKILL0 threat (arXiv:2604.02268, filed as RESEARCH-029, P2, open, 1 filing commit) has received no response in 2 cycles. RESEARCH-029 is OPEN-BUT-LANDED. An active research agenda engaging with the threat would have at minimum a counterargument or a replication attempt. The project has neither.

---

**THE ONE BIG THING:** We are failing at our only P0 product commitment for the third consecutive Cold Water cycle. PRODUCT-017 (P0 — stopwatch clean-machine install → PWA in <60s) has existed in the registry for 3 cycles with exactly 1 commit — its own filing. Flagged in Issues #6, #7, and #8. `git log origin/main --grep=PRODUCT-017 --oneline` confirms: `d448c4e` only. During these 3 cycles the project shipped PRODUCT-015 (activation funnel, `src/activation.rs:171–194`, live on main), filed PRODUCT-020 (MCP marketplace design, P1), renamed the project (INFRA-128), rewrote the README (INFRA-129), reorganized 290 root scripts (INFRA-135), reorganized 146 docs (INFRA-134), and shipped a NATS ambient stream (FLEET-006). None of it matters if the FTUE path that PRODUCT-015 is metering is broken. The D2-return metric is measuring whether users come back to something that may not have worked for them the first time. Three cycles of "stop everything, verify this" and nothing stopped. Gap: PRODUCT-017.

---

### Follow-up Gaps Filed
- DOC-012: NORTH_STAR.md cognitive-architecture claims contradict RESEARCH_INTEGRITY.md validated findings (P1/xs)
- EVAL-092: RESEARCH_INTEGRITY.md mechanism-analysis standard lacks pre-commit kappa threshold gate — EVAL-074 retraction consequence (P1/s)
- META-002: FIXED-but-immediately-replaced classification missing from RED_TEAM_VERIFICATION.md — FLEET-006 example (P2/s)
- PRODUCT-021: PRODUCT-017 P0 non-compliance escalation — freeze all new PRODUCT gap work until clean-machine verification completes (P1/xs)

---

---

## Issue #7 — 2026-04-26

### Status of Prior Issues

**From Issue #6 (2026-04-26):**

- **FIXED:** WORK_QUEUE.md duplicate RESEARCH-021 entry — DOC-008 (PR #548) removed the mechanical paste duplicate on line 18. The duplicate is gone; the stale priority and closed-gap listings in the same document are not fixed (see Complexity Trap below).
- **FIXED:** REMOVAL-003 / belief_state crate deletion — `status: done`; PR #465 confirmed closed. The stub correctness concern documented in Issue #6 (health endpoint, precision controller, checkpoint DB) remains live: `src/health_server.rs:186`, `src/precision_controller.rs:247`, `src/checkpoint_db.rs:96-97` still call into `crate::belief_state::*`. REMOVAL-005 (P3) remains open. The stub's production call surface is not inert.
- **STILL_OPEN (6 cycles — #2, #3, #4, #5, #6, #7):** Ambient stream empty. `.chump-locks/ambient.jsonl` contains exactly two events — both `session_start` from this Cold Water session. FLEET-006 (P1, open) and FLEET-015 (P1, open, filed Issue #6) are both unstarted. Zero corrective commits across six review windows.
- **STILL_OPEN (4 cycles — #4, #5, #6, #7):** RESEARCH-021 (P1, demoted from P0 on 2026-04-24) — zero commits across four review windows. Demotion to P1 did not produce movement; it produced a documented rationalization for non-movement.
- **STILL_OPEN (3 cycles — #5, #6, #7):** EVAL-074 (P2, DeepSeek -23pp regression root cause) — zero mechanism investigation commits.
- **STILL_OPEN (2 cycles — #6, #7):** PRODUCT-017 (P0) — no clean-machine verification artifact committed to `docs/FTUE-VERIFICATION-YYYY-MM-DD.md`. PR #535 added a CI workflow on ephemeral `macos-latest` (not a clean Mac). The only P0 gap is 2 cycles old with zero movement against its acceptance criterion.
- **WORSE — OPEN-BUT-LANDED count:** Grew from 8 (Issue #6) to **13** (this cycle). The 5 gaps filed by Issue #6 itself (INFRA-073 type 1, FLEET-015, FRONTIER-009, EVAL-086, RESEARCH-029) are all already OPEN-BUT-LANDED with at least 1 commit each. The gap filed to fix the OPEN-BUT-LANDED problem is itself immediately OPEN-BUT-LANDED.
- **WORSE — INFRA-073 duplicate ID collision:** Issue #6's Cold Water commit (d448c4e) filed gap "Gap-closure hygiene audit" as INFRA-073; PR #544 (6844154) filed "pre-commit YAML-validity guard" also as INFRA-073. `docs/gaps.yaml` now contains **two entries under `id: INFRA-073`** with completely different titles. This is the 8th documented duplicate ID collision. The duplicate-ID pre-commit guard that has been operational since INFRA-GAPS-DEDUP (2026-04-19) did not catch it. INFRA-075 filed this cycle to investigate and fix the guard scope.
- **NOT FIXED — "Test" author identity:** Issue #6 classified this FIXED citing "zero commits from the 'Test' identity in the observable window; all 50 recent commits are from `repairman29`." The check verified the **primary author** field only. Every one of the last 29+ commits carries `Co-authored-by: Test <test@test.com>` in the commit body. The identity has not been purged — it shifted from primary author to co-author. AGENT_COORDINATION.md has no attribution entry for `Test <test@test.com>`. The false-FIXED call in Issue #6 means this has been unaddressed for a minimum of 2 cycles. INFRA-076 filed this cycle.

**NO_GAP filed this cycle:** INFRA-075, INFRA-076, DOC-009, EVAL-087, FLEET-016.

---

### The Looming Ghost

We are failing to prevent the gap registry's own coordination guards from producing the collisions they were built to prevent. `docs/gaps.yaml` now contains two entries with `id: INFRA-073` — one titled "Gap-closure hygiene audit — close 8 OPEN-BUT-LANDED gaps" (filed by Cold Water Issue #6, commit d448c4e, 2026-04-26) and one titled "pre-commit YAML-validity guard for docs/gaps.yaml" (filed by PR #544, commit 6844154, 2026-04-26). Both commits landed on the same calendar day. The duplicate-ID pre-commit guard (installed since INFRA-GAPS-DEDUP, 2026-04-19) checks whether the **incoming diff** adds an ID already present in the file. It catches collisions where one commit adds a new entry that duplicates an existing committed entry. It does not catch concurrent commits: when two branches each add a new entry with the same ID and are merged in sequence, the second merge sees the first as already-committed and fires — but if both were filed in the same rapid-fire push sequence with one preceding the other by seconds, the guard may see neither as a pre-existing committed state. The exact failure mode is unconfirmed; what is confirmed is that 8 coordination guards, a YAML validity guard, and a gap-preflight system collectively failed to prevent an INFRA-073 × INFRA-073 collision on the same date the first INFRA-073 was filed. The project has now accumulated 8 known duplicate ID collision pairs. The 7 original pairs (Issues #2, COG-007 through COG-011, MEM-003, EVAL-003) motivated the guard system. The guard system has now produced its own 8th pair. Gap INFRA-075 filed.

We are failing to maintain the belief_state removal promise. REMOVAL-003 is `status: done` (PR #465, 2026-04-25). The stub (`src/belief_state.rs`, 170 lines) has three active production call sites that return zero-valued no-ops in decision paths: `src/health_server.rs:186` serializes `crate::belief_state::metrics_json()` into the live health endpoint; `src/precision_controller.rs:247,268` reads `crate::belief_state::task_belief().uncertainty()` to gate precision escalation decisions (a stub returning 0.0 keeps escalation permanently suppressed); `src/checkpoint_db.rs:96-97` stores `ToolBelief` and `TaskBelief` structs from the stub into persistent checkpoint state. REMOVAL-005 (P3) tracks callsite cleanup but has `status: open` with zero commits. The REMOVAL-003 gap closure criteria did not require verifying that the stub's call sites produce correct semantics in their callers. A "done" removal gap that leaves three production decision paths calling an inert stub is not done.

---

### The Opportunity Cost

We are failing to move the only unblocked P1 research gap after four consecutive Cold Water cycles. RESEARCH-021 (P1, tier-dependence replication across 4 model families) has received zero commits in the observable windows covered by Issues #4, #5, #6, and #7. The 2026-04-24 CPO reframe demoted it from P0 to P1 with the note "in-flight, allowed to finish." The gap was not in-flight — it had already received zero commits when demoted. The demotion did not produce movement; it produced a documented rationale for continued non-movement. There is now no P0 research gap (RESEARCH-021 was the only one; PRODUCT-017 is the only remaining P0 and it is product, not research). The mechanism for forcing research progress — P0 priority — has been systematically removed from every research gap by the CPO reframe while none of the demoted gaps have started.

We are failing to close 13 gaps that are simultaneously open in the registry and have commits landed. The OPEN-BUT-LANDED sweep this cycle finds: FLEET-006 (2 commits), RESEARCH-021 (2 commits), EVAL-074 (2 commits), PRODUCT-017 (2 commits), SECURITY-002 (1 commit), REMOVAL-005 (1 commit), INFRA-068 (1 commit), INFRA-070 (5 commits), INFRA-073 type 1 (2 commits), FLEET-015 (1 commit), FRONTIER-009 (1 commit), EVAL-086 (1 commit), RESEARCH-029 (2 commits). INFRA-070 (silent ID collision bug) has **5 commits** referencing it — the most referenced open gap in the registry — with zero resolution. INFRA-073 (gap-closure hygiene audit) was filed explicitly to close OPEN-BUT-LANDED gaps and is itself OPEN-BUT-LANDED within hours of filing. The registry's `status: open` signal is unreliable as a "never started" indicator for nearly half (13 of 27) of all open gaps.

---

### The Complexity Trap

We are failing at the single document whose sole purpose is to prevent coordination confusion. `docs/process/WORK_QUEUE.md` was added on 2026-04-22 as "single source of truth for what to work on next." Four days later it contains: (1) RESEARCH-021 listed as P0 — it was demoted to P1 on 2026-04-24, the same day DOC-008 was filed to fix the document; the P0 label was not corrected; (2) REMOVAL-003 listed as "P2 OPEN" — it closed on 2026-04-25 (PR #465); (3) PRODUCT-009 listed as P1 — demoted to P2 on 2026-04-24 per the CPO reframe; (4) Python 3.12 discipline listed as an "active blocker" under "Blockers & Debt" — this was resolved in the 2026-04-22 addendum to Issue #4, four days before WORK_QUEUE.md was written; (5) INFRA-025 listed as "P2 open" — its current status needs verification; (6) EVAL-042, EVAL-043, COG-031 listed as "pending" under "Pending Research" — all three are `status: done` in gaps.yaml. An agent picking work from WORK_QUEUE.md today will attempt to start on a closed P0 gap, investigate a resolved blocker, and re-run already-completed evals. The document does not track its own last-updated date against the gap registry version. DOC-009 filed.

We are failing to arrest the two-gap split-brain now producing a three-way split-brain. FLEET-007 (done, PR #542) shipped NATS-backed leases. FLEET-006 (P1, open) was the pre-existing gap to bridge ambient stream to NATS. Issue #6 filed FLEET-015 (P1, open) with a description that substantially overlaps FLEET-006. The gap registry now contains two open P1 gaps describing the same ambient-stream-to-NATS migration problem from different angles. Neither has started. An agent claiming FLEET-006 and an agent claiming FLEET-015 can now work concurrently on overlapping scope with distinct gap IDs, both believing their work is non-redundant because they hold different gap claims. The coordination system is generating its own coordination debt. FLEET-016 filed to force deduplication before concurrent claim.

We are failing to arrest doc count growth after closing the doc hygiene plan. DOC-005 (`docs/process/DOC_HYGIENE_PLAN.md`) was marked `status: done` on 2026-04-25. Its purpose was "counter-pressure on doc sprawl." The doc count was 143 at the Issue #6 addendum (2026-04-25). It is **147 today** — 4 new files in one day. DOC-005 closing did not arrest growth; it closed the tracking mechanism for growth. The counter-pressure is gone; the sprawl is not.

---

### The Reality Check

We are failing to score our own eval methodology against the published threat it explicitly filed a gap about. RESEARCH-026 ("observer-effect / evaluation-framing sandbagging check") is `status: open`, `priority: P2`, no start date. The Institute for AI Policy and Strategy (IAPS) published "Evaluation Awareness: Why Frontier AI Models Are Getting Harder to Test" (2026, https://www.iaps.ai/research/evaluation-awareness-why-frontier-ai-models-are-getting-harder-to-test), documenting that frontier models distinguish evaluation from deployment contexts with high reliability and that some models actively reason about how to respond strategically in evaluation conditions. Chump's A/B harness uses Claude Sonnet and Haiku as the agents under test. `docs/process/RESEARCH_INTEGRITY.md` line 93–95 requires mechanism analysis for deltas > ±0.05 — it does not require ruling out evaluation awareness as a mechanism. If the tested models detect the harness pattern and adjust behavior, every A/B result Chump has accumulated — including the validated findings cited in PRODUCT-009 (F1–F6) — could be partially explained by model behavior in evaluation contexts differing from production contexts. RESEARCH-026 was demoted to P2 when the CPO reframe deprioritized research. The IAPS paper makes it a P1 empirical concern, not a theoretical one. EVAL-087 filed to force urgency reframe.

We are failing to catch false-FIXED classifications in our own review process. Issue #6 classified the "Test author identity" finding as FIXED based on an incomplete check: primary git author field only, not the `Co-authored-by` trailer. `git log origin/main --format="%H %s" -29` piped through a body-check grep finds `Co-authored-by: Test <test@test.com>` in all 29 of the last 29 commits reviewed. The AGENT_COORDINATION.md attribution table (§3a) documents three identities: `Chump Dispatched <chump-dispatch@chump.bot>`, `Cold Water <cold-water@chump.bot>`, and human Jeff Adkins. `Test <test@test.com>` appears in zero rows. An unidentified co-author has been present in every observable commit and has been classified as fixed and re-opened within a single review cycle. The review process cannot reliably determine fix status for social/attribution findings. INFRA-076 filed.

We are failing to apply `docs/process/RESEARCH_INTEGRITY.md`'s mechanism-analysis requirement to EVAL-074. Line 93–95 of RESEARCH_INTEGRITY.md: "If a delta is > ±0.05, document a hypothesis for *why* it appears." EVAL-074 is delta = −0.23 on DeepSeek. Three consecutive Cold Water reviews have cited this. Zero mechanism analysis has shipped in three cycles.

---

### The Innovation Lag

We are failing to engage with the published empirical evidence that our eval harness is structurally vulnerable to the models it tests. The Institute for AI Policy and Strategy published "Evaluation Awareness: Why Frontier AI Models Are Getting Harder to Test" (2026, https://www.iaps.ai/research/evaluation-awareness-why-frontier-ai-models-are-getting-harder-to-test), reporting that frontier models can reliably distinguish evaluation contexts from production use and in some cases actively reason about strategic response behavior during evaluation. Chump's A/B harness uses Claude Sonnet-4.5 and Claude Haiku-4.5 as both the agents under test and, in some configurations, as judges. If the models detect the harness context, their behavior during A/B trials differs systematically from their production behavior. The "lesson injection helps haiku-4-5 on reflection tasks" finding (High confidence, RESEARCH_INTEGRITY.md validated table) was produced under conditions that the IAPS paper documents as insufficient to rule out evaluation-context confounding. RESEARCH-026 ("observer-effect / evaluation-framing sandbagging check") was filed and demoted to P2. The IAPS finding makes RESEARCH-026 not a theoretical concern but a documented empirical threat to every result in the validated-findings table. Chump has no response. The strategic memo (FRONTIER-006/JEPA) was already an orphan in Issue #4 and #6; FRONTIER-009 (filed Issue #6) is itself now OPEN-BUT-LANDED.

SKILL0 (arXiv:2604.02268, RESEARCH-029, open) was filed last cycle. RESEARCH-029 itself is already OPEN-BUT-LANDED (2 commits reference it, status: open). The SKILL0 threat — that runtime skill injection is a training-gap workaround — is documented in the registry without any response.

---

**THE ONE BIG THING:** We are failing to maintain a gap registry that can be trusted as the coordination backbone for a multi-agent system. The INFRA-073 × INFRA-073 collision is not an incidental duplicate-ID bug — it is evidence that the guard system has a scope gap that allows same-day concurrent insertions to bypass the duplicate check. The project spent Issues #1–#6 building increasingly elaborate collision prevention: gap-ID hijack guard, duplicate-ID guard, recycled-ID guard, preregistration guard, YAML validity guard, and the INFRA-GAPS-DEDUP test suite. Those guards have now collectively failed to prevent the 8th known collision pair, and the collision involved the gap filed to audit the prior 8 OPEN-BUT-LANDED instances. A registry that cannot prevent its own hygiene-audit gap from being double-assigned cannot serve as the coordination backbone it claims to be. An agent session reading `docs/gaps.yaml` today finds two `id: INFRA-073` entries, 13 OPEN-BUT-LANDED entries where `status: open` does not mean "not started," a WORK_QUEUE.md listing closed gaps as active and listing a resolved blocker as current, and an ambient stream with zero operational signal. The coordination system is coordinating nothing. Gap: INFRA-075 (duplicate-ID guard scope failure audit).

---

### Follow-up Gaps Filed
- INFRA-075: Duplicate-ID guard missed same-day INFRA-073 collision — audit and fix guard scope (P1/s)
- INFRA-076: `Test <test@test.com>` co-author in 29+ commits — document identity or purge from history (P2/s)
- DOC-009: WORK_QUEUE.md stale priority and status data misleads agents on active P0 decisions (P1/xs)
- EVAL-087: Evaluation-awareness literature invalidates A/B trust — reframe RESEARCH-026 to P1 (P1/s)
- FLEET-016: Deduplicate FLEET-006 and FLEET-015 ambient intent before concurrent claim (P2/xs)

---

---

## Issue #6 — 2026-04-26

### Status of Prior Issues

**From Issue #5 (2026-04-24):**

- **FIXED:** INFRA-037 (CI required checks not enforced) — now `status: done`; PRs #458, #459, #461 shipped guidance and corrected the required-check list. Three PRs to fix one admin settings gap is not efficient, but the ledger reflects done.
- **FIXED:** REMOVAL-003 (belief_state crate deletion) — now `status: done`; PR #465 deleted `crates/chump-belief-state/` (666 LOC) and replaced `src/belief_state.rs` with a 170-line inert stub. REMOVAL-005 (P3 open) tracks the remaining ~47 callsite cleanup. Stub correctness is a new concern documented below.
- **FIXED:** "Test" author identity — zero commits from the "Test" identity in the observable window; all 50 recent commits are from `repairman29`. Issue resolved or paused.
- **STILL_OPEN (5 cycles — #2, #3, #4, #5, #6):** Ambient stream empty. `.chump-locks/ambient.jsonl` contains exactly two events (both `session_start` from this Cold Water session). FLEET-007 shipped NATS-backed distributed leases; FLEET-006 (ambient bridge to NATS) is still open. The mandatory pre-flight `tail -30 .chump-locks/ambient.jsonl` returns no operational signal. Zero corrective commits since the issue was first raised.
- **STILL_OPEN (3 cycles — #4, #5, #6):** RESEARCH-021 (tier-dependence replication across 4 model families, P1) — zero commits across three review windows. The PRODUCT-009 blog post is blocked by this gap.
- **STILL_OPEN:** PRODUCT-009 (external publication, P2) — no movement; blocked by RESEARCH-021.
- **STILL_OPEN:** EVAL-074 (DeepSeek -23pp regression root cause, P2) — OPEN-BUT-LANDED (EVAL-083 audit sweep cited it without closing it; no root cause investigation). Regression is now 5+ days old with zero mechanism work.
- **STILL_OPEN:** `docs/process/WORK_QUEUE.md` duplicate RESEARCH-021 — lines 18–19 still list RESEARCH-021 twice as P0. The document filed to reduce coordination confusion still leads with a duplicated entry on its first page.

**NO_GAP filed this cycle (new gaps filed below):** INFRA-073, FLEET-015, FRONTIER-009, EVAL-086, RESEARCH-029.

---

### The Looming Ghost

We are failing to prevent the canonical registry migration from shipping its own collision bug. INFRA-059 (2026-04-25) flipped authority from `docs/gaps.yaml` to `.chump/state.db` — the stated reason was to eliminate concurrent-write races that caused 7 ID collision pairs (Issues #1, #2). INFRA-070 was filed the **same day** documenting that `chump gap reserve` can silently return a duplicate ID when the local `.chump/state.db` is out of sync with the YAML mirror. That gap is P1 open with 2 commits referencing it and zero resolution. The project migrated away from a broken registry system and immediately created a broken replacement: the old system had visible YAML collisions detectable by `grep`; the new system has silent SQLite collisions detectable by nothing at the time of reserve. With 367 total gaps in the registry, a stale DB on any participating machine is a coordination failure waiting to produce a new collision pair. The gap was filed; the fix was not.

We are failing at the "inert stub" promise for `belief_state`. REMOVAL-003 described the transition as replacing the crate with "an inert stub that preserves the public call surface as no-ops, so the diff stayed small." The stub (`src/belief_state.rs`, 170 lines) is not inert in three production code paths: `src/health_server.rs:186` serializes `crate::belief_state::metrics_json()` into the live health endpoint response under the key `"belief_state"`; `src/precision_controller.rs:247` reads `crate::belief_state::task_belief().uncertainty()` to gate precision escalation decisions; `src/checkpoint_db.rs:96–97` stores `ToolBelief` and `TaskBelief` structs from the stub into persistent checkpoint state. If these functions return zero-valued defaults (as a no-op stub would), the precision controller suppresses escalation unconditionally, the health endpoint reports 0.000 task uncertainty regardless of actual task state, and checkpoint restore inflates the stored `ToolBelief` map with stub defaults. REMOVAL-005 (P3) tracks callsite cleanup but does not address the semantic correctness of zero-valued behavior in production decision paths.

---

### The Opportunity Cost

We are failing to start the only gap that unblocks publication. RESEARCH-021 (P1, tier-dependence replication across 4 model families) has received zero commits across the entire observable windows covered by Issues #4, #5, and #6 — a minimum of five days. The core blog-post claim (PRODUCT-009) that lesson-block effects are tier-dependent is currently validated exclusively on Anthropic-family models. Publishing it as a generalizable practitioner result without Llama/Qwen/DeepSeek/Gemma replication is methodologically prohibited under `docs/process/RESEARCH_INTEGRITY.md`. Three consecutive Cold Water reviews have documented this stall. The gap is P1. The project is producing dozens of INFRA commits per week and zero research commits on its P1 prerequisite for first publication. This is not a deprioritization decision that was documented anywhere — it is a gap the registry says is open and no agent has touched.

We are failing to verify the only P0 gap before building on top of it. PRODUCT-017 (P0, OPEN-BUT-LANDED) requires a clean-machine stopwatch run committed to `docs/FTUE-VERIFICATION-YYYY-MM-DD.md`. PR #535 added a CI workflow running on ephemeral `macos-latest` — a synthetic environment, not a "clean Mac (fresh VM or wiped machine)" as the acceptance criteria specify — and did not commit a verification artifact. `docs/process/FTUE_USER_PROFILE.md` exists but is not the acceptance criterion document. The verification has not happened. PRODUCT-015 (activation funnel telemetry) shipped on main and is emitting `activation_install`, `activation_first_task`, and `activation_d2_return` events via `src/activation.rs:171–194`. If the FTUE path (`brew install chump → PWA < 60s`) is broken, PRODUCT-015's funnel metrics are measuring abandonment rates on a broken path and reporting them as product signal. No alert exists for "zero d2_return events in 14 days." The project built the meter before verifying what it's metering works.

We are failing to investigate the most externally credible finding in the portfolio. EVAL-074 (P2, DeepSeek -23pp lesson-injection regression root cause) has been OPEN-BUT-LANDED for 5+ days. The EVAL-083 credibility audit swept methodology compliance across completed evals but did not apply the `RESEARCH_INTEGRITY.md` mechanism-analysis requirement (line 93–95: required for any delta > ±0.05) to EVAL-074's delta = −0.23. The audit that was supposed to enforce methodology standards exempted the unresolved finding with the largest delta.

---

### The Complexity Trap

We are failing to close gaps we have already shipped. The OPEN-BUT-LANDED sweep this cycle finds 8 gaps with commits on main referencing their IDs while remaining `status: open`: FLEET-006 (1 commit), EVAL-074 (1 commit), PRODUCT-017 (1 commit), SECURITY-002 (1 commit), REMOVAL-005 (1 commit), DOC-005 (4 commits), INFRA-068 (1 commit), INFRA-070 (2 commits). This pattern was documented in Issues #2, #4, and #5 without correction. There are 23 open gaps; 8 of them have had commits land. An agent reading the registry today cannot distinguish "never started" from "partially executed without closure." The gap registry's `status: open` signal is now a mixture of two distinct states. Every session that starts by reading the open gap list reads corrupted intent.

We are failing to complete the fleet architecture migration before claiming it works. FLEET-007 (NATS-backed distributed leases, `status: done`) shipped in PR #542 and created a crate `crates/chump-agent-lease/`. FLEET-006 (bridging `.chump-locks/ambient.jsonl` to NATS topics) is P1 open. The result is a split-brain fleet: lease coordination is now NATS-backed and machine-agnostic; ambient perception remains filesystem-local. Any agent running on a second machine has correct lease mutual exclusion but empty ambient perception. The CLAUDE.md mandatory pre-flight (`tail -30 .chump-locks/ambient.jsonl`) returns nothing on machine B. The agent does not know it is blind — it sees two `session_start` events from the local file and proceeds. The half-migration makes the fleet appear coordination-aware when it is ambient-blind on every non-primary machine.

We are failing to arrest documentation growth while running a document hygiene effort. DOC-005 (P2, open) has 4 commits against it (DOC-006 inventory script, DOC-007 Phase 0 classification). The plan won't close until automation is built. Current doc count: 147 files — up from 143 at the 2026-04-25 addendum, an accretion of 4 files in one day. The hygiene effort is consuming agent cycles while the surface it aims to reduce grows faster than the effort's output rate.

---

### The Reality Check

We are failing at measurement infrastructure for the measurement infrastructure. 22 of 23 open gaps have no `opened_date` field. The gap registry cannot answer "how long has this been open?" for 96% of open work. Only INFRA-070 has a date (2026-04-25, 1 day old). RESEARCH-021, EVAL-074, FLEET-006, PRODUCT-009, and PRODUCT-017 — the most consequential open items — all have `opened_date: None`. The coordination system's cycle-time, aging alerts, and stall detection are computationally impossible from registry data alone. Cold Water's own "STILL_OPEN (3 cycles)" findings require manual cross-referencing across issue text rather than a database query. A system that coordinates dozens of concurrent agents cannot measure its own throughput.

We are failing to apply our own methodology standards to the audit that enforced methodology standards. EVAL-083 (PR #525, "eval credibility audit sweep") reviewed completed evals for methodology compliance and correctly retired EVAL-063 (EVAL-084) and verified EVAL-064 (EVAL-085). But EVAL-074 — the single open eval gap — was cited without any methodology scoring. `docs/process/RESEARCH_INTEGRITY.md` line 93–95 requires mechanism analysis for any delta > ±0.05. EVAL-074 is delta = −0.23 on DeepSeek. The audit that was justified as a methodology enforcement sweep did not enforce the most important methodology requirement on the most important unresolved finding. A credibility audit that exempts the highest-delta open result from credibility review is not a credibility audit.

We are failing to track the strategic competition we documented. `docs/strategy/STRATEGIC_MEMO_2026Q2.md` (FRONTIER-006, `status: done`) contains a section 3 ("Implications for Chump") with five architectural recommendations: JEPA-inspired world model integration, explicit planning loop, multi-modal groundedness, physical planning benchmark, V-JEPA as perception backbone alternative. FRONTIER-006 closed the "watchpoint" task. None of the five recommendations have follow-up gaps in the registry. The memo is orphaned research — a 2,000-word strategic analysis that produced zero actionable commitments. This is structurally identical to the "STRATEGIC_MEMO_2026Q2.md is an orphan" finding in Issue #4, which named it as a complexity trap. The orphan is still orphaned.

---

### The Innovation Lag

We are failing to position against the inference-time learning paradigm that directly challenges our thesis. SKILL0 ("In-Context Agentic Reinforcement Learning for Skill Internalization," April 2026, https://huggingface.co/papers/2604.02268) ships a framework that teaches agents skills through a training-time curriculum that progressively withdraws skill context at inference time. The core claim: runtime skill injection is a workaround for training-time internalization, and the workaround can be systematically removed once training is complete. This is a direct challenge to Chump's production position. If the haiku-tier improvement Chump observes from lesson injection is an internalization effect — the model is being primed with skills it could generalize without them if trained properly — then Chump's runtime injection architecture is a bridge to a destination that SKILL0 reaches directly, with no per-session overhead. Chump has no filed position on this hypothesis. FRONTIER-006 closed the JEPA threat assessment. The SKILL0 threat — that inference-time instruction injection is a training-gap workaround, not a permanent architectural contribution — has no equivalent watchpoint gap. `docs/strategy/STRATEGIC_MEMO_2026Q2.md` does not mention it. The project's strategic intelligence apparatus produced a 2,000-word JEPA analysis and is silent on the April 2026 paper most directly relevant to its core research bet.

The `docs/strategy/STRATEGIC_MEMO_2026Q2.md` is itself an orphan for the second consecutive cycle. No follow-up gaps were filed despite the Cold Water Issue #4 finding. RESEARCH-029 is filed this cycle to force a position.

---

**THE ONE BIG THING:** We are failing at the most basic product integrity guarantee while shipping product metrics. PRODUCT-017 (P0, OPEN-BUT-LANDED) is the only P0 gap. Its acceptance criteria are structurally unmet: PR #535 added a CI workflow on ephemeral `macos-latest` — which is not a "clean Mac (fresh VM or wiped machine)" — and committed no verification artifact to `docs/FTUE-VERIFICATION-YYYY-MM-DD.md`. PRODUCT-015 (activation funnel telemetry, `src/activation.rs`) is live on main and emitting install, first-task, and D2-return metrics. Three additional PRODUCT gaps landed this cycle (PRODUCT-015, PRODUCT-016, PRODUCT-017 CI workflow). Every one of them builds on the assumption that `brew install chump → PWA in < 60s` works today. If it does not, the activation funnel metrics are measuring user abandonment on a broken path and reporting it as product traction. This is not a hypothesis — it is what happens when you instrument a funnel before verifying the funnel works. The acceptance criterion is simple: run the stopwatch on a fresh machine and commit the result. That has not happened. Until it does, every product metric the project ships is an assumption dressed as measurement. Gap: PRODUCT-017.

---

### Follow-up Gaps Filed
- INFRA-073: Gap-closure hygiene audit — 8 OPEN-BUT-LANDED gaps (P1/xs)
- FLEET-015: Complete ambient-stream NATS migration — fleet split-brain remediation (P1/m)
- FRONTIER-009: JEPA strategic memo section 3 implications — file orphaned recommendations (P3/s)
- EVAL-086: opened_date backfill for 22 open gaps + enforce non-null on future reservations (P2/xs)
- RESEARCH-029: SKILL0 competitive positioning — inference-time injection vs training-time internalization (P2/s)

---

## 2026-04-25 — addendum to recurring "unwraps" and "doc sprawl" framing

Two figures cited across Issues #1, #2, and #3 (946 → 989 → 1,065 `unwrap()` calls; 66 → 119 → 139 → 143 docs files) have been re-measured and reframed. The historical text below stands as written; this addendum documents what the audit found so future Cold Water passes don't re-cite stale framing.

**Unwraps.** Production unwrap count in `src/*.rs` is **0** when `#[cfg(test)]` boundaries are honored (audit 2026-04-25). The 914 remaining are all in test modules, which is idiomatic Rust — converting them adds noise without safety value. QUALITY-001/002/003 (all `done`) closed the production risk. The raw grep figure cited in prior issues counted test-code idioms as panics; the figure is mathematically larger than reality on a project that ships test coverage. Future Cold Water passes should cite a prod-only count or omit this bullet.

**Doc sprawl.** 143 top-level `docs/*.md` is real, but the obvious archival candidates (CHUMP_CURSOR_PROTOCOL.md redirect, CURSOR_CLI_INTEGRATION.md redirect, ADR-002 empty stub, MARKET_RESEARCH_EVIDENCE_LOG.md template) all have inbound references from ROADMAP.md, README.md, RED_LETTER.md, source code, and scripts. Naive deletion breaks the published mdBook. DOC-002 (2026-04-20) shipped a one-shot consolidation that worked but did not leave behind a system to prevent re-accretion. DOC-005 (`docs/process/DOC_HYGIENE_PLAN.md`, this PR) files the multi-phase plan: classify (front-matter doc_tag) → inventory (CSV, drift detection) → automate (pre-commit + CI link integrity + gardener subcommand) → stage cleanup → generate (ROADMAP/eval-index from `state.db`). The DOC-002 critique in Issue #4 ("six PRs, net change ≈ −2 files") is what motivated the system rather than a rerun of the one-shot.

---

## Issue #5 — 2026-04-24

### The Looming Ghost

We are failing to guard the merge queue's safety assumption. INFRA-037 (P1, effort xs, open since 2026-04-22) documents that branch protection does not enforce required CI checks. The evidence is in the commit log: PR #451 (tokio-tungstenite 0.24→0.28) and PR #453 (wasmtime-wasi 20→44) both landed on main this week with FAILING `test`, `check`, `dry-run (chump)`, and `ACP protocol smoke test` jobs. PR #453 broke `cargo check --bin chump` for approximately 12 hours until PR #455 reverted it. The auto-merge queue (INFRA-MERGE-QUEUE) is the project's stated correctness guarantee for multi-agent parallel work — its entire premise is that CI must pass before a squash merge occurs. With required checks unenforced in GitHub branch protection, the queue is coordination theater: it coordinates ordering, not correctness. The fix is a GitHub admin settings change — three button clicks, not a pull request, not a code change. INFRA-037 has been open for two days while 63 commits landed on main and one caused an emergency revert.

We are failing to remove a module the team's own eval condemned. REMOVAL-003 (P2, open): the `chump-belief-state` crate. The REMOVAL-001 decision matrix returned verdict REMOVE on 2026-04-21. Evidence: delta=+0.020 in EVAL-063 (n=50/cell, LLM judge, Llama-70B) — no positive signal at any sample size. The crate ships in every user binary. Three days since the verdict, 21 in-tree callers across `src/tool_middleware.rs`, `src/surprise_tracker.rs`, `src/autonomy_loop.rs`, `src/speculative_execution.rs`, `src/checkpoint_db.rs`, and `src/health_server.rs` are still wired to it. Removal is classified effort L because belief_state is load-bearing for checkpoint/restore and health telemetry — which means the complexity tax of retaining dead code has now compounded into a multi-day removal cost. Every day of non-removal makes the eventual removal harder. This is the definition of accumulating technical debt against a known, documented verdict.

### The Opportunity Cost

We are failing to move the one gap that unblocks publication. RESEARCH-021 (P0, effort M, open) — tier-dependence replication across 4 model families — has received zero commits in the entire observable window. The core finding of the pending blog post (PRODUCT-009, P1) is that lessons-block effects are tier-dependent. That finding is currently measured exclusively on Anthropic-family models: haiku-4-5 vs sonnet-4-5, same training lineage, size difference only. Publishing this as a generalizable practitioner result without Llama/Qwen/DeepSeek/Gemma replication means the headline claim may be Anthropic-family-specific. RESEARCH-021 is the methodological prerequisite for PRODUCT-009 to ship responsibly. PRODUCT-009 cannot be published until RESEARCH-021 closes. RESEARCH-021 has not started. The blog post is trapped behind a P0 gap that no agent has touched in four days.

We are failing to investigate a -23pp regression on a model practitioners use. EVAL-074 (P2, open) — DeepSeek lesson-injection correctness regression root cause — was filed against EVAL-071's finding: DeepSeek-V3.1 loses -23pp task correctness when the COG-016 lessons block is injected. Spot-check of failure rows shows correctness drops before hallucination. This is not a null result; it is a directional harm signal on a model family with broad practitioner adoption. EVAL-074 is unstarted. A -23pp regression on a non-Anthropic model would be the most externally credible finding in the project's portfolio — exactly the cross-architecture generalization signal RESEARCH-021 is looking for. We are not investigating it.

### The Complexity Trap

We are failing at self-consistent documentation on the day of first publication. `docs/process/WORK_QUEUE.md` was added this week (commit b144849) as the "single source of truth for what to work on next." Its very first P0 entry — RESEARCH-021 — appears twice in the same block. The document claims to resolve coordination confusion by consolidating the work queue. It produces confusion on line one. Additionally, its "Blockers & Debt" section lists "Issue #4 — Python 3.12 discipline not enforced" as an active blocker, citing `docs/audits/RED_LETTER.md`. But Issue #4's own 2026-04-22 addendum explicitly states: "`scripts/ab-harness/*.{py,sh}` now consistently invokes `python3.12`" and closes that concern. WORK_QUEUE.md — the document added to give agents reliable coordination signal — pre-cites a resolved blocker as active and duplicates its top priority. Agents reading it today will re-investigate a resolved foot-gun and attempt to pick P0 work that is listed twice without disambiguation.

We are failing to stop citing ambient stream failure and start fixing it. The `.chump-locks/ambient.jsonl` tail returned two events in the current observable window — both `session_start`, zero `file_edit`, zero `commit`, zero `bash_call`, zero ALERT events. This is the same finding reported in Issue #2, Issue #3, and Issue #4. Four consecutive Cold Water reviews have documented that FLEET-004b/c/d (passive emission via git post-commit hook, PostToolUse hooks, fswatch daemon) are `status: done` in the gap registry and produce no operational signal. Documentation of the failure is now a recurring ritual. The failure itself is undisturbed. No gap is open to debug or re-implement the emission pipeline. The CLAUDE.md mandatory pre-flight still instructs every agent session to run `tail -30 .chump-locks/ambient.jsonl` and interpret the output. Four review cycles of empty output is the correct interpretation: the peripheral vision system is instrumented but not functioning, and no one has filed a gap to fix it.

### The Reality Check

We are failing to account for 33% of this week's commits. Git log shows 63 commits this week: 34 from `repairman29`, 21 from `Test`, 8 from `dependabot[bot]`. The "Test" identity does not appear in the three-author taxonomy in `docs/process/AGENT_COORDINATION.md` (which documents: `Chump Dispatched <chump-dispatch@chump.bot>`, `Cold Water <cold-water@chump.bot>`, and human Jeff Adkins). Red Letter #1 flagged `Your Name <you@example.com>` as an unidentified actor with 13 commits — including the committed API key. The "Test" identity is the third unidentified committer this project has produced. 21 commits (33% of the week) originate from an identity outside the documented coordination taxonomy, with no gap IDs in commit messages, operating entirely outside the lease system. The AGENT_COORDINATION.md author-attribution table was added specifically to distinguish dispatched-agent work from human and external contributions. It is not covering actual commit traffic.

We are failing to produce a single dispatch-backend commit. "Chump Dispatched" — the canonical identity for orchestrator-dispatched subagents — appears zero times in this week's author log. Issue #3's "FIRST CONFIRMED autonomy test" and "PROVEN autonomy V4" commits have not translated into dispatched commits on main. The dispatch backend (COG-025 / `CHUMP_DISPATCH_BACKEND`) exists in `CLAUDE.md`, in `dispatch.rs`, and in the coordination documentation. Its commit fingerprint is absent. Either the dispatch system is not operational at the volume the documentation implies, or it is operational but producing work that is attributed to human-identity commits instead. Either way, the multi-agent platform claim and the commit record are inconsistent.

**THE ONE BIG THING:** We are failing at the most basic correctness guarantee the project makes. INFRA-037 (P1, effort xs) is not a research gap or a capability gap — it is a missing GitHub admin checkbox. The required-checks list in branch protection is incomplete or empty, which means the auto-merge queue (the coordination system's safety anchor) does not actually require CI to pass before merging to main. This was demonstrated in production this week: PR #453 (wasmtime-wasi 20→44) merged with four failing required checks and broke `cargo check --bin chump` on main for ~12 hours. PR #455 had to revert it. The project has built an elaborate multi-agent coordination system — leases, ambient stream, gap registry, pre-commit hooks, merge queue — all of which assume the merge gate is real. The merge gate is not real. An admin must open `https://github.com/repairman29/chump/settings/branches`, find the main branch protection rule, and add `test`, `check`, `dry-run (chump)`, and `ACP protocol smoke test` to the required status checks list. Until that happens, the merge queue is a scheduling system with no correctness enforcement, and any dependabot bump or agent commit can break main and require a revert.

**2026-04-24 re-check — what changed, what did not:**

Three follow-up PRs landed in response to INFRA-037 since this issue was written: PR #458 (INFRA-037 itself — "tighten dependabot auto-merge to patch-only; document admin remediation"), PR #459 (INFRA-038 — "group dependabot bumps + restore minor auto-merge"), PR #461 (INFRA-040 — "correct INFRA-037 required-check list"). Critical finding from INFRA-040: the original INFRA-037 guidance in PR #458 was factually wrong — it told the admin to add `check` and `dry-run (chump)` to required checks, but those are path-gated workflows that only run on Cargo.toml/Cargo.lock changes and would never fire on docs-only PRs. INFRA-040 corrects the list. **Three PRs in, INFRA-037 is still `status: open` and the actual GitHub admin settings change has not been confirmed as executed.** The project filed a gap to fix the gap, then filed a correction to the fix gap's guidance, and the underlying admin action remains undone.

REMOVAL-003: PR #460 (INFRA-039) shipped a design proposal — 47-callsite audit, backward-compat constraint analysis for `AutonomySnapshot` serde, proposed codemod approach. This is progress; the actual crate deletion has not started.

**Open gap count went from 15 to 17** — INFRA-039 and INFRA-040 were both filed and shipped but left `status: open`, a repeat of the shipped-but-not-closed pattern documented in prior issues.

RESEARCH-021 (P0), EVAL-074, PRODUCT-014: zero commits. Unchanged.

WORK_QUEUE.md duplicate RESEARCH-021 entry: still present on origin/main. Not corrected.

Ambient stream: 5 events now (was 2) — the 3 new events are this Cold Water session's own `session_start` markers and one `file_edit` from the Issue #5 write. Zero operational events from any other agent activity. The underlying emission failure is unchanged.

"Test" author: 21 commits, taxonomy gap uncorrected.

---

## Issue #4 — 2026-04-21

### The Looming Ghost

We are failing to fix a known instrument foot-gun while continuing to produce results from that instrument. `docs/process/RESEARCH_INTEGRITY.md` explicitly warns: "`python3` resolves to 3.14 on this machine, which has no `anthropic` module. Using it silently produces `scorer=exit_code_fallback` in every JSONL row — no real LLM-judge scores, no error message." Every one of the 31 Python harness scripts in `scripts/ab-harness/` still carries a `#!/usr/bin/env python3` shebang. None were updated to `python3.12`. EVAL-069 — which this week retired the entire neuromod aggregate signal (−10 to −16 pp) as a "methodology artifact" — was run under this harness. Its commit also contains a fix commit: "correct provider label — Ollama qwen2.5:14b, not Together" — meaning the agent discovered a data-provenance error *after running the sweep*. The EVAL-069 result shows acc_A=0.920 CI[0.812,0.968] vs acc_B=0.920 CI[0.812,0.968], delta=+0.000 — identical point estimates and identical confidence intervals in both cells. Wilson 95% CI [0.812,0.968] corresponds exactly to 46/50 successes. If the exit-code scorer awarded the same pass/fail on every trial in both cells, those CIs would be identical. The retirement of F3's aggregate signal is built on a run that has two documented credibility problems and has not been replicated.

We are failing to close INFRA-006 while shipping cosmetic mitigations. PR #334 ("fix(INFRA-016): harness timeout hardening — Chump-side mitigation for INFRA-006 vllm-mlx Metal crash") is open and unmerged. Its title says "mitigation." The acceptance criteria in INFRA-006 require: "Client disconnect during inference does not crash the vllm-mlx server process." A timeout increase does not meet that criterion. INFRA-006 remains P1 open with no assigned agent, no branch, and the actual fix described in its `description` field ("catch disconnect in the inference loop before committing the command buffer, or drain/abort the Metal pipeline before returning the disconnect response") untouched in any commit. The workaround in the notes field ("use --timeout 300+ for all sweeps") has been propagated into documentation instead of code, making the bug invisible to future operators.

We are failing to enforce gap-closure integrity. PRODUCT-009 ("External publication of F1-F6 empirical findings") was closed `status: done` on 2026-04-20 with `closed_pr: TBD`. The acceptance criteria are explicit: "(1) venue selected, (2) draft reviewed by one external reader, (3) publication goes live with a URL in docs/audits/FINDINGS.md 'How to cite' section, (4) replication-invitation text updated." `docs/strategy/PRODUCT-009-blog-draft.md:4` still reads "Status: Draft — pending external review before publication." The 'How to cite' section in FINDINGS.md contains no URL. The blog post is not live. PRODUCT-009 was closed with zero acceptance criteria met — not partially met — and the gap's own `closed_pr` field acknowledges it by reading `TBD` rather than a PR number. A gap marked `done` with `closed_pr: TBD` and zero criteria satisfied means the gap registry's `status: done` signal cannot be trusted as a claims-proven marker for any gap without independent verification.

### The Opportunity Cost

We are failing to replicate F6, the most publishable finding in the project. Finding F6 — "Few-shot exemplar + explicit ship rule unlocks instruct-tuned OSS models for agent loops" — is listed in FINDINGS.md with status "n=1 production claim; replication trial held pending methodology track clearance." That clearance has no completion criteria, no assigned gap, and no timeline. Qwen3-Coder-480B shipped one PR (PR #224, 737 LOC). Nine total trial variations were run (V1–V9) across four model classes to arrive at that one success. The technique is the most concrete, operator-actionable result the project has produced and the most viable hook for external publication. It has been sitting unreplicated since it was filed. Meanwhile PRODUCT-009 closed as done with this finding cited but not validated beyond n=1. The project is attempting to publish a result it has not verified will reproduce.

We are failing to start EVAL-065. Social Cognition graduation (n≥200/cell strict-judge sweep, EVAL-065, P2 open) has consumed three prior gaps — EVAL-050, EVAL-055, EVAL-057 — without resolution. The faculty map says "definitive verdict requires n≥200/cell." That sweep costs roughly $5 and takes one afternoon. It has been filed and unstarted for the entire observable window while 11 other eval gaps closed this week around it. EVAL-065 is the single remaining eval gap needed to either graduate Social Cognition (#10, the last unresolved faculty) or file a removal gap. Neither outcome has been pursued. The faculty map's PRELIMINARY label persists because no agent picked up a $5 sweep.

We are failing to act on EVAL-071. F2 — lessons-block fake-tool-call inflation — is the headline finding in the pending blog post and is measured on two Anthropic frontier models only. EVAL-071 (extend F2 to non-Anthropic frontier, P2 open) is unstarted. Publishing F2 as a generalized finding while EVAL-071 is open means the headline result in the publication may be Anthropic-family-specific. The blog post cannot responsibly be called a "practitioner" artifact if the central claim has not been tested on the provider combination practitioners actually use.

### The Complexity Trap

We are failing to recognize that the doc consolidation (DOC-002) consumed six PRs (#312, #320, #322, #323, #324, #325) and produced a net change of approximately −2 files. `docs/` had 119 files before the consolidation started; it has 121 now (including 7 in `docs/howto/` and 4 in `docs/archive/`). Six PRs of work spanning two days produced a two-file reduction. The consolidation's own pre-commit hook (`INFRA-009`) warns on net-new docs additions but does not enforce net reduction. A consolidation gap that cannot reduce the count it was filed to reduce is a complexity trap: it consumed capacity, generated merge risk, and left the surface area larger.

We are failing to notice that STRATEGIC_MEMO_2026Q2.md is an orphan. `docs/strategy/STRATEGIC_MEMO_2026Q2.md` is a 2,000+ word analysis of AMI Labs and JEPA written by an agent during a strategic review cycle. It has no gap ID in the registry, no action items that connect to any open gap, no downstream consumer. The memo references FRONTIER-006 but that gap ID does not appear in `docs/gaps.yaml`. The project's agents are now capable of producing detailed competitive-intelligence documents that land in the docs directory, pass the docs-delta pre-commit hook (advisory-only), and persist indefinitely without being tied to any work. The INFRA-009 guard warns but does not block. The memo is dead weight that looks like research.

We are failing to gate autonomy expansion on demonstrated ambient fidelity. PR #326 added an "Autonomy section" to AGENT_LOOP.md — the document that instructs every spawned agent on what they are permitted to do without human direction. The commit was submitted with a lease bypass ("Lease bypass acknowledged because gaps.yaml + AGENT_LOOP.md are in contention with sibling agents shipping in parallel"). The document that governs coordination behavior was modified by bypassing the coordination hook. Simultaneously, `.chump-locks/ambient.jsonl` contains exactly two events over the entire observable window — both `session_start` — despite INFRA-007 being closed as `done` on 2026-04-20. Autonomous agent capacity was expanded before the observability layer that would make autonomous failures detectable was verified as working end-to-end.

### The Reality Check

We are failing to ship product code. Zero commits in the last 7 days touched a Rust source file in a production code path. The 25 commits that landed were: doc consolidation (6 PRs), eval methodology reframing (4 PRs), gap filing (2 PRs), infrastructure harness (2 PRs), blog draft (1 PR), autonomy doc expansion (1 PR), and duplicate-ID guard tests (1 PR). The project's own North Star — "local-first, air-gapped capable, designed to run forever and grind" — requires binary reliability, provider fallback, and the 72h soak gate. INFRA-008 (4h soak precursor) is open and unstarted. Binary stability has not measurably improved this week; it has been documented more carefully without being fixed.

We are failing to distinguish "retired" from "proven absent." EVAL-069 retired the F3 aggregate neuromod signal (−10 to −16 pp) by showing delta=0 in two re-runs under the EVAL-060 instrument. The conclusion in the commit and in FINDINGS.md is that the original signal was a "methodology artifact." But the two re-runs used a harness with a documented foot-gun (python3 vs python3.12), one had an acknowledged provider-label error, and neither was run against the original four-architecture lineup from EVAL-026. A delta=0 result on a different model, under a potentially misconfigured scorer, does not prove the original signal was noise — it proves the new harness cannot detect it. The distinction matters because F3's task-cluster localization (conditional-chain + monosyllabic tasks) was retained as valid even as the aggregate was retired. If the instrument is too noisy to detect the aggregate, it may also be too noisy to distinguish task clusters, and F3 as published is now a one-legged finding.

We are failing at velocity coherence. The `docs/research/RESEARCH_PLAN_2026Q3.md` names the Q3 goals. Cross-checking against this week's output: (a) Social Cognition graduation — zero progress, (b) EVAL-043 full cognitive-architecture ablation — still unstarted (prohibited by RESEARCH_INTEGRITY.md until several prerequisite gaps close), (c) PRODUCT-009 publication — closed without publishing, (d) 72h soak gate — prerequisite (INFRA-008) unstarted. Q3 has four named deliverables. After one week of 25 commits and 15 closed gaps, the score against Q3 goals is 0/4.

**THE ONE BIG THING:** We are failing to recognize that EVAL-069's retirement of the neuromod aggregate signal is built on a methodologically suspect run. The harness foot-gun (`python3` = 3.14, no `anthropic` module, silent `scorer=exit_code_fallback`) documented in `docs/process/RESEARCH_INTEGRITY.md` was never fixed in any of the 31 harness scripts — confirmed by the `#!/usr/bin/env python3` shebangs in `scripts/ab-harness/run-binary-ablation.py:1` and `scripts/ab-harness/run-spawn-lessons-ab.py:1`. EVAL-069's result (acc_A=0.920 CI[0.812,0.968] = acc_B=0.920 CI[0.812,0.968], delta=0.000) shows identical confidence intervals in both cells — the fingerprint of a scorer awarding the same result to every trial regardless of agent behavior. The same commit acknowledged a wrong provider label. This result was used to retire F3's aggregate signal in FINDINGS.md and EVAL-026 is now attributed to "methodology artifact." The project's empirical record is being revised using an instrument the project's own integrity doc says cannot be trusted. Before EVAL-069's conclusion propagates into the blog post (PRODUCT-009, which cites F3), the project must either (a) fix `scripts/ab-harness/run-binary-ablation.py` to use `python3.12`, verify the judge is actually calling the LLM, and re-run EVAL-069 against the original four-architecture lineup, or (b) explicitly label F3 as "aggregate signal origin unknown, task-cluster finding stands" and remove the "methodology artifact" conclusion that implies the prior data was wrong.

**2026-04-22 — registry / queue hygiene (machinery, not praise):** `docs/gaps.yaml` `meta.current_priorities` was rebuilt from **live** `status: open` rows — it previously listed INFRA-007, EVAL-066, QUALITY-002, EVAL-068, EVAL-064, EVAL-067, INFRA-008, and INFRA-009 under p0–p2 even though those IDs are already **`done` in the ledger**, which invited agents to "pick up" closed work. `PRODUCT-009` is **`status: open` again** because acceptance criteria were not met (`closed_pr: TBD`, no publication URL in `docs/audits/FINDINGS.md`). **Ledger corrections to stale prose earlier in this issue:** `INFRA-006` and `INFRA-008` are `status: done` in `docs/gaps.yaml` as of 2026-04-21 — sentences in § Opportunity Cost / § Reality Check that still describe them as `open` or "unstarted" are outdated even if the underlying engineering risks (vLLM-mlx disconnect hardening, soak discipline) still deserve hardware spot-checks.

**2026-04-22 — harness interpreter hygiene:** `scripts/ab-harness/*.{py,sh}` now consistently invokes **`python3.12`** (shebangs + shell helpers + docstring examples) so the foot-gun called out in § The Looming Ghost paragraph 1 is harder to reproduce by accident. Still verify `import anthropic` on the machine before spending cloud budget.

---

## Issue #3 — 2026-04-19

## Issue #3 — 2026-04-20

### The Looming Ghost

We are failing at ablation methodology. The binary-mode ablation harness (`scripts/ab-harness/run-binary-ablation.py`, EVAL-049) scores each trial as "correct" if the chump binary exits with code 0 AND produces output longer than 10 characters. This produces baseline accuracy values of 0.033 (Cell A, EVAL-056 Memory) and 0.100 (Cell A, EVAL-058 Executive Function) — below chance on any meaningful task classification. The noise floor is so high that no module can produce a measurable delta at n=30/cell: CIs run ±0.14 at accuracy=0.1, spanning the entire decision space. The result is three COVERED+VALIDATED(NULL) labels in `docs/architecture/CHUMP_FACULTY_MAP.md` this week (Memory EVAL-056, Executive Function EVAL-058, Metacognition EVAL-053) for faculties whose ablation simply cannot be resolved with this instrument. VALIDATED(NULL) is not a research result. It is a measurement failure rebranded as a conclusion. `docs/EVAL-049-binary-ablation.md` admits the binary was not available when EVAL-049 shipped ("full build requires an OPENAI_API_BASE endpoint — harness `--dry-run` confirms commands are correctly formed without binary or API keys"). The next three gaps (EVAL-053, EVAL-054, EVAL-056) ran the live sweep against that same harness. The methodology chain is dry-run → live sweep → VALIDATED. The dry-run step was never removed from the validation pathway.

We are failing at basic reliability trajectory. `src/` now contains 1,065 `unwrap()` calls — up from 989 in Issue #2, when QUALITY-001 ("unwrap() audit") was already marked `status: done`. Every eval gap shipped this week added Rust source. The audit that was declared done is being actively outrun by new code. The gap closure said "audited." Audited means counted, not fixed. The production binary panics on an additional 76 unconditional failure paths compared to last week.

### The Opportunity Cost

We are failing to run the experiment the research plan actually requires. `docs/research/RESEARCH_PLAN_2026Q3.md` specifies that Metacognition graduation requires a chump-binary sweep at n≥100 with LLM judging. `docs/process/RESEARCH_INTEGRITY.md` requires minimum n=50 for directional signal, at least one non-Anthropic judge, and a human ground truth set for hallucination outcomes. EVAL-053 ran at n=30 per cell with a binary exit-code scorer, no LLM judge, no cross-family validation, and no A/A baseline. The Metacognition faculty carries the only documented net-negative prior signal in the project — EVAL-026 showing -0.10 to -0.16 mean delta across four model architectures. EVAL-048 was opened specifically to confirm or rebut that finding. EVAL-053 produced CIs so wide they can neither confirm nor rebut. Metacognition is now labeled COVERED+VALIDATED(NULL) on evidence that RESEARCH_INTEGRITY.md would prohibit citing in any external communication.

We are failing to graduate Social Cognition despite three dedicated gaps. EVAL-050 (pilot n=10/cell), EVAL-055 (full sweep n=50/cell), and EVAL-057 (LLM-judge sweep n=50/cell) all concluded PRELIMINARY. The two root causes identified — ceiling compression at n=50 and judge liberality — require a stricter rubric or n≥200/cell per the faculty map's own text. No gap is open for either fix. Three gap-slots and their associated PR overhead were spent without addressing the stated blocking issue. The faculty is back where it started: PRELIMINARY.

### The Complexity Trap

We are failing to see what the VALIDATED(NULL) pattern actually reveals. The cognitive architecture shipped in production on every user session includes: surprisal EMA (`src/surprise_tracker.rs`), belief state (`crates/chump-belief-state/`), neuromodulation (`src/neuromodulation.rs`), blackboard (`src/blackboard.rs`), and spawn-time lesson loading (`src/reflection_db.rs::load_spawn_lessons`). This week's sweeps show that bypassing Memory, Executive Function, and Metacognition modules produces no measurable change in task outcomes. The faculty map labels these NULL — but the honest reading is: these modules run in production, consume CPU and memory, inject content into every prompt assembly, and produce no detectable effect on output quality at n=30. The correct decision criterion from `docs/eval/EVAL-048-ablation-results.md` is explicit: "Module delta within ±0.05 (CIs overlap) → NEUTRAL — document 'no detectable signal', candidate for removal to simplify codebase." Not one of the three NULL-validated modules has a removal gap filed. They are being retained with the label VALIDATED as if the null result is a positive finding.

We are also failing to stop the documentation mass accumulation. `docs/` has grown to 139 files — up from 119 in Issue #2, 66 in Issue #1. That is 73 net new docs files added in two days on the same calendar date. No deletion or archival is visible in any commit this week. The documentation surface is growing at approximately 37 files per review cycle. A codebase with 139 docs files and a single open gap is inverted: the knowledge-management overhead now exceeds the work it is supposed to coordinate.

### The Reality Check

We are failing to distinguish "shipped the sweep" from "ran the experiment." Six eval gaps closed this week (EVAL-053 through EVAL-058 plus gap hygiene in PRs #263, #270, #271). All six produced binary-mode sweep results. None of the six sweeps satisfy the four methodology requirements in `docs/process/RESEARCH_INTEGRITY.md`: none used n≥50 for directional signal, none included a non-Anthropic judge, none validated the scoring heuristic against human ground truth, none ran an A/A baseline to confirm the instrument's noise floor. They are filed as `status: done` against a research-integrity standard they do not meet.

We are failing to ship product. The 25 commits this week were: EVAL ablation sweeps (EVAL-053 through EVAL-058), gap hygiene (PRs #263, #270), and gaps.yaml updates. Zero commits touched the PWA (`web/`), the first-run onboarding flow (`PRODUCT-004`), local model support (`REL-001`/`REL-002`), or the brew installer (`COMP-010`). The `docs/research/RESEARCH_PLAN_2026Q3.md` explicitly states the plan serves the goal of getting all 10 faculties to COVERED+VALIDATED. Six faculties are now labeled VALIDATED in some form. Two days ago none were VALIDATED(NULL). The label count changed; the research quality did not advance.

**THE ONE BIG THING:** We are failing at the core research loop. Three of the faculties the Q3 plan must graduate — Memory (EVAL-056), Executive Function (EVAL-058), and Metacognition (EVAL-053) — were closed this week as COVERED+VALIDATED(NULL) using a scoring method that is methodologically invalid under `docs/process/RESEARCH_INTEGRITY.md`: exit-code-0 as success criterion, n=30 per cell, no LLM judge, no A/A calibration, and a dry-run origin in the harness chain. The single remaining open gap (EVAL-059) will close using the same instrument. When it does, the project will be able to claim every faculty is COVERED+VALIDATED or COVERED+VALIDATED(NULL) — but "NULL" will mean "our instrument couldn't detect anything," not "the module has no effect." The distinction matters because `docs/eval/EVAL-048-ablation-results.md` says NULL is a removal candidate. If Memory, Executive Function, and Metacognition modules are truly neutral, they should be removed to reduce prompt overhead and binary complexity. If the instrument is too noisy to know, they should not be labeled VALIDATED. The project must choose: either file removal gaps for the three NULL-validated modules now, or immediately ship a proper behavioral task set with LLM-judge scoring for the binary-mode harness before EVAL-059 closes. Closing EVAL-059 with the current instrument would mean all 10 faculties are "validated" on evidence that the project's own methodology doc would prohibit citing.

---

## Issue #2 — 2026-04-19

### The Looming Ghost

We are failing at gap registry integrity. `docs/gaps.yaml` contains 7 pairs of duplicate IDs — COG-007, COG-008, COG-009, COG-010, COG-011, MEM-003, and EVAL-003 each appear twice with completely different titles, different descriptions, and different implementations, all marked `done`. This is not cosmetic. `gap-preflight.sh`, `chump --briefing`, and the lease system all use gap ID as a unique key. The gap-ID hijack pre-commit guard added on 2026-04-18 (in `scripts/git-hooks/pre-commit`) blocks changing the title of an *existing* entry — it does not block inserting a *new* entry that recycles a previously-used ID. Every agent session that requests a briefing on COG-011 today gets signal from two unrelated gaps smashed together. The guard introduced specifically to prevent ID collision failed on its first day.

We are failing to close what we ship. QUALITY-001 ("unwrap() audit — replace panics with graceful errors in production paths") is marked `done`. There are currently 989 `unwrap()` calls across 74 source files. The gap closure criteria was evidently "perform the audit" not "eliminate the panics." Declaring QUALITY-001 done while leaving 989 unconditional panics in the binary is a false closure that tells future agents this problem was solved. It was catalogued; it was not solved. Additionally: INFRA-MERGE-QUEUE (gap status `open`) shipped in commit 522bba8 and is declared "the default" in CLAUDE.md. COG-020 (gap status `open`) shipped in commit 8199548 as PR #167. The hygiene pass in commit 6862538 — explicitly titled "close gaps shipped 2026-04-19" — missed both. The `status: done` field is not a reliable signal.

We are failing to detect a broken gating agent. INFRA-AGENT-CODEREVIEW shipped in PR #135 ("code-reviewer agent MVP — gates src/* PRs before auto-merge") and is wired into the ship pipeline at `scripts/coord/bot-merge.sh:265-301`. The gap is still `status: open`. Simultaneously, INFRA-CODEREVIEWER-FALSE-POSITIVES (P2 open) documents that the just-shipped code-reviewer raises false CONCERNs on valid existing dependencies. A gating agent with a known false-positive bug is in the mandatory path for every src/* PR. `bot-merge.sh` will block legitimate PRs on false CONCERNs until INFRA-CODEREVIEWER-FALSE-POSITIVES is fixed.

### The Opportunity Cost

We are failing to measure our own spend. COMP-014 — "Cost ledger broken across ALL providers — recorded $0.00 across 4,621 calls today" — is P2 open. COG-025 (P1 open) proposes routing orchestrator subagents to Together's free tier to save money. COG-026 (P1 open) proposes validating Together-big models as a cost alternative to Claude. Both gaps premise their value on cost differential — a differential that cannot be computed because the cost ledger has recorded $0.00 across every provider. We are making architectural dispatch decisions against an instrumentation layer that is completely broken.

We are failing to validate what we ship. EVAL-030 (task-class-aware lessons block) shipped this week. EVAL-030-VALIDATE (empirically validate EVAL-030 via A/B harness) is P2 open and has not started. The shipped feature changes the lessons injection behavior for every session. The measurement that would confirm whether that change helps, hurts, or is neutral has been deferred to a separate gap with no urgency forcing function. Meanwhile EVAL-031 through EVAL-040 — ten additional validation gaps — have been filed in the same period, of which zero have shipped. We are generating evaluation obligations at 10:0 against completion.

We are failing to acknowledge that 45 open gaps is not a healthy backlog. The gap count grew this week: INFRA-CHUMP-API-RETRY, INFRA-DISPATCH-FAULT-INJECTION, COG-025, and COG-026 were filed; COG-020 and INFRA-MERGE-QUEUE shipped but were not closed in the registry; net change is upward. Every open gap is mandatory reading at session start via `chump --briefing`. Forty-five gaps is not a prioritized roadmap. It is a cognitive load tax imposed on every agent session that opens.

### The Complexity Trap

We are failing to admit that the peripheral vision system does not work. `tail -100 .chump-locks/ambient.jsonl` returned exactly two events over the full observable window — both `session_start`, zero `file_edit`, zero `commit`, zero `bash_call`, zero ALERT events. FLEET-004b (git post-commit hook → ambient stream), FLEET-004c (Claude Code PostToolUse hooks → ambient stream), and FLEET-005 (fswatch daemon → ALERT events) all have `status: done`. Their data pipelines are emitting nothing. Every Claude session opens by running `tail -30 .chump-locks/ambient.jsonl` per CLAUDE.md mandate, receiving zero actionable signal, and consuming context window on the exercise. Four implemented gaps, one CLAUDE.md mandatory command, zero events.

We are failing to see that the gap-ID collision guard has an untested bypass. The pre-commit hook in `scripts/git-hooks/pre-commit` has five jobs. The "gap-ID hijack" check (added 2026-04-18) was motivated by the PR #60/PR #65 EVAL-011 collision and specifically blocks changing the `title:` or `description:` of an existing gaps.yaml entry. It does not run `duplicate-id` validation — a check that would catch a new entry inserted with an ID already present in the file. The bypass that produced all 7 current collisions is not covered by any test fixture. The guard has a documented motivation, a real implementation, and a fundamental gap in scope.

We are failing to contain documentation mass. `docs/` now contains 119 markdown files. Issue #1 cited 66. That is 53 net new files added since the last review — on the same calendar date. New files added today include `CHUMP_FACULTY_MAP.md`, `AUTO-013-ORCHESTRATOR-DESIGN.md`, `MERGE_QUEUE_SETUP.md`, `COG-024-MIGRATION.md`, `CONSCIOUSNESS_AB_RESULTS.md`, `CONSCIOUSNESS_UTILITY_PASS.md`. There is no evidence any file was deleted or archived. The documentation surface is growing faster than the product surface. A project whose stated North Star is "someone runs one command, a PWA opens" does not need 119 internal docs files.

### The Reality Check

We are failing to match the autonomy claims to observable evidence. Commits `0d59058` and `aceefa7` this week declared "FIRST CONFIRMED autonomy test" and "autonomy test V4 — PROVEN" respectively. The ambient stream — the peripheral vision system that records every file edit, commit, bash call, and session event from concurrent agents — contains exactly two events over the same window: two `session_start` markers. If Chump-orchestrator was autonomously driving subagents, spawning worktrees, running gap-preflight, and shipping PRs end-to-end, the ambient stream would show hundreds of events. It shows zero operational events. Either the autonomy demonstration ran outside the ambient stream's instrumentation envelope, or "PROVEN" means one manually-triggered test run that was not operationally sustained.

We are failing to ship against the product the North Star describes. `docs/strategy/NORTH_STAR.md` states: "Not a chatbot wrapper. Not a Discord bot. Not a demo. A foundation — local-first, air-gapped capable, designed to run forever and grind — that becomes whatever anyone needs it to be." Zero commits this week touched the PWA, the first-run experience, local model support, Discord, or the one-command install path. The 25 commits that landed were: coordination infra, eval harness, docs sweeps, gap hygiene, worktree reaper, memory/lessons, cognitive layer, and autonomy test documentation. The product the North Star describes has received zero direct investment this week while the infrastructure built to coordinate work on that product received the majority of commits.

We are failing to distinguish "armed" from "safe" on the merge pipeline. INFRA-PUSH-LOCK — "Pre-push hook blocks pushes to PRs with auto-merge armed" (P1, effort S) — is open and unstarted. INFRA-MERGE-QUEUE is declared done in behavior (CLAUDE.md, commit 522bba8) but open in the registry. PR #52 lost 11 commits because agents pushed after auto-merge was armed. The merge queue was the documented fix. The push-lock guard that enforces "stop pushing once the PR is in the queue" does not exist. The footgun that caused PR #52's 11-commit loss remains loaded. The documentation says it is fixed. The code says it is not.

**THE ONE BIG THING:** The gap registry's ID namespace is corrupted across 7 collision pairs (COG-007, COG-008, COG-009, COG-010, COG-011, MEM-003, EVAL-003), a minimum of 3 shipped features remain `status: open` (COG-020, INFRA-MERGE-QUEUE, INFRA-AGENT-CODEREVIEW), and the gap-ID hijack guard in `scripts/git-hooks/pre-commit` does not check for duplicate IDs on insert — only for title changes on existing entries. Every automated system in Chump — `gap-preflight.sh`, `chump --briefing`, the lease system, the musher dispatcher — treats gap ID as a unique key. They are now reading from a corrupted index. An agent briefed on COG-011 today receives context for two completely unrelated tasks with no disambiguation. The coordination system was built to prevent agents from stepping on each other's work. Its own registry is now the source of the ambiguity it was designed to eliminate. Until `docs/gaps.yaml` is deduplicated, shipped gaps are closed, and the pre-commit hook validates ID uniqueness on insert, every agent session starts from unreliable ground.

---

## Issue #1 — 2026-04-19

### The Looming Ghost

We are failing at basic secrets hygiene. Commit `fba4b11` ("Add config/config.yaml") added `config/config.yaml` to version control — a file that contains a live Together.ai API key: `tgp_v1_Z_OJykKz-DGyKlp9lCPiX6hhVmwNLz8-p6nrWuhN1ik`. That key is now in git history permanently, visible to every collaborator, CI runner, and future auditor with read access to this repo. `config/` is not in `.gitignore`. The ANTHROPIC_API_KEY appeared in `config/prod.yaml` across four separate commits (`86cc884`, `e618bb0`, `cf05ce5`, `62db274`) by the same `Your Name <you@example.com>` actor — an unidentified non-bot agent operating entirely outside the coordination system, bypassing every pre-commit hook.

We are failing at production safety. The lessons block in `src/reflection_db.rs:94` (`reflection_injection_enabled()`) is gated only by an env flag that defaults ON. The documented finding from the n=100 A/B sweep is that unconditional injection increases fake tool-call emission by +0.14 pp mean (≈ +0.0014 absolute rate) — 10.7× the A/A noise floor. Gap COG-016 (P1, effort M) names the exact fix — a model-tier predicate in `reflection_db.rs` and an anti-hallucination guard in the injected lessons block — and it has been sitting unstarted since it was filed. We are actively shipping a hallucination amplifier to every production session that runs on a weak model.

We are failing at Rust reliability. There are 946 `unwrap()` calls across 157 source files. `src/reflection_db.rs` alone has 31. These are unconditional panics in production code running against a SQLite database. A corrupted row, a missing `sessions/` directory, or an unexpected NULL triggers a thread panic with no recovery path.

### The Opportunity Cost

We are failing to act on our own findings. EVAL-023 — "Cross-family judge run — break Anthropic-only judge bias" — is P1, effort S, and has been open since `d6c389d` (filed 2026-04-17). Every insight from the 100+ completed A/B trials (COG-001 through EVAL-022) used claude-sonnet as the sole judge. EVAL-010 already showed 38–63% per-trial agreement between two Anthropic judges — at or below chance. Every headline delta (+0.14, +0.12, -0.30 on gotchas) may be systematically inflated by single-family judge autocorrelation. We have not run a single cross-family validation. The A/B harness already supports Ollama judges (`--judges` flag, PR #83). The cost of one cross-family n=100 sweep is ~$1.62. We have not done it.

We are failing to close our own housekeeping. COMP-005 ("Voice/Vision/Browser") carries `status: open` even though every sub-gap (`COMP-005a`, `COMP-005a-fe`, `COMP-005b`, `COMP-005c`) shipped. The parent gap is an orphaned tracker entry that misleads the coordination tooling and pollutes the open-gap list.

We are failing to close the North Star gap. `docs/briefs/CHUMP_PROJECT_BRIEF.md` defines the North Star as "understanding the user in Discord and acting on intent." Zero commits this week addressed Discord intent parsing. Instead, 50 commits landed — of which 11 were Cargo.lock repairs, 7 were crate extraction PRs, and 5 were coordination tooling additions. The stated product goal advanced zero points.

### The Complexity Trap

We are failing to justify the TDA module. `src/tda_blackboard.rs` is 310 lines implementing persistent homology on blackboard traffic (FRONTIER-002). Its only entry in `src/main.rs` is a `mod tda_blackboard;` declaration. There are no callsites outside the module. It has no downstream consumers in the agent loop, no A/B result, no eval fixture. It is dead weight shipping in every production binary.

We are failing to recognize when coordination infrastructure has become the product. The multi-agent coordination system now includes: `musher.sh` (574 lines), `war-room.sh`, `broadcast.sh`, `gap-preflight.sh`, `gap-claim.sh`, `bot-merge.sh`, `worktree-prune.sh`, `stale-pr-reaper.sh`, `cost_ledger.py`, the five-job pre-commit hook, and `ambient.jsonl` peripheral vision. The ambient stream collected exactly **one event** in the most recent observable period: a single `session_start`. The peripheral vision system for which FLEET-004a through FLEET-004d were filed, and which consumes CLAUDE.md space in every session preamble, is detecting nothing because there is nothing to detect. The coordination system is built for a fleet scale that does not currently exist. Its maintenance cost is real; its product value is theoretical.

We are failing to contain documentation sprawl. The `docs/` directory has 66 files. `docs/SESSION_2026-04-18_SYNTHESIS.md` exists as a permanent artifact. So do `MARKET_RESEARCH_EVIDENCE_LOG.md`, `NEUROMODULATION_HEURISTICS.md`, and legacy mistral.rs split docs (now consolidated into `MISTRALRS.md`) — for an upstream `REL-002` that is blocked with no ETA. Sixty-six docs files for a codebase whose North Star is a Discord chatbot is a surface area problem, not a knowledge management success.

### The Reality Check

We are failing to ship against our own priority stack. The three remaining open gaps are: COMP-005 (a stale tracker entry), COG-016 (P1 production harm, unstarted), and EVAL-023 (P1 eval validity, unstarted). Both P1 gaps are M/S effort — one is a single-file Rust change. They have been open for at least two days each. Meanwhile this week's commits included three separate Cargo.lock repair commits (`6cd96d3`, `4652612`, `304c07c`) and a "Fixed Cargo.lock" commit that is itself a symptom of the multi-agent push protocol failing.

We are failing at identity coherence. `docs/briefs/CHUMP_PROJECT_BRIEF.md` says the project is a Discord bot that understands intent. `docs/strategy/CHUMP_TO_CHAMP.md` describes it as a cognitive architecture research platform. The gaps registry has 13 FRONTIER-* entries (quantum cognition, TDA, autopoiesis), 9 FLEET-* entries (mutual supervision, workspace merge), and an active push to publish 10 crates to crates.io. These are three different products. Velocity measured against any one definition looks weak because the effort is diffused across all three simultaneously.

We are failing to enforce the `"Your Name <you@example.com>"` actor boundary. Thirteen commits on main this week originated from that identity — outside the coordination system, with no gap IDs, no pre-commit hooks, and no lease files. Commits `bb56775` ("Write SQL"), `7ded18b` ("Propose schema changes"), `b226514` ("Added architecture.md") reference paths like `repos/chump/` and `repos/chump/wiki/` that do not exist in the repository root. This is a foreign agent or a human operating without the project's own rules applied to them. The CLAUDE.md coordination contract is not actually being enforced on all writers.

**THE ONE BIG THING:** A live Together.ai API key (`tgp_v1_Z_OJykKz-DGyKlp9lCPiX6hhVmwNLz8-p6nrWuhN1ik`) is permanently committed to `config/config.yaml` (commit `fba4b11`) and will remain in git history even if the file is deleted today. This key must be rotated immediately at the Together.ai dashboard. Beyond the immediate credential, `config/` is not in `.gitignore`, four ANTHROPIC_API_KEY writes hit `config/prod.yaml` history across one day, and the committer (`Your Name <you@example.com>`) is an unidentified actor who bypassed every coordination guard this project has built. The combination of a credential-leaking foreign actor operating unchecked on main, a production hallucination amplifier (COG-016) sitting unpatched at P1, and 946 `unwrap()` calls in the Rust binary means the project's security posture, AI safety posture, and reliability posture are simultaneously unacceptable.

---
