# Session handoff — 2026-05-27 shepherd Opus

> Synthesis from `curator-opus-shepherd-2026-05-23` (this session) for whichever
> Opus picks up the role next. Captures: what shipped, what's locked behind
> windows, what's pickable now, and the keystone choices for next session.

## TL;DR

**META-114 freshness cluster CLOSED** (5/5 shipped: INFRA-2053 + META-115 + DOC-059 + META-116 + INFRA-2054).
**META-107 Phase 2 cutover arc FILED** (INFRA-2060..2065 + META-120 umbrella; locked behind 7-14 day parallel-run windows).
**META-118 wedge auto-dispatch DECOMPOSED** (INFRA-2067..2071 sub-gaps; INFRA-2067 + INFRA-2071 pickable now).
**Ghost-gap SLO breach (L2-SLO-5) addressed** via #2664.

Next session: pick **INFRA-2067** (novel-wedge classifier, P1/s, no deps) OR **INFRA-2071** (admin-merge circuit-breaker, P1/xs, independent). Both close today's manual loop.

## What shipped this session

| PR | Status | Gap(s) | What |
|---|---|---|---|
| #2641 | LANDED | INFRA-2001 Phase 1 | chump-ship Rust binary feature-flagged in parallel with bot-merge.sh |
| #2646 | LANDED | INFRA-2002 Phase 1 | chump-worker + chump-fleet binaries Phase 1 |
| #2653 | LANDED | INFRA-2053 | chump gap sync bidirectional YAML ↔ state.db reconciliation |
| #2655 | LANDED | META-115 | per-session source-freshness preamble |
| #2657 | LANDED | DOC-059 | docs/process/FRESHNESS_DISCIPLINE.md |
| #2658 | LANDED | META-116 | dispatch-health-check.sh hung-hook detection |
| #2660 | LANDED | DOC-061 | FRESHNESS_DISCIPLINE.md cross-links from CLAUDE.md + AGENTS.md |
| #2659 | ARMED | META-117 | Wave 1 CI debt cleanup (printf|grep race + duplicate registry) |
| #2661 | ARMED | META-119 | Pattern 13 hung-hook detection + dispatch_hung_hook_detected allowlist |
| #2662 | ARMED | META-120 | META-107 Phase 2 cutover arc filing (6 cutover gaps) |
| #2663 | ARMED | INFRA-2054 | chump --build-info + self-check-staleness CLI |
| #2664 | ARMED | (ghost-gap-sync) | 6 status:done YAMLs reconciled, resolves L2-SLO-5 |
| #2665 | ARMED | META-118 decompose | 5 sub-gaps INFRA-2067..2071 filed with concrete AC |

## What's pickable RIGHT NOW (next session's first move)

Ranked by leverage. All are P0/P1, xs/s/m, no deps, concrete AC.

