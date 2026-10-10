# RESILIENT-448 — closed not-a-bug: AC is not implementable as specified

RESILIENT-448 ("Integrate Tier 3 escalation using existing Discord DM path
(RESILIENT-274 tier-3 send)") was spec-enriched by `chump-gap-enricher`
(EFFECTIVE-446) into four concrete acceptance criteria. Verified against
current `origin/main`: the AC describes a code shape that does not exist and
cannot be added without contradicting the AC's own constraints.

1. **AC1 asks for `src/improve.rs::implement_gap` to contain "a match arm for
   the identifier `RESILIENT-448`."** `implement_gap`'s `gap` parameter is
   `chump_handoff::external_repo_schema::ProposedGap` — the Scout-produced
   struct for *external*-repo onboarding proposals (`title`, `domain`,
   `priority`, `effort`, `confidence`, `source_of_evidence`,
   `acceptance_criteria_draft`, `layer`, `doctrine_justification`). It has
   **no `id` field at all** — there is nothing in scope inside
   `implement_gap` that ever holds a Chump gap-registry ID like
   `"RESILIENT-448"`. `implement_gap` is the external-repo self-improvement
   agent dispatcher; it has no notion of Chump's own gap IDs, let alone a
   literal one for itself. Adding a dead `match` arm on a string that is
   never produced would be exactly the kind of unreachable/fabricated code
   the durable-fix doctrine rules out.

2. **AC3 names the wrong test file.** The AC requires
   `scripts/ci/test-resilient-206-free-tier-provider-preserved.sh` to exercise
   a mocked `discord_dm::send_dm_impl` with the Tier 3 JSON payload. That
   script is RESILIENT-206's fleet-worker free-tier-provider-list regression
   test (`CHUMP_FREE_TIER_PROVIDERS` / `OPENAI_MODEL` resolution) — it has no
   relationship to Discord DMs, tiers, or `src/system_prompt.rs`.

3. **AC3 also requires a mock seam that doesn't exist.**
   `discord_dm::send_dm_impl` is a private `async fn` in `src/discord_dm.rs`
   with no injection point; there is no existing mock harness for it. Wiring
   one would require editing `src/discord_dm.rs` — but AC4 explicitly
   forbids touching anything outside `src/improve.rs` and
   `src/system_prompt.rs`. AC3 and AC4 are mutually unsatisfiable as written.

4. **The dependency is unmet.** `depends_on: RESILIENT-445` (wire the
   standing duty-officer loop over the playbook registry) has not merged to
   `origin/main` as of this gap's claim — only local, uncommitted attempts
   exist across several concurrent worktrees. The `Tier::Tier3` routing
   value the description refers to doesn't exist either:
   `duty_officer::Tier` (RESILIENT-444, shipped) has variants `AutoHeal` /
   `Runbook` / `Escalate` (T1/T2/T3), not `Tier3`.

Closing as not-a-bug rather than fabricating a dead code path against an
AC set that contradicts itself (AC3 vs AC4) and references a struct field
that doesn't exist (AC1). If a real RESILIENT-274 tier-3-send integration is
wanted once RESILIENT-445 lands, it belongs on `duty_officer::route` /
`playbook_registry`'s T3 action path (which already calls through the
existing, unchanged `discord_dm::send_dm_if_configured`), not on the
external-repo `implement_gap` dispatcher.
