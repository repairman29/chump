# RESILIENT-447 — closed not-a-bug: AC targets code that doesn't exist

RESILIENT-447 ("Integrate Tier 2 agent-run runbook with approval flow
(RESILIENT-265), RESILIENT-274 slice") was spec-enriched by
`chump-gap-enricher` (EFFECTIVE-446) into four concrete acceptance criteria.
Verified against current `origin/main`: the AC describes a code shape that
does not exist, in the same way RESILIENT-446 (#5243) and RESILIENT-448
(#5241) did.

1. **`request_approval(signal)` does not exist in `src/discord.rs`, or
   anywhere.** The real approval primitive is
   `approval_resolver::request_approval_for(tool_name: &str, args:
   &serde_json::Value) -> (String, watch::Receiver<Option<bool>>, bool)` in
   `src/approval_resolver.rs:79` — it lives in a different file, takes a
   `(tool_name, args)` pair (not a `duty_officer::Signal`), and returns a
   receiver + join flag rather than being a fire-and-forget call keyed on a
   signal. `src/discord.rs` only *consumes* `AgentEvent::ToolApprovalRequest`
   events (line ~666) to post the approve/deny card; it defines no
   `request_approval` function of its own.

2. **`REALITY_CHECK` does not exist anywhere in the codebase.**
   `grep -rn "REALITY_CHECK" src/ crates/` (excluding `target/`) returns
   nothing. There is no mocked or real reality-check step for any tier to
   trigger before requesting approval.

3. **There is no "Tier 2 routing" to attach either step to.** The real
   `Tier` type (RESILIENT-444, shipped) is `duty_officer::Tier` in
   `src/duty_officer.rs`, with variants `AutoHeal` / `Runbook` / `Escalate`
   (T1/T2/T3) — `Tier::Runbook` is the T2 variant the AC means, but
   `DutyOfficer::route` is a bare trait method
   (`fn route(&self, tier: Tier, signal: Signal) -> Result<()>`) and its only
   implementation, `TestDutyOfficer`, just records `(tier, signal)` pairs for
   tests — it calls neither a reality-check nor `request_approval_for`.
   Wiring either into `route`'s `Tier::Runbook` arm is new product work, not
   a bug fix against existing behavior, and the AC's own function name
   (`request_approval(signal)` in `src/discord.rs`) doesn't match where that
   work would actually land (`approval_resolver::request_approval_for`).

4. **No "runbook function" exists for an approved path to call.** AC3 asks
   for a unit test that simulates a button press and verifies "the approved
   path calls the appropriate runbook function," but no runbook-dispatch
   function is referenced by the AC or exists on the `Tier::Runbook` path
   today — `playbook_registry` (RESILIENT-443) holds playbooks keyed by
   signal kind, but nothing in `duty_officer.rs` or `approval_resolver.rs`
   calls into it yet.

5. **The dependencies are unmet.** `depends_on: ["RESILIENT-445",
   "RESILIENT-446"]`. `RESILIENT-445` (wire the standing duty-officer loop
   over the playbook registry) has not merged to `origin/main` — only local,
   divergent, uncommitted attempts exist across several concurrent
   worktrees (`git log --all` shows a dozen+ differently-worded
   `RESILIENT-445: wire standing duty-officer loop...` commits, none of them
   ancestors of `origin/main`). `RESILIENT-446` was itself closed as
   not-a-bug (#5243) with no real code shipped.

Closing as not-a-bug rather than fabricating a `request_approval(signal)`
function in `src/discord.rs` and a `REALITY_CHECK` step that match the
letter of the AC but not the actual `duty_officer::Tier::Runbook` /
`approval_resolver::request_approval_for` shape. This mirrors RESILIENT-446
(#5243) and RESILIENT-448 (#5241): same root cause — `chump-gap-enricher`
authored AC for a RESILIENT-274 tier-N slice against an unmerged
RESILIENT-445, describing code that doesn't exist in the named location. If
a real Tier-2-runbook-with-approval integration is wanted once RESILIENT-445
lands, it belongs on `duty_officer::route`'s `Tier::Runbook` arm calling
`approval_resolver::request_approval_for`, not on a `request_approval(signal)`
function invented inside `src/discord.rs`.
