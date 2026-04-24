# Intent → action patterns (Discord)

This doc helps **Chump** (Discord bot) and **Cursor** (when editing bot behavior) map natural-language user intent to the right action. Use it to reduce over-asking and to take the right action when intent is clear.

## Principles

- **Infer intent** from the user's message; when it's clear, **do the action** and confirm briefly.
- **Only ask** when genuinely ambiguous (e.g. two possible targets) or when the action is destructive/irreversible.
- **Reply quality:** Concise answers; optional structured follow-up (e.g. "Created task 3. Say 'work on it' to start.").

## Pattern → action mapping

| User intent (examples) | Inferred action | Tool / behavior |
|------------------------|-----------------|------------------|
| "Can you …", "Could you …", "Please …" + *task* | Do the task | Parse the verb and object; e.g. "create a task", "run …", "remind me …". |
| "Add a task: …", "Create a task: …", "New task: …" | Create task | `task_create` (or equivalent); body = rest of message. |
| "Remind me to …", "Remind me that …" | Store memory / reminder | Memory store with reminder semantics if available; else task. |
| "Run …", "Execute …", "Can you run …" | Run a command | `run_cli` if allowed; confirm command before running if dangerous. |
| "What's the status of …", "Is … done?" | Answer from state | Check task queue, memory, or logs; reply concisely. |
| "Reboot yourself", "Self-reboot" | Self-reboot bot | Run `scripts/self-reboot.sh` via run_cli (see ROADMAP.md). |
| "Use Cursor to fix …", "Let Cursor fix …" | Delegate to Cursor | `run_cli` with `agent -p "..." --force`; see [CHUMP_CURSOR_FLEET.md](CHUMP_CURSOR_FLEET.md) §3 and mixed-squad notes in [CURSOR_CLAUDE_COORDINATION.md](CURSOR_CLAUDE_COORDINATION.md). |
| "Work on task 3", "Start task 3" | Focus on task | Set current task / start work on that task. |
| Vague or multiple possible actions | Ask once, briefly | e.g. "Do you want me to (a) create a task or (b) run that command?" |

## Adding or refining patterns

- Add new rows to the table when new intents are observed or requested.
- Keep examples in natural language; Chump uses NLP/soul to map messages to these patterns.
- If Cursor changes bot code, update this doc so Chump's behavior and docs stay aligned.

## References

- **docs/INTENT_CALIBRATION.md** — Labeled eval set + scoring for pilots (H1 wedge).
- **docs/ROADMAP.md** — Bot capabilities (understand intent, reduce over-asking).
- **docs/archive/2026-04/briefs/CHUMP_PROJECT_BRIEF.md** — Current focus (infer intent, take action when clear).
- **AGENTS.md** — When Chump delegates to Cursor (e.g. complex fixes, cursor_improve).
