# Queue-tender observability spec (INFRA-2362)

The "queue-tender" is the pr-queue auto-processor in `scripts/coord/pr-shepherd-daemon.sh`
(shipped incrementally as META-181 through META-186, then hardened by INFRA-2346
CLEAN_GREEN admin-merge / BLOCKED_FLAKE rerun tiers and INFRA-2349's time-bounded
trunk-red cascade gate). This doc answers the 4 productization questions this gap
was refiled to close.

## 1. Events emitted on success / failure / timeout

Every action the auto-processor takes is audited via ambient.jsonl (grep-able,
no separate log to lose). Full field definitions live in
`docs/observability/EVENT_REGISTRY.yaml`.

| Outcome class | Event | Notes |
|---|---|---|
| Success | `pr_queue_auto_action` action=`admin_merge` \| `flake_rerun` | reason=`trusted_author` \| `known_flake` |
| Failure (gh call errored) | `pr_queue_auto_action` action=`admin_merge_failed` \| `flake_rerun_failed` | reason=`gh_exit_<N>` |
| Guard-skip (not a failure) | `pr_queue_auto_action` action=`admin_merge_skipped` \| `flake_rerun_skipped` | reason=`trunk_red` \| `capped` \| `no_run_id` |
| Timeout / gate-expiry | `pr_queue_cascade_gate_expired` (INFRA-2349) | trunk-red gate held admin-merges/rebases beyond `CASCADE_MAX_HOLD_MINUTES` (default 120); emitted once per tick while the condition holds |
| Per-tick rollup | `pr_queue_skipped_trunk_red` | single-line summary emitted once per tick when >=1 admin-merge was blocked by trunk-red |
| Per-tick heartbeat | `pr_shepherd_tick`, `pr_classified` (one per PR) | liveness + classification audit trail, independent of whether any action fired |
| Safe-mode transitions | `pr_shepherd_safe_mode_entered` / `_cleared` (META-187) | daemon suspends rebase/arm/gap-file actions for 30 min after any trunk_red sighting |
| Steward-needed signal | `pr_wedged` | PR open >24h, no commits in 12h, no auto-merge armed — debounced once/PR/24h |

## 2. Cost tracked and reported to operator

The auto-processor's cost is GitHub API budget, not LLM tokens — it never calls
an LLM. Before INFRA-2362 the daemon called `gh` directly, so its calls were
**invisible** to `scripts/dev/api-cost-leaderboard.sh` (which ranks scripts by
`kind=github_api_call` events emitted by `scripts/coord/lib/github.sh`).

Fix shipped in this gap: the 3 mutating gh calls the auto-processor makes
(`gh pr merge --squash --admin`, `gh run rerun --failed`, `gh pr merge --auto`)
are now routed through `chump_gh` (function-only — `CHUMP_GH_NO_PATH_INJECT=1`
so only these explicit calls are recorded, not every `gh` invocation in the
script). `CHUMP_AMBIENT_OVERRIDE` is pinned to the daemon's own `$AMBIENT` path
so the telemetry lands in the same file as the rest of the daemon's events even
under the stale-worktree condition META-248 fixed.

Operator-facing reporting:
```bash
scripts/dev/api-cost-leaderboard.sh --window 24h            # ranked by script+api
scripts/dev/api-cost-leaderboard.sh --window 24h | grep pr-shepherd-daemon
```
Read (list) calls stay tagged `CHUMP_GH_CALL_CRITICALITY=background` (pre-existing,
META-182) so they yield to critical-path work when the GraphQL bucket is tight
(INFRA-1080); the 3 mutation calls above default to `critical` — they are
rate-limited by the per-tick caps (`MAX_ADMIN_MERGES`, `MAX_FLAKE_RERUNS_PER_PR`)
instead, since blocking a merge/rerun on GraphQL headroom would defeat the point.

## 3. Failure-class taxonomy (transient vs permanent)

| Class | Reasons | Behavior |
|---|---|---|
| Transient (self-heals, no operator action) | `trunk_red` (gate active, trunk-sentinel still within its own recovery window), `capped` (per-tick cap hit — retried next tick), `no_run_id` (CI run not yet indexed — retried next tick) | Auto-processor backs off and retries on a later tick; no gap filed |
| Permanent (needs a human or a follow-up gap) | `gh_exit_<N>` (admin-merge or rerun call itself failed — auth, branch-protection, conflict) | Surfaced via `admin_merge_failed` / `flake_rerun_failed`; classification engine (META-185/186) separately files a follow-up gap for `BLOCKED_REAL_FAIL` PRs (non-flake CI failures) |
| Escalation timeout | trunk-red held continuously for >= `CASCADE_MAX_HOLD_MINUTES` | `pr_queue_cascade_gate_expired` — INFRA-2349 treats "still red after 2h" as a signal that trunk-sentinel's own 60-min operator page has already fired, so the gate releases instead of starving the queue indefinitely |

## 4. Smoke test command to verify observability

```bash
bash scripts/ci/test-pr-queue-processor.sh
```

7 scenarios, synthetic `gh`/`chump` stubs, no network. Scenario 1 (trusted+green
PR) additionally asserts a `kind=github_api_call` event with `api="pr merge"` is
recorded for the admin-merge action — the regression guard for the cost-tracking
gap this doc closes. Scenario 4 exercises the trunk-red skip + rollup path;
scenario 7 exercises the INFRA-2349 cascade-gate-expiry timeout path.
