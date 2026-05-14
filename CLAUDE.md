# Claude Code — Chump session rules (hot overlay)

> **Canonical agent rules live in [`AGENTS.md`](./AGENTS.md)** (Linux Foundation AGENTS.md spec). This file is the **Claude-Code-specific overlay** — Chump session flow + Claude-Code-only mechanics (subagent spawning, OAUTH token paths, `.claude/` directory conventions).
>
> A non-Claude harness (opencode-bigpickle, codex, manual, etc.) reads `AGENTS.md` + the two contract specs (links activate once #1718 + #1721 land):
> - `docs/process/HARNESS_CONTRACT.md` (INFRA-1044) — what Chump needs FROM the agent (file tools, shell, git, gh)
> - `docs/process/AGENT_API.md` (INFRA-1050) — what Chump gives TO the agent (`--briefing`, `--execute-gap`, `ambient emit`, `health`)
>
> Read order for Claude Code sessions: `AGENTS.md` first, then this file. (INFRA-1046)

## Mission
Build agents that are **Credible**, **Effective**, **Resilient**, and **Zero-Waste**.
Full pillar definitions and coordination docs: [`AGENTS.md`](./AGENTS.md) + [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md).
Eval/research work also reads [`docs/process/RESEARCH_INTEGRITY.md`](./docs/process/RESEARCH_INTEGRITY.md).

## Mission Driver — every session, not just when asked

You are responsible for **driving the 4 pillars**, not just servicing gaps as they appear. The fleet defaults to filing gaps about itself (because that's what's easy to notice) — Resilient and Zero-Waste pile up while Effective and Credible starve. Counteract that on purpose.

**At session start AND every iter of any loop:**

1. **Pillar inventory.** Count fleet-pickable gaps per pillar (INFRA P0|P1 xs|s|m, no deps). Quick scan via title prefix tags `EFFECTIVE:` / `CREDIBLE:` / `RESILIENT:` / `ZERO-WASTE:` / `MISSION:`.
2. **Balance lever.** If any pillar < 2 pickable, file 1-2 gaps to refill. If one pillar > 50% of pool, demote some to P2.
3. **Title-tag every new gap** with the pillar prefix so the *why* is visible to picker + reviewer.
4. **P0 budget = 5 max.** Reserve P0 for true unblockers across all 4 pillars; demote inflation.
5. **Roadmap-before-gaps.** When unsure what to file, re-read `docs/ROADMAP.md` first. Gaps implement the roadmap, not the other way around. If the roadmap is missing or stale, write/update it before refilling.
6. **Don't optimize the engine while the car sits in the driveway.** Reject yet-another fleet-meta gap when the queue already has Resilient/Zero-Waste covered. Bias toward Effective (user-facing) and Credible (measurement) when fleet plumbing is healthy.

PM-curation role: see **META-046**. Honest pillar-grade reports are part of the job, not an aside.

Explicit SLO targets for each pillar and layer: [`docs/process/FLEET_SLOS.md`](./docs/process/FLEET_SLOS.md).
Check current vs. target at any time: `chump health --slo-check` (exits non-zero on breach).

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

## Two-phase decomposition (don't pre-slice into sub-gaps)

**At filing time**: write the rough decomposition intent into the gap *description*, not as filed sub-gaps. Sub-gaps filed in advance age badly — the codebase shifts before they're picked.

Example description for a large gap:
```
Rough shape: (a) DB query layer in src/gap_store.rs,
(b) CLI handler with --apply/--dry-run/--json flags (see consolidate arm as model),
(c) ambient event registered in EVENT_REGISTRY.yaml,
(d) CI test using synthetic state.db fixture.
Key constraint: depends_on is stored as JSON array — use parse_json_ac_list pattern.
```

**At claim time**: run `chump gap decompose <ID>` — it reads the description as LLM context and generates sub-gaps against the *current* codebase. Use `--dry-run` to inspect the full prompt before calling the LLM; use `--no-description` if the description is stale.

Never file sub-gaps manually in advance. The filing agent's context is valuable input to decompose, not a substitute for it.

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

## Spawning subagents (META-027) — Claude-Code-only

> Uses Claude Code's `Agent` tool. Non-Claude harnesses parallelize via the fleet (multiple workers) — see harness contract doc §Out-of-scope.

When spawning via the `Agent` tool, paste the full shipping epilogue from
`docs/process/SUBAGENT_DISPATCH.md` into every subagent prompt.

**Wall-clock budget:** `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` (default 900s = 15 min).
If `bot-merge.sh` has been running for 15 min without progress markers, the
subagent **must** switch to manual recovery — passive waiting is a stall pattern.
See the SUBAGENT_DISPATCH.md "STOP" block for the exact mandate.

**Model:** always sonnet (INFRA-515). Haiku hesitates in `--dangerously-skip-permissions`
mode and burns the slot waiting for stdin that never comes.

## Auth modes (INFRA-622) — Claude-Code-specific OAUTH path

> `ANTHROPIC_API_KEY` is the universal path any harness uses to call Anthropic. `CLAUDE_CODE_OAUTH_TOKEN` is Claude Code's subscription-OAUTH path. Non-Claude harnesses calling Anthropic use the API key only.

Both `ANTHROPIC_API_KEY` (API-key) and `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAUTH) are first-class.

| Mode | Env | Notes |
|---|---|---|
| `auto` (default) | — | Prefer `ANTHROPIC_API_KEY` if non-empty; else OAUTH |
| `api-key` | `CHUMP_AUTH_MODE=api-key` | Force API key; error if absent |
| `oauth` | `CHUMP_AUTH_MODE=oauth` | Force subscription token; error if absent |

Workers re-evaluate credentials before each `claude -p` spawn. OAUTH tokens are refreshed to `~/.chump/oauth-token.json` every 5 min; workers read from there. On a 401, the fleet falls back to the other mode (if available) and emits `kind=fleet_auth_fallback` to `ambient.jsonl`.

Validate: `chump fleet doctor` — exits non-zero if no valid auth path found.

## GitHub credentials for agents (INFRA-AGENT-CREDS)

Autonomous agents spawned via `chump --execute-gap` or `/api/gap/work` need GitHub access to commit, push, and merge PRs.

Two modes:

**1. Implicit (local dev)** — agent inherits parent process environment:
- `gh` CLI token from macOS keyring (or system credential helper)
- SSH keys from `~/.ssh/` 
- No explicit configuration needed; works on developer machines
- **Limitation:** breaks in Docker, sandboxed workers, different-user processes

**2. Explicit (production)** — agent uses environment variables:
```bash
export GH_TOKEN="ghp_..."                    # GitHub API token (overrides keyring)
export SSH_KEY_PATH="~/.ssh/id_ed25519"     # Path to SSH key for git ops
export GITHUB_TOKEN="ghp_..."                # Alternative to GH_TOKEN (some tools)
```

Pass these to the workflow:
```bash
GH_TOKEN="..." chump --execute-gap <ID>
# or via PWA:
GH_TOKEN="..." curl -X POST http://localhost:3000/api/gap/work/<ID>
```

**Sanitization:** credential values never appear in logs. Only `"forwarding explicit GH_TOKEN"` debug messages confirm presence.

**Backwards compatible:** if env vars unset, agent falls back to keyring (implicit mode).

## Hard rules

- **`proprietary/` — NEVER commit here.** Private sibling repo; stray copies must not be staged or referenced.
- **Default model: haiku for IDE sessions, sonnet for fleet workers.** Cost-sensitive sweeps: `FLEET_MODEL=haiku`. Opus is ~50× haiku per token.
- **Never push directly to `main`.** See [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01).
- **Always work in a linked worktree** — `gap-claim.sh` refuses the main checkout.
- **Linked worktree git path confusion (INFRA-779):** On macOS, `/tmp` → `/private/tmp` symlink plus concurrent sibling claims can corrupt a worktree's gitdir back-reference, causing `git rev-parse --show-toplevel` to return the wrong path. Recovery: `GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/<wt-name> GIT_WORK_TREE=/private/tmp/<wt-name> git <cmd>`. Prevention: `chump claim` now auto-repairs the gitdir after `git worktree add`.
- **Never start a gap without `gap-preflight.sh` first.**
- **Never leave a lease behind** — `chump --release` or delete `.chump-locks/<session>.json`.
- **Commit often** (every 30 min) — use `scripts/coord/chump-commit.sh <files> -m "msg"`, not bare `git commit`.
- **Mutate gaps via `chump gap …` only** — `.chump/state.db` is canonical. Use `chump gap show <ID>` to inspect.
- **Rebase if your branch is more than 15 commits behind main.**
- **Auto-merge is the default.** `bot-merge.sh --auto-merge` arms it. Once armed, treat PR as frozen — new work → new PR.
- **PRs are intent-atomic**, not file-count-bounded. One logical change per PR.
- **`--no-verify` is the reason most regressions ship.** Use very sparingly.

## Cache-first reads (INFRA-1081, 2026-05-14)

The fleet has a **local SQLite cache** at `.chump/github_cache.db` populated by a
**webhook receiver** (`scripts/ops/github-webhook-receiver.py`). Every fleet
script that wants PR state should **read from the cache first**, fall back to
direct `gh api` only on miss.

```bash
source "$(dirname "$0")/lib/github_cache.sh"

# PR state — replaces gh pr view
cache_lookup_pr "<number>"           # returns JSON; falls back to REST on miss

# BEHIND scan — replaces gh pr list with mergeStateStatus filter
cache_query_behind_prs               # returns one number per line

# Per-PR check status — replaces gh api repos/X/commits/SHA/check-runs
cache_lookup_checks "<head_sha>"     # returns `name\tstatus\tconclusion` per check
```

**Already migrated:** queue-driver.sh (BEHIND scan), bot-merge.sh FLEET-029
overlap scan via chump-ambient-glance.sh, pr-rescue.sh per-PR meta fetch.
**Next consumers** (filed as gaps): bot-merge per-PR check-runs polling
(INFRA-1130), ghost-gap-reaper (INFRA-1082 audit).

**When in doubt:** read from cache. Cache miss is cheap (1 REST call, REST
core bucket stays healthy during GraphQL exhaustion). Polling GraphQL is the
costly path.

## Call criticality (INFRA-1080, 2026-05-14)

`chump_gh` now classifies each call as **critical** (default) or **background**.
Background calls get preempted when `remaining_graphql < 10%` so critical-path
operations never starve.

```bash
# Default — proceeds even when bucket is tight
chump_gh pr merge "$PR" --auto --squash

# Tag as background — yields the bucket to critical callers
CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list ...
```

| Critical (default) | Background (opt-in) |
|---|---|
| `gh pr create` / `gh pr merge` | label edits |
| `gh pr update-branch` | overlap scans |
| ship-blocking REST writes | dashboard refreshes |
| operator-initiated rescue | cache reconcile per-PR fetches |

**Why it matters:** GraphQL exhaustion is multiple-times-per-day during fleet
peaks. Without criticality tags, a background dashboard poll can starve a
ship-blocking merge. With them, the merge fires, the poll waits.

## GraphQL exhaustion handling (INFRA-1040 / INFRA-1079)

Automated:
- **Secondary rate-limit self-throttle** — `chump_gh` caps to
  `CHUMP_GH_MAX_CALLS_PER_MIN` (default 60) across the fleet via a shared
  sliding window. Per-script override: `CHUMP_GH_THROTTLE_<UPPERCASE_SCRIPT>=N`.
- **Exhaustion signal** — first call to see `remaining_graphql ≤ 100` emits
  `kind=graphql_exhausted` to `ambient.jsonl` (debounced once per reset window).
  Every fleet agent reading ambient pivots to REST-only paths simultaneously.

Manual operator actions when you see repeated `graphql_exhausted` or
`gh_self_throttled` events:
- Run `scripts/dev/api-cost-leaderboard.sh --window 1h` to find the burner.
- Background-tag the noisiest non-critical caller via `CHUMP_GH_CALL_CRITICALITY=background`.
- If structural: file an INFRA-NEW-MIGRATE-<script>-TO-CACHE follow-up.

## Push routing — opt-in (FLEET-034, 2026-05-14)

Default work distribution remains **pull**: each worker polls `state.db`, picks
the first eligible gap, and claims atomically. That model degrades past ~30
workers (every worker performs O(open-gap) sqlite reads per cycle).

**Push tier (opt-in).** When NATS is reachable, run one `chump-coord assign`
daemon per fleet — it watches `state.db`, and for each `status:open` gap
publishes a `WorkEnvelope` to:

```
chump.work.<priority>.<class>.<machine>
   priority  P0 | P1 | P2 | P3
   class     derived from gap.skills_required (runtime, coord, docs, …),
             falling back to lowercased gap.domain. "any" if neither.
   machine   gap.preferred_machine if set, else "any"
```

Workers run `chump-coord worker` with capability env vars:

```bash
WORKER_SKILLS=rust,sqlite,macos WORKER_MACHINE=macbook WORKER_BACKEND=claude \
  chump-coord worker --subjects 'chump.work.>.runtime.macbook,chump.work.>.coord.>'
```

**Ack semantics.** First worker to win the existing NATS-KV atomic claim
(`try_claim_gap`) wins the lease — that *is* the ack. Lost-race workers fall
through and drain the next envelope. Worker death is detected via the existing
KV TTL on the claim key (`CHUMP_GAP_CLAIM_TTL_SECS`).

**Speculative override (INFRA-311).** A gap with `replicas: N` in `notes`
publishes N envelopes for the same gap; the first N workers to ack share the
race but only one wins the CAS — others discard.

**Offline fallback.** When `CHUMP_NATS_URL` is unset or the broker is
unreachable, **both** sides degrade cleanly: `chump-coord assign` logs the
condition and exits 0 (a supervisor can restart it on broker recovery), and
`chump-coord worker` exits 0 with a `falling back to pull loop` message so the
existing `scripts/dispatch/worker.sh` PULL path takes over without manual
intervention. **state.db remains the source of truth** in both modes — NATS
only routes the question of *which* worker should pick *which* open gap.

**Cognitive model.** The old docs implied "dispatcher dispatches"; in reality
the system pulls when offline and pushes when a broker is available. The push
daemon publishes hints; the pull-side atomic claim remains the authoritative
hand-off.

## Fleet scaling gate (INFRA-518)

Scaling fleet size is a deliberate stress test of prior-tier fixes. Each step-up requires the
previous tier to be stable; each step-down trigger must be respected without operator override.

### Scale-up criteria (all must hold)

| Metric | 2 → 3 workers | 3 → 4 workers |
|---|---|---|
| Waste rate (`chump waste-tally --window 2h`) | < 20 % | < 15 % |
| Ship rate (PRs merged / PRs opened, last 10) | ≥ 70 % | ≥ 80 % |
| `fleet_wedge` events in ambient.jsonl (last 2 h) | 0 | 0 |
| `silent_agent` events (last 2 h) | ≤ 1 | 0 |
| `pr_stuck` events (last 2 h) | ≤ 1 | 0 |
| Open INFRA gaps blocking fleet (P0/P1 kind=fleet) | 0 | 0 |

Run before any scale-up:
```bash
chump waste-tally --window 2h          # check waste rate
scripts/dispatch/fleet-status.sh       # check ship rate + agent health
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(fleet_wedge|silent_agent|pr_stuck)"'
```

### Logging requirement (mandatory)

Every scale-up **and** scale-down must emit to `ambient.jsonl`:
```bash
printf '{"ts":"%s","kind":"fleet_scale_change","from":%d,"to":%d,"rationale":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <old_size> <new_size> "<reason>" \
  >> .chump-locks/ambient.jsonl
```

### Back-off triggers (immediate, no debate)

- **`fleet_wedge` event appears** → drop to 2 workers; hold until 0 wedges for 30 min.
- **`silent_agent` count > 1 in 1 h** → drop to 2 workers; investigate picker/lease race.
- **`pr_stuck` cluster (≥ 3 in 2 h)** → drop to 2 workers; diagnose bot-merge contention.
- **Waste rate > 30 % at any size** → drop to 2 workers; file a gap for the dominant waste kind.
- **CI failure rate > 25 % (last 8 PRs)** → hold current size; do not scale up until resolved.

### Rollback procedure

```bash
# 1. Kill excess workers (tmux pane names fleet-worker-N)
tmux kill-pane -t fleet-worker-<N>
# 2. Release orphaned leases
ls .chump-locks/*.json | xargs -I{} chump --release --lease {}
# 3. Log the scale-down (see Logging requirement above)
# 4. Update FLEET_SIZE in run-fleet.sh invocation or env
```

Full retrospective: [`docs/syntheses/fleet-scaling-2026-05-06.md`](./docs/syntheses/fleet-scaling-2026-05-06.md)

## MISSION-PM: gap registry health (META-046)

Run `chump gap audit-priorities [--json]` to get a PM health snapshot.
Exits non-zero if **P0 count > 5**, any **open P0 stuck > 7 d**, or any
**vague (no AC) pickable gap** exists.

Metrics reported:

| Metric | Meaning |
|---|---|
| P0 count + ages | Open P0 gaps and how long they have been open |
| Vague pickable | Open gaps with no acceptance_criteria — unpickable in practice |
| Double-encoded depends_on | `depends_on` stored as JSON-string-of-JSON — import bug |
| Missing-dep refs | `depends_on` entries pointing at non-existent gap IDs |
| Open with closed_pr | status:open but closed_pr set — needs `chump gap ship` |
| race-* test pollution | Open gaps with title starting `race-` — test fixture leak |

Incorporate into the pre-ship checklist for any gap that touches the registry
or picker logic:

```bash
chump gap audit-priorities          # non-zero = stop and fix
```

CI gate: `scripts/ci/test-gap-audit-priorities.sh`

## On-demand docs (read only when you hit the failure surface)

- Subagents, fleet launcher, disk hygiene, operational gotchas (binary wedge, rebase footgun, syspolicyd, etc.): [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md)
- Subagent dispatch: model defaults, no-clarifying-questions directive, shipping epilogue, WIP-rescue: [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md)
- Script taxonomy, canonical tool per task, entry points per directory: [`scripts/README.md`](./scripts/README.md)
- Coordination script entry points, decision guide, full coord/ reference: [`scripts/coord/README.md`](./scripts/coord/README.md)
- A2A frontier roadmap — six layers from NATS-primary delivery to signed provenance, mapped onto today's chump-coord primitives: [`docs/design/A2A_ROADMAP.md`](./docs/design/A2A_ROADMAP.md) (META-061; sub-gaps INFRA-1118 through INFRA-1123)
