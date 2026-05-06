# Claude Code — Chump session rules (hot overlay)

## Mission
Build agents that are **Credible**, **Effective**, **Resilient**, and **Zero-Waste**.
Full pillar definitions and coordination docs: [`AGENTS.md`](./AGENTS.md) + [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md).
Eval/research work also reads [`docs/process/RESEARCH_INTEGRITY.md`](./docs/process/RESEARCH_INTEGRITY.md).

## MANDATORY pre-flight (every session, before any work)

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
bash scripts/setup/install-ambient-hooks.sh 2>&1 | tail -2  # FLEET-023, idempotent
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
chump-coord watch &                              # FLEET-006 (skip if NATS unavailable)
chump gap list --status open                     # canonical .chump/state.db
scripts/coord/gap-preflight.sh <GAP-ID>          # exits 1 if not pickable — stop if so
chump --briefing <GAP-ID>                        # MEM-007 per-gap context
```

`ambient.jsonl` is your peripheral vision — watch for `lease_overlap`, `silent_agent`,
`edit_burst`, `queue_config_drift`, `pr_stuck`, `subagent_budget_exceeded`,
`lessons_injection_active`. Full event-kind guide: [CLAUDE_GOTCHAS.md](./docs/process/CLAUDE_GOTCHAS.md).

## Claim before writing any code

```bash
chump claim <GAP-ID> [--paths CSV]   # atomic: fetch + verify + doctor + worktree + lease
# fallback if broken:
scripts/coord/gap-claim.sh <GAP-ID>                       # existing gap
chump gap reserve --domain INFRA --title "short title"    # new gap
```

If preflight fails, **stop** — do not bypass.

## Ship pipeline (always)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

Manual fallback if broken:
```bash
git push -u origin <branch> --force-with-lease
gh pr create --base main
gh pr merge <N> --auto --squash
chump gap ship <ID> --update-yaml
```

## Hard rules

- **`proprietary/` — NEVER commit here.** Private sibling repo; stray copies must not be staged or referenced.
- **Default model: haiku for IDE sessions, sonnet for fleet workers.** Cost-sensitive sweeps: `FLEET_MODEL=haiku`. Opus is ~50× haiku per token.
- **Never push directly to `main`.** See [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01).
- **Always work in a linked worktree** — `gap-claim.sh` refuses the main checkout.
- **Never start a gap without `gap-preflight.sh` first.**
- **Never leave a lease behind** — `chump --release` or delete `.chump-locks/<session>.json`.
- **Commit often** (every 30 min) — use `scripts/coord/chump-commit.sh <files> -m "msg"`, not bare `git commit`.
- **Mutate gaps via `chump gap …` only** — `.chump/state.db` is canonical. Use `chump gap show <ID>` to inspect.
- **Rebase if your branch is more than 15 commits behind main.**
- **Auto-merge is the default.** `bot-merge.sh --auto-merge` arms it. Once armed, treat PR as frozen — new work → new PR.
- **PRs are intent-atomic**, not file-count-bounded. One logical change per PR.
- **`--no-verify` is the reason most regressions ship.** Use very sparingly.

## On-demand docs (read only when you hit the failure surface)

- Subagents, fleet launcher, disk hygiene, operational gotchas (binary wedge, rebase footgun, syspolicyd, etc.): [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md)
