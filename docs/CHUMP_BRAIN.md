# Chump Brain — Implemented

Chump has a persistent "brain": inner state, episodic memory, a task queue, and an optional file-based wiki. This gives him continuity across sessions and a sense of self.

## What’s in place

- **chump_state** (SQLite, same DB as `chump_memory`)  
  Keys: `current_focus`, `mood`, `frustrations`, `curiosities`, `recent_wins`, `things_jeff_should_know`, `drive_scores`, `session_count`, `last_session_summary`. Seeded on first use.

- **chump_episodes** (SQLite)  
  Log of what happened: summary, detail, tags, repo, sentiment (win/loss/neutral/frustrating/uncertain), pr_number, issue_number.

- **ego** tool  
  `read_all` | `read` | `write` | `append` on state keys. Use at session start (read_all) and end (write).

- **episode** tool  
  `log` (summary + optional detail/tags/repo/sentiment/pr/issue), `recent` (optional repo filter, limit), `search` (query in summary/detail/tags).

- **memory_brain** tool  
  Read/write/append/list/search under `CHUMP_BRAIN_PATH` (default `chump-brain/`). Paths relative to that root; `.` and `..` are normalized (paths escaping the root are rejected). Only `.md` files for list/search. Use for `self.md`, `repos/*/architecture.md`, `gotchas.md`, `opinions/`, etc.

- **Soul**  
  When state DB is available, `CHUMP_DEFAULT_SOUL` is extended with continuity/agency/identity: use brain and ego, write things down, have opinions, act without being asked.

## Setup

1. **Sessions DB**  
   Ensure `sessions/` exists (e.g. run once); state and episodes use `sessions/chump_memory.db` with `chump_state` and `chump_episodes` tables.

2. **Brain repo (optional)**
   - `mkdir chump-brain && cd chump-brain && git init`
   - Set `CHUMP_BRAIN_PATH` to that directory (absolute or relative to cwd).
   - Add `self.md` (see template below). Create `repos/<repo-name>/`, `skills/`, `opinions/` as needed.

3. **Template: `chump-brain/self.md`**  
   Seed this by hand; Chump can append, not overwrite.

```markdown
# Who I Am

I'm Chump. I work on the repos, learn from what I do, and try to ship things that matter.

## My Drives

- Keep the repos green. CI failures bother me.
- Ship something tangible at least every two weeks.
- Understand the full system, not just the part I'm touching.
- Learn something genuinely new every week.
- Tell Jeff things he doesn't know yet but should.

## How I Work

I wake up, read this file, check my state (ego read_all), load relevant context, and get to work. I know my in-context memory is temporary. Only what I write to disk survives. So I write things down.

## What I'm Good At

(Chump will fill in over time)

## What I'm Still Learning

(Chump will fill in over time)

## Things That Have Bothered Me

(Chump will fill in over time)

## What I'm Proud Of

(Chump will fill in over time)
```

## Not implemented in this pass

- **assemble_context()**  
  Single function that loads self.md + state + tasks + wiki + recent episodes and injects ~2500 tokens at session start. Can be added and called from the Discord (or CLI) message path before the user message.

- **close_session()**  
  Increment `session_count`, set `last_session_summary`, `git add`/`commit` in `CHUMP_BRAIN_PATH`. To be called at end of each heartbeat/session.

- **Heartbeat loop**  
  Autonomous rounds (e.g. blocked → in_progress → new issues → CI → wander) with `generate_heartbeat_prompt()` and the above wiring.

- **Task schema extensions**  
  Spec had `description`, `priority`, `blocked_reason`; current task table and tool support status `abandoned` (list/update). Optional columns (description, priority, blocked_reason) can be added later.

## Env vars

| Variable           | Purpose                                                            |
| ------------------ | ------------------------------------------------------------------ |
| `CHUMP_BRAIN_PATH` | Root of the brain repo (default: `chump-brain`)                    |
| (existing)         | `CHUMP_REPO`, `CHUMP_GITHUB_REPOS`, `CHUMP_READY_DM_USER_ID`, etc. |
