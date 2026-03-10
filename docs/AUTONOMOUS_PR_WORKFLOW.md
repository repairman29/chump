# Autonomous PR Workflow: From Chatbot to Agent

This doc captures the design for Chump as an **autonomous contributor**: task queue, GitHub workflow tools, heartbeat-driven work, and safety.

---

## What’s Implemented

- **edit_file** — Exact string replacement: `path`, `old_str`, `new_str`. `old_str` must appear exactly once (use read_file first). Safer than full-file write. Audit: `chump_log::log_edit_file`.
- **gh tools** (when CHUMP_REPO + CHUMP_GITHUB_REPOS set): `gh_list_issues` (repo, label?, state?), `gh_create_branch` (name), `gh_create_pr` (title, body, base?), `gh_pr_checks` (pr_number), `gh_pr_comment` (pr_number, body). All wrap `gh` CLI; repo must be in allowlist.
- **Soul** — Autonomous-work guidelines in system prompt: read issue fully, run tests before/after edit, clear PR description, when uncertain set blocked and notify; default to caution on merges.

---

## The Core Missing Piece: Task Queue

Chump has no persistent “things I am trying to accomplish.” A **task** tool backed by SQLite (same pattern as memory DB) with states: `open → in_progress → blocked → done`.

- Table: `chump_tasks(id, title, description, repo, issue_number, status, created_at, updated_at, notes)`.
- Tool: `task` with actions `create`, `list` (filter by status), `update` (status, notes), `complete`.
- Heartbeat rounds: (1) pull highest-priority open task, (2) work on it (read, edit, test, push), (3) update state; if blocked, set blocked and DM owner.

---

## Autonomous PR Loop (Target)

1. `gh_list_issues` (e.g. label `chump` or `good-first-issue`) → pick one.
2. Memory recall: what do I already know about this codebase?
3. `gh_create_branch` (e.g. `fix/issue-47`).
4. read_file / list_dir / grep (run_cli) to find relevant code.
5. **edit_file** (old_str / new_str) for changes.
6. run_cli `cargo test` or `npm test`.
7. If green: git add, git_commit, git_push, **gh_create_pr**.
8. If red: diagnose, retry up to N times, or set task blocked.
9. Store learnings in memory; DM owner with PR link or blocker summary.

---

## Safety (Before Pushing to Main)

- **Short-term:** Only push to branches named `chump/*`; PRs require human approval (GitHub branch protection). `DRY_RUN=1`: skip `git push` and `gh pr create`, log what would have been done. Max 1 PR per heartbeat round.
- **Medium-term:** `CHUMP_GITHUB_REPOS` allowlist (already used). Require tests to pass before push (run_cli). Optional: delegate(summarize) on own diff for PR body self-audit.
- **Longer-term:** After push, poll `gh pr checks`; try to fix failures up to 3 times; if still blocked, DM with full context.

---

## Heartbeat → Drive Loop

Replace static `PROMPTS` in `heartbeat-learn.sh` with a **dynamic** flow:

1. Check open GitHub issues (label `chump` or `good-first-issue`) → pick one.
2. Check CI status on open PRs → fix any that are red.
3. Check task queue for open/blocked → resume.
4. If nothing urgent: research a topic relevant to the repo.
5. End-of-round summary: DM owner (notify_owner) with what was accomplished or blocked.

Add a `chump` label to issues you want Chump to attempt; he picks them up in the next heartbeat.

---

## DM on Completion / Block

Reuse Discord DM (e.g. `CHUMP_READY_DM_USER_ID`). Add a **notify_owner** path (or env) so heartbeat (or the agent) can send a structured summary: “Opened PR #89 for issue #47. Tests pass.” or “Blocked on issue #47: CI red, couldn’t fix after 3 tries.”

---

## Summary: Next Code Steps

| Order | Item                                                                 | Status  |
| ----- | -------------------------------------------------------------------- | ------- |
| 1     | edit_file tool                                                       | Done    |
| 2     | gh tools (list_issues, create_pr, pr_checks, comment, create_branch) | Done    |
| 3     | Task queue SQLite + task tool                                        | Pending |
| 4     | Heartbeat: dynamic prompts from issues + task queue                  | Pending |
| 5     | notify_owner (DM on completion/block)                                | Pending |
| 6     | Soul: autonomous guidelines                                          | Done    |

See [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) and [CHUMP_IDENTITY](CHUMP_IDENTITY.md) for repo awareness and personality.
