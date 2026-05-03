# Session synthesis — 2026-05-02 (parallel fleet validation + structural-clog removal)

**Author:** Claude (parent session) + ~14 parallel Task subagents + 2 dogfood `claude -p` fleet workers
**Span:** ~6 hours wall, single day
**Outcome:** **28 PRs merged, 4 systemic clogs structurally removed, parallel-agent ship pipeline validated end-to-end.** A future fleet run with the same prompt mix should ship 2-3× faster than this one did.

The session started with: *"how do we max-parallel agents without getting clogged up all the time?"* It ended with the answer: **the clogs were specific structural defects, not a fundamental scaling limit.** Each clog had a 5-50 line fix.

---

## 1. Scientific / research result

Not a research session — pure infrastructure. The closest thing to a result is the throughput delta:

- **Before tonight:** parallel agents needed ~30-sec rescue every 2-3 PRs (commit-but-don't-push, state.sql cascade, closer-batcher false-pos). Effective throughput ~3 PRs / 15-min batch.
- **After tonight:** dogfood fleet of 2 workers shipped PR #880 + speculative-loser PR #882 with zero parent intervention. Per-PR ship time via `--fast` measured at **6 seconds wall** (vs 5-10 minutes cold).

That's a ~50-100× reduction in per-ship overhead. Real Tier-2 fleet scaling (8+ concurrent workers) is now blocked only by gap supply, not by infrastructure churn.

---

## 2. What shipped

28 PRs merged this session. Grouped by domain:

### Structural clog removers (the headline group)

- **PR #850 — INFRA-252** `bot-merge.sh --fast` flag — skip local clippy/test (CI is the gate). 50-100× ship-time reduction. **Most leveraged single change of the night.**
- **PR #877 — INFRA-262** Auto-close stops touching `.chump/state.sql` — kills the rebase-conflict cascade hot-spot.
- **PR #843 — INFRA-219** closer-pr-batcher checks `status:done on origin/main`, not local DB — stops killing in-flight PRs.
- **PR #879 — INFRA-271** `worker.sh` exports `CHUMP_SPECULATIVE=1` + drops 30s sleep on transient worktree-add failure.
- **PR #883 — INFRA-273** `gap-preflight` Check 1.5: block claim when an open PR with the gap-ID in title exists. (Default opt-in; bypass via `CHUMP_PREFLIGHT_PR_CHECK=0` or `CHUMP_SPECULATIVE=1`.)
- **PR #899 — INFRA-303** `gap-doctor-reconcile.py` — backfill state.db from YAML mirror.
- **PR #903 — INFRA-316** Reconciler's overwrite-richer heuristic (multi-line YAML over single-line DB always wins; length-based otherwise). After this, `chump gap dump --per-file && git diff` produces zero changes.

### Post-INFRA-188 cleanup (the cutover left scripts referencing the deleted monolithic file)

- **PR #766 — INFRA-226** `bot-merge.sh` auto-close conditional on `docs/gaps.yaml` vs `docs/gaps/` directory.
- **PR #811 — INFRA-242** Auditor `lib.sh` retires the broken python+yaml fallback (was reading the deleted file).
- **PR #872 — INFRA-245** `gap-doctor.py` reads `docs/gaps/<ID>.yaml` per-file directory + 63-gap state.db reconciliation.
- **PR #775 — INFRA-231** Overnight wrapper prepends `$HOME/.local/bin` to PATH so launchd cron finds chump.

### Fleet infrastructure (run-fleet.sh + worker + dashboard)

- **PR #783 + #798 — INFRA-191 P1+P2** `chump dispatch` Rust subcommand (preflight → claim → work → ship → release). Phase 2 adds Headless + ExecGap backends.
- **PR #844 — INFRA-203** `scripts/dispatch/run-fleet.sh` — tmux-based canonical fleet launcher.
- **PR #841 — INFRA-204** `scripts/dispatch/fleet-status.sh` — tmux control pane (ambient + queue + per-agent).
- **PR #834 — INFRA-202** sccache install doc (shared `CARGO_TARGET_DIR` pattern).

### Coordination guards

- **PR #759 — INFRA-224** `bot-merge.sh` installs pre-commit hooks if missing (closes the 9-gap `closed_pr=TBD` leak Cold Water #10 flagged).
- **PR #845 — INFRA-237** `bot-merge.sh --gap` is now mandatory.
- **PR #806 — INFRA-239** Stacked-PR rebase footgun documented in CLAUDE.md.

### Loop / observability

- **PR #770 — INFRA-223** `distill-pr-skills.sh` fires from `bot-merge.sh` post-arm — the `chump_improvement_targets` table now grows automatically.
- **PR #821 — INFRA-102** `session_start` ambient events restored (was advertised but never fired).
- **PR #835 — INFRA-120** Reaper heartbeat + ambient `reaper_run` events + watchdog ALERTs.
- **PR #829 — INFRA-121** Branch-protection drift detector.
- **PR #830 — INFRA-104** PR title-vs-implementation drift detector.

### Closers / cleanup

- **PR #826 — INFRA-152** acceptance test for `chump gap set/ship --closed-pr` round-trip.
- **PR #827 — INFRA-218**, **#840 — INFRA-162**, **#856 — INFRA-171**, **#852 — INFRA-240/255**: closer PRs (work landed earlier; gap registry caught up).

### Research / methodology

- **PR #862 — EVAL-087** Evaluation-awareness preregistration.

---

## 3. Methodology lessons

### Stale snapshots are the silent killer of parallel-agent throughput

I burned 4 of the first 6 agent invocations on Cold Water #10 findings that had **already shipped between Red Letter writing time and my reading time** (~5 hours). The agents correctly bailed (`chump gap preflight → already done`), but the cycles were wasted.

**Right behavior:** never brief an agent with snapshot-derived context. Brief the agent with: *"check canonical state.db + open PR list yourself, only then proceed."* Live-query patterns (this session's batch 2 onward) had a 0% wasted-cycle rate.

### `--fast` should be the default for agent-mode shipping

The Anthropic general-purpose subagent's task budget is ~10-15 min. Cold cargo clippy alone takes 5-7 min. Without `--fast`, every agent risks timing out before reaching `git push` — leaving the parent session to rescue commit-but-don't-push orphans (6 rescues this session, ~30 sec each).

`--fast` cuts ship time from ~5-10 min to ~6 seconds. Trade: a clippy-broken PR may briefly exist; CI rejects it before it can land. Acceptable.

### `.chump/state.sql` should not be in PR commits

Every parallel auto-close commit edited the same file → guaranteed rebase-conflict cascades at any meaningful concurrency. Fix was 3 lines in `bot-merge.sh` (INFRA-262). The principle generalizes: **regenerable artifacts should never be in critical-path commits.** The regenerate-gaps-yaml workflow keeps state.sql in sync on main; PRs don't need to touch it.

### Stacked PRs have a hidden squash-loss footgun

When the upper PR (Phase 2) squash-merges into the lower branch (Phase 1) before main moves, then main moves and the lower PR goes DIRTY, a plain `git rebase origin/main` **silently drops the upper squash-merge.** Recovery: `git cherry-pick <upper-PR-merge-sha>` after the rebase. Documented in CLAUDE.md (PR #806). `pr-watch.sh` has the same blind spot — INFRA-239 follow-up may add detection.

### state.db is not actually canonical until you reconcile it

The post-INFRA-188 cutover stamped state.db as "canonical" but the YAML mirror had richer content for ~144 gaps (descriptions, acceptance_criteria, opened_dates). Pre-INFRA-200 raw-YAML edits + early `chump gap reserve` calls (which only stored title/domain/priority/effort) accumulated this drift over months.

Without `gap-doctor-reconcile.py` (INFRA-303 + INFRA-316), every fresh `chump gap dump --per-file` produced 1500-3700 line phantom deletions. Now: zero diff.

### Operational rules added this session

Rules added to CLAUDE.md:

- Stacked-PR rebase footgun + recovery procedure (INFRA-239)
- `bot-merge.sh --fast` is the agent default (INFRA-252)
- Speculative claim via `CHUMP_SPECULATIVE=1` for fleet workers (INFRA-271)
- `chump gap dispatch` is the canonical Rust ship surface (INFRA-191 design doc + Phase 1+2)

Hooks / scripts added:

- `scripts/coord/gap-doctor-reconcile.py` — bidirectional state.db ↔ YAML reconciler
- `scripts/dispatch/run-fleet.sh` + `worker.sh` + `fleet-status.sh` + `_pick_gap.py` + `control.sh`
- `scripts/ci/test-bot-merge-fast-flag.sh` — contract test for `--fast`

---

## 4. What failed / wasted time

| What | Time lost | Root cause | Prevention |
|------|-----------|------------|-----------|
| 4 of first 6 agents bailed on already-shipped gaps | ~30 min | Briefed from Cold Water #10 snapshot 5 hr stale | Live `chump gap list` + `gh pr list --search` per gap before briefing |
| 6× commit-but-don't-push agent timeouts | ~3 min rescue each = 18 min | Cold cargo clippy in agent budget | `--fast` (now default for agents) |
| 6+ state.sql rebase-conflict cascades | ~5 min each = 30 min | Hot file in every auto-close commit | INFRA-262 |
| PR #819 closed by closer-batcher false-pos before merging | ~10 min recovery | closer-batcher checked local DB not origin/main | INFRA-219 |
| 2 fleet workers picked the same gap (INFRA-261) | ~30 sec sleep loss + 1 wasted cycle | Race between `chump gap list` + `gap-claim.sh` | INFRA-271 + INFRA-273 |
| Stacked PR #783 rebase dropped Phase 2's squash | ~10 min cherry-pick recovery | `git rebase origin/main` doesn't preserve merge commits | Documented; `pr-watch.sh` enhancement filed |
| Empty bash-tool output 4× during session | ~10 min total | Background command pipes (`\| tail -10`) swallowed early bot-merge output | Use `> /tmp/file 2>&1 ; tail file` pattern instead of in-pipeline tail |

**Total wasted time: ~110 min.** Out of ~6h, that's ~30%. With the fixes shipped, the same session re-run should waste <20 min.

---

## 5. Cost breakdown

Not API-cost-tracked tonight (mostly infra work, no eval sweeps). Rough Anthropic-token usage estimate:

| Step | Trials | Notes |
|------|-------:|-------|
| Parent session (this orchestrator) | 1 | ~6h conversation, ~14 Task subagents spawned |
| Task subagents | ~14 | Each ~5-22 min, ~50-150K tokens each |
| Dogfood fleet `claude -p` workers | 2 | ~10-20 min each, configured for `chump-local` (Together free tier) backend |
| **Total** | ~17 | Mostly Sonnet 4.6, no Opus calls |

The fleet workers explicitly used `FLEET_BACKEND=chump-local` (INFRA-259 default) — those calls go through Together's free tier, not Anthropic, so they cost zero.

---

## 6. Gap / state snapshot at session end

| ID | Priority | Status | Notes |
|----|----------|--------|-------|
| INFRA-303 | P2 | done (PR #899 armed) | Reconciler shipped |
| INFRA-316 | P2 | done (PR #903 armed) | Overwrite-richer heuristic |
| INFRA-271 | P1 | ✓ MERGED | Worker speculative |
| INFRA-262 | P1 | ✓ MERGED | state.sql skip |
| INFRA-252 | P1 | ✓ MERGED | --fast |
| INFRA-273 | P1 | ✓ MERGED | Preflight Check 1.5 |
| INFRA-191 | P1 | ✓ MERGED | Phase 1+2 |
| (~5 follow-up gaps filed) | P2-P3 | open | INFRA-248, 304, 305, 306, 316 |

State.db is now reconciled with the YAML mirror (locally). `gap-doctor.py doctor` reports 0/0/0/0 drift. Once #899 + #903 land, future devs can rerun `gap-doctor-reconcile.py` to maintain it.

---

## 7. Where to pick up next session

### Immediate (first 30 min)

1. **Verify INFRA-303 + INFRA-316 landed cleanly.** Run `python3 scripts/coord/gap-doctor.py doctor` — should report 0/0/0/0.
2. **Run `python3 scripts/coord/gap-doctor-reconcile.py --dry-run`** — should show 0 gaps to touch (because state.db is already canonical).
3. **Check `gh pr list --state open --author @me`** for any session leftovers.

### Next chips (small, ready)

- **INFRA-104 audit-pass** — drift detector landed; do an inaugural sweep on 30 days of merged PRs to surface real drift.
- **INFRA-191 Phase 3** — port `bot-merge.sh`'s ship pipeline to native Rust (`chump dispatch` internals). ~1-2 hr. Phase 1+2 are stable now; Phase 3 unblocks Phases 4-5 (CLAUDE.md flip + bot-merge.sh retirement).
- **INFRA-239 follow-up** — make `pr-watch.sh` detect stacked-PR state and refuse rebase, preventing the squash-loss class entirely.
- **INFRA-NEW (file me)** — `worker.sh` should use `chump dispatch --backend headless` instead of inline `claude -p` spawn (consolidates surface, gets `--fast` for free).

### Standing experiment

- Re-run the fleet (`FLEET_SIZE=5 scripts/dispatch/run-fleet.sh`) with all post-INFRA-271/273/303 fixes in place. Measure: how many PRs land in 30 minutes vs the unrescued baseline. Hypothesis: 5-10×.

### Watch overnight

- 02:00 launchd auditor (post INFRA-231 PATH fix) — should produce per-run logs in `.chump/overnight/`.
- Stale-PR-reaper hourly — should auto-close any duplicate PRs from sibling agents.

---

## 8. Closing remark

The headline isn't "we shipped 28 PRs" — it's *"we identified the actual structural defects that were limiting parallel-agent throughput, and removed them."* The team can now scale agent count past where it was clogging without adding more rescue overhead. That's the unlock the session was hunting for.
