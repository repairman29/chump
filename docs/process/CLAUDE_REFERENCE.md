# CLAUDE.md reference sections (moved out of the hot overlay by ZERO-WASTE-125)

Read only when you hit the failure surface. Canonical hot rules stay in CLAUDE.md / AGENTS.md.

## Auth modes (INFRA-622) — Claude-Code-specific OAUTH path

> `ANTHROPIC_API_KEY` is the universal path any harness uses to call Anthropic. `CLAUDE_CODE_OAUTH_TOKEN` is Claude Code's subscription-OAUTH path. Non-Claude harnesses calling Anthropic use the API key only.

Both `ANTHROPIC_API_KEY` (API-key) and `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAUTH) are first-class.

| Mode | Env | Notes |
|---|---|---|
| `auto` (default) | — | Prefer `ANTHROPIC_API_KEY` if non-empty; else OAUTH |
| `api-key` | `CHUMP_AUTH_MODE=api-key` | Force API key; error if absent |
| `oauth` | `CHUMP_AUTH_MODE=oauth` | Force subscription token; error if absent |

Workers re-evaluate credentials before each `claude -p` spawn and read `~/.chump/oauth-token.json`. The "refreshed every 5 min" promise is **not implicit** — it only holds while the standalone refresher daemon is installed and alive:

- **Substrate:** `scripts/coord/oauth-token-refresh.sh` (INFRA-2124, hardened INFRA-1865) — extracts the token from the macOS Keychain entry `Claude Code-credentials`, hash-compares against the current file (rewrites + emits `kind=oauth_token_refreshed` only when the token actually changed — no log spam), and validates the extracted token against a real `claude -p` call before it's allowed to overwrite a still-good file (failure → `kind=oauth_token_invalid`, old file kept).
- **Cadence:** `launchd/com.chump.oauth-refresh.plist`, `StartInterval=300` (5 min). Install (idempotent): `bash scripts/setup/install-oauth-refresh-launchd.sh`. Verify it's actually loaded: `launchctl list | grep com.chump.oauth-refresh` — an installed-but-unloaded plist is exactly how the token went 16d stale (INFRA-1865).
- **Platform:** macOS-only (Keychain-backed). Linux hosts get a loud `kind=oauth_refresh_unsupported_platform` error rather than a silent no-op — a Linux-native keystore/env-fallback path is still an open operator decision.
- **Smoke test:** `bash scripts/ci/test-oauth-refresher.sh`.
- **Staleness detector:** `scripts/coord/infra-watcher-loop.sh` emits `kind=oauth_token_stale_despite_daemon` when the file is stale despite the plist showing loaded — read that event before re-diagnosing this by hand.

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

## Local CI discipline (mandatory, INFRA-1673)

**Run local CI before every push that touches Rust or scripts.**

Operator philosophy: every push that fails CI on GitHub costs ~15 minutes round-trip. The same failure caught locally costs <60 seconds. Multiply over a day of work and the difference is hours. Long-term direction is **fully local execution, no GH dependencies** — local CI is the first step.

```bash
# Before EVERY push that touches Rust or scripts:
chump preflight              # INFRA-1670; runs cargo fmt/clippy/check + relevant test-*.sh
                             # Target: <60s warm, <120s cold.
                             # Bypass: CHUMP_PREFLIGHT_SKIP=1 + add a body trailer:
                             #   Preflight-Skip-Reason: <one sentence why>
```

Until INFRA-1670 ships the tool, manually run these in sequence — they're what the tool will wrap:

```bash
cd <worktree>
PATH=$HOME/.cargo/bin:$PATH cargo fmt --all -- --check
PATH=$HOME/.cargo/bin:$PATH cargo clippy --workspace --all-targets -- -D warnings
PATH=$HOME/.cargo/bin:$PATH cargo check --workspace
# Then any scripts/ci/test-*.sh that match files you touched.
```

**Why this is mandatory, not advisory:** the last 48h surfaced 6 different CI failure classes (cargo fmt drift, clippy dead_code, INFRA-682 path-filter missing, INFRA-1274 raw-gh allowlist missing, INFRA-1287 registry-orphan, INFRA-755 obs-budget) — every one a 1-line fix that would have taken <30s locally. The slow round-trip is a discipline failure, not a CI failure.

**Bypass discipline:** `--no-verify` and `CHUMP_PREFLIGHT_SKIP=1` are operator escape hatches. Each use emits `kind=preflight_bypassed` to `ambient.jsonl` for audit. Don't skip routinely; the audit log will show patterns and force a conversation.

**Pairs with:** INFRA-1670 (the tool), INFRA-1671 (pre-push hook enforcement), INFRA-1672 (smart scoping for speed).

### preflight-vs-CI parity allowlist (INFRA-2120 / INFRA-1867)

When you add a new `run:` step to `.github/workflows/ci.yml`, the pre-commit
hook (`scripts/git-hooks/pre-commit`, block 18) and the CI step
`preflight-vs-CI parity smoke (INFRA-1867)` will both fail unless the new
gate satisfies **one** of three classifications:

1. **Mirrored in preflight** — add the same `scripts/ci/test-foo.sh` (or
   `cargo fmt|clippy|check` invocation) to `src/preflight.rs` so it also
   runs in `chump preflight`. Preferred path — local + CI stay in sync.
2. **Tier-D (cannot mirror)** — if the gate genuinely can't run locally
   (e.g. it talks to GitHub APIs or the merge queue), add it to the
   `## Tier D` section of `docs/process/CI_GATES_INVENTORY.md` with a
   reason. The parity script's matcher uses substring matching against
   the step name + run command, so a Tier-D entry like
   `gap-status-guard.yml` matches any step whose name or run-line
   contains that string.
