---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Autonomous PR Workflow

How Chump creates branches, opens PRs, and merges them autonomously. Requires `CHUMP_GITHUB_REPOS` and `GITHUB_TOKEN` in `.env`.

## Setup

```bash
# .env
CHUMP_GITHUB_REPOS=jeffadkins/Chump
GITHUB_TOKEN=ghp_xxx...
```

Add repo to `CHUMP_GITHUB_REPOS` (comma-separated for multi-repo). Chump uses the `github_*` tools to list issues, create branches, open PRs.

## Ship pipeline

Agents use `scripts/bot-merge.sh --gap <GAP-ID> --auto-merge`:

1. `gap-claim.sh <GAP-ID>` — write lease file
2. `gap-preflight.sh <GAP-ID>` — verify gap is open and unclaimed
3. Implement changes in linked worktree
4. `chump-commit.sh <files> -m "msg"` — commit without stomping other agents
5. `bot-merge.sh --gap <GAP-ID> --auto-merge` — rebase, fmt, clippy, push, PR, enable auto-merge

**Never push directly to main.** All agent PRs go through the merge queue ([MERGE_QUEUE_SETUP.md](MERGE_QUEUE_SETUP.md)).

## Approval gates

Chump can request peer approval (Mabel or human) before pushing:

```bash
# .env — tools that require approval before execution
CHUMP_PEER_APPROVE_TOOLS=git_push,merge_pr
```

When a tool in this list is called:
1. Chump writes `brain/a2a/pending_approval.json`
2. Mabel's Verify round picks it up via SSH, runs tests, calls `POST /api/approve`
3. Chump proceeds; Discord/web human approval also works

## Code review gate

`INFRA-AGENT-CODEREVIEW` (in-queue) wires `scripts/code-reviewer-agent.sh` into the merge pipeline. Until then, review is manual or skipped for doc-only PRs.

## Atomic PR discipline

Once `bot-merge.sh` runs and auto-merge is armed, **do not push more commits**. GitHub captures the branch at first-CI-green and drops everything pushed after. See CLAUDE.md footnote `[^pr52]` for the historical context (PR #52, 11 commits lost).

## See Also

- [CLAUDE.md](../CLAUDE.md) — session rules and hard limits
- [AGENT_COORDINATION.md](AGENT_COORDINATION.md) — lease system, ambient stream
- [MERGE_QUEUE_SETUP.md](MERGE_QUEUE_SETUP.md) — GitHub merge queue config
- [OPERATIONS.md](OPERATIONS.md) — heartbeat scripts, mabel-farmer peer approval
