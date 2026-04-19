# PWA Wedge Path

**No Discord required.** This doc defines the minimal viable path for a new user to reach the "aha moment" using only the PWA (web UI). Companion to [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) and [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).

## What is the wedge?

The wedge is the moment a user completes their first autonomous task end-to-end — from natural language → Chump plans → Chump executes → result returned — without touching Discord or a terminal.

For external pilots, reaching **N3 tier** (3 sessions, 1 task completed) is the measurable proxy.

## Minimum path (PWA-only)

```
1. cargo build --release
2. CHUMP_HOME=/path/to/brain ./target/release/chump web --port 5173
3. Open http://localhost:5173
4. Type a task in the Tasks panel → Submit
5. Watch tool calls stream in the Activity feed
6. Confirm result in the response pane
```

No `.env` required beyond `CHUMP_HOME`. Ollama model (`qwen2.5:14b`) is the default backend — see [SETUP_AND_RUN.md](SETUP_AND_RUN.md) for the pull command.

## Discoverability improvements (shipped)

- **Tasks panel** in `web/index.html` surfaces task-create as a first-class action (not buried in text box)
- **Wedge hint banner** shown to sessions with 0 tasks completed
- Task shortcuts (e.g. "Summarize last 3 files I edited") pre-populate the input

These improvements are tracked as done in [ROADMAP.md](ROADMAP.md) under *PWA-first H1 path audit*.

## Remaining friction

| Friction | Impact | Fix |
|----------|--------|-----|
| `CHUMP_HOME` not set → WebView blank | High | `./run-web.sh` now checks and errors early |
| First `cargo build` 5–8 min, no progress | Medium | Golden path calls it out; LTO expected |
| Ollama pull (8GB) not in initial prereqs | Medium | EXTERNAL_GOLDEN_PATH.md §2 lists it |
| Memory search not available without embedding model | Low | Degraded gracefully; shown as "(embeddings disabled)" |

## In-app discoverability checklist

- [x] Tasks panel visible without scrolling on 1280px+ viewport
- [x] "Create task" button in hero position
- [x] Streaming tool-call progress shown during execution
- [x] Completion state clearly distinguished from in-progress
- [ ] Onboarding tooltip on first load (Tier 2 — [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md))
- [ ] "Try this" example task buttons

## See Also

- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) — full first-install walkthrough
- [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) — N1–N4 tier definitions and SQL queries
- [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) — planned PWA enhancements
- [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) — API surface the PWA calls
