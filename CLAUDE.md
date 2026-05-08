# Claude Code — Chump session rules (hot overlay)

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

## Auth modes (INFRA-622)

Both `ANTHROPIC_API_KEY` (API-key) and `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAUTH) are first-class.

| Mode | Env | Notes |
|---|---|---|
| `auto` (default) | — | Prefer `ANTHROPIC_API_KEY` if non-empty; else OAUTH |
| `api-key` | `CHUMP_AUTH_MODE=api-key` | Force API key; error if absent |
| `oauth` | `CHUMP_AUTH_MODE=oauth` | Force subscription token; error if absent |

Workers re-evaluate credentials before each `claude -p` spawn. OAUTH tokens are refreshed to `~/.chump/oauth-token.json` every 5 min; workers read from there. On a 401, the fleet falls back to the other mode (if available) and emits `kind=fleet_auth_fallback` to `ambient.jsonl`.

Validate: `chump fleet doctor` — exits non-zero if no valid auth path found.

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
