# Wishlist

**Implemented:** schedule (chump_scheduled + fire_at/4h/2d/30m, list, cancel; heartbeat calls schedule_due → session prompt → schedule_mark_fired), diff_review (git diff → worker code-review prompt → self-audit for PR).

**Backlog (close loops: see results, react, ask when uncertain):**

| Item                | Status      | Note                                                                       |
| ------------------- | ----------- | -------------------------------------------------------------------------- |
| screenshot + vision | Not started | Headless/screencap + vision API to verify UI, read error dialogs           |
| run_test            | Not started | Structured pass/fail/error, which tests failed; wrap cargo/npm test        |
| read_url            | Not started | Fetch docs page (strip nav/footer); run_cli+curl is half-possible          |
| watch_file          | Not started | Log Jeff’s edits; next session sees “Jeff edited X since last run”         |
| introspect          | Not started | Query recent tool-call history (ground truth vs episodes)                  |
| sandbox             | Not started | Clean copy (cp or Docker), try, teardown; no polluting working tree        |
| Emotional memory    | Partial     | Episode has sentiment; add search by sentiment / “list frustrations”       |
| ask_jeff            | Not started | Async Q/A thread; next session starts with “Jeff’s answers since last run” |
