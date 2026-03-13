# Chump Brain

Persistent state, episodes, task queue, and optional file wiki. Same DB as memory: `sessions/chump_memory.db` → tables `chump_state`, `chump_episodes`, `chump_tasks`, `chump_scheduled`.

## State and tools

| Table / tool       | Purpose                                                                                                                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **chump_state**    | Keys: current_focus, mood, frustrations, curiosities, recent_wins, things_jeff_should_know, drive_scores, session_count, last_session_summary. Seeded on first use.                                    |
| **ego**            | `read_all` \| `read` \| `write` \| `append` on state keys. Use at session start/end.                                                                                                                   |
| **chump_episodes** | Log: summary, detail, tags, repo, sentiment (win/loss/neutral/frustrating/uncertain), pr_number, issue_number.                                                                                         |
| **episode**        | `log`, `recent` (repo filter, limit), `search` (summary/detail/tags).                                                                                                                                  |
| **memory_brain**   | Read/write/append/list/search under `CHUMP_BRAIN_PATH` (default `chump-brain/`). Paths relative to root; only `.md` for list/search. Use for self.md, repos/\*/architecture.md, gotchas.md, opinions/. |
| **Soul**           | When state DB is present, default soul gains continuity/agency: use brain and ego, write things down, act without being asked.                                                                         |

## Setup

1. **Sessions** — Run once so `sessions/` exists; state/episodes use the same DB.
2. **Brain repo (optional)** — `mkdir chump-brain && cd chump-brain && git init`; set `CHUMP_BRAIN_PATH`. Add `self.md` (see below).

**Template `chump-brain/self.md`** (Chump can append, not overwrite):

```markdown
# Who I Am

I'm Chump. I work on the repos, learn from what I do, and try to ship things that matter.

## My Drives

- Keep the repos green. CI failures bother me.
- Ship something tangible at least every two weeks.
- Understand the full system. Learn something new every week.
- Tell Jeff things he doesn't know yet but should.

## How I Work

I wake up, read this file, check my state (ego read_all), load context, and get to work. Only what I write to disk survives. So I write things down.

## What I'm Good At / Still Learning / Bothered Me / Proud Of

(Chump fills in over time)
```

## Env

| Variable           | Purpose                                  |
| ------------------ | ---------------------------------------- |
| `CHUMP_BRAIN_PATH` | Brain wiki root (default: `chump-brain`) |

## Shared brain (Mabel + Chump)

When `chump-brain/` is a git repo with a remote both can push to, both agents share the same wiki and intel notes.

### Brain repo (this project)

- **GitHub repo:** [github.com/repairman29/chump-brain](https://github.com/repairman29/chump-brain) (private). Created from the Mac `chump-brain/` directory; initial commit has `self.md` and `repos/`.
- **Mac:** `chump-brain/` in the Chump repo is the clone; `heartbeat-self-improve.sh` runs `git -C chump-brain pull` before each round. Push from Mac when you add content: `git -C chump-brain add -A && git commit -m "..." && git push`.
- **Pixel:** Clone lives at `~/chump/chump-brain`. The Pixel’s SSH public key (`~/.ssh/id_ed25519.pub`) is added as a **deploy key** (read/write) on the GitHub repo so clone/push works without a token. `heartbeat-mabel.sh` runs `git -C chump-brain pull` at round start and `git add -A && git commit -m "mabel sync" && git push` at round end when there are changes.
- **CHUMP_BRAIN_PATH:** Default is `chump-brain` (relative to repo root on Mac, or `~/chump/chump-brain` on Pixel). Set only if you use a different path.

### Sync behavior

- **Mabel (Pixel):** At round start `git -C chump-brain pull`; at round end, if there are changes, `git add -A && git commit -m "mabel sync" && git push`.
- **Chump (Mac):** Before each heartbeat round `git -C chump-brain pull`.

Future: assemble_context(), close_session(), heartbeat loop wiring, task schema (description, priority, blocked_reason).
