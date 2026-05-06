# Claude Code — Chump session rules (hot overlay)

## Mission (4 pillars)

Build agents that are **Credible**, **Effective**, **Resilient**, and
**Zero-Waste** — alone or as a team. Every session should answer
whether or not it advanced the mission on at least one pillar.

- **Credible** — outputs are tested, measured, and honest about what
  they do and don't establish.
- **Effective** — moves an agent toward solving real problems, not
  toward shipping infrastructure for its own sake.
- **Resilient** — degrades gracefully, recovers from common failure
  modes (binary wedge, merge conflict, CI flake) without operator
  rescue.
- **Zero-Waste** — does not burn compute, time, or cost on cycles
  that produce no value. Track via `chump waste-tally` (INFRA-488)
  which classifies fleet wedges, starvation, abandoned leases, stuck
  PRs, silent reapers, and lease overlaps from `ambient.jsonl`.

> **Read [`AGENTS.md`](./AGENTS.md) first** for build/test/lint commands,
> code style, gap-registry pattern, PR guidelines.
> **This file** is the must-do-now overlay. **For operational gotchas
> (chump-doctor heal, raw-YAML-edit guard, INFRA-272 path-filter trap,
> stacked-PR rebase footgun, syspolicyd wedge, etc.) read
> [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md)
> on-demand when you hit the failure surface** — do not preload it.
> Eval/cognitive-architecture work also reads
> [`docs/process/RESEARCH_INTEGRITY.md`](./docs/process/RESEARCH_INTEGRITY.md).

## MANDATORY pre-flight (every session, before any work)

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
bash scripts/setup/install-ambient-hooks.sh 2>&1 | tail -2  # FLEET-023, idempotent
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
chump-coord watch &                              # FLEET-006 (skip if NATS unavailable)
chump gap list --status open                     # canonical .chump/state.db
# python3 scripts/coord/gap-doctor.py doctor     # vacuous post-INFRA-498 — no YAML drift to detect
scripts/coord/gap-preflight.sh <GAP-ID>          # exits 1 if not pickable
chump --briefing <GAP-ID>                        # MEM-007 per-gap context
```

`ambient.jsonl` is your peripheral vision — file edits, commits, bash
calls, ALERTs from concurrent sessions. Watch for `lease_overlap`,
`silent_agent`, `edit_burst`, `queue_config_drift`, `pr_stuck`,
`subagent_budget_exceeded`, `lessons_injection_active` — see
[CLAUDE_GOTCHAS.md → ambient event kinds](./docs/process/CLAUDE_GOTCHAS.md).

## Claim before writing any code

**Canonical (INFRA-468, atomic):**
```bash
chump claim <GAP-ID> [--paths CSV]   # one call: fetch + verify + doctor + worktree + lease
                                      # prints `cd <worktree>` hint at the end
```

That replaces the 6-step shell dance and the `cd` mistakes that come
with it. `--paths` is optional but recommended (declares lease scope so
the INFRA-189 out-of-scope guard is meaningful).

**Manual fallback** (use if `chump claim` is broken or unavailable):
```bash
scripts/coord/gap-claim.sh <GAP-ID>                       # existing gap
chump gap reserve --domain INFRA --title "short title"    # new gap (canonical, post-INFRA-059)
```

`gap-claim.sh` writes `.chump-locks/<session>.json`; auto-expires with
the session TTL. Reserved gaps must ship in the same PR as their
implementation. If preflight fails, **stop** — do not bypass.

## Ship pipeline (always)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

Rebases on main, runs fmt/clippy/tests, pushes, opens the PR, runs
`chump gap ship <ID> --closed-pr <PR#> --update-yaml` (INFRA-154
auto-close), arms auto-merge. **`--gap` is required** (INFRA-237) — pass
explicitly, auto-derive from canonical branch name (`chump/infra-NNN-…`),
or use `--gap none` for genuine non-gap PRs.

Manual recovery path if `bot-merge.sh` is broken:
`git push -u origin <branch> --force-with-lease && gh pr create --base main && gh pr merge <N> --auto --squash`,
then `chump gap ship <ID> --update-yaml` and release the lease.

## Hard rules

