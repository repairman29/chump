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
