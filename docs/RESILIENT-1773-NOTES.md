# RESILIENT-1773 — closed not-a-bug: leaked test-fixture gap, no real work item

RESILIENT-1773 has an empty description, empty acceptance criteria, and
empty notes in `.chump/state.db`:

```
$ chump gap show RESILIENT-1773 --json
{
  "id": "RESILIENT-1773",
  "title": "RESILIENT-1494 canonical store test",
  "description": "",
  "acceptance_criteria": "",
  "notes": "",
  "created_at": 1793239931,
  "priority": "P1",
  "effort": "m",
  ...
}
```

`created_at=1793239931` falls inside the `1793221893..1793239932` leak
window already diagnosed in RESILIENT-1761's close-out
(`docs/RESILIENT-1761-NOTES.md`). The title string
`"RESILIENT-1494 canonical store test"` is the literal fixture title
string reserved by the unit test
`dispatch::tests::resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing`
in `src/dispatch.rs`:

```rust
let gap_id = store
    .reserve(
        "RESILIENT",
        "RESILIENT-1494 canonical store test",
        "P1",
        "m",
    )
    .expect("reserve gap");
```

That test opens its `GapStore` against a temp-dir `main_repo`, not the
production checkout, so the reservation shouldn't reach the real
`.chump/state.db` — but RESILIENT-1773 exists in the canonical store with
exactly that title, `priority: P1`, `effort: m`, matching the test's
`reserve()` call byte-for-byte. This is the same leak class RESILIENT-1761
and RESILIENT-1762 already closed out, continuing past CREDIBLE-152's
reserve guard.

Verified separately that the actual test coverage this title describes
already shipped: `resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing`
exists on `main` (added under PR #5696, closing RESILIENT-1494) and passes
(`cargo test --bin chump resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing`
→ 1 passed). There is no outstanding "canonical store test" work to do —
it's done, and this gap is just another leaked reservation record from the
same root cause, not a new tracking ticket.

Closing as not-a-bug per the reality-check doctrine (`AGENTS.md` →
Reality-check before alarm-class beliefs, CREDIBLE-090) rather than
inventing fictional work against a leaked gap. The root-cause leak (test
suites' `reserve()` calls landing in the production `state.db`) is already
tracked by the follow-up filed alongside RESILIENT-1761's close.
