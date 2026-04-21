# INFRA-008 Precursor Soak Run — 20260420

**Status:** IN PROGRESS
**Start:** 2026-04-20T03:15:00Z
**Walltime cap:** 14400s (4h)
**Backend:** claude
**Orchestrator:** target/release/chump-orchestrator
**Max parallel:** 2
**Log:** logs/soak/soak-20260420T031500Z.log

## Purpose

This is the 4-hour precursor soak test defined in INFRA-008. Its purpose is to act
as a cheaper forcing function for the 72h autonomy gate — exposing the same failure
modes in an afternoon rather than 3 days.

The soak runs `chump-orchestrator --watch --no-dry-run` unattended against the mixed
infra+eval+docs backlog. A watchdog restarts the orchestrator on crash. Results are
captured here as the soak progresses.

## Success Criteria

| Criterion | Required | Result |
|-----------|----------|--------|
| (a) PRs shipped | ≥1 | TBD |
| (b) Unrecovered panics | 0 | TBD |
| (c) Ambient activity throughout | yes | TBD |
| (d) Cost | <$5 (claude) / <$1 (local) | TBD |

## How to Start the Soak

```bash
# Standard 4h run (background, survives session close):
nohup scripts/soak/run-4h-precursor.sh > logs/soak/current.log 2>&1 &
echo "Soak PID: $!"

# Smoke test (15 min):
SOAK_WALLTIME_SEC=900 scripts/soak/run-4h-precursor.sh

# Watch live log:
tail -f logs/soak/current.log
```

## Environment at Launch

- Host: darwin 25.2.0 (M4 MacBook Pro, 24GB)
- Branch: claude/infra-008
- Gap registry: docs/gaps.yaml
- INFRA-007 (ambient stream fix): merged — ambient.jsonl emitting correctly
- Active concurrent agents at launch: see ambient.jsonl below

## Ambient Stream at T0

```
(see logs/soak/soak-20260420T031500Z.log for live events)
```

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 2026-04-20T03:15:00Z | Soak script launched via nohup |
| T+1h | First checkpoint (see below) |
| T+2h | Second checkpoint |
| T+3h | Third checkpoint |
| T+4h | Soak complete |

## Checkpoints

_Checkpoints are written here automatically by the soak wrapper every hour._

### T+1h checkpoint

| Metric | Value |
|--------|-------|
| PRs shipped since start | TBD |
| Unrecovered panics | TBD |
| Ambient events (last 60m) | TBD |
| Note | — |

### T+2h checkpoint

| Metric | Value |
|--------|-------|
| PRs shipped since start | TBD |
| Unrecovered panics | TBD |
| Ambient events (last 60m) | TBD |
| Note | — |

### T+3h checkpoint

| Metric | Value |
|--------|-------|
| PRs shipped since start | TBD |
| Unrecovered panics | TBD |
| Ambient events (last 60m) | TBD |
| Note | — |

## Final Result

**End:** TBD
**Outcome:** TBD

| Criterion | Required | Result | Pass? |
|-----------|----------|--------|-------|
| (a) PRs shipped | ≥1 | TBD | TBD |
| (b) Unrecovered panics | 0 | TBD | TBD |
| (c) Ambient activity throughout | yes | see checkpoints | TBD |
| (d) Cost | <$5 | see GitHub billing | manual |

## Watchdog Log

_The watchdog restarted the orchestrator N times:_

| Restart # | Time | Exit code | Reason |
|-----------|------|-----------|--------|
| — | — | — | — |

## Notes / Observations

_Fill in after soak completes._

- Binary panics: none observed / LIST
- Queue drain pattern: (fast early, slow late, etc.)
- Cost estimate: (check Anthropic billing dashboard)
- Gaps shipped: (list PR numbers)
- Blockers surfaced: (anything that stopped the soak)

## Go/No-Go Assessment for 72h Gate

Based on this soak run:

| Blocker | Status | Evidence |
|---------|--------|----------|
| #1 Trustworthy eval signal | TBD | |
| #3 Cost-routing proven | TBD | |
| #4 Ambient stream emitting | TBD | |
| #5 Binary stability | TBD | |

**Recommendation:** TBD — fill after soak completes.
