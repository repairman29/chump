---
name: harvester
description: Chump's fleet cartographer — operate the 76-repo arsenal catalog. Use to (1) refresh the catalog after a fleet change, (2) write a Cross-Pollination Brief (CP-NNN) harvesting a primitive from one repo to another, (3) check whether a proposed change duplicates prior art that already exists in the arsenal, (4) deep-scan an unexplored cluster. **This skill is a thin wrapper over `scripts/arsenal/harvest.sh`** (the harness-neutral CLI). Examples that should trigger this skill, "refresh the arsenal", "is there already a /foo primitive in our repos?", "write a harvest brief for X", "check INFRA-NNNN against the arsenal".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
---

# /harvester — Chump Fleet Cartographer

The Harvester is a permanent capability of Chump-the-engine, **not** a Claude-Code-only feature. The canonical surface is the harness-neutral shell CLI at [`scripts/arsenal/harvest.sh`](../../../scripts/arsenal/harvest.sh) — any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that parses `$ARGUMENTS` and shells out. The protocol lives at [`docs/arsenal/HARVESTER.md`](../../../docs/arsenal/HARVESTER.md). The catalog lives at [`docs/arsenal/GLOBAL_ARSENAL.json`](../../../docs/arsenal/GLOBAL_ARSENAL.json). The harvest queue lives at [`docs/arsenal/HARVEST_ROADMAP.md`](../../../docs/arsenal/HARVEST_ROADMAP.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS` and shell out to `scripts/arsenal/harvest.sh`. Default subcommand if empty: `scan`. If `$ARGUMENTS` looks like a gap ID (e.g. `INFRA-NNNN`), treat as `check INFRA-NNNN`.

```bash
# Simple pass-through:
scripts/arsenal/harvest.sh $ARGUMENTS
```

## Subcommands (full reference: `scripts/arsenal/harvest.sh help`)

| Subcommand | What it does | When to dispatch the `harvester` Agent for follow-up |
|---|---|---|
| `scan` | Refresh `docs/arsenal/raw/github_repos.json` from `gh repo list` and rebuild the catalog | After scan, summarize counts, new alerts, and any new duplications back to the user |
| `check <topic>` | Print arsenal overlap with a topic — primitives index, cluster keywords, repo descriptions, **plus** roadmap+CP brief grep. Exit 0 if matches found, exit 1 if none | If matches are found, the user usually wants a recommended Smart-Harvest route — dispatch the agent to draft one |
| `brief <src> <target>` | Scaffold a Cross-Pollination Brief stub at `docs/arsenal/cross-pollination/CP-NNN-*.md` | Dispatch the agent to fill in the TODO sections by reading the source repo |
| `deep-scan <cluster>` | List repos in cluster with health metadata | For real deep-reads (file contents, not just metadata), dispatch the agent with multiple parallel `Explore` subagents per repo |
| `list-clusters` | Print all 11 known clusters | — |

## Behavior rules

- **Surface text from `harvest.sh` to the user directly.** Don't re-paraphrase. The exit codes are meaningful.
- **Use the Harvester voice when reporting.** "Speak with authority. Cite repo + file + commit. Treat re-implementation as a discovery failure."
- **If the user asks for something the CLI doesn't yet support** (e.g. "deep-scan all 45 unexplored repos"), dispatch the `harvester` Agent (`subagent_type: harvester`) to do it — the agent has broader tool access for parallel scouting.
- **Never bypass `scripts/arsenal/harvest.sh`.** All catalog reads/writes flow through it so future productization (INFRA-1823) can replace the shell with a Rust subcommand without breaking the contract.
