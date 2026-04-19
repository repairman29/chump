# UI Manual Test Matrix (20 scenarios)

Manual test checklist for the Chump PWA. Run before releasing a new build or after significant UI changes. Machine-verifiable subset is in `scripts/battle-qa.sh`; this matrix covers the human-in-the-loop and visual scenarios.

Companion docs: [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md), [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md).

## Test environment

- Browser: Chrome (latest), Safari (latest)
- Server: `./run-web.sh` (default model: Ollama 14B)
- Viewport: 1280×800 (laptop) + 390×844 (mobile)

## Scenarios

| # | Scenario | Steps | Expected | Pass/Fail |
|---|----------|-------|----------|-----------|
| 1 | Page load | Open http://localhost:5173 | Dashboard visible within 2s; no console errors | |
| 2 | Task submit — simple | Type "What files did I edit today?" → Enter | Response streams; no spinner freeze | |
| 3 | Task submit — tool use | Type "List open gaps" | Tool call visible in activity feed; result returned | |
| 4 | Streaming deltas | Type a long-answer question | Text streams character by character; no flash | |
| 5 | Multi-turn | Two back-to-back messages in same session | Both messages visible; context maintained | |
| 6 | Task create via panel | Click Tasks → "+ New task" → fill form → Submit | Task appears in list; status "pending" then "done" | |
| 7 | Memory search | Type "What did I work on last week?" | Memory hit shown with timestamp | |
| 8 | Error recovery | Kill vLLM mid-response | Cascade to Ollama; response resumes or errors cleanly | |
| 9 | Mobile viewport | Resize to 390px | No overflow; input accessible; results readable | |
| 10 | Dark mode | Toggle system dark mode | UI respects prefers-color-scheme | |
| 11 | File paste | Paste an image into chat | Image thumbnail shown; vision query executes | |
| 12 | Conversation history | Reload page | Previous session visible in history panel | |
| 13 | Fleet status | Check Fleet section | Mabel status shown (online/offline); last seen timestamp | |
| 14 | Autonomy status | Check Activity feed | Ship heartbeat round visible; last task status shown | |
| 15 | Discord adapter indicator | Sidebar | Discord connected/disconnected badge shown | |
| 16 | Settings panel | Open ⚙ | Model name, cascade providers, env var summary visible | |
| 17 | Cost tracker | After a task | Cost badge shows non-zero value | |
| 18 | Cancel task | Submit task → click Cancel | Task stops; no orphaned tool calls | |
| 19 | Battle QA trigger | Settings → "Run battle QA (3)" | Results appear in activity feed within 60s | |
| 20 | mistral.rs mode | Set `CHUMP_INFERENCE_BACKEND=mistralrs` → restart | Same scenarios 2–5 pass with mistral.rs backend | |

## Known failures (as of 2026-04-19)

| # | Issue | Workaround |
|---|-------|------------|
| 17 | Cost shows $0.00 for all providers (COMP-014) | None until COMP-014 shipped |
| 20 | mistral.rs mode not stable in streaming + tool-call path | Use Ollama backend for tool-heavy tasks |

## See Also

- [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md) — browser vs Tauri parity
- [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) — inference backend benchmarks
- [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) — planned PWA enhancements
