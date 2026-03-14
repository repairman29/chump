# Wishlist

**Implemented:** schedule (chump_scheduled + fire_at/4h/2d/30m, list, cancel; heartbeat calls schedule_due → session prompt → schedule_mark_fired), diff_review (git diff → worker code-review prompt → self-audit for PR), run_test (src/run_test_tool.rs), read_url (src/read_url_tool.rs), ask_jeff (src/ask_jeff_tool.rs + ask_jeff_db; context_assembly injects recent answers). Git diff at startup in context_assembly (watch-style context). Emotional memory: episode sentiment + recent_by_sentiment; recent frustrating episodes in context_assembly for failure-pattern check; ego frustrations in context.

**Backlog (close loops: see results, react, ask when uncertain):**

| Item                | Status      | Note                                                                       |
| ------------------- | ----------- | -------------------------------------------------------------------------- |
| screenshot + vision | Not started | Headless/screencap + vision API to verify UI, read error dialogs           |
| run_test            | Done        | See Implemented above (src/run_test_tool.rs)                              |
| read_url            | Done        | See Implemented above (src/read_url_tool.rs)                              |
| watch_file (full)   | Partial     | Log Jeff’s edits; next session sees “Jeff edited X since last run”         |
| introspect          | Not started | Query recent tool-call history (ground truth vs episodes)                  |
| sandbox             | Not started | Clean copy (cp or Docker), try, teardown; no polluting working tree        |
| Emotional memory    | Done        | Episode has sentiment; add search by sentiment / “list frustrations”       |
| ask_jeff            | Done        | Async Q/A thread; next session starts with “Jeff’s answers since last run” |
