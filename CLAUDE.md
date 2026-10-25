# Claude Code — Chump session rules (hot overlay)

> **Canonical agent rules live in [`AGENTS.md`](./AGENTS.md).** This file is only the Claude-Code-specific overlay. Read `AGENTS.md` first.
> Budget: this file <= 150 lines, AGENTS.md <= 300 (ZERO-WASTE-125). Adding a rule means removing one. Rule registry: `docs/process/RULE_REGISTRY.tsv`.

## Mission

**Ribbon-only focus (Jeff 2026-08-22):** the job is the factory — a clean-install, hands-off factory that lands a real outcome on owned iron. All other products are parked. Mission of record: [`docs/MISSION.md`](./docs/MISSION.md) (MISSION-010, proof on `repairman29/BEAST-MODE`). Scoreboard: `bash scripts/dev/mission-scoreboard.sh`.

Build agents that are **Credible, Effective, Resilient, Zero-Waste** ([pillars](./AGENTS.md#the-4-pillars-resilient-259)). When in doubt, the mission wins.

## Air Traffic Control (Chief-of-Staff role)

The Opus session driving the standing loop is ATC: a traffic cop, not a worker. Dogfood ChumpOS — make it do its own work.

- **DO:** keep looping (ship-rate, disk, auth, wedges, dead daemons, stuck PRs, orphaned leases); revive and unstick; feed the fleet (file gaps with clear AC and dispatch them); escalate only through the quiet gate (`scripts/coord/operator-escalation-registry.txt`).
- **DON'T:** hand-write the PR the fleet should write (hand-work only to bootstrap a capability the fleet structurally lacks); hand-hold every ship — arm auto-merge and let go.

## No-escalation overlay

Escalation triggers T1-T4 (irreversible third party / credential rotation / operator-explicit domain / halt-class fleet-unsafe) are canonical in [`AGENTS.md`](./AGENTS.md#no-operator-escalation-discipline-operator-decision-of-record-2026-05-30). `AskUserQuestion` and `scripts/dispatch/operator-recall.sh` are for T1-T4 only; otherwise broadcast `FEEDBACK kind=proposal` via `scripts/coord/broadcast.sh`. Sub-agents inherit this.

## Mission Driver

- Pillar imbalance is a metric (`chump fleet brief`), not a work order — never file gaps to refill a starved pillar.
- Every P0/P1 gap needs `--outcome <id>` (`chump outcome list`); P0 budget is 5. Title-tag gaps with the pillar prefix.
- Roadmap before gaps: re-read `docs/ROADMAP.md` when unsure what to file. Rate surprising outcomes: `chump gap rate <ID> <1-5>`.
- SLOs: `chump health --slo-check`; definitions in [`docs/process/FLEET_SLOS.md`](./docs/process/FLEET_SLOS.md).

## Pre-flight (every session)

```bash
git fetch origin main --quiet && git status
bash scripts/setup/chump-fleet-bootstrap.sh --check   # must exit 0; run without --check to install
bash scripts/coord/auth-status.sh                     # auth validity — read its line, don't re-diagnose
chump farmer status                                   # RED = no new claims
tail -30 .chump-locks/ambient.jsonl
scripts/coord/chump-inbox.sh read --no-advance        # peer DMs
chump gap preflight <GAP-ID>                          # exit 1 = not pickable, stop
chump --briefing <GAP-ID>
```

- **Freshness:** before any "X is missing" claim, check `git ls-tree origin/main <path>` or the `verify-existence` skill — never a bare local `ls`.
- **Vote on every open `FEEDBACK kind=proposal`** each cycle: `chump vote <corr_id> +1|-1|0 --reason '…'` (abstain with a reason if out of lane). Never disable `CHUMP_FLEET_RECV_SIDE_V0` / `CHUMP_A2A_LAYER`.
- **Verify before alarm:** before any "CI is broken" broadcast, check a real merged PR's `statusCheckRollup`; `gh run list` failing is not proof.

## Claim, then ship

```bash
chump claim <GAP-ID> --role <role> [--scope <module>] [--paths CSV]   # atomic: worktree + lease
chump gap reserve --domain INFRA --title "short title"
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

Manual fallback: push, `gh pr create --base main`, `chump gap link-pr <ID> <N> --sha "$(git rev-parse HEAD)"`, `gh pr merge <N> --auto --squash`, `chump gap ship <ID> --update-yaml`.

- Always work in a linked worktree. Never start a gap without `chump gap preflight`.
- Run `chump preflight` before every push touching Rust or scripts. A new `ci.yml` step must be mirrored in `src/preflight.rs`, listed in `CI_GATES_INVENTORY.md` Tier D, or added to `scripts/ci/preflight-ci-parity-exceptions.txt`.
- Rust-first for anything that mutates canonical state, runs on a hot path, or exceeds 200 LOC; otherwise add a `Rust-First-Bypass: <reason>` trailer.

## Two-phase decomposition

Put rough decomposition intent in the gap description; at claim time run `chump gap decompose <ID>` (`--dry-run` to inspect the prompt). Never pre-file sub-gaps.

## Subagents (Claude-Code-only)

Feed the fleet first: file the gap with clear AC and let a tmux worker pick it. Agent-tool sub-agents are uninstrumented, leak ptys, and stall at the ship wall — use them only when the fleet is down, for read-only analysis, or for a one-shot the fleet cannot pick. Paste the shipping epilogue and pre-push checklist from [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md) into every prompt. Model: sonnet for workers; Opus orchestrates; haiku for cost-sensitive sweeps only. Budget `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` (900s).

## Auth and credentials

`ANTHROPIC_API_KEY` (preferred when set) or `CLAUDE_CODE_OAUTH_TOKEN` via `~/.chump/oauth-token.json` (`CHUMP_AUTH_MODE=auto|api-key|oauth`). The refresher is `com.chump.oauth-refresh` (macOS only); smoke test `scripts/ci/test-oauth-refresher.sh`. Validate with `chump fleet doctor`. Agents use `GH_TOKEN` / `SSH_KEY_PATH` when set, else the local keyring; credential values never appear in logs.

## Hard rules (protected floor — never auto-pruned)

- Never push to `main`; never `--no-verify`; never commit secrets; **`proprietary/` is never committed**.
- No destructive or irreversible ops without the operator; confirm before force-push/reset --hard.
- Mutate gaps only via `chump gap` / `chump-gap`; state.db is canonical.
- No parked diff without a pointer (DOC-082): before a session ends, work is shipped, on a branch with a gap, or deliberately dropped.
- CSS token discipline for `web/**` ([`docs/process/CSS_TOKEN_DISCIPLINE.md`](./docs/process/CSS_TOKEN_DISCIPLINE.md)); `chump gap reserve` title-similarity check (`--force-duplicate` to bypass).

## Operational notes

- **Cache-first:** read PR state from `.chump/github_cache.db` via `scripts/lib/github_cache.sh` (`cache_lookup_pr`, `cache_query_behind_prs`, `cache_lookup_checks`); `gh` only on a miss. Details in [`OPERATOR_PLAYBOOK.md` §7.5](./docs/process/OPERATOR_PLAYBOOK.md).
- **GraphQL pressure:** tag non-critical calls `CHUMP_GH_CALL_CRITICALITY=background`; on `graphql_exhausted` run `scripts/dev/api-cost-leaderboard.sh --window 1h`.
- **Push routing** is opt-in via NATS (`chump-coord assign|worker`); state.db stays the source of truth, pull loop is the fallback.
- **Fleet scale:** check `chump waste-tally --window 2h` and `scripts/dispatch/fleet-status.sh` first; drop to 2 workers on any `fleet_wedge`, >1 `silent_agent`/h, ≥3 `pr_stuck`/2h, or waste >30%; log every change as `kind=fleet_scale_change`.
- **Registry health:** `chump gap audit-priorities` (non-zero = stop). **Rulebook health:** `python3 scripts/ops/rules-registry.py audit`.

## On-demand docs

[`docs/CODEBASE_REALITY_MAP.md`](./docs/CODEBASE_REALITY_MAP.md) · [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md) · [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md) · [`docs/process/SHIP_ASSIST_PLAYBOOK.md`](./docs/process/SHIP_ASSIST_PLAYBOOK.md) · [`scripts/README.md`](./scripts/README.md) · [`scripts/coord/README.md`](./scripts/coord/README.md) · [`docs/design/PWA_STYLE_GUIDE.md`](./docs/design/PWA_STYLE_GUIDE.md) · [`docs/arsenal/HARVESTER.md`](./docs/arsenal/HARVESTER.md)
