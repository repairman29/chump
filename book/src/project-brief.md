# Chump project brief

Used with **docs/ROADMAP.md**. Doc index: [docs/README.md](docs/README.md). Read by the self-improve heartbeat (work, opportunity, cursor_improve), the Discord bot, and Cursor agents to stay focused. The roadmap holds prioritized goals and unchecked items; this brief holds conventions and current focus. For the single vision and build/deploy order (Horizon 1 → 2 → 3), see [docs/ECOSYSTEM_VISION.md](docs/ECOSYSTEM_VISION.md).

## Current focus

- **North star:** Improve **implementation** (ship working code/docs), **speed** (faster rounds, less friction), **quality** (tests, clippy, clarity), and **bot capabilities**—especially **understanding the user in Discord and acting on intent** (infer what they want from natural language; create tasks, run commands, or answer without over-asking).
- **Roadmap:** Read **docs/ROADMAP.md** for what to work on. Pick from unchecked items, the task queue, or codebase scans (TODOs, clippy, tests). Do not invent your own roadmap. At the start of work, opportunity, and cursor_improve rounds, read **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md** so choices align with current focus and conventions.
- In Discord: infer intent from natural language; take action (task create, run_cli, memory store, etc.) when clear; only ask when genuinely ambiguous. See **docs/INTENT_ACTION_PATTERNS.md** for intent→action examples.
- Add or update tasks in Discord: "Create a task: …" — Chump picks them up in the next heartbeat round.
- Optional: add repo to `CHUMP_GITHUB_REPOS` and set `GITHUB_TOKEN` (see `.env.example` and docs/AUTONOMOUS_PR_WORKFLOW.md).
- Improve the product and the Chump–Cursor relationship: write Cursor rules (.cursor/rules), AGENTS.md, and docs; use Cursor to implement; improve handoffs. See docs/ROADMAP.md for concrete items.
- **Push and self-reboot:** To have the bot push to the Chump repo and restart with new capabilities: add the repo to `CHUMP_GITHUB_REPOS`, set `GITHUB_TOKEN`, set `CHUMP_AUTO_PUSH=1`. After pushing bot-affecting changes, the bot may run `scripts/self-reboot.sh` (or the user can say "reboot yourself"). See docs/ROADMAP.md "Push to Chump repo and self-reboot".
- **Roles should be running:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender (navbar app → Roles tab). Schedule them with launchd/cron for 24/7 help; see docs/OPERATIONS.md.
- **Fleet symbiosis:** Mutual supervision, single report, hybrid inference, peer_sync loop, Mabel self-heal — see ROADMAP "Fleet / Mabel–Chump symbiosis".

## Conventions

- Tool usage, naming, Git (chump/* branches, PRs): see AUTONOMOUS_PR_WORKFLOW and .cursor/rules when present.
- When editing the roadmap: use patch_file (or write_file) to change `- [ ]` to `- [x]` when an item is done.
- **Cursor:** When working in this repo, read **docs/ROADMAP.md**, **AGENTS.md** (Chump–Cursor collaboration and handoff format), and **.cursor/rules** for what to work on and how to hand off. For roles, shared context, and the full communication protocol see **docs/CHUMP_CURSOR_PROTOCOL.md**.

## Quality

- Edits should include **tests or docs** where appropriate (new behavior → test; config/ops → doc).
- **PR descriptions** and **handoff summaries** (to Chump or Cursor) should be clear: what changed, outcome, and suggested next steps (e.g. "Run battle_qa again; mark task #3 done").
