# Autonomous PR Workflow: From Chatbot to Agent

This doc captures the design for Chump as an **autonomous contributor**: task queue, GitHub workflow tools, heartbeat-driven work, and safety.

---

## What's Implemented

- **edit_file** — Exact string replacement: `path`, `old_str`, `new_str`. `old_str` must appear exactly once (use read_file first). Safer than full-file write. Audit: `chump_log::log_edit_file`.
- **gh tools** (when CHUMP_REPO + CHUMP_GITHUB_REPOS set): `gh_list_issues` (repo, label?, state?), `gh_create_branch` (name), `gh_create_pr` (title, body, base?), `gh_pr_checks` (pr_number), `gh_pr_comment` (pr_number, body). All wrap `gh` CLI; repo must be in allowlist.
- **Task queue** — SQLite-backed `chump_tasks` table + `task` tool (create, list, update, complete). States: `open → in_progress → blocked → done | abandoned`. Same DB as memory (`sessions/chump_memory.db`).
- **Notify** — `notify` tool queues a DM to `CHUMP_READY_DM_USER_ID`. Discord handler sends it after the turn. CLI mode: logged only.
- **Soul** — Autonomous-work guidelines in system prompt: read issue fully, run tests before/after edit, clear PR description, when uncertain set blocked and notify; default to caution on merges.
- **Self-improve heartbeat** — `scripts/heartbeat-self-improve.sh`: dynamic prompts that drive Chump through a work loop (check queue → find opportunities → do work → test → commit → report). Three round types cycle: **work** (queue-driven), **opportunity** (scan codebase for improvements), **research** (web search + store learnings). Supports DRY_RUN, kill switch, retry.

---

## How It Works

### Task Sources

Chump gets work from three places:

1. **You assign tasks** — Tell Chump in Discord or CLI: "Create a task: add unit test for wasm_calc_tool timeout." He uses the task tool to queue it.
2. **Chump finds opportunities** — In opportunity rounds, he scans for TODOs, unwrap() calls, clippy warnings, failing tests, missing docs, and unchecked roadmap items. He creates tasks for what he finds.
3. **GitHub issues** (optional) — Label issues with `chump` or `good-first-issue`. In work rounds, Chump can check `gh_list_issues` and create tasks from them.

### Round Types

The self-improve heartbeat cycles through three round types: **work, work, opportunity, work, work, research**.

- **Work rounds:** Check task queue → pick highest-priority open task → read code → edit → test → commit → update task → notify if notable.
- **Opportunity rounds:** Scan codebase (TODOs, unwrap, clippy, roadmap) → create up to 3 tasks → work on the most impactful one.
- **Research rounds:** Pick a topic relevant to recent work → web_search → store learnings in memory → optionally create a task if a learning suggests an improvement.

### Autonomous PR Loop

1. Pick a task (from queue, or create one from opportunity scan).
2. Memory recall: what do I already know about this area?
3. `gh_create_branch` (e.g. `chump/task-12-fix-unwrap`).
4. `read_file` / `list_dir` / `run_cli grep` to find relevant code.
5. `edit_file` (old_str / new_str) for changes.
6. `run_cli "cargo test"` — must pass before commit.
7. If green: `git_commit`, `git_push`, optionally `gh_create_pr`.
8. If red: diagnose, retry up to 3 times, or set task blocked.
9. `episode log` with summary; `notify` owner with PR link or blocker.

---

## Safety

- **Branch policy:** Only push to branches named `chump/*`. PRs require human merge (GitHub branch protection).
- **DRY_RUN:** `HEARTBEAT_DRY_RUN=1` or `DRY_RUN=1` — skip `git push` and `gh pr create`, log what would have been done.
- **Max 1 change per round.** Chump does not try to do everything at once.
- **Repo allowlist:** `CHUMP_GITHUB_REPOS` restricts which repos Chump can operate on.
- **Tests required:** Chump always runs `cargo test` before committing. If tests fail, he does not push.
- **Kill switch:** `touch logs/pause` or `CHUMP_PAUSED=1` — heartbeat skips rounds; Discord says "I'm paused."
- **Blocked → notify:** When stuck, Chump sets the task to blocked with notes and DMs the owner.

---

## Running the Self-Improve Heartbeat

```bash
# Standard (8h, 45 min rounds)
./scripts/heartbeat-self-improve.sh

# Custom duration and interval
HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=30m ./scripts/heartbeat-self-improve.sh

# Quick test (2 min, 30s rounds)
HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-self-improve.sh

# Dry run (no push, no PR)
HEARTBEAT_DRY_RUN=1 ./scripts/heartbeat-self-improve.sh

# With retry on transient failures
HEARTBEAT_RETRY=1 ./scripts/heartbeat-self-improve.sh
```

**Log:** `logs/heartbeat-self-improve.log` (append). Each round logs type (work/opportunity/research), start, ok/fail.

**Chump Menu:** "Start self-improve (8h)" and "Start self-improve (quick 2m)" alongside "Start heartbeat (8h learning)" in the Chump & heartbeat section.

---

## Giving Chump Tasks

In Discord or CLI, just tell him:

```
Create a task: add unit test for delegate_tool timeout handling
Create a task: refactor memory_tool to use a shared reqwest client
Create a task: update README to document the self-improve heartbeat
```

He'll use the task tool to queue them. Next self-improve round, he picks up the highest-priority open task.

To check the queue: "List your tasks" or "Show me open tasks."
To reprioritize: "Update task 5 to blocked with notes: waiting on upstream fix."

---

## Summary: Implementation Status

| Order | Item                                                                 | Status      |
| ----- | -------------------------------------------------------------------- | ----------- |
| 1     | edit_file tool                                                       | **Done**    |
| 2     | gh tools (list_issues, create_pr, pr_checks, comment, create_branch) | **Done**    |
| 3     | Task queue SQLite + task tool                                        | **Done**    |
| 4     | Notify tool (DM owner on completion/block)                           | **Done**    |
| 5     | Soul: autonomous guidelines                                          | **Done**    |
| 6     | Self-improve heartbeat (dynamic prompts, round types)                | **Done**    |
| 7     | Chump Menu: "Start self-improve" button                              | **Done**    |
| 8     | Tier 5 autonomy test (full self-improve cycle)                       | **Pending** |

See ROADMAP_DOGFOOD_SELF_IMPROVE and CHUMP_IDENTITY (in chump-repo/docs when present) for repo awareness and personality.