- **`proprietary/` is a private sibling repo — NEVER commit it here (2026-05-03).** Private swarm-autonomy code lives at `https://github.com/repairman29/chump-proprietary` (PRIVATE), checked out locally at `~/Projects/chump-proprietary/`. This public repo's `.gitignore` lists `proprietary/` as a defense-in-depth safety net. If you see a `proprietary/` directory inside *this* repo's tree it is a stray copy — do not stage it, do not edit it, do not reference it from public code. Public Chump and the private crate are independent: no submodule, no workspace membership, no shared `Cargo.toml`. Fleet workers running in public Chump worktrees should ignore `proprietary/` entirely.
- **Default model: haiku for IDE sessions, sonnet for fleet workers**
  (`.claude/settings.json` pins `claude-haiku-4-5` for the operator's
  Claude Code app; INFRA-515 flipped fleet's `FLEET_MODEL` default to
  sonnet 2026-05-06 because haiku asks clarifying questions instead
  of acting in `--dangerously-skip-permissions` mode — observed 1 ship
  out of 9 cycles on haiku). Cost-sensitive fleet sweeps:
  `FLEET_MODEL=haiku`. Opus is ~50× haiku per token.
- **Never push directly to `main`.** Branch + worktree naming follows
  [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01)
  (canonical `chump/<codename>` branch, `.chump/worktrees/<name>`).
- **Always work in a linked worktree, never in the main repo root.**
  `gap-claim.sh` refuses the main checkout (override
  `CHUMP_ALLOW_MAIN_WORKTREE=1` for bootstrapping only).
- **Never start a gap without `gap-preflight.sh` first.**
- **Never leave a lease behind** — `chump --release` or delete
  `.chump-locks/<session>.json` when done.
- **Commit often** (every 30 min of work) — uncommitted edits risk being
  overwritten by `git pull`.
- **Use `scripts/coord/chump-commit.sh <files> -m "msg"`**, not
  `git add && git commit` — wrapper resets unrelated staged files from
  other agents (twice-observed stomp on 2026-04-17).
- **Mutate gaps via `chump gap …` only** — `.chump/state.db` is canonical;
  `.chump/state.sql` is the tracked human-readable mirror. Per-file
  `docs/gaps/<ID>.yaml` mirrors were deleted in INFRA-498 as redundant
  with state.sql. Use `chump gap show <ID>` for human inspection.
- **Rebase if your branch is more than 15 commits behind main.**
- **Auto-merge IS the default** (since INFRA-MERGE-QUEUE 2026-04-19).
  `bot-merge.sh --auto-merge` arms `gh pr merge --auto --squash` at PR
  creation, BUT only if all required CI checks are passing
  (CI pre-flight gate, INFRA-CHOKE 2026-04-24).
- **Atomic PR discipline.** Once `bot-merge.sh` runs, treat the PR as
  frozen — do not push more commits. If you need to add work, open a
  *new* PR. Pushing-after-arm reintroduces the squash-loss footgun
  (PR #52 lost 11 commits).
- **PRs are intent-atomic, not file-count-bounded.** A PR is one
  logical change. Mechanical refactors ship as one PR regardless of
  file count.
- **`--no-verify` is the reason most regressions ship.** Use very
  sparingly.

## Subagents / fleet / coordination docs

Spawning subagents, fleet launcher knobs, and the full coordination doc
index live in
[`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md)
— read on-demand when you hit a specific failure surface.

## Worktree disk hygiene (INFRA-210)

Each linked worktree historically compiled its own `target/` (2–8 GB after
clippy + test). At FLEET_SIZE=10–50 that becomes a hard disk ceiling.

**Shared target dir (default since INFRA-210):** `run-fleet.sh` auto-exports
`CARGO_TARGET_DIR=$REPO_ROOT/target` when the caller has not set it, so all
fleet worktrees share one target tree. Override to a location outside the repo
(e.g. `~/.cache/chump-fleet-target/`) for even cleaner separation:

```bash
export CARGO_TARGET_DIR=~/.cache/chump-fleet-target
scripts/dispatch/run-fleet.sh
```

Cargo handles concurrent reads safely; concurrent writes to the same crate on
different branches are serialized by cargo's internal file locking.

**sccache (optional, recommended for warm-cache build time):** Install once per
machine with `scripts/setup/install-sccache.sh` (idempotent: `brew install
sccache` + writes `.cargo/config.toml` with `rustc-wrapper = "sccache"` and a
10 GB cache). First worktree to build a crate version populates the cache;
subsequent worktrees compile it in <60 s. `.cargo/config.toml` is
`.gitignore`d so CI runners without sccache are unaffected. Opt out: `rm
.cargo/config.toml`.

**bot-merge.sh target purge:** automatically skipped when `CARGO_TARGET_DIR`
points outside the worktree — the shared cache should not be wiped at ship
time. Set `CHUMP_KEEP_TARGET=1` to suppress the purge even for in-worktree
targets.

Full details (reaper, stale-worktree automation, disk alerts):
[CLAUDE_GOTCHAS.md → Worktree disk hygiene](./docs/process/CLAUDE_GOTCHAS.md).
