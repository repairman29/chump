# Chump roadmap

**This file is the single source of truth for what to work on.** Heartbeat (work, opportunity, cursor_improve rounds), the Discord bot, and Cursor agents should read this file—and `docs/CHUMP_PROJECT_BRIEF.md` for focus and conventions—to know what they're doing. Do not invent your own roadmap; pick from the unchecked items below, from the task queue, or from codebase scans (TODOs, clippy, tests).

**North star:** Roadmap and focus should improve **implementation** (ship working code and docs), **speed** (faster rounds, less friction, quicker handoffs), **quality** (tests, clippy, error handling, clarity), and **bot capabilities**—especially **understanding the user in Discord and taking action from intent** (infer what they want from natural language; create tasks, run commands, or answer without over-asking).

## How to use this file

- **Chump (heartbeat / Discord):** In work rounds, use the task queue first; when the queue is empty or in opportunity/cursor_improve rounds, read this file and `docs/CHUMP_PROJECT_BRIEF.md`, then create tasks or do work from the unchecked items.
- **Cursor (when Chump delegates or you're in this repo):** Read this file and `docs/CHUMP_PROJECT_BRIEF.md` when starting. Pick implementation work from the roadmap priorities or from the prompt Chump gave you. Align with conventions in CHUMP_PROJECT_BRIEF and `.cursor/rules/`.

## Current focus (align with CHUMP_PROJECT_BRIEF)

- **Implementation, speed, quality, bot capabilities:** Prioritize work that improves what we ship, how fast we ship it, how good it is, and how well the Discord bot understands and acts on user intent (NLP / natural language).
- Improve the product and the Chump–Cursor relationship: rules, docs, handoffs, use Cursor to implement.
- Task queue and GitHub (optional): create tasks from Discord or issues; use chump/* branches and PRs unless CHUMP_AUTO_PUBLISH is set.
- Keep the stack healthy: Ollama, embed server, battle QA self-heal, autonomy tests. **Run the roles in the background:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender (Chump Menu → Roles tab; schedule with launchd/cron per docs/OPERATIONS.md).

## Prioritized goals (unchecked = work to do)

### Bot capabilities (Discord: understanding and intent)

- [ ] Understand user intent in Discord: infer what the user wants (create task, run something, answer question, remember something) from natural language; take the right action (task create, run_cli, memory store, etc.) without asking for clarification when intent is clear.
- [ ] Document intent→action patterns: add examples or rules (e.g. in .cursor/rules or docs) so Chump and Cursor improve at parsing "can you …", "remind me …", "run …", "add a task …", etc.
- [ ] Reduce over-asking: when the user's message implies a clear action, do it and confirm briefly; only ask when genuinely ambiguous or dangerous.
- [ ] Improve reply quality and speed in Discord: concise answers, optional structured follow-ups (e.g. "I created task 3; say 'work on it' to start").

### Push to Chump repo and self-reboot

- [ ] Ensure Chump repo is in `CHUMP_GITHUB_REPOS` and `GITHUB_TOKEN` (or `CHUMP_GITHUB_TOKEN`) is set so the bot can git_commit and git_push to chump/* branches. Set `CHUMP_AUTO_PUSH=1` so the bot may push after commit without asking.
- [ ] After pushing changes that affect the bot (soul, tools, src): run `scripts/self-reboot.sh` to kill the current Discord process, rebuild release, and start the new bot so it runs with the latest capabilities. Invoke via run_cli: `nohup bash scripts/self-reboot.sh >> logs/self-reboot.log 2>&1 &`. Optional: set `CHUMP_SELF_REBOOT_DELAY=10` (seconds before kill). User can also say "reboot yourself" or "self-reboot" to trigger it. See docs/OPERATIONS.md.

### Product and Chump–Cursor

- [ ] Add or refine `.cursor/rules/*.mdc` so Cursor follows repo conventions and handoff format.
- [ ] Update AGENTS.md and docs (e.g. CURSOR_CLI_INTEGRATION.md, CHUMP_PROJECT_BRIEF.md) so Cursor and Chump have clear context.
- [ ] Improve handoffs: when Chump calls Cursor CLI, pass enough context in the prompt; document what works in docs.
- [ ] Run cursor_improve rounds (or Cursor) to implement one roadmap item at a time; mark done here when complete.

### Keep roles running (background help)

- [ ] Run Farmer Brown on a schedule (e.g. launchd every 120s) so the stack is diagnosed and repaired automatically. Run Heartbeat Shepherd, Sentinel, Memory Keeper, Oven Tender on their recommended schedules (see docs/OPERATIONS.md). Chump Menu → Roles tab shows all five; use launchd/cron for 24/7.

### Implementation, speed, and quality

- [ ] Reduce unwrap() in non-test code (grep; replace with proper error handling where appropriate).
- [ ] Fix or document TODOs in `src/` (grep -rn TODO src/).
- [ ] Keep battle QA green: run battle_qa self-heal when failing; fix tests or prompts.
- [ ] Clippy clean: run `cargo clippy` and fix warnings.
- [ ] Speed: shorten round latency where possible (prompt size, tool use batching, model choice); document what slows rounds.
- [ ] Quality: ensure edits include tests/docs where appropriate; clear PR descriptions and handoff summaries.

### Optional integrations

- [ ] GitHub: add repo to CHUMP_GITHUB_REPOS, set GITHUB_TOKEN; Chump can list issues, create branches, open PRs (see docs/AUTONOMOUS_PR_WORKFLOW.md).
- [ ] ADB tool: see docs/ROADMAP_ADB.md for Pixel/Termux companion; enable via CHUMP_ADB_* in .env.

### Backlog (see docs/WISHLIST.md)

- [ ] run_test tool: structured pass/fail, which tests failed (wrap cargo/npm test).
- [ ] read_url: fetch docs page (strip nav/footer) for research.
- [ ] Other wishlist items as prioritized.

## When you complete an item

- Uncheck → check the box in this file (edit_file: `- [ ]` → `- [x]`).
- If it was a task, set task status to done and episode log.
- Optionally notify if something is ready for review.

## Related docs

| Doc | Purpose |
|-----|---------|
| docs/CHUMP_PROJECT_BRIEF.md | Current focus, conventions, tool usage |
| docs/AUTONOMOUS_PR_WORKFLOW.md | Task queue, PR flow, round types |
| docs/CURSOR_CLI_INTEGRATION.md | How Chump invokes Cursor; timeouts, prompts |
| docs/ROADMAP_ADB.md | ADB tool design and roadmap |
| docs/WISHLIST.md | Backlog and future tools |
