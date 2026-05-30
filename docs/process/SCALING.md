# Batched Merge Train — operator guide

INFRA-2130 SCALE-A. Last updated: 2026-05-30.

## What this is

The `chump-integrator-daemon` batches `ready_to_ship` gaps through a
preflight gate and (when enabled) pushes an integration branch, opens one PR,
and arms auto-merge. Instead of running CI once per gap, CI runs once for a
batch of up to 5 gaps. At 8 min per CI cycle this shifts the theoretical
ceiling from ~7 PRs/hr toward ~35 PRs/hr for the batched cohort.

The daemon is **DRY-RUN by default**. Operator must explicitly opt in to LIVE
mode. This document explains how.

---

## Quick state check

```bash
# Is the daemon installed and running?
launchctl print gui/$(id -u)/com.chump.integrator-daemon

# What mode is it in?
launchctl print gui/$(id -u)/com.chump.integrator-daemon \
  | grep CHUMP_INTEGRATOR_LIVE

# Recent cycle output
tail -100 ~/.chump/logs/integrator-daemon.err

# Ambient events from the last hour
grep "integration_cycle" .chump-locks/ambient.jsonl | tail -20
```

---

## Install (dry-run, safe default)

```bash
scripts/setup/install-integrator-daemon.sh
```

This installs the plist with `CHUMP_INTEGRATOR_LIVE=0`. The daemon fires
every 15 minutes, selects candidates, builds and preflights an integration
branch, then logs what it would have shipped. No git push, no PR.

---

## Flip to LIVE mode

LIVE mode pushes the integration branch, opens a PR, and arms `--auto --squash`
merge. Before flipping:

1. Confirm trunk is not RED:
   ```bash
   cat .chump-locks/trunk-red-detector-state.json | python3 -c \
     "import sys,json; d=json.load(sys.stdin); print('RED' if d.get('is_red') else 'GREEN')"
   ```
2. Confirm dry-run cycles have been logging sane manifests for at least one hour:
   ```bash
   tail -20 ~/.chump/logs/integrator-daemon.err | grep DRY-RUN
   ```
3. Flip:
   ```bash
   scripts/setup/install-integrator-daemon.sh --uninstall
   scripts/setup/install-integrator-daemon.sh --live
   ```

To flip back to dry-run at any time:
```bash
scripts/setup/install-integrator-daemon.sh --uninstall
scripts/setup/install-integrator-daemon.sh
```

---

## Safety rails (always active in LIVE mode)

| Rail | Behavior |
|---|---|
| Trunk-RED gate | Reads `.chump-locks/trunk-red-detector-state.json`. If `is_red=true`, emits `integration_trunk_red_hold` and skips the cycle entirely. |
| Batch cap | `CHUMP_INTEGRATOR_BATCH_MAX` (default 5). Applied on top of the general `CHUMP_INTEGRATOR_MAX_BATCH`. Raise only after observing stable cycles. |
| `do-not-batch` label | Candidates with the configured label (`CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL`, default `do-not-batch`) are excluded before the batch is assembled. Apply this label to a PR via `gh pr edit <N> --add-label do-not-batch`. |
| Circuit breaker | On any LIVE ship failure (push or merge), the daemon emits `integration_cycle_failed`, rolls back the integration branch, and forces the next cycle into dry-run. Resets automatically on the next successful LIVE cycle. |

---

## Rollback procedure

If a LIVE cycle ships something wrong:

1. The integration PR is just a regular squash-merge PR. Revert it like any other:
   ```bash
   gh pr view <N>   # find the merge commit
   git revert <merge-sha>
   gh pr create --base main --head <revert-branch> --title "revert: integration-<cycle-id>"
   ```
2. Re-queue affected gaps: `chump gap requeue <GAP-ID>` for each gap in the batch.
3. Check the circuit breaker: look for `integration_cycle_failed` in ambient.jsonl.
   The daemon will be in dry-run automatically until the next successful LIVE cycle.
4. If the branch was pushed but the PR was not yet merged, close the PR and delete
   the branch:
   ```bash
   gh pr close <N>
   git push origin --delete chump/integration-<cycle-id>
   ```

---

## When NOT to use the batched merge train

- During a trunk-RED incident (the rail handles this automatically, but if the
  detector is not running, disable LIVE mode manually).
- When a large structural refactor is in flight (conflicts will break batches;
  let the refactor land first).
- When the CI queue is already saturated — batching helps throughput but adds
  one extra PR to the queue per batch.
- For `do-not-batch`-labelled PRs: security fixes, rollbacks, and anything that
  must land atomically on its own should carry this label.

---

## Env knobs reference

| Variable | Default | Purpose |
|---|---|---|
| `CHUMP_INTEGRATOR_LIVE` | `0` | Set to `1` to enable LIVE mode (alias for `DRY_RUN=0`). |
| `CHUMP_INTEGRATOR_DRY_RUN` | `1` | Authoritative dry-run flag. Overrides `LIVE` when set. |
| `CHUMP_INTEGRATOR_BATCH_MAX` | `5` | v1 LIVE-mode batch cap. |
| `CHUMP_INTEGRATOR_VOLUME_THRESHOLD` | `5` | Min candidates before a cycle fires. |
| `CHUMP_INTEGRATOR_LOC_BUDGET` | `1500` | Max total estimated LOC per batch. |
| `CHUMP_INTEGRATOR_MAX_BATCH` | `10` | General selector cap (LIVE cap is the tighter of the two). |
| `CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S` | `480` | Preflight command timeout. |
| `CHUMP_INTEGRATOR_SAMPLING_PCT` | `100` | Phase 2 live-cycle sampling rate 0–100. |
| `CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL` | `do-not-batch` | GitHub label that opts a PR out of batching. |

---

## Ambient events

| Event | When emitted |
|---|---|
| `integration_cycle_started` | Every cycle, before candidate selection. |
| `integration_trunk_red_hold` | LIVE cycle held because trunk is RED. |
| `cycle_sampling_decision` | After CLAIM; records live vs dry-run decision. |
| `integration_candidates_selected` | After SELECT with candidate list. |
| `integration_branch_merged` | Per-candidate merge into integration branch. |
| `integration_preflight_started` | Before preflight command runs. |
| `integration_preflight_failed` | Preflight exited non-zero. |
| `integration_cycle_completed` | LIVE cycle shipped successfully; carries `pr_url`. |
| `integration_cycle_failed` | LIVE ship failed; circuit breaker armed. |
| `integration_dry_run_skip` | Cycle forced to dry-run by circuit breaker. |
| `integration_cycle_dry_run_completed` | Dry-run cycle completed normally. |
| `integration_cycle_shipped` | Legacy event kept for kpi-report consumers. |

---

## Cross-references

- INFRA-2130 — parent gap (daemon skeleton + LIVE-mode toggle)
- INFRA-2132 — ambient event kinds registered
- INFRA-2136 — C8 SHIP/BISECT step (bisect oracle, deferred)
- INFRA-2139 — Phase 2 sampling gate
- RESILIENT-050 — trunk-RED detector (provides the state file this daemon reads)
- `docs/strategy/INTEGRATION_CYCLE_2026-05-29.md` — architecture + mode taxonomy
