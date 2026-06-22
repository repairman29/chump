# Fleet scaling retrospective — 2026-05-06

**Gap:** INFRA-518  
**Author:** Fleet worker (sonnet)  
**Status:** Criteria established; 2→3 stress test pending operator green-light

---

## Context

Prior work (INFRA-513, logged in 2026-05-02 synthesis) validated a 2-worker parallel fleet:
- 28 PRs merged in a single session
- Per-PR ship time via `--fast`: **6 seconds wall** (vs 5–10 min cold)
- 2 dogfood workers shipped with zero parent intervention

INFRA-518 gates expansion to 3 and then 4 workers as deliberate stress tests of
the fixes that made Tier-2 stable. Each tier is a controlled experiment, not a
free scale-up.

---

## Known failure modes at higher concurrency

### 2 → 3: Picker race (INFRA-513)
At 3 concurrent workers, `gap-claim.sh` can race on the same gap if the NATS
lock window is < the DB write round-trip. Symptom: two workers claim the same
gap; one silently fails its first commit, producing a `silent_agent` event.
Fix: INFRA-513 added atomic claim via `chump claim` (single DB transaction).
**Stress-test criterion:** zero `silent_agent` events for ≥ 30 min at FLEET_SIZE=3.

### 3 → 4: bot-merge contention
At 4 workers, `bot-merge.sh` rebases hit `origin/main` at near-simultaneous
intervals. The rebase+push window is ~8 seconds; with 4 workers on 6-second
ship cycles, collision probability is ~30 % per cycle without jitter. Symptom:
`pr_stuck` cluster (multiple PRs failing the rebase step). INFRA-409 restored
the atomic picker invocation in `worker.sh` which reduces overlap, but the
4-worker tier requires explicit jitter validation.
**Stress-test criterion:** `pr_stuck` rate < 15 % (< 2 of last 13 PRs) at FLEET_SIZE=4.

---

## Scaling thresholds (operative)

See [`CLAUDE.md` → Fleet scaling gate](../CLAUDE.md) for the full gate table.
Thresholds in brief:

| Transition | Waste rate | Ship rate | fleet_wedge | silent_agent | pr_stuck |
|---|---|---|---|---|---|
| 2 → 3 | < 20 % | ≥ 70 % | 0 (2 h) | ≤ 1 (2 h) | ≤ 1 (2 h) |
| 3 → 4 | < 15 % | ≥ 80 % | 0 (2 h) | 0 (2 h) | 0 (2 h) |

---

## Back-off rules rationale

| Trigger | Rationale |
|---|---|
| `fleet_wedge` | Single wedge can cascade — second worker inherits a corrupted branch state. Hard stop. |
| `silent_agent` > 1 | Two silenced agents means the picker race is live; extra workers amplify it. |
| `pr_stuck` cluster ≥ 3 | Pattern of 3 indicates systemic bot-merge contention, not transient CI flake. |
| Waste rate > 30 % | More than 1 in 3 cycles producing nothing — adding workers multiplies the waste. |
| CI failure > 25 % | Likely a shared dependency or branch-state issue; scaling makes diagnosis harder. |

---

## Experiment plan (when operator triggers scale-up)

1. **Baseline read** (at FLEET_SIZE=2, stable for ≥ 1 h):
   ```bash
   chump waste-tally --window 2h
   scripts/dispatch/fleet-status.sh --json
   tail -200 .chump-locks/ambient.jsonl | python3 -c "
   import sys, json
   events = [json.loads(l) for l in sys.stdin if l.strip()]
   for k in ['fleet_wedge','silent_agent','pr_stuck']:
       print(k, sum(1 for e in events if e.get('kind')==k))
   "
   ```

2. **Scale to 3** (if all criteria met):
   ```bash
   printf '{"ts":"%s","kind":"fleet_scale_change","from":2,"to":3,"rationale":"criteria met: waste<20%,ship>=70%,0 wedges"}\n' \
     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   FLEET_SIZE=3 scripts/dispatch/run-fleet.sh
   ```
   Monitor for 30 min. Check `silent_agent` events (INFRA-513 stress test).

3. **Scale to 4** (if 3-worker tier stable for ≥ 30 min):
   ```bash
   printf '{"ts":"%s","kind":"fleet_scale_change","from":3,"to":4,"rationale":"3-worker tier stable: 0 silent_agent, waste<15%"}\n' \
     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   FLEET_SIZE=4 scripts/dispatch/run-fleet.sh
   ```
   Monitor for 30 min. Check `pr_stuck` rate (bot-merge contention stress test).

4. **Post-experiment capture**: append actual event counts and observed metrics to this file.

---

## Post-validation data (fill in after experiment)

| Date | Tier | Duration | PRs merged | Waste rate | fleet_wedge | silent_agent | pr_stuck | Outcome |
|---|---|---|---|---|---|---|---|---|
| (pending) | 2→3 | — | — | — | — | — | — | — |
| (pending) | 3→4 | — | — | — | — | — | — | — |

---

## Post-mortem: 2026-05-16 PR-stuck cluster (INFRA-1393)

**Cluster**: 11 PRs blocked 14–19h on 2026-05-16 (PRs #2150–2182).
**Cause**: `ci_flake` — audit CI job failed on unallowlisted orphan event kinds
introduced by the rebase-daemon (INFRA-1403/1406). Every open PR touching
audited paths was blocked until the allowlist was patched.
**Resolution**: Three fix PRs landed in sequence (#2178, #2197, #2209); all
11 PRs subsequently merged.
**Durable fix**: INFRA-1410 (PR-stuck SLO + auto-respawn, merged PR #2260
2026-05-16T17:09Z) — prevents recurrence by auto-restarting wedged PRs and
alerting when a cluster forms. Audit allowlist now enforced by CI gate.
