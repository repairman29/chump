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

Chump's own development is done by the fleet — Claude Code, opencode, and
manual operator commits all interop through the same coordinator primitives.

See [`docs/ROADMAP.md`](./docs/ROADMAP.md) for the 4-pillar mission and active thrusts,
[`docs/architecture/ARCHITECTURE.md`](./docs/architecture/ARCHITECTURE.md) for the system map,
[`docs/research/RESEARCH_PLAN_2026Q3.md`](./docs/research/RESEARCH_PLAN_2026Q3.md) for current
direction, and [`docs/architecture/TEAM_OF_AGENTS.md`](./docs/architecture/TEAM_OF_AGENTS.md) for the
multi-agent design.

## Build commands

```bash
cargo build                       # debug build of full workspace
cargo build --release             # release build
cargo build --bin chump           # CLI binary only (fastest iteration)
cargo check --bin chump --tests   # type-check without codegen (use this in tight loops)
```

## Test commands

```bash
cargo test                        # full workspace test run
cargo test -p <crate>             # single crate
cargo test <name_substr>          # filter by test name
cargo test -- --nocapture         # show println! output during tests
```

## CI test fixture conventions (INFRA-505)

Tests under `scripts/ci/` must not couple to real gap IDs or live file paths
as fixtures — every architectural change cascades into test fixes otherwise
(5 cascading breaks during the YAML-deletion arc, INFRA-499).

**Allowed patterns:**

- **Self-contained reservation:** reserve a fresh gap on-the-fly with
  `chump gap reserve` (e.g. `coord-surfaces-smoke.sh`).
- **Synthetic IDs:** use placeholder IDs that can never be real gaps:
  `INFRA-B1`, `EVAL-TEST`, `TEST-A` — uppercase `TEST` prefix or a letter
  suffix signals synthetic.
- **Isolated temp repo:** create a `$(mktemp -d)` git repo with arbitrary
  fixture data; the fixture IDs are contained within that temp tree.
- **Fixture-as-argument:** accept `--gap-id <ID>` so CI can pass any ID.

**Required when you break a rule:**

If a test references a real gap ID or a live `docs/gaps/<ID>.yaml` path,
add a `# why this is OK:` comment immediately before the reference that
explains: (a) what the fixture is, (b) why it cannot be replaced, and (c)
that the file is not actually read from the live repo.

Violation without a comment is a PR review blocker. See
`scripts/ci/test-ci-fixture-coupling.sh` for the automated lint.

## Rust-first vs. shell-OK (META-064)

When you reach for `nano scripts/coord/foo.sh`, check the criteria first.
The codebase has shipped 16k+ LOC of "this was shell, now we port it to
Rust" gaps in the last quarter. Most could have been Rust from day 1.

**Rust-first IF *any* of these hold:**
- Mutates canonical state: `state.db`, `.chump-locks/*.json`, `ambient.jsonl`, `docs/gaps/*.yaml`
- Called from a hot path: `worker.sh` per-cycle, `bot-merge.sh` per-ship, every claim
- Shares a process boundary with a Rust caller (subprocess-race candidate)
- Will outlive 3 months (durable tooling)
- > 200 LOC at first commit

**Shell is OK IF *all* of these hold:**
- Glue between existing CLI tools (`gh` + `git` + `jq`)
- One-shot or exploratory
- < 200 LOC, no state mutation
- No regression-test maintenance burden

**Bypass:** for legitimate shell that meets Rust-first criteria (e.g. a
30-line glue shim), add to the commit body trailer:
```
Rust-First-Bypass: <one-sentence reason>
```
Enforced by `scripts/git-hooks/pre-commit-rust-first.sh`; bypass goes
into the audit log.

## Redundancy prevention (META-063)

Before writing a new `*.sh` under `scripts/coord/`, `scripts/ops/`, or
`scripts/dispatch/`, **check whether existing files in the same dir
already do most of the work.** Today's audit (2026-05-14) found:
- 7 worktree-scanning reapers (collapse target: `scripts/lib/worktree-iter.sh`)
- 4 stacked `gh` wrapper layers
- 8 lease-JSON parsers reinventing the same regex
- 6 CI tests hard-coding `src/gap_store.rs` for content greps

Each of these was added as a "new" script that *looked* unique at filing
time but ended up consolidated retroactively. The `pre-commit-redundancy.sh`
hook catches the worst class: bash function-name shape that overlaps
Jaccard ≥ 0.6 with an existing sibling.

