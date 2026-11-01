# RESILIENT-1759 — closed not-a-bug: the canonical-store test already shipped

RESILIENT-1759 asked for a "RESILIENT-1494 canonical store test" — a test
verifying that `chump dispatch` resolves a gap from the CANONICAL gap store
(not a fresh linked worktree's empty `.chump/state.db`) and fails loud on a
missing gap, per RESILIENT-1494 AC1.

That test already exists and already passes on `main`:

```
$ git log -1 --format='%H %s' -- src/dispatch.rs | grep RESILIENT-1494
fa0c74d161fb097261c400922c47b0a41d1e0067 fix(dispatch): harden resume commit
check, oauth/canonical gap load, shared target & cargo admission (INFRA-8114,
RESILIENT-1494, RESILIENT-1642, RESILIENT-1640) (#5696)

$ cargo test --bin chump \
    resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing
running 1 test
test dispatch::tests::resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing ... ok
```

The test (`src/dispatch.rs`, `dispatch::tests::resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing`):

1. Seeds a gap titled "RESILIENT-1494 canonical store test" into the
   canonical store at `main_repo/.chump/state.db`.
2. Creates a linked worktree with its own empty `.chump/` dir and asserts
   `dispatch_repair::load_canonical_gap` still resolves the gap by walking
   back to the main checkout's store.
3. Asserts that resolving a nonexistent gap ID via
   `dispatch_repair::build_auto_prompt_checked` returns `Err` (fails loud)
   rather than silently building an empty/fallback prompt — the exact
   wrong-prompt-freelancing failure mode RESILIENT-1494 was filed to close.

RESILIENT-1759 was filed as a follow-up to make sure this coverage existed,
but it landed in the same PR (#5696) that closed RESILIENT-1494 itself —
the gap never got marked done because nothing re-checked it after the fact.

No code change needed. Closing as not-a-bug per the reality-check doctrine
(`AGENTS.md` → Reality-check before alarm-class beliefs, CREDIBLE-090)
rather than writing a duplicate test against coverage that already exists
and already passes.
