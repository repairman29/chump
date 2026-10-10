# RESILIENT-446 — closed not-a-bug: AC targets code that doesn't exist

RESILIENT-446 ("Integrate Tier 1 auto-heal execution (RESILIENT-273) into the
routing logic, RESILIENT-274 slice") was spec-enriched by `chump-gap-enricher`
(EFFECTIVE-446) into three concrete acceptance criteria targeting
`crates/chump-gap-store/src/lib.rs::routing_scoreboard`. Verified against
current `origin/main`: the AC describes a function and type that don't exist
in that shape anywhere in the repo.

1. **`routing_scoreboard` has nothing to do with `Tier`.** The AC says to
   "detect when `routing_scoreboard` returns `Tier::Tier1`" and invoke
   `auto_heal(signal)` from inside it. `GapStore::routing_scoreboard()`
   (`crates/chump-gap-store/src/lib.rs:6539`) aggregates
   `routing_outcomes` rows into `Vec<ScoreboardEntry>` — a dispatch
   success-rate rollup used by `chump dispatch scoreboard` / the COG-037
   Thompson-sampling router. It has no `Tier` return value, no concept of a
   "signal," and nothing in it calls `officer.route`.

2. **`Tier::Tier1` doesn't exist anywhere in the codebase.** The real `Tier`
   type (RESILIENT-444, shipped) is `duty_officer::Tier` in
   `src/duty_officer.rs`, with variants `AutoHeal` / `Runbook` / `Escalate`
   (T1/T2/T3) — not `Tier1`/`Tier2`. The real routing call is
   `DutyOfficer::route(&self, tier: Tier, signal: Signal)`, a trait method on
   `src/duty_officer.rs:33`, invoked as `officer.route(tier, signal)` in that
   file's own tests — not inside `crates/chump-gap-store`.

3. **The dependency is unmet.** `depends_on: RESILIENT-445` (wire the
   standing duty-officer loop over the playbook registry) has not merged to
   `origin/main` — only local, divergent, uncommitted attempts exist across
   several concurrent worktrees (`git log --all` shows at least a dozen
   differently-worded `RESILIENT-445: wire standing duty-officer loop...`
   commits, none of them ancestors of `origin/main`).

Closing as not-a-bug rather than fabricating a `Tier::Tier1` arm and a
`TEST_AUTO_HEAL_CALLS` stub inside an unrelated dispatch-scoreboard function
just to satisfy the letter of the AC. This mirrors RESILIENT-448's closure
(PR #5241) — same root cause: `chump-gap-enricher`-authored AC for a
RESILIENT-274 tier-N slice that doesn't match the real `duty_officer::Tier` /
`duty_officer::route` shape, filed against an unmerged RESILIENT-445. If a
real Tier-1 auto-heal integration is wanted once RESILIENT-445 lands, it
belongs on `duty_officer::route`'s `Tier::AutoHeal` arm in
`src/duty_officer.rs`, not on `chump-gap-store`'s dispatch-outcome
scoreboard.
