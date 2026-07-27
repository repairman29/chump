# PR-stuck-cluster observability (INFRA-1749)

How the fleet notices a batch of PRs going BLOCKED at the same time, escalates
it, and tracks the cost of doing so. This doc is the narrative companion to
the `pr_stuck` family of entries in
[`EVENT_REGISTRY.yaml`](./EVENT_REGISTRY.yaml) — read this first for the
story, then the registry for exact field shapes.

## Event lifecycle

```
pr_stuck  →  pr_stuck_cluster  →  pr_stuck_announced  →  rescue / resolve / exempt
(per-PR)     (correlated 3+)      (alert broadcast)       (terminal state)
```

1. **`pr_stuck`** — per-PR signal. Emitted by
   `scripts/ops/stuck-pr-filer.sh` (INFRA-307) when a single open PR has been
   `mergeStateStatus=BLOCKED` for more than `CHUMP_PR_STUCK_SLO_HRS` (default
   4h for the filer's own SLO; the cluster detector below uses a 2h window).
   This is the raw material every downstream stage reads from
   `ambient.jsonl` — nothing upstream of this event exists; it's the first
   place a stall becomes visible.

2. **`pr_stuck_cluster`** — correlated signal. Emitted by
   `scripts/coord/pr-stuck-cluster-detector.sh` (INFRA-1133) when it finds
   **3+ distinct `pr_stuck` events inside a rolling `CHUMP_PR_CLUSTER_WINDOW_S`
   window** (default 7200s / 2h). A cluster is treated as evidence of a
   *systemic* blockage (one bad CI check, a rate-limit wall, a rebase-conflict
   storm) rather than N independent one-off stalls, so on `--apply` it files a
   **P0** `RESILIENT` gap (`chump gap reserve --priority P0`) with the
   affected PR list, per-PR age, and a root-cause checklist baked into the
   gap description. Dedup is a stamp file per cluster-id under
   `.chump-locks/.cluster-sent/<cluster_id>.ts`; re-filing the *same* set of
   PRs within `CHUMP_PR_CLUSTER_RESEND_COOLDOWN_S` (default 24h) is
   suppressed. Companion run-level event
   **`pr_stuck_cluster_detector_run`** (INFRA-2754/INFRA-2906) fires on
   *every* invocation regardless of outcome — see
   [Failure-class taxonomy](#failure-class-transient-vs-permanent) below.

3. **`pr_stuck_announced`** — alert broadcast. Emitted by
   `scripts/coord/pr-stuck-announcer.sh` (INFRA-1251) when it independently
   finds an open PR stuck past its own SLO with at least one failing required
   check, and broadcasts a `STUCK` a2a event (targeted at the claim-holder if
   one exists, fleet-wide otherwise). This runs on its own dedup cadence
   (`.chump-locks/.stuck-sent/<PR>.ts`, `CHUMP_PR_STUCK_RESEND_COOLDOWN_S`
   default 6h) independent of the cluster detector — a single stuck PR can be
   *announced* without ever becoming part of a *cluster*, and a cluster can
   fire without every member PR having been individually announced yet
   (detector reads `pr_stuck`, not `pr_stuck_announced`).

4. **Terminal state — rescue / resolve / exempt.** Every stuck PR ends in one
   of three states, each with its own emitter:
   - **Rescue** — `scripts/coord/pr-rescue.sh`,
     `scripts/coord/pr-failure-auto-rescue.sh`, or
     `scripts/coord/last-mile-rescuer.sh` intervene (rebase, re-trigger CI,
     surgical fix) and the PR goes green. The reaper's own first-line rescue
     attempt is logged as **`pr_stuck_cycle_1_rebase_attempted`**
     (`scripts/ops/stale-pr-reaper.sh`, INFRA-1410) before any close action.
   - **Resolve** — `scripts/ops/queue-health-monitor.sh` emits
     **`pr_resolved`**, paired 1:1 with the `pr_stuck` event it clears, when a
     previously-stuck PR is observed to have naturally unblocked (CI went
     green, merge queue drained).
   - **Exempt** — `scripts/ops/stale-pr-reaper.sh` emits
     **`pr_stuck_exempt`** for PRs carrying the `do-not-respawn` label; all
     auto-respawn logic is skipped and pending state cleared. If a PR is
     never rescued/resolved/exempted, the reaper eventually emits
     **`pr_auto_closed_for_respawn`** — closes the PR and reopens its gap for
     the next picker (`stuck-pr-filer.sh` reads this event to trigger the
     reopen).

Every stage's emitter script and full `fields_required` list is registered in
`EVENT_REGISTRY.yaml` under the matching `kind:` entry — this doc explains
*why* the lifecycle is shaped this way, the registry is the field-level
source of truth.

## Cost tracking

`pr_stuck_cluster` carries a deliberate non-zero cost estimate in
`default_tokens_per_kind()` (`src/waste_tally.rs`):

```rust
"pr_stuck_cluster" => 5_000,
```

`chump waste-tally` reads this constant to convert raw cluster-event counts
into an estimated token/dollar cost
(`crate::session_ledger::cost_usd_from_tokens`) without needing an actual
session-token ledger entry — the estimate stands in for the diagnosis +
rescue effort a P0 cluster gap is expected to cost once picked. Regression
coverage lives in `src/waste_tally.rs::infra951_default_tokens_per_kind_returns_estimates`,
which pins the exact value so a future edit can't silently zero it out.

Consumers of the cost signal, per the registry `consumers:` list:

- **`chump waste-tally`** — rolls the estimated cost into the fleet-wide
  waste report (`chump waste-tally --window 2h`, referenced by the
  `CLAUDE.md` scale-down gate).
- **`fleet-brief`** (`scripts/dispatch/fleet-brief.sh`) — surfaces recent
  `pr_stuck_cluster` events in the 60-second operator briefing so a P0
  cluster gap isn't missed between sessions.
- **`watchdog`** — the run-level `pr_stuck_cluster_detector_run` event lets a
  watchdog process assert the detector itself is alive (fires on every
  invocation, `outcome` field distinguishes no-op from actual filing) without
  the detector ever needing to file a gap just to prove liveness.

## Failure-class: transient vs. permanent

Two axes of "why is this stuck" show up in this system, and they call for
different recovery actions:

### Root-cause taxonomy (what made the PRs stuck)

Baked into the cluster gap's description by `pr-stuck-cluster-detector.sh` as
root-cause hypotheses for the human/agent picking up the P0 gap:

| Class | Signature | Recovery action |
|---|---|---|
| **Transient — CI flake** | One check intermittently red across otherwise-unrelated PRs | `gh pr comment <N> -b "/rerun-failed"`; re-run the specific failing check |
| **Transient — rate limit** | `graphql_exhausted` / `gh_self_throttled` events in `ambient.jsonl` near the cluster window | Wait for reset window or background-tag non-critical callers (`CHUMP_GH_CALL_CRITICALITY=background`); see `CLAUDE.md` §GraphQL exhaustion handling |
| **Transient — rebase-conflict storm** | Multiple PRs touching overlapping files, all `mergeStateStatus=BLOCKED` on conflicts | `scripts/coord/pr-rescue.sh` per PR — automated rebase + push cycle |
| **Permanent — human forget** | Gaps filed, PRs armed with `--auto-merge`, but nobody is monitoring the queue (operator/curator absent) | Operator/curator picks up the queue; not fixable by an automated rescue script — needs a human (or curator) to actually look |

This taxonomy is *advisory* — the detector doesn't classify automatically
(it can't tell CI-flake from rebase-storm just from `pr_stuck` events), it
just hands the picker a checklist. It's a separate axis from:

### Failure-class field (why the *detector run itself* failed)

This is a machine-checked field on **`pr_stuck_cluster_detector_run`**
(`_pscd_failure_class()` in `pr-stuck-cluster-detector.sh`), about the
detector's own execution, not about why the PRs are stuck:

| `failure_class` | `outcome` values | Meaning | Retry guidance |
|---|---|---|---|
| `none` | `no_op`, `dry_run`, `cluster_filed`, `help` | Not a failure — normal exit path | n/a |
| `transient` | `gap_id_extract_failed`, `error` | `chump gap reserve` may have succeeded but output was unparseable, or an unclassified error | Retry may succeed as-is |
| `permanent` | `gap_reserve_failed`, `bad_args` | `chump gap reserve` itself returned nonzero, or the script was invoked wrong | Retries repeat until the root cause (bad args, gap-store issue) is fixed |

Don't conflate the two tables: a cluster gap can be filed successfully
(`failure_class=none`, `outcome=cluster_filed`) describing a PR set whose
root cause is a permanent human-forget problem, or the detector run itself
can fail (`failure_class=permanent`) with zero clusters ever having existed.

## Smoke test + manual invocation

Automated coverage:

```bash
scripts/ci/test-pr-stuck-cluster-detection.sh        # detection logic: threshold, window, dedup/cooldown
scripts/ci/test-pr-stuck-cluster-observability.sh     # run-level event: no_op/dry_run/bad_args outcome + failure_class
```

Both are wired into `chump preflight` (INFRA-2925) — run before pushing any
change to the detector.

Manual dry-run (no gap filed, no ambient events beyond the run-level one):

```bash
scripts/coord/pr-stuck-cluster-detector.sh
```

Manual apply (files the P0 gap and emits `pr_stuck_cluster` if 3+ stuck PRs
are in-window):

```bash
scripts/coord/pr-stuck-cluster-detector.sh --apply
```

Useful overrides for testing against a smaller/larger window or threshold:

```bash
scripts/coord/pr-stuck-cluster-detector.sh --window 3600 --threshold 2 --cooldown 60
```

`LOCK_DIR` can be pointed at a scratch directory (as the smoke tests do) to
exercise the detector against a synthetic `ambient.jsonl` without touching
the real fleet state.
