# PR Stuck Runbook

A PR is "stuck" when it has been open for > 2 hours with failing CI checks or merge conflicts,
and no forward progress is being made toward merge.

## Symptoms

Ambient event kinds to watch:
- `pr_stuck` — emitted when a PR exceeds the stuck threshold (default 2h, failing checks)
- `pr_stuck_announced` — `scripts/coord/pr-stuck-announcer.sh` broadcast a STUCK alert for one
  PR; carries `failure_class` (see taxonomy below)
- `pr_stuck_announcer_summary` — one per announcer run (success or no-op); cost/reach fields
  `eligible`, `announced`, `skipped_dedup`, `api_calls`, `duration_s` (INFRA-2728)
- `pr_stuck_announcer_error` — announcer aborted before completing a scan (e.g. `gh repo view`
  failed); fields `stage`, `reason` (INFRA-2728)
- `pr_stuck_cluster` — 3+ PRs stuck simultaneously in a 2h window (`scripts/coord/pr-stuck-cluster-detector.sh`)
- `pr_rescue_triggered` — auto-rebase+re-arm attempt started
- `pr_rescue_completed` — rescue succeeded
- `pr_rescue_failed` — rescue failed (manual intervention needed)
- `stuck_pr_filing_dedup_hit` — filer skipped duplicate stuck-PR gap

**`failure_class` taxonomy** (INFRA-2728, set by `pr-stuck-announcer.sh`'s `classify_failure()`):
- `transient` — failing check name matches a known flaky/timeout pattern; safe to auto-retry
  (`/rerun-failed`) before escalating
- `permanent` — `mergeable_state=dirty` (real merge conflict) or a failing check that isn't a
  known-flaky pattern; needs rebase or a real fix, will not self-resolve on retry
- `unknown` — blocked with no identifiable failing check; needs manual triage

Check:
```bash
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(pr_stuck|pr_rescue)"'
gh pr list --state open --json number,title,updatedAt,mergeable

# Smoke test: verify the announcer still emits summary + failure_class fields (INFRA-2728)
bash scripts/ci/test-pr-stuck-observability.sh
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
