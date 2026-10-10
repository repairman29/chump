# RESILIENT-442 — closed as superseded by already-shipped RESILIENT-443

RESILIENT-442 ("Define Playbook Registry data structures (Signal → Tier →
Action)", RESILIENT-274 slice) asks for `src/playbook_registry.rs` with a
`Signal`/`Tier` enum pair, a `PlaybookEntry` struct, a `PlaybookRegistry` map,
and `fn get_entry(&self, signal: &Signal) -> Option<&PlaybookEntry>`.

`src/playbook_registry.rs` already exists on `main`, shipped by
**RESILIENT-443** (#4628, "implement registry loading from JSON file"), and
covers the substance of every AC:

1. **`Tier` enum + `PlaybookEntry` struct + `PlaybookRegistry` map** —
   present verbatim (`Tier::AutoHeal`/`Runbook`/`Escalate`,
   `PlaybookEntry { signal, tier, action, detect, verify,
   false_positive_class }`, `PlaybookRegistry { entries: HashMap<String,
   PlaybookEntry> }`).
2. **Public lookup API** — `PlaybookRegistry::get_entry` exists, keyed on
   `&str` rather than a closed `Signal` enum. This is an intentional
   divergence from the gap's literal AC, not a gap: per
   `docs/design/DUTY_OFFICER.md` §3, the registry is **data-driven** —
   signals are "ambient kind OR a derived metric," loaded at runtime from
   `docs/process/PLAYBOOK_REGISTRY.yaml` (13 signals today, growing). A fixed
   `Signal` enum would have to be recompiled for every new signal the fleet
   adds, which contradicts the extensibility the registry was built for.
   `&str` keys are the correct shape for the shipped design.
3. **Unit test coverage for lookup** — `tests::load_registry_reads_entries`
   (and `tests::load_registry_reads_fixture_file`) assert `get_entry` returns
   the right entry for a known signal and `None` for an unknown one —
   covering the same ground as the requested `tests::registry_lookup`.

Closing RESILIENT-442 rather than adding a second, enum-keyed
`PlaybookRegistry` next to the one already in production use by the
duty-officer loop (`scripts/coord/duty-officer-loop.sh`) and its CI coverage
(`scripts/ci/test-duty-officer-loop.sh`).
