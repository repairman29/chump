---
name: claim-without-collision
description: Atomic gap claim that verifies no sibling owns the gap and emits lease_overlap on race detection
version: 1
platforms: []
metadata: {}
---

# claim-without-collision

## User story

**As a Picker agent**, when I am about to claim a gap and set up a worktree,
**I want my claim to be atomic across NATS-KV + file-lock + ambient signals, with race detection that fails fast**,
**so that two workers never end up editing the same gap and producing conflicting PRs that waste both their cycles plus operator firefighting**.

## When this skill applies

Trigger this skill whenever you are about to:
- Run `chump gap claim <ID>` for any gap
- Set up a `.chump/worktrees/<name>` or `.claude/worktrees/<name>` linked worktree
- Acquire a lease in `.chump-locks/<session>.json`
- Pick a gap suggested by `chump gap list`, `chump gap pickable`, or planner output

## Procedure

1. **Preflight gate** (mandatory, exits non-zero on any block):
   ```bash
   chump gap preflight <GAP-ID>
   ```
   Verifies: gap is `open`, not `done-on-main`, no live claim by another session, no merge-queue lock.

2. **Sibling-lease scan** (defense in depth — preflight queries a different lock layer):
   ```bash
   # File-layer
   ls .chump-locks/claim-*.json 2>/dev/null | xargs -I{} jq -r 'select(.gap_id == "<GAP-ID>") | "\(.session_id) expires \(.expires_at)"' {}
   # Ambient-layer (catches in-flight claim events not yet visible in lock files)
   tail -200 .chump-locks/ambient.jsonl | jq -r 'select(.kind=="claim" and .gap_id=="<GAP-ID>") | "\(.ts) \(.session_id)"' | tail -3
   ```
   If either layer shows a live competitor, **STOP** — pick a different gap.

3. **Atomic claim**:
   ```bash
   chump claim <GAP-ID> --paths <CSV-of-paths-you-will-touch>
   ```
   Atomic: fetch + verify + doctor + worktree + lease in one transaction. The `--paths` arg is critical — it lets path-level lease coordination (per [INFRA-1549](docs/gaps/INFRA-1549.yaml)) detect future Edit/Write overlaps within the gap.

4. **Post-claim verification** (catches the INFRA-1602 double-claim class):
   ```bash
   # Confirm exactly ONE lease exists for this gap, and it's yours
   for f in .chump-locks/claim-*.json; do
     jq -r --arg gap "<GAP-ID>" --arg me "$CHUMP_SESSION_ID" \
       'select(.gap_id == $gap) | "\(.session_id)\(if .session_id == $me then " [MINE]" else " [STRANGER]" end)"' "$f"
   done
   ```
   If you see `[STRANGER]` alongside `[MINE]` → race detected, emit `lease_overlap` and abandon.

5. **Heartbeat enrollment**:
   ```bash
   # worker.sh handles this automatically per cycle; manual sessions should call:
   chump --heartbeat <session-id>
   ```
   Without heartbeat, your lease will be reaped after `CHUMP_GAP_CLAIM_TTL_SECS`.

## Pitfalls

### Pitfall 1: Preflight-OK does not guarantee claim-OK
Preflight queries state.db; the actual claim may collide with a NATS-KV or file-lock race. **Always do step 4 (post-claim verification).**

### Pitfall 2: NATS-KV vs file-lock divergence
Workers using `chump-coord` (NATS path) and workers using only `.chump-locks/*.json` (file path) can both think they own a gap. Per [INFRA-1608](docs/gaps/INFRA-1608.yaml), the fleet has shipped this bug at least once (INFRA-1602 had two simultaneous live leases on 2026-05-17). **Until INFRA-1608 ships, treat post-claim verification as load-bearing, not optional.**

### Pitfall 3: Orphaned leases don't get reaped on session crash
If a sibling session died mid-claim, its lease file persists until `chump --release` runs OR the TTL expires (default 3600s). You may see `[STRANGER]` for a zombie session. **Diagnose with**: `ps -p $STRANGER_PID 2>&1 | tail -1` — if "No such process", the lease is orphaned and `stale-lease-reaper.sh` will clear it on next cron tick (~5 min wait, or run manually).

### Pitfall 4: Speculative claims left behind
`chump claim --speculative` leaves a different lease shape. Don't conflate a speculative claim with a live worker. Speculative leases have `speculative: true` in the JSON.

## Verification (how to know this skill worked)

- `chump gap show <GAP-ID>` shows your session as the live claimer (no `[STRANGER]` row)
- Your worktree is created cleanly at `.chump/worktrees/<name>` or equivalent
- No `lease_overlap` event appears in ambient.jsonl for this gap-id+timestamp window
- Your subsequent commits ship without "gap already claimed by another worker" errors

## Outcome recording

```
skill_manage(action=record_outcome, name=claim-without-collision, success=true)
```

Call `success=true` when:
- The claim succeeded and your work shipped (PR merged)
- You ABANDONED a gap because step 2 or 4 caught a stranger lease (the most valuable case — you avoided the collision)

Call `success=false` when:
- You claimed successfully but a sibling shipped conflicting changes anyway (race window the procedure didn't catch)
- Your post-claim verification missed a stranger that surfaced later as a conflict
- Heartbeat lapsed and your lease got reaped mid-work

## Cross-references

- **Gap covering the integrity bug**: [INFRA-1608](docs/gaps/INFRA-1608.yaml) (atomic-claim CAS hardening + lease_overlap emission)
- **Path-level wire-up**: [INFRA-1549](docs/gaps/INFRA-1549.yaml) (PreToolUse Edit|Write coordination via chump-agent-lease)
- **Atomic claim source**: `src/atomic_claim.rs::run_claim`
- **Lease lib**: `scripts/lib/lease.sh`
- **Documented in**: AGENTS.md "How to claim work" + CLAUDE.md "MANDATORY pre-flight"
