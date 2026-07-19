# pr-stuck-cluster observability (INFRA-1749)

Answers the four observability questions for the pr-stuck-cluster detection
path (`scripts/coord/pr-stuck-cluster-detector.sh`, INFRA-1133). Filed after
a real cluster incident (2 PRs blocked >2h, 2026-05-23); the mechanism below
already existed at the time — this doc is the missing writeup, not new code.

## 1. Events emitted on success / failure / timeout

The lifecycle is a chain of ambient events, each keyed by `kind`, tracked
through `docs/observability/EVENT_REGISTRY.yaml`:

| Stage | kind | Emitter |
|---|---|---|
| Detect (single PR) | `pr_stuck` | `scripts/ops/stuck-pr-filer.sh` (INFRA-307) |
| Detect (cluster, 3+ PRs in 2h) | `pr_stuck_cluster` | `scripts/coord/pr-stuck-cluster-detector.sh` (INFRA-1133) |
| Announce | `pr_stuck_announced` | `scripts/coord/pr-stuck-announcer.sh` |
| First rescue attempt (rebase) | `pr_stuck_cycle_1_rebase_attempted` | `scripts/ops/stale-pr-reaper.sh` (INFRA-1410) |
| Rescue succeeded | `pr_stuck_resolved` | reaper / bot-merge (paired with `pr_stuck`) |
| Rescue failed → close+respawn | `pr_auto_closed_for_respawn` | `scripts/ops/stale-pr-reaper.sh` |
| Exempted (known long-block reason) | `pr_stuck_exempt` | `scripts/ops/stale-pr-reaper.sh` |

There is no separate "timeout" kind — a timeout is `pr_stuck` aging past
`CHUMP_PR_STUCK_SLO_HRS` (default 2h) without a `pr_stuck_resolved` pair,
which is exactly the condition `pr-stuck-cluster-detector.sh` scans for.

## 2. Cost tracking

`chump waste-tally` (`src/waste_tally.rs`) is the cost consumer for this
event family. Every `pr_stuck_cluster` event is assigned a default cost of
5,000 tokens / 300s of operator-or-curator triage time
(`default_tokens_per_kind("pr_stuck_cluster")`, `src/waste_tally.rs:115,268`).
Reported to the operator via:

```bash
chump waste-tally --window 2h      # per-CLAUDE.md fleet scaling gate check
```

`pr_stuck_cluster` also feeds `fleet-brief` and `watchdog` per its
`consumers:` list in EVENT_REGISTRY.yaml — the fleet-brief SessionStart
digest surfaces `Alerts(30m)` derived from the same stream.

## 3. Failure-class taxonomy (transient vs. permanent)

The cluster detector's description template (`pr-stuck-cluster-detector.sh`)
encodes four root-cause hypotheses, mapped to transient vs. permanent below:

| Class | Root cause | Transient? | Recovery |
|---|---|---|---|
| CI flake | one required check flaky | transient | re-run via `gh pr comment <N> -b "/rerun-failed"` |
| Rate limit | GraphQL/REST exhaustion | transient | wait / `CHUMP_GH_CALL_CRITICALITY=background` on non-critical callers |
| Rebase conflict storm | multiple PRs conflict on merge | transient | `scripts/coord/pr-rescue.sh` |
| Human forget | armed for auto-merge, operator didn't monitor | permanent (needs intervention) | operator triage |

The reaper (`stale-pr-reaper.sh`) encodes the same transient/permanent split
operationally: cycle 1 (`pr_stuck_cycle_1_rebase_attempted`) always assumes
transient and retries; only after that attempt fails does it treat the PR as
permanent and emit `pr_auto_closed_for_respawn`.

## 4. Smoke test command

```bash
scripts/ci/test-pr-stuck-cluster-detection.sh
```

Covers: no-stuck-events (no-op), below-threshold (no-op), 3+-in-window
(gap filed + `pr_stuck_cluster` emitted), outside-window (no-op),
cooldown-dedup (no re-file within 24h), cooldown-expired (re-file allowed).

Manual dry-run against live `ambient.jsonl`:

```bash
scripts/coord/pr-stuck-cluster-detector.sh          # dry-run, no gap filed
scripts/coord/pr-stuck-cluster-detector.sh --apply  # files INFRA-NEW-* P0 gap if cluster found
```
