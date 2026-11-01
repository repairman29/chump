# RESILIENT-1775 — closed not-a-bug: canonical store test already shipped under RESILIENT-1494

RESILIENT-1775 ("RESILIENT-1494 canonical store test") asks for a test of
RESILIENT-1494's canonical-gap-resolution fix. That fix, and the exact test,
already shipped together in PR #5696
(`fix(dispatch): harden resume commit check, oauth/canonical gap load, shared
target & cargo admission (INFRA-8114, RESILIENT-1494, RESILIENT-1642,
RESILIENT-1640)`), merged 2026-10-24.

The test lives at `src/dispatch.rs::dispatch::tests::
resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing`
and covers both halves of the AC:

1. A gap reserved in the canonical `GapStore` at the main checkout's
   `.chump/state.db` resolves correctly via `dispatch_repair::load_canonical_gap`
   even when invoked from a linked worktree whose own `.chump/` is empty.
2. A missing gap ID causes `dispatch_repair::build_auto_prompt_checked` to
   fail loud (`Err`, containing "not found in canonical gap store") instead of
   silently falling back to a placeholder prompt.

Verified on current `main` with the current binary:

```
$ cargo test --package chump --bin chump resilient_1494_canonical_gap_resolves_from_main_checkout
running 1 test
test dispatch::tests::resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 3011 filtered out
```

Closing as not-a-bug per the reality-check doctrine (`AGENTS.md` →
Reality-check before alarm-class beliefs, CREDIBLE-090). No follow-up filed —
this is a leaked duplicate of already-shipped work, same class as
RESILIENT-1809/RESILIENT-1829/INFRA-8826/INFRA-8828.
