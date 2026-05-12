# Fleet Wedge Runbook

A fleet wedge occurs when all workers are blocked waiting on locks, PRs, or resources and
no forward progress is being made. Gap throughput drops to zero.

## Symptoms

Ambient event kinds to watch:
- `fleet_wedge` — emitted by the coordinator when all workers are stuck
- `fleet_wedge_storm` — 3+ wedge events within 30 minutes
- `silent_agent` — no output from a worker for > 10 minutes
- `lease_overlap` — two workers claimed the same gap

Check:
```bash
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(fleet_wedge|fleet_wedge_storm|silent_agent)"'
scripts/dispatch/fleet-status.sh
```

## Steps

1. **Confirm wedge** — at least one worker has been silent for > 10 min:
   ```bash
   tail -100 .chump-locks/ambient.jsonl | grep fleet_wedge
   scripts/dispatch/fleet-status.sh
   ```

2. **Scale down to 2 workers** (per CLAUDE.md back-off rule):
   ```bash
   tmux kill-pane -t fleet-worker-3 2>/dev/null || true
   tmux kill-pane -t fleet-worker-4 2>/dev/null || true
   printf '{"ts":"%s","kind":"fleet_scale_change","from":4,"to":2,"rationale":"fleet_wedge backoff"}\n' \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   ```

3. **Release orphaned leases**:
   ```bash
   ls .chump-locks/*.json | while read f; do
       chump --release --lease "$f" 2>/dev/null && echo "released $f"
   done
   ```

4. **Identify root cause** — look at the most recent wedge:
   ```bash
   tail -50 .chump-locks/ambient.jsonl | python3 -c "
   import sys, json
   for line in sys.stdin:
       try:
           e = json.loads(line)
           if e.get('kind') == 'fleet_wedge':
               print(json.dumps(e, indent=2))
       except: pass
   "
   ```

   Common causes:
   - **`pr_stuck` cluster** — bot-merge.sh contention; see [pr-stuck.md](pr-stuck.md)
   - **`silent_agent` cluster** — lease race; see [silent-agent.md](silent-agent.md)
   - **`queue_config_drift`** — picker saw no pickable gaps; run `chump gap list --status open`
   - **`edit_burst`** — worker writing too many files; check last gap's diff size

5. **Resolve root cause** (see linked runbooks if applicable).

6. **Restart workers** once stable:
   ```bash
   scripts/dispatch/run-fleet.sh 2
   ```

7. **Log scale-up** when metrics clear (waste < 20%, ship rate ≥ 70%, 0 wedge events in 30 min):
   ```bash
   printf '{"ts":"%s","kind":"fleet_scale_change","from":2,"to":%d,"rationale":"%s"}\n' \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <target> "<reason>" >> .chump-locks/ambient.jsonl
   ```

## Verify

```bash
# No new wedge events
tail -100 .chump-locks/ambient.jsonl | grep fleet_wedge

# Workers running and picking up gaps
scripts/dispatch/fleet-status.sh

# SLO check passes
chump health --slo-check
```

## Escalation

- Wedge persists > 30 min after scale-down → manual investigation required
- Emergency fast-path (every 5 min) auto-invokes Opus for CI root-cause when `fleet_wedge` fires
- Check `scripts/coord/emergency-fast-path.sh` logs for auto-remediation attempts