**Bypass:** when the overlap is intentional (e.g. a deliberate variant
that legitimately can't extend the existing file), add to the commit
body trailer:
```
Redundancy-OK: <one-sentence reason>
```
Logged to ambient as `kind=redundancy_bypass_used`.

Sibling rules: META-064 (Rust-first), META-065 (auto-prioritization).

## Lint and format commands

```bash
cargo fmt --all                   # format the workspace (CI runs --check)
cargo fmt --all -- --check        # what CI runs
cargo clippy --all-targets --all-features -- -D warnings
```

The pre-commit hook auto-runs `cargo fmt` on staged `.rs` files and re-stages
the result, so manual `cargo fmt` is rarely required before committing.

## Local CI discipline — mandatory (INFRA-1673)

**Run local CI before every push that touches Rust or scripts.** The same
failure caught locally costs <60s; caught on GitHub Actions it costs ~15
minutes round-trip. Long-term direction: **fully local execution, GitHub
Actions as opt-in fallback only**.

```bash
chump preflight              # INFRA-1670 (once shipped): single command that
                             # runs cargo fmt --check, clippy -D warnings, check,
                             # and any scripts/ci/test-*.sh that match the diff.
                             # Target: <60s warm, <120s cold.
```

Until INFRA-1670 ships, do it manually:

```bash
PATH=$HOME/.cargo/bin:$PATH cargo fmt --all -- --check
PATH=$HOME/.cargo/bin:$PATH cargo clippy --workspace --all-targets -- -D warnings
PATH=$HOME/.cargo/bin:$PATH cargo check --workspace
# Then any scripts/ci/test-*.sh that match the files you touched.
```

**Bypass discipline:** if you must push without preflight (emergency, agent
sandbox without cargo, etc.), set `CHUMP_PREFLIGHT_SKIP=1` AND add a
commit-body trailer:

```
Preflight-Skip-Reason: <one sentence why>
```

Each bypass emits `kind=preflight_bypassed` to `ambient.jsonl` for audit.
Routine bypasses surface in retrospectives.

**Why mandatory:** 2026-05-20→22 surfaced 6 distinct CI failure classes
(cargo fmt drift, clippy dead_code, INFRA-682 path-filter, INFRA-1274
raw-gh allowlist, INFRA-1287 registry-orphan, INFRA-755 obs-budget) — every
one a 1-line fix that would have taken <30s locally. Slow round-trips are
discipline failures, not CI bugs.

**Pairs with:** INFRA-1670 (the tool), INFRA-1671 (pre-push hook),
INFRA-1672 (smart scoping for speed).

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

## Reading code economically (DOC-019, 2026-05-03)

Token cost discipline. Every full file read of `provider_cascade.rs`
(~1500 lines) or similar costs ~5-8K input tokens. After context
compaction the same agent often re-reads the same file — observed 2× in
a single session 2026-05-03. At fleet scale this is real budget.

- **Files >500 lines: default to `grep -n <symbol>` + `Read offset/limit`.**
  Read the full file only when the change touches structure (cross-cutting
  refactor, file-level rename). For point fixes — even ones that read
  several disjoint regions — `grep -n` then 2-3 narrow `Read`s wins by
  large margins.
- **`Read` supports `offset` + `limit`.** Use them. The line-number
  output from `grep -n` is the offset.
- **`cat` is forbidden via the Bash tool.** Use `Read` instead — same
  reason: tighter scoping and a reviewable transcript.

When in doubt: grep first, ask what region is relevant, then read it.

## PR check polling discipline (DOC-020, 2026-05-03)

`gh pr checks <N>` polling burns output tokens fast (~200/poll for the
diff + your reasoning). Cap at **3 attempts** per session, then back off:

1. **Hand off to `pr-watch-shepherd`** — already running on launchd, will
   auto-rebase + re-arm DIRTY/BEHIND PRs. Don't do its job.
2. **Use `ScheduleWakeup` (~1200s) or `Bash run_in_background`** for
   "check back later" — the runtime notifies you when something
   completes, so you don't poll.
3. **Move on to the next gap.** PRs are async; treat them that way.

Never poll a check loop in a tight `while`. If you find yourself doing
"let me just check one more time," stop — you're rate-limiting your own
session, and someone else's PR is starving for review.

## Cache-first reads (INFRA-1081, 2026-05-14)

The fleet has a **local SQLite cache** at `.chump/github_cache.db` populated
by a webhook receiver (`scripts/ops/github-webhook-receiver.py`). Every
script that wants PR state should **read from the cache first**, fall back
to direct `gh api` only on miss.

Source the helper lib then call the cache helpers:

```bash
source "$(dirname "$0")/lib/github_cache.sh"

# PR state — replaces gh pr view
cache_lookup_pr "<number>"            # returns JSON; falls back to REST on miss

# BEHIND scan — replaces gh pr list with mergeStateStatus filter
cache_query_behind_prs                # one PR number per line

# Per-PR check status — replaces gh api repos/X/commits/SHA/check-runs
cache_lookup_checks "<head_sha>"      # tab-separated name\tstatus\tconclusion
```

**Already-migrated callers:** `queue-driver.sh` (BEHIND scan),
`chump-ambient-glance.sh --check-prs` (overlap scan via bot-merge),
`pr-rescue.sh` (per-PR meta loop).
**Next consumers** (open gaps): `bot-merge.sh` per-PR check-runs polling,
`ghost-gap-reaper.sh`, others identified by the API cost leaderboard
(`scripts/dev/api-cost-leaderboard.sh`).

**When in doubt:** read from cache. Cache miss is one cheap REST call;
polling GraphQL is the costly path.

## Call criticality (INFRA-1080, 2026-05-14)

`chump_gh` (the gh wrapper in `scripts/coord/lib/github.sh`) classifies each
call as **critical** (default) or **background**. Background calls are
preempted when `remaining_graphql < CHUMP_GH_BACKOFF_THRESHOLD%` (default
10%) so critical-path operations never starve.

```bash
# Default — proceeds even when bucket is tight
chump_gh pr merge "$PR" --auto --squash

# Tag as background — yields to critical callers when graphql is low
CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list ...
```

| Critical (default) | Background (opt-in) |
|---|---|
| `gh pr create` / `gh pr merge` | label updates |
| `gh pr update-branch` | overlap scans |
| ship-blocking REST writes | dashboard refreshes |
| operator-initiated rescue | cache reconcile per-PR fetches |

Without criticality tags a background dashboard poll can starve a
ship-blocking merge. With them, the merge fires, the poll waits.

## GraphQL exhaustion handling (INFRA-1040 / INFRA-1079)

Automated:

- **Secondary rate-limit self-throttle** — `chump_gh` caps fleet calls to
  `CHUMP_GH_MAX_CALLS_PER_MIN` (default 60) via a shared sliding window.
  Per-script override: `CHUMP_GH_THROTTLE_<UPPERCASE_SCRIPT>=N`.
- **Exhaustion signal** — first call to see `remaining_graphql ≤ 100` emits
  `kind=graphql_exhausted` to `.chump-locks/ambient.jsonl` (debounced once
  per reset window). Every agent watching ambient pivots to REST-only paths
  simultaneously.

When you see repeated `kind=graphql_exhausted` or `kind=gh_self_throttled`
in ambient:

1. Run `scripts/dev/api-cost-leaderboard.sh --window 1h` to find the burner.
2. Background-tag the noisiest non-critical caller via
   `CHUMP_GH_CALL_CRITICALITY=background`.
3. If structural, file a follow-up gap migrating that caller to
   `cache_lookup_*` helpers.

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

## How to claim work

Chump uses a **gap registry** stored canonically in `.chump/state.db`
(SQLite, since INFRA-059). `docs/gaps/<ID>.yaml` files are a human-readable
per-file mirror (post-INFRA-188) that gets regenerated, not edited by hand.
Each gap is an atomic unit of work with a stable ID (e.g. `COMP-007`,
`MEM-007`). Before starting work:

0. **Install pre-commit hooks** (one-shot, after fresh clone or `git worktree add`) —
   `scripts/setup/install-hooks.sh`. Idempotent. The hooks (`docs-delta`,
   `closed_pr-integrity`, `raw-YAML-edit`, `recycled-id`, `duplicate-id-insert`,
   `cross-judge-audit`, `preregistration-required`, etc.) catch silent ledger
   corruption + research-methodology violations at commit time. **Without
   them, your commits silently bypass every guard** — Cold Water Issue #10
   (2026-05-02) found 9 gaps shipped to `origin/main` with `closed_pr: TBD`
   precisely because remote-dispatched sandboxes had skipped this step.
   `bot-merge.sh` now auto-bootstraps if hooks are missing (INFRA-209/INFRA-224),
   but the explicit one-shot is still the right call when you first land in a fresh checkout.

1. **Pick an open gap** — `chump gap list --status open` (canonical) or
   `grep -lE 'status:[[:space:]]*open' docs/gaps/*.yaml` (per-file mirror fallback).
2. **Preflight** — `chump gap preflight <GAP-ID>` checks done-on-main and live
   claims by sibling sessions.
3. **Claim** — `chump gap claim <GAP-ID>` writes a lease file under `.chump-locks/<session_id>.json`.
   **Claims do not go in the registry** — they live in lease files only.
   The registry records `status: open` / `status: done` and nothing else
   about ownership. The `CHUMP_GAPS_LOCK` pre-commit guard rejects writes
   of `in_progress` / `claimed_by` / `claimed_at` to any `docs/gaps/<ID>.yaml`.
   **Never leave a lease behind** — run `chump --release` or delete
   `.chump-locks/<session>.json` when the gap ships or is abandoned.
4. **Work in a linked worktree** — `git worktree add .chump/worktrees/<name>
   -b chump/<codename> origin/main` (canonical; see "Naming conventions"
   below). Existing `.claude/worktrees/` paths still accepted by tooling.
   Never work in the main repo root.
5. **Reclaim disk (many worktrees / agents)** — Each linked worktree grows its
   own `target/` (multi‑GB). After ship, `bot-merge.sh` deletes `./target` in
   that tree unless `CHUMP_KEEP_TARGET=1`. For merged or abandoned trees, run
   `scripts/ops/stale-worktree-reaper.sh` (starts in **dry-run**; use `--execute` to
   remove) or on macOS install the hourly LaunchAgent once:
   `scripts/setup/install-stale-worktree-reaper-launchd.sh`, then verify
   `launchctl list | grep dev.chump.stale-worktree-reaper`. Per-tree
   opt-out: `touch <worktree>/.chump-no-reap`. Details: `CLAUDE.md` section
   **Worktree disk hygiene**.

### Diagnosing divergence (added 2026-05-02 / META-014)

Before filing an RCA / regression gap that claims "X reverted my change /
X overwrote my edit / origin has unexpected state," **verify against
origin/main directly.** Agents routinely conflate local working-tree
state (and system-reminder file content, which mirrors the local checkout)
with what's actually on the trunk. INFRA-238 is the cautionary example:
~30 minutes wasted writing a P0 root-cause analysis for a phantom revert
that turned out to be a stale local working tree 8 commits behind
origin/main. The closures had **always** been `status: done` upstream;
only the local checkout still showed `status: open`. The gap had to be
closed as misdiagnosis (PR #804) with a long `closed_interpretation`.

```bash
# Before filing an RCA / regression gap, verify against origin/main:
git fetch origin main --quiet
git show origin/main:<file> | head -50          # what's actually on main
git diff HEAD origin/main -- <file>             # how your tree differs
git log origin/main --oneline --since='2 days ago' -- <file>
```

Apply this any time you're about to file a "this used to work,"
"X reverted my Y," or "origin has unexpected state" gap. **Always.**
If the verify-against-origin output shows the expected state, the
"divergence" was a stale local working tree, not a real revert — don't
file the gap.

When the gap ships, run `chump gap ship <GAP-ID> --update-yaml` to flip
`status: done` + stamp `closed_date` in `.chump/state.db` AND regenerate
`docs/gaps/<GAP-ID>.yaml` so the human-readable diff lands **atomically with
the implementing PR** (one commit, not a follow-up).

**Spawning subagents — always prepend the default briefing prefix (META-028).**
Every `Agent`-tool prompt must start with the contents of
`docs/process/SUBAGENT_DEFAULT_BRIEFING.md` (or the path returned by
`bash scripts/lib/get-agent-briefing-prefix.sh`). The prefix includes the
no-clarifying-questions directive, Agent-vs-SendMessage discipline, chump-doctor
heal pattern, and manual-recovery budget. Override project-wide with
`CHUMP_AGENT_DEFAULT_PREFIX=<path>`. Without this prefix, subagents routinely
stall on clarifying questions or fail to self-ship.

**Running a fleet of agents (INFRA-203).** The canonical multi-agent
launcher is `scripts/dispatch/run-fleet.sh` — it spawns N tmux panes plus a
control pane, with each worker looping pick-gap → claim → worktree →
`claude -p --dangerously-skip-permissions` → ship via `bot-merge.sh` →
release. Defaults: `FLEET_SIZE=8`, P0/P1 only, xs/s/m effort only,
auto-pickup excludes EVAL-/RESEARCH-/META-. Knobs: `FLEET_SIZE`,
`FLEET_DOMAIN_FILTER`, `FLEET_TIMEOUT_S`, `FLEET_DRY_RUN=1` (plan-only).
Stop with `tmux kill-session -t chump-fleet` or `FLEET_SIZE=0
scripts/dispatch/run-fleet.sh`. See `CLAUDE.md` section **Fleet launcher**
for the full env reference.

**Gap closure precision fields (2026-04-24):**
- `acceptance_verified:` — array of `yes` / `no` for each acceptance criterion,
  documenting which criteria justified closure when not all are met. Prevents
  definition drift (e.g., "eliminate all panics" filed vs "categorize production
  panics" executed).
- `closed_interpretation:` — free text explaining the closure rationale when
  criteria changed mid-execution. Example: "Aggregate signal never measured
  under working LLM judge (EVAL-069 used broken scorer); task-cluster
  localization (EVAL-029) stands independently." Makes evolution visible in diffs.

## Filing follow-up gaps — the feeder system (2026-05-02)

**The gap registry only stays useful if it is actively fed.** When you
spot a real bug, design hole, tooling drift, reproducible guard misfire,
coordination race, or non-obvious finding while doing other work — file
it as a gap **immediately**. Do not ask the operator first.

**Why this is non-negotiable:**

The cost of NOT filing is silent regression: every shipped session leaves
behind 2–5 unfiled findings the agent diagnosed end-to-end. Without a
filing reflex, those findings die with the session context and resurface
later as fresh incidents (with the same root cause and a new
investigator). The cost of an over-eager filing is near zero: gap-doctor
detects YAML↔DB drift, the closer-pr-batcher reaps stale ones (modulo
INFRA-219 false-closes), and humans can re-prioritize freely. **Asymmetric
cost = bias toward filing.** This is exactly why the registry has
hundreds of small-effort gaps and is still load-bearing.

**Triggers (file when you observe any of these):**

- A bug you diagnosed end-to-end (root cause + reproducer in hand).
- A tool / script / workflow that doesn't behave as documented.
- A pre-commit / pre-push / CI guard that misfires reproducibly.
- A coordination race or stomp you recovered from manually.
- A toolchain mismatch surfaced by a major change (e.g. a flag that
  references a now-deleted file, an env var with stale defaults).
- A pattern you recognize that already happened ≥2 times in this session
  or recent ambient.jsonl.

**Skip filing only when:**

- You lack confidence the finding is real (it could be a one-off, a
  user-error, an environment quirk).
- It's pure speculation about hypothetical edge cases nobody's hit.
- It's already filed (search `chump gap list --status open` first; the
  ID picker race + closer-batcher false-close mean dup-filings happen).

**The filing flow (post-INFRA-188 cutover):**

```bash
chump gap reserve --domain INFRA --title "<one-line title>" \
  --priority P1 --effort s
# → returns INFRA-NNN
chump gap set INFRA-NNN --description "$(cat <<'EOF'
<paragraph: what's broken, reproducer, fix paths>
EOF
)" --acceptance-criteria "<criterion 1>|<criterion 2>"
# Surgical YAML write (the canonical state.db → docs/gaps/<ID>.yaml
# tooling has known lossiness — INFRA-208 / INFRA-233; surgical Write
# is the only safe per-file path until those land):
#   create docs/gaps/INFRA-NNN.yaml mirroring the schema of a sibling.
git add docs/gaps/INFRA-NNN.yaml
CHUMP_RAW_YAML_LOCK=0 scripts/coord/chump-commit.sh \
  docs/gaps/INFRA-NNN.yaml -m "chore(gaps): file INFRA-NNN — <title>"
CHUMP_GAP_CHECK=0 git push -u origin chore/file-infra-NNN
gh pr create --base main --title "..." --body "..." && \
  gh pr merge $(gh pr list --head chore/file-infra-NNN \
    --json number -q '.[0].number') --auto --squash
```

**Priority guidance** (set your best judgement; operator re-prioritizes):
- **P0** — blocks current work for the team / fleet (queue-jam, every-PR
  guard misfire, data-loss bug).
- **P1** — observed-and-painful (tools that misbehave when you reach for
  them, drift that bites repeatedly).
- **P2** — niggling (test coverage holes, stale comments, ergonomic
  improvements, doc-vs-code drift not actively biting).

**Bundling:** when multiple findings share a session origin or causal
chain, bundle them into ONE PR with multiple `chore(gaps): file …`
entries to save merge-queue friction. Atomic-PR discipline still holds
— bundle ≠ pushing after arm. But each individual gap still gets its
own per-file YAML + state.db row.

**Lessons fed back:** the `chump_skills` table (INFRA-195) and the
COG-024 lessons-injection pipeline both depend on this feeder system.
Filings → reflections → distilled directives → next-session prompt
context. The loop is only as strong as the upstream filing rate.

## Filing meta-patterns — when individual filings aren't enough (2026-05-02)

Reactive filing (file the symptom you just observed) is necessary but
**not sufficient.** Sessions in flow miss recurring patterns because each
incident looks unique in the moment. Three behaviours close that gap:

**1. Periodic RCA pass.** At cycle end (and at any natural pause —
between PRs, after a multi-step task lands, when the operator says
"review"), run a 5-minute scan: of the gaps you filed this session,
which share root causes? Which describe the same class of
failure? File a META-* gap covering the class.

The 2026-05-02 ghost-elimination session is the cautionary example:
14 individual gaps filed (INFRA-208, 216, 217, 219, 220, 232, 233,
234, 236, 237, 238, 241, 243; META-006/012). Two recurring patterns
(per-file YAML mid-flight collisions; agents conflating local
working tree with origin/main state) only got filed (INFRA-246,
META-014) **because the operator asked**. Without that prompt, both
would have slipped — both will keep biting at fleet-size 8+.

**2. Verify-against-origin/main before filing RCA gaps.** This
guardrail goes in [META-014](docs/gaps/META-014.yaml) — adding a
"Diagnosing divergence" subsection above. Briefly: when a gap
description claims "X reverted my change / X overwrote my edit /
origin has unexpected state," verify with `git fetch origin main &&
git show origin/main:<path>` BEFORE filing. INFRA-238 was a 100%
misdiagnosis (~30 min wasted + closure-by-supersession PR) caused by
reading system-reminder file content as origin/main state.

**3. Pattern-counter automation.** [INFRA-249](docs/gaps/INFRA-249.yaml)
ships `scripts/coord/recurring-gap-pattern-detector.sh` — runs against
recently-filed gap titles, surfaces clusters with N≥3 gaps in 7 days
sharing significant keywords. ALERT lines emit to `ambient.jsonl` so
agents see "the team has filed 4 'guard misfire' gaps in the last
week — consider a META-* gap covering the class" without having to do
a periodic-RCA pass manually. Defense in depth, not replacement for
behaviour 1.

**4. Runtime verification before missing-claim.** Before filing a gap
that claims a feature is missing, broken, or unfiled, run all three
checks. `chump gap show <ID>` returns "not found" both for typos AND
for gaps that shipped and were reaped from the active registry — the
silence is ambiguous and will mislead you:

- **`gh search code <ID>` (or `git log --all --oneline | grep <ID>`)** —
  does the gap ID appear in any shipped commit subject? Reaped gaps
  leave their `feat(<ID>):` commit behind even after the YAML is gone.
- **`ast-grep --pattern 'fn $NAME(...)' src/`** (or `grep -rln <symbol>
  src/`) — does the symbol exist? Raw grep misses generics and matches
  comments; ast-grep is structural.
- **Runtime surface** — does the script exist on disk (`test -x`)? Is
  the endpoint registered in `web_server.rs` (`grep -n '"/api/X"'`)?
  Is the ambient `kind` actually emitted by anyone (`grep -rE
  '"kind":"<X>"' src/ scripts/`)?

The helper `scripts/dev/verify-existence.sh <ID-or-symbol>` (INFRA-1589)
runs the four standard checks and returns tri-state
`{confirmed_shipped | confirmed_absent | ambiguous}` so you can do this
in one shell call before filing.

[INFRA-1575](docs/gaps/INFRA-1575.yaml) (2026-05-16) is the cautionary
precedent: an agent filed a P1 gap claiming a 10-gap A2A implementation
chain (INFRA-1296..1302 + PRODUCT-103..105) was missing from the
registry. All ten had in fact shipped (PRs #1900, #1960, #1967, #1969,
#1972, #1991, #1992, #1994, #1997, #1998, #2004). The agent stopped at
`chump gap show: not found` and never checked git history or the
runtime surface (broadcast.sh exists, /api/broadcast registered).
INFRA-238 is the earlier sibling — claiming origin/main reverted state
without `git fetch origin main && git show origin/main:<path>`
verification. Same class.

[INFRA-1583](docs/gaps/INFRA-1583.yaml) (chump-mcp-code MCP server,
Phase 5) will ship a structured query layer that makes these checks
one MCP call each, 100× cheaper than file reads. Until then, the
CLI shortcuts above are the discipline.

**Why these four matter together:** behaviour 1 is the human-in-the-
loop catch (what the operator just did with the "Did we do any RCA
work?" question). Behaviour 2 prevents stale-tree misdiagnosis.
Behaviour 3 automates the cluster-detection half of behaviour 1 so
cycle-end RCA becomes "review the pattern-detector's ALERT list"
instead of "scan all session filings from memory." Behaviour 4 closes
the missing-claim misdiagnosis class (INFRA-1575 / INFRA-238) by
requiring runtime verification before existence assertions. None alone
is enough; together they make both pattern-blindness AND
existence-hallucination recoverable errors rather than silent ones.

## Naming conventions (INFRA-186, 2026-05-01)

**The project owns the namespace, not the tool.** Branches, worktree
paths, lease files, ambient events, and bot identities use the
`chump-` / `chump/` / `.chump/` prefix regardless of which agent
(Claude, Cursor, Goose, Aider, future tools) is the actor. The
specific tool identity is captured separately — in commit author /
co-author fields, lease metadata, and ambient `session_start` events
— not embedded in shared project artifacts.

**Why this matters:** when the convention is `claude/<codename>`,
every other tool that joins the fleet either renames-on-arrival
(observed friction: an agent recently renamed
`worktree-fleet-matrix-wiring` → `claude/...` because CLAUDE.md said
so) or pollutes the namespace with `cursor/`, `goose/`, `aider/`
prefixes. Both leak the tool of origin into project history where it
doesn't belong.

| Artifact | Canonical | Acceptable (legacy) |
|---|---|---|
| Feature branch | `chump/<short-codename>` | `claude/<…>`, `cursor/<…>`, etc. |
| Linked worktree | `.chump/worktrees/<name>/` | `.claude/worktrees/<…>` |
| Lease file dir | `.chump-locks/<session>.json` | (already canonical) |
| State / SQLite | `.chump/state.db`, `.chump/state.sql` | (already canonical) |
| Bot commit identity | `<role>@chump.bot` (e.g. `cold-water@chump.bot`, `chump-ftue-bot@…`) | (already canonical) |
| Ambient stream | `.chump-locks/ambient.jsonl`, NATS subject `chump.events.>` | (already canonical) |

**Migration:** existing `claude/*` branches and `.claude/worktrees/`
trees stay as history — no rename. New branches and worktrees use
`chump/<codename>` and `.chump/worktrees/<name>` from this commit
forward. `bot-merge.sh` and `chump gap` commands accept either prefix during
the transition (INFRA-187 will tighten the default to `chump/`).

**Tool-specific overlays** (skills, hooks, harness behavior) still
live in tool-named files: `CLAUDE.md`, `GEMINI.md`, `.cursorrules`,
etc. Those defer to AGENTS.md for shared conventions and only carry
tool-specific overlays. If a rule appears in both AGENTS.md and a
tool-specific file, AGENTS.md wins.

**Freshness discipline** — every harness must defend against the seven
staleness layers (git main, state.db, chump binary, launchd plists, YAML
gaps, fleet-registry, docs). Before any "X is missing" claim, run
`git ls-tree origin/main path/to/X` or invoke the harness equivalent of
the `verify-existence` check — local `ls` lies when the checkout is
40+ commits behind. Full rules + per-layer fixes + anti-patterns in
[`docs/process/FRESHNESS_DISCIPLINE.md`](docs/process/FRESHNESS_DISCIPLINE.md)
(DOC-059 / META-114). The per-session preamble at
`scripts/coord/freshness-preamble.sh` (META-115) is harness-neutral and
classifies session-start state as FRESH/STALE/CRITICAL_STALE.

## Pull request guidelines

- **Branch:** `chump/<short-codename>` (canonical, see "Naming
  conventions" above). Never push directly to `main`. Existing
  tool-prefixed branches (`claude/<…>`, `cursor/<…>`) still accepted
  by tooling for backward compat; new branches use `chump/<codename>`.
- **Intent-atomic, not file-count-bounded.** A PR is one logical change — a
  feature, a bug fix, a codemod, a config update. Mechanical multi-file
  refactors (renames, dead-code removal, dep swaps) ship as one PR no matter
  the file count, because the merge queue verifies the whole change end-to-end
  and one revert beats coordinating three. Stack only when the changes are
  *logically* distinct. (Older guidance said "≤ 5 files" — that was for human
  reviewers; superseded by the merge-queue + required-CI workflow.)
- **One gap per PR.** If you find adjacent work, open a follow-up PR rather
  than expanding the current one.
- **Ship via the pipeline** — `scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge`
  rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and arms the
  merge queue. See `CLAUDE.md` for the Chump-specific arming/freeze rule
  (don't push to a PR after auto-merge is armed).
- **Commit messages:** conventional-commits style — `feat(<gap-id>): summary`,
  `fix(<scope>): summary`, `docs(<scope>): summary`. The gap ID in the
  commit subject lets the pre-push hook validate scope.
- **Off-rails guard (RESILIENT-025/026): full claim contract enforced at commit and push.** When a `.chump-locks/claim-*.json` exists, the pre-commit hook blocks commits whose subject doesn't contain the claimed gap ID (RESILIENT-025), blocks staged files not in `claim.paths` (RESILIENT-026 — auto-allowed: `.chump/state.sql`, `docs/gaps/*.yaml`, `.gitignore`), and the pre-push hook blocks pushes from the wrong branch (`chump/<gap-id>-claim` required, RESILIENT-026). Intentional pre-req integrations: add `Off-Rails-Bypass: <reason>` trailer (emits `kind=off_rails_bypassed` with `bypassed_field` for audit). Bypass: `CHUMP_OFF_RAILS_CHECK=0`.

### Stacked PRs (INFRA-061 / M3)

When two related gaps would touch the same files, ship them as a **stack**
instead of in parallel — the second PR uses the first PR's branch as its
base, so when the first PR lands, the merge queue auto-rebases the stacked
PR onto the new main:

```bash
# Ship the prerequisite (e.g. add an API)
scripts/coord/bot-merge.sh --gap GAP-A --auto-merge   # opens PR #100, base=main

# Ship the dependent change (e.g. migrate callers) on top
scripts/coord/bot-merge.sh --gap GAP-B --stack-on GAP-A --auto-merge
# opens PR #101 with base=claude/<branch-of-PR-100>
```

`bot-merge.sh` resolves `--stack-on <PREV-GAP>` via `gh pr list` to find the
prev gap's open PR head branch; if no open PR is found (prev already
landed), it silently falls back to `base=main`. One-deep stacks cover the
common dispatcher case; deeper stacks chain by always `--stack-on`-ing the
most recent open ancestor.

`chump gap reserve --stack-on <PREV>` records the dependency hint and
prints the right `bot-merge.sh` invocation to stderr — useful when the
musher is reserving the gap programmatically and needs to remember to
stack later.

Reserve stacks for **logically distinct** changes; a single mechanical
codemod across many files should still ship as one atomic PR.

## Cross-tool note

Chump-internal agents read **both** `AGENTS.md` and `CLAUDE.md` (concatenated,
with `AGENTS.md` first as the canonical layer and `CLAUDE.md` as the
Chump-specific overlay). External agents that only honor the AGENTS.md
convention will get a coherent project picture from this file alone — they
won't get the lease/NATS coordination details, but they'll know the build,
test, code-style, and PR conventions.

For Cursor-specific behavior, CLI delegation, and safe multi-agent fleet work see
`docs/process/CHUMP_CURSOR_FLEET.md` and `.cursor/rules/chump-multi-agent-fleet.mdc`
(plus `.cursor/rules/chump-cursor-agent.mdc`). For learned user preferences and
workspace facts maintained by `agents-memory-updater`, see `docs/CONTINUAL_LEARNING.md`.

## Publishing to crates.io

See [`docs/operations/PUBLISHING.md`](docs/operations/PUBLISHING.md) for crates.io publish workflow and [`docs/process/CRATES_EXTRACTION_PLAN.md`](docs/process/CRATES_EXTRACTION_PLAN.md) for extraction status.

Publish hygiene rules:
- **No `path` dependencies** in publish-candidate crates — use versioned registry deps
- **Conventional commits** required for auto-changelog (use `feat:`, `fix:`, `chore:` prefixes)
- Run `cargo publish --dry-run` before any PR touching publishable crates
- Check `docs/eval/INFRA-025-crate-publish-audit.md` for bucket classification (publish/internal/repo-only)

## Session handoff format (META, 2026-05-10)

When handing off between agents (e.g. Claude Code → goose, or across
sessions for the same tool), use the structured format documented in
[`docs/CONTINUAL_LEARNING.md`](./docs/CONTINUAL_LEARNING.md). The format
captures: goal, instructions, discoveries, accomplishments, and prioritized
next steps. This prevents context-window loss of diagnosed-but-unfiled
findings between sessions.

## Learned User Preferences

- When continuing another tool's in-flight thread (for example Claude Code), prefer driving the scoped handoff to a clear engineering stopping point (clean commit, PR or merge, and explicit notes on what is still outstanding) before returning to general backlog review unless you explicitly redirect mid-thread.
- For preregistered research gaps that include paid cloud sweeps, treat merged harness and documentation as distinct from empirical gap closure: keep the gap's `.chump/state.db` status (mirrored in `docs/gaps/<ID>.yaml`) accurate until preregistered acceptance criteria (including measured results and the agreed write-up locations) are actually satisfied when API access and budget exist.

## Learned Workspace Facts

- RESEARCH-026 observer-effect work is wired through `scripts/ab-harness/` (`run-observer-effect-ab.sh`, `run-cloud-v2.py`, `sync-reflection-paired-formal.py`, `analyze-observer-effect.py`); continuous integration runs `bash scripts/ci/test-research-026-preflight.sh` without calling external model APIs.
