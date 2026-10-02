# Claude Code — Chump session rules (hot overlay)

> **Canonical agent rules live in [`AGENTS.md`](./AGENTS.md).** This file is
> the Claude-Code-specific overlay. Read AGENTS.md first, then this file.
>
> **Rulebook budget (ZERO-WASTE-125):** this file is capped at 150 lines,
> enforced by `scripts/ci/test-claude-md-budget.sh`. New rules require
> removing lines elsewhere (one-in-one-out). The self-pruning loop that
> measures every rule/gate in this repo and ranks delete candidates lives
> at [`docs/process/RULE_REGISTRY.md`](./docs/process/RULE_REGISTRY.md) —
> run `chump rules audit --window 30d` before proposing a new gate.

## Mission

> **RIBBON-ONLY FOCUS (operator decision, Jeff 2026-08-22):** cutting the
> ribbon (a clean-install, hands-off factory landing a real outcome on
> owned iron) is the only thing that matters right now. See
> [`docs/MISSION.md` → Ribbon-only focus](./docs/MISSION.md#ribbon-only-focus-operator-decision-jeff-2026-08-22).

Canonical mission gap: **MISSION-010** (self-coordinating fleet).
Scoreboard: `bash scripts/dev/mission-scoreboard.sh`. The 4 pillars
(Credible/Effective/Resilient/Zero-Waste) are *how*; the mission is *what*
"done" looks like — see [`AGENTS.md` → The 4 pillars](./AGENTS.md#the-4-pillars-resilient-259).

## Air Traffic Control — Chief-of-Staff role

The standing Opus loop is ATC: keep the machine healthy, keep looping, and
**dogfood ChumpOS by making it do its own work, never doing that work for
it.** ATC scans health, revives/unsticks wedges, feeds the fleet (files +
dispatches gaps), and escalates only through the quiet gate — never
hand-builds what the fleet should build. Full role detail:
[`docs/process/ATC_ROLE.md`](./docs/process/ATC_ROLE.md).

## No-escalation overlay

Canonical rule: [`AGENTS.md` → No-operator-escalation](./docs/process/NO_OPERATOR_ESCALATION.md).
Claude-Code specifics: `AskUserQuestion` and `scripts/dispatch/operator-recall.sh`
are T1–T4-only. Sub-agent dispatches inherit the same no-clarifying-questions
discipline (`docs/process/SUBAGENT_DISPATCH.md`).

## Mission Driver — pillar balance

Count fleet-pickable gaps per pillar each session. **Don't manufacture
gaps to refill a starved pillar** — that produced the 2026-07-26
gap-bankruptcy (1,214 → 25 self-referential gaps). A pillar refills by
picking a real outcome whose work happens to be that pillar. Every
P0/P1 gap must trace to an outcome (`--outcome <id>`, MISSION-045). P0
budget = 5 max. Full driver detail: [`docs/process/MISSION_DRIVER.md`](./docs/process/MISSION_DRIVER.md).

## MANDATORY pre-flight (every session, before any work)

```bash
git fetch origin main --quiet && git status
bash scripts/setup/chump-fleet-bootstrap.sh --check  # must exit 0
bash scripts/coord/auth-status.sh                    # auth VALIDITY probe
chump farmer status                                  # lights-on check
scripts/coord/chump-inbox.sh read --no-advance       # peer DMs
chump gap list --status open
chump gap preflight <GAP-ID>                         # stop if it fails
chump --briefing <GAP-ID>
bash scripts/coord/freshness-preamble.sh             # FRESH/STALE gate
bash scripts/dev/mission-scoreboard.sh
```

Full pre-flight rationale + ambient-stream reading guide:
[`docs/process/PREFLIGHT_CHECKLIST.md`](./docs/process/PREFLIGHT_CHECKLIST.md).

## A2A consensus — always-on and mandatory

Vote on every open `FEEDBACK kind=proposal` in your inbox each cycle —
`chump vote <corr_id> +1|-1|0 --reason '<why>'` (abstain `0` still counts
toward quorum). Never disable `CHUMP_FLEET_RECV_SIDE_V0` / `CHUMP_A2A_LAYER`.
Full detail: [`docs/process/A2A_CONSENSUS.md`](./docs/process/A2A_CONSENSUS.md).

## Claim before writing any code

```bash
chump claim <GAP-ID> --role <role> [--paths CSV]   # atomic claim
chump gap preflight <GAP-ID>                        # run first; stop if it fails
```

## Ship pipeline (always)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

Manual fallback: `git push -u origin <branch> --force-with-lease` →
`gh pr create --base main` → `gh pr merge <N> --auto --squash` →
`chump gap ship <ID> --update-yaml`.

## Hard rules

Core ship-discipline (never push to `main`, auto-merge default, PR
atomicity, `--no-verify` ban, mutate-gaps-via-`chump-gap`, commit-often,
rebase-if-behind, lease hygiene, uncommitted-work/`wip-snapshot`) is
canonical in [`AGENTS.md` → Ship discipline](./AGENTS.md#ship-discipline--core-hard-rules-resilient-259-harness-agnostic).

Claude-Code/session-specific additions:

- **`proprietary/` — NEVER commit here.** Private sibling repo.
- **Default model: haiku for IDE sessions, sonnet for fleet workers.**
- **Always work in a linked worktree** — `chump claim` refuses the main checkout.
- **Never start a gap without `chump gap preflight <GAP-ID>` first.**
- **Session close-out — no parked diff without a pointer.** Every WIP
  reaches: shipped, a branch WITH a gap pointing at it, or deliberately
  dropped. Never leave real work uncommitted in the main checkout.
- **Verify-before-alarm.** Run the 4-step rollup check on a real
  recently-merged PR before any ALERT-class "CI is broken" broadcast — see
  [`SHEPHERD_LOOP_PLAYBOOK.md`](./docs/process/SHEPHERD_LOOP_PLAYBOOK.md) Pattern 14.
- **CSS token discipline** for `web/**/*.{js,html,css}` — see
  [`docs/process/CSS_TOKEN_DISCIPLINE.md`](./docs/process/CSS_TOKEN_DISCIPLINE.md).

Full hard-rule detail (gap-reserve similarity gate, off-rails guard,
worktree disk hygiene, fleet scaling gate, auth modes, GitHub credentials
for agents): [`docs/process/CLAUDE_HARD_RULES_DETAIL.md`](./docs/process/CLAUDE_HARD_RULES_DETAIL.md).

## Local CI discipline (mandatory)

Run `chump preflight` before every push that touches Rust or scripts — a
failure caught locally costs <60s, the same failure on GitHub CI costs
~15 minutes round-trip. Parity rules between preflight and `ci.yml`:
[`docs/process/CI_GATES_INVENTORY.md`](./docs/process/CI_GATES_INVENTORY.md) (Tier D / allowlist).

## Spawning subagents (Claude-Code-only)

**Feed the fleet first** — file the gap and let a tmux worker pick it;
reserve Agent-tool dispatch for fleet-down / read-only analysis / a
structural one-shot the fleet can't pick. Always paste the shipping
epilogue + pre-push checklist from `docs/process/SUBAGENT_DISPATCH.md`.
Model: always sonnet. Full rationale: [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md).

## On-demand docs

Full index (style guides, ship-assist playbook, scheduling layers,
harvester, cache-first reads, bootstrap, decomposition): see the doc table
in [`docs/process/ON_DEMAND_DOCS_INDEX.md`](./docs/process/ON_DEMAND_DOCS_INDEX.md).
