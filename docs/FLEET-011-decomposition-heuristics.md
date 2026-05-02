---
doc_tag: log
owner_gap: FLEET-011
last_audited: 2026-05-02
---

# FLEET-011 — Work decomposition heuristics & learning

**Status:** v0 shipped 2026-05-02 (FLEET-025); v1 (learning loop) and v2 (auto-decomposition) deferred to follow-up gaps.

The FLEET vision (`docs/strategy/FLEET_VISION_2026Q2.md`) Layer 2 names work-decomposition as one of three "next-up" capabilities. FLEET-008 (work board) and FLEET-010 (help-seeking) shipped 2026-05-02 in PRs #754 and #760. This doc records the heuristic strategy for the third — FLEET-011 — and what each version delivers.

---

## v0 — bot-merge size advisory (FLEET-025, this PR)

**What it does.** When `bot-merge.sh` reaches the post-test stage, it computes:
- `n_files = git diff --name-only --diff-filter=AM origin/main...HEAD | wc -l`
- `loc_changed = sum(insertions + deletions)` from `git diff --shortstat`
- `codemod_ratio = % of files in {docs/gaps/, .chump/state.sql, Cargo.lock, book/src/}`

If `n_files > 5` AND `loc_changed > 500` AND `codemod_ratio < 80%`, it emits a one-line stderr advisory and an `event=decomposition_hint, kind=oversize` ambient row. **Never blocks** — this is a nudge, not a gate.

**Tunables (env vars):**
- `CHUMP_DECOMP_HINT=0` — silence entirely
- `CHUMP_DECOMP_FILE_THRESHOLD` — default 5
- `CHUMP_DECOMP_LOC_THRESHOLD` — default 500

**Why these defaults.** Empirically, PRs in this repo cluster bimodally:
- Atomic intent PRs: 1-3 files, <200 LOC (the ~80% case)
- Refactor / multi-system / mass changes: 8+ files, 1000+ LOC

The 5-file/500-LOC threshold sits in the gap. The codemod-ratio carve-out exists because gap-registry regen, lockfile bumps, and book/src sync routinely touch many files but ARE atomic by intent — splitting them would introduce broken intermediate `main` state.

**False-positive accounting (planned).** v0 emits `decomposition_hint` events but doesn't yet measure heeded-vs-ignored. v1 closes that loop.

---

## v1 — heeded/ignored learning loop (deferred to FLEET-026)

**What it would add.** Track for each `decomposition_hint`:
- Was the PR shipped as-is (ignored hint)?
- Was the PR closed and resubmitted as ≥2 smaller PRs (heeded hint)?
- Did the as-is PR land cleanly or generate fix-up PRs (revealed-correct vs revealed-wrong)?

After ~30 hints, compute:
- **heeded-rate** = % of hints that led to a PR split
- **revealed-correct rate** for ignored hints = % that needed a fix-up after landing
- Adjust thresholds: if revealed-correct < 30%, raise the threshold (we're nagging on PRs that are actually fine); if > 70%, lower it (we're missing real problems).

**Storage.** Use `chump_improvement_targets` (existing reflection store). Each hint = one row; the post-merge fix-up detection runs in `scripts/dev/heartbeat-self-improve.sh`.

---

## v2 — task-class-aware auto-decomposition (deferred to FLEET-027)

**What it would add.** Heuristic 3 from FLEET-011 acceptance: if `task_class in (refactor, rebase, multi-system)`, decompose by default — propose a stack plan to the agent before it ships. Probably wired into `chump --briefing` so it triggers at gap-pickup time, not at ship time.

Requires:
- Task-class inference from gap title/description (could use existing `perception_layer` patterns)
- A `chump decomposition propose <GAP-ID>` CLI command that reads the gap, scans related code, and outputs a 2-5 step plan
- Integration with FLEET-008 (work board) so the proposed steps become claimable subtasks

---

## Why v0 first

1. **Cheap to ship and observe** — 50 lines of bash, no new dependencies, advisory-only so zero blast radius.
2. **Generates the data v1 needs.** Without `decomposition_hint` events in ambient, there's nothing to measure heeded-rate against.
3. **Doesn't lock in thresholds.** The env-var-tunable design lets us adjust before formalizing.

The pattern matches INFRA-189 (out-of-scope guard) which also shipped warn-mode first to observe false-positive rate before flipping to enforce.

---

## Acceptance vs the parent FLEET-011 gap

| FLEET-011 acceptance | v0 status |
|---|---|
| Heuristic rules implemented and documented | ✅ rule 1 (size), this doc; rules 2+3 deferred to v2 |
| Agent tracks decomposition outcomes (success/failure/abort) | ❌ deferred to v1 |
| Agent adjusts decomposition bias based on learned success rate | ❌ deferred to v1 |
| docs/FLEET-011-decomposition-heuristics.md documents rules and learning trajectory | ✅ this doc |

Parent gap stays **open** until v1 lands; v0 closes FLEET-025.
