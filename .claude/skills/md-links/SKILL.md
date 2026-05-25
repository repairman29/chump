---
name: md-links
description: Chump's docs link-integrity curator (curator-opus-md-links role) — scan docs/**/*.md for broken internal cross-references, broken external URLs, and stale INFRA-NNNN gap references; file follow-up gaps for cohorts of broken links; emit heartbeat. Use to (1) run a fast scan of docs/process/ for broken links; (2) run a full scan of the entire docs/ tree; (3) check whether specific anchors exist in a target file; (4) scan for stale gap references in docs; (5) emit a heartbeat so the orchestrator can confirm liveness. This skill is a thin wrapper over scripts/coord/md-links-loop.sh (the harness-neutral CLI). Examples that should trigger this skill: "check docs for broken links", "scan docs/process for dead references", "are there stale gap refs in the docs", "heartbeat from md-links curator", "does docs/foo.md have an anchor #bar".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# /md-links — Docs Link-Integrity Curator Loop

The md-links curator is one of the named Opus curators in Chump's role-scoped fleet (target / ci-audit / handoff / shepherd / decompose / harvester / md-links). The canonical surface is the harness-neutral shell CLI at `scripts/coord/md-links-loop.sh`. Any harness (Claude Code, opencode, codex, manual operator) invokes it the same way.

This slash command is a thin Claude-Code convenience that runs the work-your-lane protocol. The discipline lives at [`.claude/agents/md-links.md`](../../agents/md-links.md). The role-scoped fleet vision is at [`docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`](../../../docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md).

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → `scripts/coord/md-links-loop.sh tick`
- `scan` / `scan <path>` → `scripts/coord/md-links-loop.sh scan [path]`
- `heartbeat` → `scripts/coord/md-links-loop.sh heartbeat`
- `help` → `scripts/coord/md-links-loop.sh help`

```bash
scripts/coord/md-links-loop.sh $ARGUMENTS
```

Surface stdout from the script directly to the user — don't paraphrase. Exit codes are meaningful (0 = broken links found or heartbeat OK; 1 = no broken links found / clean; 2 = bad subcommand or missing arg; 3 = state missing / docs dir not found).

## What the script checks

### Internal cross-references

For every `[text](path.md)` and `[text](path.md#anchor)` link in the scanned markdown files, the script verifies:

1. The target file exists (resolved relative to the linking file's directory, or relative to `docs/` for absolute-style paths starting with `/`).
2. If an anchor is present (`#section-name`), the anchor exists in the target file — i.e. the target file contains a heading that matches when lowercased and with spaces replaced by hyphens.

Links to external URLs (`http://`, `https://`) are skipped by the internal checker; use `scan --external` (operator-invoked, not CI-safe) for those.

### Stale gap references

For every `INFRA-NNNN`, `META-NNN`, `CREDIBLE-NNN`, or similar gap-id pattern found in a markdown file, the script checks whether the gap exists in state.db via `chump gap show <ID>`. If the gap no longer exists or the state.db query returns an error, the reference is flagged as stale.

### Output format

Each broken link is printed as:

```
BROKEN  docs/foo/bar.md:42  [text](../missing.md)  reason: target-missing
STALE   docs/foo/bar.md:99  INFRA-9999              reason: gap-not-in-state-db
```

Exit 0 if any broken/stale items found (actionable), exit 1 if the tree is clean (nothing to file).

## The work-your-lane protocol

| Step | What | Source |
|---|---|---|
| 1 | Read inbox for dispatch / STUCK / WARN items | `chump-inbox.sh read` |
| 2 | Scan doc segment for broken links | `md-links-loop.sh scan [path]` |
| 3 | File a gap per broken-link cluster (≥ 3 with shared root) | `chump gap reserve` |
| 4 | Heartbeat — emit liveness | `md-links-loop.sh heartbeat` |
| 5 | Broadcast DONE on each filed cluster | `scripts/coord/broadcast.sh DONE` |

## Lane scope (hard boundary)

The md-links curator reports and files gaps. It does NOT:

- Fix broken links directly (owning curator's lane)
- Rename files or move directories (any domain curator's lane)
- Write new docs (target or handoff lane)
- Run external URL scans in CI (external scanning is opt-in, never in test gate)

Refuses cross-lane work unless `CHUMP_MD_LINKS_LANE_OVERRIDE=1`; emits `kind=md_links_lane_override` to ambient when override fires.

## Behavior rules

- **Surface text from the underlying script to the user directly.** Don't re-paraphrase `md-links-loop.sh` output.
- **Never file N individual gaps for N individual broken links.** One gap per cluster — registry inflation is a Zero-Waste violation.
- **External URL scanning is opt-in.** Only use `scan --external` when the operator explicitly requests it. Never let it run in the CI gate.
- **Cap each iteration at 12 minutes** — if hit, broadcast STUCK and let next tick retry.

## Cross-references

- [`scripts/coord/md-links-loop.sh`](../../../scripts/coord/md-links-loop.sh) — canonical CLI; all subcommands invoke here
- [`.claude/agents/md-links.md`](../../agents/md-links.md) — agent body with full discipline
- [`docs/architecture/TEAM_OF_AGENTS.md`](../../../docs/architecture/TEAM_OF_AGENTS.md) — team hierarchy
- [`docs/process/INBOX_WATCHER_PATTERN.md`](../../../docs/process/INBOX_WATCHER_PATTERN.md) — real-time inbox wake contract
- [`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../../../docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md) — productization AC template
- [`.claude/skills/handoff/SKILL.md`](../handoff/SKILL.md) — sibling pattern (read for productization template)