3. **Allowlist exception** — last-resort escape hatch. Append a line to
   `scripts/ci/preflight-ci-parity-exceptions.txt` of the form:
   ```
   <step-name-or-script-basename>       # reason: <why this can't mirror>
   ```
   Bare entries match the step name, the `scripts/ci/...sh` path, OR a
   substring of either. Keep entries narrow (prefer the exact script
   basename) so the allowlist doesn't silently absorb future drift.

Adding a step without doing one of (1)/(2)/(3) is what produces the
"unmirrored gate in job=" failure surface (rank-2 CI-rot class per
`docs/strategy/CI_REVIEW_2026-05-29.md` Lever 4). The pre-commit hook
fires *only* when ci.yml is staged, so the cost is paid by the contributor
making the change, not by every push.


## Rust-first vs. shell-OK (META-064, 2026-05-14)

When you reach for `nano scripts/coord/foo.sh`, pause and check the criteria
below first. The codebase has shipped 16k+ LOC of "this was shell, now we
port it to Rust" gaps in the last quarter. Most of that work could have
been Rust from the start.

**Rust-first IF *any* of these hold:**
- Mutates canonical state: `state.db`, `.chump-locks/*.json`, `ambient.jsonl`, `docs/gaps/*.yaml`
- Called from a hot path: `worker.sh` per-cycle, `bot-merge.sh` per-ship, every claim
- Shares a process boundary with a Rust caller (subprocess-race candidate)
- Will outlive 3 months (durable tooling, not exploratory)
- > 200 LOC at first commit (size predicts maintenance compounding)

**Shell is OK IF *all* of these hold:**
- Glue between existing CLI tools (`gh` + `git` + `jq`)
- One-shot or exploratory
- < 200 LOC, no state mutation
- No regression-test maintenance burden (no `scripts/ci/test-<name>.sh` sibling required)

**Bypass:** when adding shell that hits the Rust-first criteria intentionally
(e.g. a 30-line `gh + jq` glue shim that legitimately doesn't need types),
add this trailer to the commit body:
```
Rust-First-Bypass: <one-sentence reason>
```
The pre-commit gate at `scripts/git-hooks/pre-commit-rust-first.sh` checks
for the trailer when the criteria match; bypass goes into the audit log.

Sibling rules: META-063 (no new duplicates), META-065 (auto-prioritization).

## Cache-first reads (INFRA-1081, 2026-05-14)

> **🚨 DEFAULT to `cache_lookup_pr` / `sqlite3 .chump/github_cache.db`. `gh pr view` and `gh api` ONLY on cache miss.**
>
> The cache is fed in real-time by a smee.io tunnel → Python webhook receiver
> → SQLite. Reading from it is **< 100 ms** per query. Polling `gh` is
> **5-30 s per call** AND burns the global rate limit AND triggers
> `graphql_exhausted` cascades that blind every other curator. There is **no
> excuse** for `gh pr view <N>` when `.chump/github_cache.db` has the answer
> with fresher data than gh's own GraphQL.
>
> If you find yourself running `gh pr view` / `gh api repos/.../check-runs`
> in a loop — **stop**, read this section, and use the cache. Failure to do
> so is anti-pattern #9 in [`docs/process/OPERATOR_PLAYBOOK.md`](./docs/process/OPERATOR_PLAYBOOK.md). Operator-paged 2026-05-30T09:27Z.

The fleet has a **local SQLite cache** at `.chump/github_cache.db` populated by a
**webhook receiver** (`scripts/ops/github-webhook-receiver.py`) via a smee.io
tunnel. Every fleet script that wants PR state should **read from the cache first**, fall back to
direct `gh api` only on miss.

**Setup + healthcheck:** see [OPERATOR_PLAYBOOK.md §7.5 Local Infrastructure](./docs/process/OPERATOR_PLAYBOOK.md#75-local-infrastructure--webhook--smee--cache--docker). Quick check before any "polling gh":

```bash
pgrep -fa 'smee-client'      # tunnel alive?
pgrep -fa 'github-webhook'   # receiver alive?
sqlite3 .chump/github_cache.db "SELECT MAX(fetched_at_local) FROM pr_state;"  # last update?
```

```bash
source "$(dirname "$0")/lib/github_cache.sh"

# PR state — replaces gh pr view
cache_lookup_pr "<number>"           # returns JSON; falls back to REST on miss

# BEHIND scan — replaces gh pr list with mergeStateStatus filter
cache_query_behind_prs               # returns one number per line

# Per-PR check status — replaces gh api repos/X/commits/SHA/check-runs
cache_lookup_checks "<head_sha>"     # returns `name\tstatus\tconclusion` per check
```

Additional helpers (INFRA-1275):

```bash
# List open PRs — replaces gh pr list with mergeStateStatus=BEHIND filter off
cache_query_open_prs                 # returns `number\ttitle\thead_ref` per row

# Title-substring search — replaces gh pr list --search
cache_query_open_prs_by_title "X"    # same shape, filtered by LOWER(title) LIKE

# Per-PR file list — replaces gh api repos/X/pulls/N/files
cache_lookup_pr_files "<number>"     # background-tagged REST under the hood

# Branch -> PR number + state (open/merged/closed), including merged & closed PRs (INFRA-8578)
cache_lookup_pr_state_by_branch "<branch>"  # returns `number\tstate`; REST fallback on miss

# Bulk refill — call once on cold cache, REST not GraphQL
cache_refresh_open_prs               # writes up to 100 open PRs into pr_state
```

**Already migrated:** queue-driver.sh (BEHIND scan), bot-merge.sh FLEET-029
overlap scan, pr-rescue.sh per-PR meta fetch, chump-ambient-glance.sh
(INFRA-1275), gap-preflight.sh (INFRA-1275).
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

