# AGENTS.md — agent guidance for Chump

This file follows the [AGENTS.md](https://aaif.io/) cross-tool convention
(Linux Foundation, Dec 2025). It is the **canonical, tool-agnostic** entry
point for any agent in this repo — Claude Code, opencode, Codex CLI, Aider,
Cursor, goose, or a human committing directly.

> **Rulebook budget (ZERO-WASTE-125):** this file is capped at 300 lines,
> `CLAUDE.md` at 150, enforced by `scripts/ci/test-claude-md-budget.sh`.
> Detail moves to an on-demand doc, never grows inline. See
> [`docs/process/RULE_REGISTRY.md`](./docs/process/RULE_REGISTRY.md) for
> the self-pruning loop that measures every rule/gate in this repo and
> [`docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md`](./docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md)
> for narrative detail cut from this pass.
>
> **Harness-specific addenda:** [`CLAUDE.md`](./CLAUDE.md) overlays this
> file for Claude Code / Chump fleet workers (lease rules, `chump-commit.sh`,
> fleet mechanics). Read AGENTS.md first, then CLAUDE.md if applicable.

## Project overview

**Chump** is a Rust-based multi-agent fleet coordinator and gap registry.
It coordinates many concurrent agent sessions against a shared codebase via
lease-based file ownership, a coordination event stream (`ambient.jsonl`),
and a per-gap "briefing" memory system.

> **Mission:** [`docs/MISSION.md`](./docs/MISSION.md) (MISSION-014).
> Canonical gap: MISSION-010. Scoreboard: `bash scripts/dev/mission-scoreboard.sh`.

See [`docs/ROADMAP.md`](./docs/ROADMAP.md), [`docs/architecture/ARCHITECTURE.md`](./docs/architecture/ARCHITECTURE.md),
and [`docs/architecture/TEAM_OF_AGENTS.md`](./docs/architecture/TEAM_OF_AGENTS.md).

## The 4 pillars (RESILIENT-259)

Every gap is graded on: **Credible** (receipts, not self-report — see
[Reality-check](#reality-check-credible-090) / [Durable-fix](#durable-fix-doctrine-credible-105)),
**Effective** (rolls up to a `docs/MISSION.md` outcome), **Resilient**
(keeps shipping through failure), **Zero-Waste** (no dupes, no idle loops,
no unaccountable token burn). SLO targets: [`docs/process/FLEET_SLOS.md`](./docs/process/FLEET_SLOS.md).

**Mine the almanac before you build or holler.** [`docs/ALMANAC.md`](./docs/ALMANAC.md)
answers "have we built X" across the ~95-repo fleet with `repo:path:line`
receipts — cheaper than a grep fan-out. Hit friction? File `chump voice`
([`docs/process/VOICE_OF_AGENT.md`](./docs/process/VOICE_OF_AGENT.md))
before escalating.

## Build / test / lint

```bash
cargo build --bin chump               # fastest iteration
cargo check --bin chump --tests       # type-check, no codegen
cargo test -p <crate>                 # single crate
cargo fmt --all -- --check            # what CI runs
cargo clippy --all-targets --all-features -- -D warnings
```

Linux: `scripts/setup/provision-chumpd-host.sh --install-deps`, then
`scripts/setup/install-chumpd.sh`. Full detail: [`docs/process/BUILD_AND_TEST.md`](./docs/process/BUILD_AND_TEST.md).

**Local CI is mandatory before every Rust/script push (INFRA-1673).**
`chump preflight` mirrors fmt/clippy/check + the relevant `scripts/ci/test-*.sh`
locally in seconds instead of a ~15-minute CI round-trip. No skip env var
exists (INFRA-2422) — a main-RED gate auto-skips itself via
`.chump/main-preflight-state.json`.

## Code style

Rust 2024. No `unwrap()`/`expect()`/`panic!` in production paths —
`anyhow::Result` at binaries, `thiserror` in libraries, `?`/`match`.
`tracing` (not `log`) with structured fields. `tokio` + `async fn`. Keep
public surface narrow; re-export from `lib.rs`.

## Engineering discipline — read the doc, don't re-derive the rule

| Topic | Doc |
|---|---|
| CI fixture conventions (no real gap IDs as fixtures) | [`docs/process/CI_FIXTURE_CONVENTIONS.md`](./docs/process/CI_FIXTURE_CONVENTIONS.md) |
| Rust-first vs. shell-OK (META-064) | [`docs/process/RUST_FIRST.md`](./docs/process/RUST_FIRST.md) |
| Redundancy prevention (META-063) | [`docs/process/REDUNDANCY_PREVENTION.md`](./docs/process/REDUNDANCY_PREVENTION.md) |
| Shared services over silos (INFRA-3463) | [`docs/process/CANONICAL_SERVICES.md`](./docs/process/CANONICAL_SERVICES.md) |
| Reading code economically (token cost) | [`docs/process/READING_CODE_ECONOMICALLY.md`](./docs/process/READING_CODE_ECONOMICALLY.md) |
| PR check polling discipline | [`docs/process/PR_CHECK_POLLING.md`](./docs/process/PR_CHECK_POLLING.md) |
| Cache-first `gh` reads (INFRA-1081) | [`docs/process/OPERATOR_PLAYBOOK.md §7.5`](./docs/process/OPERATOR_PLAYBOOK.md#75-local-infrastructure--webhook--smee--cache--docker) |
| `chump_gh` call criticality + GraphQL exhaustion | [`docs/process/GH_CALL_CRITICALITY.md`](./docs/process/GH_CALL_CRITICALITY.md) |
| Communication channels (broadcast/DM/ambient/heartbeat) | [`docs/process/OPUS_MESSAGE_PROTOCOL.md`](./docs/process/OPUS_MESSAGE_PROTOCOL.md) |

## Reality-check (CREDIBLE-090)

> A detector is a SIGNAL; the thing being broken is an OUTCOME. Verify
> against ground truth before you broadcast / escalate / halt.

Run `scripts/dev/reality-check.sh "<belief>"` before any "X is down/dead/
broken/halted" statement. Decisive proof: did `origin/main` merge in the
last hour? If yes, **not dead — stand down**. `claude -p` in your shell,
`chump fleet doctor` exit-0, and the fleet-brief banner are NOT proof of
fleet auth validity (RESILIENT-086) — the recent-merge check is.

## Durable-fix doctrine (CREDIBLE-105)

> Fix the thing that's broken — not your path around it.

Full doctrine: [`docs/process/DURABLE_FIX_DOCTRINE.md`](./docs/process/DURABLE_FIX_DOCTRINE.md).
Pre-workaround test: (1) are you hiding the failure or fixing it
(`--no-verify`, retry-until-green, mocking past it)? (2) who inherits the
breakage if you route around it? (3) is the deferral visible (filed gap +
audit signal)? A workaround is a bridge, never a terminal action.

## No-operator-escalation discipline

> Operator directive (2026-05-30): default mode is team consensus, not
> operator escalation.

Broadcast `FEEDBACK kind=proposal` for anything that isn't trivially your
own call; let the deliberator tally votes. The **only** 4 legitimate
escalation triggers: **T1** irreversible third-party action, **T2**
credential rotation needing hands-on-keyboard, **T3** operator-explicit-domain
(legal/pricing/branding), **T4** halt-class condition where consensus itself
is unsafe. Full table + examples: [`docs/process/NO_OPERATOR_ESCALATION.md`](./docs/process/NO_OPERATOR_ESCALATION.md).

## Ship discipline — core hard rules (RESILIENT-259, harness-agnostic)

- **Never push directly to `main`.** Every change lands via a PR.
- **Auto-merge is the default**; once armed, the PR is frozen.
- **PRs are intent-atomic**, not file-count-bounded. One gap per PR.
- **`--no-verify` is the reason most regressions ship.** Use sparingly.
- **Mutate gaps via `chump gap …` only** — `.chump/state.db` is canonical.
- **Commit often** via `scripts/coord/chump-commit.sh <files> -m "msg"`.
- **Rebase if >15 commits behind main.**
- **Never leave a lease behind.**
- **Off-rails guard (RESILIENT-025/026):** claim contract enforced at
  commit + push when a `.chump-locks/claim-*.json` exists. Disable (rare):
  `CHUMP_OFF_RAILS_CHECK=0`.
- **Commit early — uncommitted work is unrecoverable (RESILIENT-256).**
  `chump wip-snapshot` for a dirty-tree safety net; always work in a linked
  worktree, never the shared primary checkout.

Workspace-scoped gaps (reference paths outside the claiming repo's own
tree) route to an operator/ATC session, not a fleet worker — tag
`skills_required: workspace_scope`. Detail: [`docs/process/WORKSPACE_SCOPED_GAPS.md`](./docs/process/WORKSPACE_SCOPED_GAPS.md) (RESILIENT-292).

## Mission Driver — loop discipline (INFRA-2208)

Every loop tick ends in one of: a shipped change, a dispatched subagent, a
defensible BLOCKED with a named unblock condition, or a documented pickup
of the next-best gap. "Standing by" / "conserving tokens" are not valid
end-states. 3 stuck ticks → broadcast `STUCK` and stop.

## How to claim work

`.chump/state.db` is canonical (SQLite); `docs/gaps/<ID>.yaml` is a
regenerated mirror. Flow: `chump gap preflight <ID>` →
`chump gap claim <ID>` (writes `.chump-locks/<session>.json`, never the
registry) → work in a linked worktree → `chump gap ship <ID> --update-yaml`.
Install hooks once per checkout: `scripts/setup/install-hooks.sh`.
Full walkthrough incl. disk reclaim, divergence diagnosis, subagent
briefing prefix, fleet launcher: [`docs/process/CLAIM_WORKFLOW.md`](./docs/process/CLAIM_WORKFLOW.md).

## Filing follow-up gaps (the feeder system)

File immediately when you spot a bug, drift, misfiring guard, or
coordination race — don't ask first. Asymmetric cost: silent regression if
you don't file; near-zero cost if you over-file. Skip only when you lack
confidence it's real, it's pure speculation, or it's already filed. Filing
flow + priority guidance + bundling: [`docs/process/FILING_GAPS.md`](./docs/process/FILING_GAPS.md).
Pattern-level follow-through (periodic RCA pass, verify-before-RCA,
pattern-counter automation, runtime verification before missing-claim):
[`docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md`](./docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md).

## Naming conventions (INFRA-186)

The project owns the namespace, not the tool: `chump-` / `chump/` /
`.chump/` prefixes regardless of agent identity. Canonical branch:
`chump/<codename>`; legacy `claude/*` accepted during transition. Full
table + freshness-discipline cross-ref: [`docs/process/NAMING_CONVENTIONS.md`](./docs/process/NAMING_CONVENTIONS.md).

## Pull request guidelines

Branch `chump/<codename>`, never push to `main`, one gap per PR, ship via
`scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge`. Conventional
commits (`feat(<gap-id>): summary`). Stacked PRs (`--stack-on`) for
logically-distinct dependent changes: [`docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md`](./docs/process/RULEBOOK_ARCHIVE_PRE_ZW125.md).

## Cross-tool note

Chump-internal agents read **both** AGENTS.md (canonical) and CLAUDE.md
(Chump overlay). External AGENTS.md-only agents get build/test/style/PR
conventions without the lease/NATS coordination detail. Cursor-specific:
`docs/process/CHUMP_CURSOR_FLEET.md`. Publishing: [`docs/operations/PUBLISHING.md`](./docs/operations/PUBLISHING.md).
