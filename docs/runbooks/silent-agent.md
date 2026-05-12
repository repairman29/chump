# Silent Agent Runbook

A silent agent is a worker that has held a lease for > 10 minutes without emitting any output
to `ambient.jsonl`. This typically indicates a hang, OOM, or lease-management race.

## Symptoms

Ambient event kinds to watch:
- `fleet_worker_silent` — emitted by the coordinator when a worker stops logging
- `silent_agent` — older variant; same meaning
- `lease_overlap` — two workers holding the same gap lease simultaneously
- `subagent_budget_exceeded` — worker spawned too many subagents (can cause hangs)

Check:
```bash
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(fleet_worker_silent|silent_agent|lease_overlap)"'
ls -la .chump-locks/*.json
```

## Steps

1. **Confirm silence** — check when the worker last wrote an event:
   ```bash
   tail -50 .chump-locks/ambient.jsonl | python3 -c "
   import sys, json
   from datetime import datetime, timezone
   events = []
   for line in sys.stdin:
       try: events.append(json.loads(line))
       except: pass
   if events:
       last = events[-1]
       ts = last.get('ts','?')
       print(f\"Last event: {ts}  kind={last.get('kind','?')}  agent={last.get('agent_id','?')}\")
   "
   ```

2. **Identify orphaned leases**:
   ```bash
   for f in .chump-locks/*.json; do
       echo "=== $f ==="
       cat "$f" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gap_id','?'), d.get('claimed_at','?'), d.get('pid','?'))"
   done
   ```

3. **Check if worker process is alive**:
   ```bash
   # Find worker PIDs from lease files
   cat .chump-locks/*.json 2>/dev/null | python3 -c "
   import sys, json
   for line in sys.stdin:
       try:
           d = json.loads(line)
           pid = d.get('pid')
           gap = d.get('gap_id','?')
           if pid:
               print(f'gap={gap} pid={pid}')
       except: pass
   "
   # Check each PID
   ps aux | grep claude
   ```

4. **Kill silent worker and release its lease**:
   ```bash
   # Kill the process if still running but hung
   kill <PID> 2>/dev/null || true

   # Release the lease
   chump --release --lease .chump-locks/<session>.json

   # Or manually remove
   rm .chump-locks/<session>.json
   ```

5. **If 2+ silent agents in 1h** (CLAUDE.md back-off rule — scale down):
   ```bash
   tmux kill-pane -t fleet-worker-3 2>/dev/null || true
   tmux kill-pane -t fleet-worker-4 2>/dev/null || true
   printf '{"ts":"%s","kind":"fleet_scale_change","from":3,"to":2,"rationale":"silent_agent cluster"}\n' \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   ```

6. **Diagnose root cause**:
   - **OOM**: check `dmesg | grep -i oom` or system memory pressure
   - **Deadlock in gap**: check the gap's branch for unbounded loops or infinite waits
   - **Picker race**: two workers picked the same gap; check for `lease_overlap` events
   - **subagent budget**: worker spawned too many subagents; see `subagent_budget_exceeded` event

7. **Requeue the abandoned gap**:
   ```bash
   chump gap requeue <GAP-ID>   # resets status to open, clears lease
   ```

## Verify

```bash
# No new silent events
tail -50 .chump-locks/ambient.jsonl | grep -E 'fleet_worker_silent|silent_agent'

# Leases are clean
ls .chump-locks/*.json

# Workers are emitting events
tail -20 .chump-locks/ambient.jsonl

# Fleet status healthy
scripts/dispatch/fleet-status.sh
```

## Escalation

- Emergency fast-path (`scripts/coord/emergency-fast-path.sh`) auto-invokes Opus on
  `silent_agent_cluster` (2+ in 1h)
- Opus curator checks for silent agents every 10 min and files an INFRA gap if cluster persists
- If the same gap causes repeated silent agents: close the gap and file a replacement with
  smaller scope or clearer AC
