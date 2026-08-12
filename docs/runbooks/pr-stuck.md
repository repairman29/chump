# PR Stuck Runbook

A PR is "stuck" when it has been open for > 2 hours with failing CI checks or merge conflicts,
and no forward progress is being made toward merge.

## Symptoms

Ambient event kinds to watch:
- `pr_stuck` — emitted when a PR exceeds the stuck threshold (default 2h, failing checks)
- `pr_rescue_triggered` — auto-rebase+re-arm attempt started
- `pr_rescue_completed` — rescue succeeded
- `pr_rescue_failed` — rescue failed (manual intervention needed)
- `stuck_pr_filing_dedup_hit` — filer skipped duplicate stuck-PR gap

Check:
```bash
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(pr_stuck|pr_rescue)"'
gh pr list --state open --json number,title,updatedAt,mergeable
```

## Steps

1. **Identify stuck PRs**:
   ```bash
   gh pr list --state open --json number,title,updatedAt,mergeable,statusCheckRollup \
       | python3 -c "
   import sys, json
   from datetime import datetime, timezone, timedelta
   prs = json.load(sys.stdin)
   now = datetime.now(timezone.utc)
   for pr in prs:
       updated = datetime.fromisoformat(pr['updatedAt'].replace('Z','+00:00'))
       age_h = (now - updated).total_seconds() / 3600
       if age_h > 2:
           print(f\"PR #{pr['number']}: {pr['title']} ({age_h:.1f}h, mergeable={pr['mergeable']})\")
   "
   ```

2. **Check CI failures** for each stuck PR:
   ```bash
   gh pr checks <PR_NUMBER> --json name,state,completedAt
   ```

3. **If merge conflict** — rebase onto main:
   ```bash
   gh pr checkout <PR_NUMBER>
   git fetch origin main
   git rebase origin/main
   # resolve conflicts if any
   git push --force-with-lease
   ```

4. **If CI failure** — diagnose and fix:
   - For known flaky tests: re-run via `gh pr comment <N> -b "/rerun-failed"`
   - For real failures: read the log, fix the code, push a new commit
   - For pre-existing main failures: add `Test-Gate-Bypass: <reason>` to commit body

5. **Re-arm auto-merge** after rebase:
   ```bash
   scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
   ```

6. **If 3+ stuck PRs in 2h** (CLAUDE.md back-off rule):
   ```bash
   # Scale down to 2 workers; diagnose bot-merge contention
   tmux kill-pane -t fleet-worker-3 2>/dev/null || true
   printf '{"ts":"%s","kind":"fleet_scale_change","from":3,"to":2,"rationale":"pr_stuck cluster"}\n' \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   ```

## Verify

```bash
# PR merged or CI green
gh pr checks <PR_NUMBER>

# No new pr_stuck events
tail -50 .chump-locks/ambient.jsonl | grep pr_stuck

# Gap shipped
chump gap show <GAP-ID>
```

## Escalation

- Auto-rescue (`pr_rescue_triggered`) fires within 10 min via `scripts/coord/opus-curator.sh`
- If `pr_rescue_failed`: the gap is unblocked but the PR needs manual push; check the rescue log
- Persistent stuck cluster (> 1h) → drop fleet to 2 workers and file an INFRA gap for root cause

## Observability (INFRA-2942) {#observability-infra-2942}

`scripts/coord/pr-stuck-cluster-detector.sh` emits `kind=pr_stuck_cluster_detector_run`
on **every** invocation (no_op, dry_run, cluster_filed, help, bad_args,
gap_id_extract_failed, gap_reserve_failed, error) via a `trap ... EXIT` — not just
the cluster-detected path. Fields: `outcome`, `stuck_pr_count`, `duration_ms`,
`gap_reserve_calls`, `failure_class`. Registered in
[`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml).

**Cost tracking.** `gap_reserve_calls` counts gap-reserve mutations performed
during that run (0 unless a gap was actually filed). This event itself has no
per-kind cost row in `chump waste-tally` (falls through to the 0 default) — it's
a free run-level audit trail. The billed signal is the sibling `pr_stuck_cluster`
kind (5,000 tokens/incident), which `chump waste-tally` sums and `fleet-brief`
surfaces. Read `gap_reserve_calls` directly off `ambient.jsonl` when auditing
detector mutation cost specifically:
```bash
grep '"kind":"pr_stuck_cluster_detector_run"' .chump-locks/ambient.jsonl | tail -1
```

**Failure-class taxonomy** (INFRA-2906), defined in
`scripts/coord/pr-stuck-cluster-detector.sh:_pscd_failure_class`:
- `none` — not a failure (`no_op` / `dry_run` / `cluster_filed` / `help`)
- `transient` — retry may succeed as-is (`gap_id_extract_failed` / `error`)
- `permanent` — retry repeats until root cause fixed (`gap_reserve_failed` / `bad_args`)

**Smoke test:** `scripts/ci/test-pr-stuck-cluster-observability.sh` (standalone
runnable; covers `no_op`/`dry_run`/`bad_args` outcome paths and asserts
`failure_class` on each). Wired into `chump preflight` via
`crates/chump-preflight/src/preflight.rs` (INFRA-2925).