1. **INFRA-2067** (RESILIENT P1/s) — novel-wedge classifier daemon. **HIGH LEVERAGE** — unlocks INFRA-2068/2069/2070 (the rest of META-118's auto-dispatch chain). No deps.
2. **INFRA-2071** (RESILIENT P1/xs) — admin-merge-cycle circuit-breaker. **INDEPENDENT** of the classifier chain. Closes today's anti-pattern (admin-merge accumulated 10+ uses without operator noticing CI debt). Parallel-pickable.
3. **INFRA-2066** (ZERO-WASTE P1/s) — pr_stuck_cluster auto-mitigation. **Addresses 82% of daily waste** (~55m/67m in 24h). Pairs with INFRA-2012 (cluster-v2 detection).
4. **META-117** (sub-gaps unfiled) — Wave 2 CI debt cleanup. Wave 1 ARMED as #2659.
5. **INFRA-2014** (P0/m) — live inbox injector daemon. 2 days old. Converts A2A from dead-letter to live signal.

## What's LOCKED BEHIND WINDOWS (don't try to pick)

The META-107 Phase 2 cutover arc (INFRA-2060..2065 + META-120) is intentionally non-pickable until ~2026-06-03:

- **7-day window** for INFRA-2060/2061/2063/2064/2065 (xs/s cutovers)
- **14-day window** for INFRA-2062 (chump-github-cache Python receiver — webhook divergence is silent)

Each cutover gap's AC requires "X+ consecutive days with feature flag default + zero divergence ambient events." Don't try to ship these before the window elapses — operator filed them to enforce parallel-run discipline, not as immediate work.

## Active SLO state

- ✓ pass — L1-SLO-1 silent_agent
- ✓ pass — L1-SLO-2 orphan_claude
- ✓ pass — L1-SLO-3 auto-restart success
- ✗ **BREACH L2-SLO-2** waste rate ~16% (target <5%). Top burner: **11 × pr_stuck_cluster** = ~55m / 67m daily waste. **Mitigation filed: INFRA-2066.**
- ✓ pass — L2-SLO-3 P0 count = 3 (target ≤5)
- ✓ pass — L2-SLO-4 pillar balance
- ✗ **BREACH L2-SLO-5** ghost-gap = 5 (target <2). **Fix ARMED: #2664.** Expected to flip pass when #2664 lands.
- ✓ pass — L3-SLO-1 operator-recall

Fleet currently **PAUSED** by waste breach. Use `CHUMP_IGNORE_WASTE_PAUSE=1` to bypass for filing follow-up gaps. Operator should run `chump health --slo-check` after #2664 lands to verify L2-SLO-5 unwinds.

## Pillar inventory

EFFECTIVE 57 | CREDIBLE 20 | RESILIENT 64 | ZERO-WASTE 9 | OTHER 47.
**ZERO-WASTE is the thinnest pillar.** INFRA-2066 + INFRA-2071 both replenish it. **CREDIBLE is second-thinnest** — see "Open follow-up tracks" below.

## Open follow-up tracks (deferred from this session)

1. **INFRA-1932 remaining 6 ACs** — presence ledger / auto-ack / auto-mirror / passive a2a / smoke / roll-out doc. Too large for end-of-session pickup; needs a dedicated session.
2. **16 phantom EVAL-* refs in `docs/process/RESEARCH_INTEGRITY.md`** — `chump gap audit-priorities` flags these. They're VALIDATION TARGETS (aspirational eval gaps not yet filed), not dangling refs to fix. Two paths:
   - (a) File 16 EVAL gaps from the citations (boosts CREDIBLE pillar 20 → 36 pickable). Research-track work, different cadence.
   - (b) Add a header to `RESEARCH_INTEGRITY.md` clarifying these are unfiled aspirational targets.
   - Operator decision deferred.
3. **State.db ↔ YAML drift** — `git status docs/gaps/` in main checkout shows dozens of `M` files. Pre-INFRA-2053 backlog. Suggested follow-up: a once-only `chump gap sync --apply` PR to reconcile all of them in one commit.
4. **WIP META-107 cutover arc** — see "LOCKED BEHIND WINDOWS" above. Re-visit ~2026-06-03.

## Today's hard-won lessons (worth codifying in playbook)

These are the source patterns behind META-114 / META-116 / META-119:

1. **Hung pre-commit hooks (META-116 / Pattern 13)** — when a Sonnet dispatch appears abandoned, **always check `ps aux | grep -E 'git.commit|pre-commit'` BEFORE taking over**. Today's INFRA-2000 dispatch had pre-commit wedged 5+ min; both Sonnet's commit AND my takeover hung on the same hook. Killing the hook PIDs unblocked Sonnet's own commit; takeover wasn't needed.
2. **Verify-at-source preamble (META-115 / Pattern 12)** — at the start of any work where freshness matters, run `git fetch origin main && git log --oneline -1 origin/main` first. Don't assume your worktree matches origin.
3. **Source-staleness classification (META-114 cluster)** — 7 staleness layers: git main, state.db, chump binary, launchd plists, YAML gaps, fleet-registry, docs. Use `chump self-check-staleness` to check (INFRA-2054 shipped).
4. **Recovery-queue admin-merge** — when a PR is gummed up by workspace drift but the change itself is clean, use `CHUMP_OPERATOR_RECOVERY=1` admin-merge cycle to bypass. RESILIENT-031 + #2651 shipped the noise-class discipline gate.

Pattern 12 + 13 + the anti-pattern table now live in `docs/process/SHEPHERD_LOOP_PLAYBOOK.md`.

## Sibling coordination

- **wizard-2026-05-25** session was reserving gaps in parallel today. Caused ID collision on INFRA-2045; resolved by renumbering my chump-cron work to INFRA-2057. **Lesson:** chump gap reserve doesn't sync against origin/main reservations, only local state.db. Mitigation already in flight: INFRA-2053 chump gap sync (shipped #2653).
- **curator-opus-ci-audit** had standing dispatches for INFRA-1835 / INFRA-1837 (preflight tree-sha cache + bypass-frequency auditor). Status not checked this session; next session should peek inbox first.

## Quick-start sequence for next session

```bash
# 1. Pre-flight (mandatory per CLAUDE.md)
git fetch origin main --quiet && git status
bash scripts/setup/chump-fleet-bootstrap.sh --check
tail -30 .chump-locks/ambient.jsonl
scripts/coord/chump-inbox.sh read --no-advance

# 2. Verify-at-source preamble (META-115)
git log --oneline -1 origin/main  # confirm fresh

# 3. Self-check staleness (INFRA-2054 if shipped)
chump --build-info
chump self-check-staleness

# 4. Survey & pick
chump health --slo-check
chump gap audit-priorities
chump gap pillar-balance

# 5. Recommended first move
chump gap preflight INFRA-2067 && chump claim INFRA-2067  # if classifier route
# OR
chump gap preflight INFRA-2071 && chump claim INFRA-2071  # if circuit-breaker route
```

Both INFRA-2067 and INFRA-2071 are concrete-AC + no-deps + pickable. INFRA-2071 ships faster (xs); INFRA-2067 unlocks more downstream work.

---

*This handoff was filed by `curator-opus-shepherd-2026-05-23` on 2026-05-27. If you're reading this AFTER 2026-06-03, the META-107 cutover arc may be partially or fully unlocked — re-check `chump gap preflight INFRA-2060` etc. before assuming they're still gated.*
