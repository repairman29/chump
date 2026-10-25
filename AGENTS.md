# AGENTS.md — agent guidance for Chump

This file follows the [AGENTS.md](https://aaif.io/) cross-tool convention adopted
by the Agentic AI Foundation (Linux Foundation, Dec 2025) as one of three founding
projects (alongside MCP and goose). It is the **canonical, tool-agnostic** entry
point for **any agent** working in this repo — Claude Code, opencode, Codex CLI,
Aider, Cursor, goose, or a human committing directly.

> **Harness-specific addenda:**
> - [`CLAUDE.md`](./CLAUDE.md) — overlay for Claude Code and Chump fleet workers.
>   Adds lease / coordination rules, `chump-commit.sh`, commit-time guards,
>   ambient stream discipline, and Chump fleet mechanics. Read AGENTS.md first,
>   then CLAUDE.md if you are a Claude Code session or a Chump fleet worker.
> - Other harnesses (opencode, Aider, goose): follow AGENTS.md; CLAUDE.md rules
>   do not apply unless you are running inside the Chump fleet dispatcher.

---

## Project overview

**Chump** is a Rust-based multi-agent fleet coordinator and gap registry.
It coordinates many concurrent agent sessions — from any coding tool — against a
shared codebase, using lease-based file ownership, a coordination event stream
(`ambient.jsonl`), and a per-gap "briefing" memory system. The workspace ships a
`chump` CLI binary (the coordinator), an optional built-in agent (Ollama/vLLM
backend), several supporting crates, and a docs/ ledger that drives autonomous
gap-picking.

Chump's own development is done by the fleet on a swappable harness
(`CHUMP_AGENT_HARNESS`) — OpenCode is the default model gateway for bulk work,
Claude Code is reserved as the hard-ship fallback, and manual operator commits
all interop through the same coordinator primitives.

> **The load-bearing mission lives in [`docs/MISSION.md`](./docs/MISSION.md)**
> (MISSION-014). Canonical mission gap: **MISSION-010**. Read it before filing
> any new gap — the 4 pillars below grade *how* every gap is built; MISSION.md
> tells you *what* "done" looks like for the year. Active mission pointer:
> `~/.chump/ACTIVE_MISSION` (currently `MISSION-010`).
> Scoreboard (read-only, safe anytime): `bash scripts/dev/mission-scoreboard.sh`.

See [`docs/ROADMAP.md`](./docs/ROADMAP.md) for the 4-pillar mission and active thrusts,
[`docs/architecture/ARCHITECTURE.md`](./docs/architecture/ARCHITECTURE.md) for the system map,
[`docs/research/RESEARCH_PLAN_2026Q3.md`](./docs/research/RESEARCH_PLAN_2026Q3.md) for current
direction, and [`docs/architecture/TEAM_OF_AGENTS.md`](./docs/architecture/TEAM_OF_AGENTS.md) for the
multi-agent design.

## The 4 pillars (RESILIENT-259)

Every gap, from any harness, is graded on these four qualities — they are
**how** the fleet moves toward the mission, not the mission itself:

- **Credible** — measurement over vibes. Claims about "shipped" / "working" /
  "healthy" are backed by receipts (a test, a log line, a ground-truth check),
  not self-report. See [Reality-check](#reality-check-before-alarm-class-beliefs--ship-check-first-credible-090)
  and [Durable-fix doctrine](#durable-fix-doctrine--no-band-aids-credible-105) below.
- **Effective** — user-facing progress. Work rolls up to an outcome in
  `docs/MISSION.md`, not fleet-internal plumbing for its own sake.
- **Resilient** — the fleet keeps shipping through failure: wedges get
  unstuck, leases don't leak, uncommitted work reaches the object store early.
- **Zero-Waste** — no duplicate implementations, no idle loop ticks, no
  token burn without a ship-class outcome (see "Mission Driver — loop
  discipline" below).

Full pillar SLO targets: [`docs/process/FLEET_SLOS.md`](./docs/process/FLEET_SLOS.md).

## Build commands

```bash
cargo build                       # debug build of full workspace
cargo build --release             # release build
cargo build --bin chump           # CLI binary only (fastest iteration)
cargo check --bin chump --tests   # type-check without codegen (use this in tight loops)
```

### Linux-first setup (INFRA-3342)

If you are on Linux, standard installation via `brew` might be unavailable or incomplete. Follow the **Linux substrate** path for the most reliable experience:

1. **System dependencies:** Run `bash scripts/setup/provision-chumpd-host.sh --install-deps` to install required GTK/Webkit libs, Rust, and `gh`.
2. **Supervisor daemon:** Run `bash scripts/setup/install-chumpd.sh` to build and register the `chumpd` supervisor with `systemd --user`.
3. **Verify:** `systemctl --user status chumpd` should show "active (running)".

`chump demo [--seed N] [--duration 60m] [--dry-run] ...` (INFRA-2391) — the
META-072 Track-3 autonomous-throughput demo loop (crates/chump-demo), wired
as a real subcommand instead of an undiscoverable standalone binary. It execs
the sibling `chump-demo` binary built by this workspace, so `cargo build`
(which builds both bins) is a prerequisite.

## Test commands

```bash
cargo test                        # full workspace test run
cargo test -p <crate>             # single crate
cargo test <name_substr>          # filter by test name
cargo test -- --nocapture         # show println! output during tests
```

## Lint and format commands

```bash
cargo fmt --all                   # format the workspace (CI runs --check)
cargo fmt --all -- --check        # what CI runs
cargo clippy --all-targets --all-features -- -D warnings
```

The pre-commit hook auto-runs `cargo fmt` on staged `.rs` files and re-stages
the result, so manual `cargo fmt` is rarely required before committing.

## Code style

- **Edition:** Rust 2024 across the workspace.
- **No `unwrap()` / `expect()` in production paths.** Tests and one-shot
  scripts may unwrap freely. Library and binary code returns `Result` and uses
  `?` or explicit `match`. Use `expect("invariant: ...")` only when documenting
  a true invariant.
- **No `panic!` outside tests.** Same reasoning.
- **Errors:** use `anyhow::Result` at binary boundaries, `thiserror` for
  library error types. Add context with `.context("doing X")?`.
- **Logging:** `tracing` (not `log`). Use structured fields, not formatted
  strings: `tracing::info!(gap_id = %id, "claimed gap")`.
- **Async:** `tokio` runtime; prefer `async fn` over manual `Future` impls.
- **Modules:** keep public surface narrow — re-export from `lib.rs` /
  `mod.rs` rather than letting callers reach into submodules.

## Where to find docs

| Doc | Purpose |
|---|---|
| [`docs/architecture/ARCHITECTURE.md`](./docs/architecture/ARCHITECTURE.md) | System map: crates, data flow, key types |
| [`docs/process/AGENT_COORDINATION.md`](./docs/process/AGENT_COORDINATION.md) | Lease system, branch model, failure modes |
| [`docs/architecture/TEAM_OF_AGENTS.md`](./docs/architecture/TEAM_OF_AGENTS.md) | Multi-agent design and roles |
| [`docs/design/A2A_ROADMAP.md`](./docs/design/A2A_ROADMAP.md) | Frontier a2a roadmap — six layers (NATS-primary, RPC, capability discovery, shared KV, deliberation, signed provenance) sequenced from today's primitives to world-class fleet coordination (META-061) |
| [`docs/architecture/A2A_TWO_WAY_COMMS.md`](./docs/architecture/A2A_TWO_WAY_COMMS.md) | Two-way operator ↔ fleet comms: identity model, urgency/severity schema, reach hierarchy (inbox/toast/push/digest), filter rules, correlation_id reply contract (DOC-049) |
| [`docs/research/RESEARCH_PLAN_2026Q3.md`](./docs/research/RESEARCH_PLAN_2026Q3.md) | Current research/roadmap direction |
| [`docs/research/RESEARCH_EXECUTION_LANES.md`](./docs/research/RESEARCH_EXECUTION_LANES.md) | Lane A vs Lane B research ops + weekly cadence |
| [`docs/eval/batches/README.md`](./docs/eval/batches/README.md) | Committed audit trail for each paid (Lane B) sweep |
| [`docs/research/RESEARCH_AGENT_REVIEW_LOG.md`](./docs/research/RESEARCH_AGENT_REVIEW_LOG.md) | Agent session blockers, CI flakes resolved, double-backs (append-only) |
| `.chump/state.db` | **Canonical** gap registry (SQLite, since INFRA-059); access via `chump gap …` subcommands |
| [`docs/gaps/`](./docs/gaps/) | Human-readable per-file mirror of the registry (one `<ID>.yaml` per gap, post-INFRA-188); regenerated by `chump gap set/ship/dump`. The legacy monolithic `docs/gaps.yaml` was deleted in INFRA-188. |
| `.chump/state.sql` | Readable SQL diff of `state.db`; regenerate with `chump gap dump --out .chump/state.sql` after merge conflicts |
| [`docs/operations/PUBLISHING.md`](./docs/operations/PUBLISHING.md) | crates.io publish order, tokens, and consumer `path`+`version` deps |
| [`docs/operations/INFERENCE_PROFILES.md`](./docs/operations/INFERENCE_PROFILES.md) | Local inference (vLLM-MLX 8000 / Ollama 11434) |
| [`scripts/README.md`](./scripts/README.md) | Script taxonomy, canonical tool per task, entry points per directory (DOC-024) |
| [`docs/process/EXTERNAL_REPO_USAGE.md`](./docs/process/EXTERNAL_REPO_USAGE.md) | Onboarding guide for non-Chump repos using Chump as a coordination platform (DOC-022) |
| [`docs/ALMANAC.md`](./docs/ALMANAC.md) | Almanac protocol — the fleet reference desk: CLI/MCP surfaces, tool-by-question-shape table, seven trust rules with incident receipts, latency budget, voice contract for spoken turns (DOC-085) |

## Reality-check before alarm-class beliefs — ship-check FIRST (CREDIBLE-090)

> **A detector is a SIGNAL; the thing being broken is an OUTCOME. Verify the
> outcome against ground truth before you broadcast / escalate / halt.**

Run `scripts/dev/reality-check.sh "<belief>"` before any "X is down / dead /
broken / halted / starved" statement. The decisive ground truth: **did
`origin/main` merge in the last hour?** (`git log origin/main --since='1 hour ago'`).
If yes, it is **NOT dead — stand down**, full stop.

**Auth-dead / fleet-dead is the #1 false-positive** (mis-called 4× through
2026-06-07, the fleet shipping each time). Three "proofs" that do **NOT** measure
fleet auth: (a) **`claude -p` in your shell** tests *your* interactive login, not
the fleet's `ANTHROPIC_API_KEY` env path (check `launchctl getenv ANTHROPIC_API_KEY`);
(b) **`chump fleet doctor` exit-0** checks auth *presence*, not *validity*
(RESILIENT-086); (c) the **fleet-brief `✓ healthy` banner** ignores ship-rate.
The recent-merge check is the only proof of life.

## No-operator-escalation discipline (operator-decision-of-record 2026-05-30)

> **Operator directive 2026-05-30T17:30Z (verbatim):** *"Make sure the don't escalate to the human protocol is locked in for agents. I'm not here to babysit. I'm here for results."*

**Default mode is team consensus, not operator escalation.** When an agent (orchestrator OR sub-agent) faces a decision that isn't trivially their own, the default action is to broadcast a `FEEDBACK kind=proposal` to peer curators (see [`docs/process/OPUS_MESSAGE_PROTOCOL.md`](./docs/process/OPUS_MESSAGE_PROTOCOL.md)), let the deliberator-loop tally votes, and act on `kind=consensus_resolved`. NOT to ping the operator.

### The 4 legitimate escalation triggers (the ONLY ones)

| Code | Trigger | Example |
|------|---------|---------|
| **T1** | Irreversible third-party action with no consensus mandate | Production deploy beyond chump itself; financial spend; external comms to partners/customers/lawyers |
| **T2** | Credential rotation requiring operator hands-on-keyboard | R2 token rotation (secret values write-only via gh); OAuth setup; SSH key provisioning on new hardware |
| **T3** | Operator-explicit-domain decisions | Legal / license model (MIT vs dual); partnership pitches; pricing / business model; public branding / messaging |
| **T4** | Halt-class fleet condition where consensus itself is unsafe | trunk-RED **AND** auth-storm **AND** queue-starve simultaneously; deliberator-loop down; broadcast.sh broken |

**Everything else → team consensus.** If you're tempted to call `AskUserQuestion` or `scripts/dispatch/operator-recall.sh`, run through the 4 triggers first. If none match, broadcast `FEEDBACK kind=proposal` instead.

### Legitimate vs illegitimate examples

| Situation | Legitimate channel |
|-----------|--------------------|
| "Should I close this stale PR?" | **Team consensus** (broadcast FEEDBACK proposal); illegitimate to ask operator |
| "Which of these 4 design options should we use?" | **Team consensus** (broadcast FEEDBACK proposal with quorum target); illegitimate to AskUserQuestion |
| "Should I admin-merge this PR?" | **Team consensus via PR #2841 ConsensusCoordinator gate**; illegitimate to ask operator unless T4 |
| "Should I push the R2 cred rotation?" | **T2 — operator escalation legitimate** (operator has the secret values) |
| "Trunk is red on 4 simultaneous failure surfaces and deliberator is down" | **T4 — operator escalation legitimate** (consensus mechanism unsafe) |
| "Should we partner with Anthropic?" | **T3 — operator escalation legitimate** (operator-explicit-domain) |
| "We need to choose between X and Y for the cockpit design" | **Team consensus** (broadcast FEEDBACK proposal); illegitimate to ask operator |

### Enforcement

- Detector emits `kind=operator_escalation_unjustified` (registered in `docs/observability/EVENT_REGISTRY.yaml`) when an agent invokes operator-escalation outside the 4 triggers
- Audit leaderboard: `scripts/dev/operator-escalation-leaderboard.sh` shows agents-per-day with unjustified escalations
- SLO target: < 1 unjustified escalation per fleet-day
- This rule extends to sub-agents via [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md)

## Ship discipline — core hard rules (RESILIENT-259, harness-agnostic)

These apply to **any** agent that claims/ships a gap through the `chump`
CLI and `bot-merge.sh` pipeline — Claude Code, opencode, Codex, or manual —
not just Claude Code sessions:

- **Never push directly to `main`.** Every change lands via a PR.
- **Auto-merge is the default.** `bot-merge.sh --auto-merge` arms it. Once
  armed, treat the PR as frozen — new work goes in a new PR.
- **PRs are intent-atomic**, not file-count-bounded. One logical change per PR.
- **`--no-verify` is the reason most regressions ship.** Use very sparingly.
- **Mutate gaps via `chump gap …` only** — `.chump/state.db` is canonical.
  Use `chump gap show <ID>` to inspect; never hand-edit `docs/gaps/*.yaml`.
- **Commit often** (every 30 min) — use `scripts/coord/chump-commit.sh <files> -m "msg"`,
  not bare `git commit`.
- **Rebase if your branch is more than 15 commits behind main.**
- **Never leave a lease behind** — release the claim or delete
  `.chump-locks/<session>.json` when the gap ships or is abandoned.
- **Off-rails guard (RESILIENT-025/026): claim contract enforced at commit +
  push.** When a `.chump-locks/claim-*.json` exists, the pre-commit hook
  blocks any commit whose subject doesn't contain the claimed gap ID
  (RESILIENT-025, always on), and the pre-push hook blocks pushes from the
  wrong branch. Path-scope enforcement (RESILIENT-026) is opt-in — it only
  fires when the claim declared paths via `chump claim --paths CSV`. Disable
  (rare): `CHUMP_OFF_RAILS_CHECK=0`.
- **Uncommitted work is the ONE class git cannot recover — commit early
  (RESILIENT-256).** Unstaged changes never enter the object store: no
  reflog entry, no stash, `git fsck --lost-found` finds nothing. Use `chump
  wip-snapshot [--dir D]` to write a dirty tree to `refs/wip/<branch>/<epoch>`
  without touching the working tree, and never work in a shared primary
  checkout — use a linked worktree (`scripts/dev/own-worktree.sh <slug>`) so
  a `reset --hard` or `checkout -- .` can never destroy another session's
  in-flight work.

## Claiming, shipping, and local CI

- Claim first: `chump gap preflight <ID>` then `chump claim <ID> --role <role>` (atomic: worktree + lease). Always work in a linked worktree.
- Before any push touching Rust or scripts run `chump preflight` (fmt/clippy/check + matching `scripts/ci/test-*.sh`).
- Ship with `scripts/coord/bot-merge.sh --gap <ID> --auto-merge`; manual fallback: push, `gh pr create`, `chump gap link-pr`, `gh pr merge --auto --squash`.
- Read PR state from `.chump/github_cache.db` (`scripts/lib/github_cache.sh`) before calling `gh`; tag non-critical gh calls `CHUMP_GH_CALL_CRITICALITY=background`.
- File follow-up gaps via `chump gap reserve` (P0/P1 need `--outcome`); vote on open `FEEDBACK kind=proposal` via `chump vote`.

## Rulebook budget (ZERO-WASTE-125)

CLAUDE.md <= 150 lines, AGENTS.md <= 300 lines (`scripts/ci/test-rulebook-budget.sh`). At budget, adding a rule requires removing one. Every rule/gate is registered in `docs/process/RULE_REGISTRY.tsv`; `python3 scripts/ops/rules-registry.py audit` ranks delete candidates. Sections removed in the first prune cycle live in git history (`git log -p -- AGENTS.md`).
