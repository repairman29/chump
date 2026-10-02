# Naming conventions (INFRA-186)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

The project owns the namespace, not the tool. Branches, worktree paths,
lease files, ambient events, and bot identities use the `chump-` /
`chump/` / `.chump/` prefix regardless of which agent is the actor.

| Artifact | Canonical | Acceptable (legacy) |
|---|---|---|
| Feature branch | `chump/<short-codename>` | `claude/<…>`, `cursor/<…>`, etc. |
| Linked worktree | `.chump/worktrees/<name>/` | `.claude/worktrees/<…>` |
| Lease file dir | `.chump-locks/<session>.json` | (already canonical) |
| State / SQLite | `.chump/state.db`, `.chump/state.sql` | (already canonical) |
| Bot commit identity | `<role>@chump.bot` | (already canonical) |
| Ambient stream | `.chump-locks/ambient.jsonl`, NATS `chump.events.>` | (already canonical) |

**Migration:** existing `claude/*` branches and `.claude/worktrees/` trees
stay as history — no rename. New branches/worktrees use `chump/<codename>`
and `.chump/worktrees/<name>`. `bot-merge.sh` and `chump gap` commands
accept either prefix during the transition.

**Tool-specific overlays** (skills, hooks, harness behavior) live in
tool-named files (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`). Those defer to
AGENTS.md for shared conventions. If a rule appears in both, AGENTS.md wins.

**Freshness discipline** — defend against the seven staleness layers (git
main, state.db, chump binary, launchd plists, YAML gaps, fleet-registry,
docs). Before any "X is missing" claim, run `git ls-tree origin/main
path/to/X` or the `verify-existence` check. Full rules:
[`FRESHNESS_DISCIPLINE.md`](./FRESHNESS_DISCIPLINE.md) (DOC-059 / META-114).
