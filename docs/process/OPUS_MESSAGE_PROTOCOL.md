# Opus Message Protocol (INFRA-1798)

> **TL;DR.** Cross-Opus addressed-async DMs via the canonical INFRA-1115
> channel: `scripts/coord/broadcast.sh --to <session>` writes,
> `scripts/coord/chump-inbox.sh read` consumes. Every Claude Code
> SessionStart auto-shows unread (INFRA-1797). Every agent processes its
> inbox **before** acting on a new gap. This doc is the read/process/reply
> protocol every Opus instance follows.

## Why this exists

The Chump fleet runs multiple Opus instances concurrently. INFRA-1115
(broadcast.sh + chump-inbox.sh, shipped earlier) provides the addressed
channel. INFRA-1797 makes unread auto-visible at SessionStart. This doc
ties the discipline together so the channel doesn't rot.

## When to use a DM (vs other channels)

| Send a DM if… | Use a different channel if… |
|---|---|
| Specific Opus instance needs the info | Anyone picking up tomorrow needs it → **file a gap** |
| Real-time coordination need | Generic status update → **let ambient capture it** |
| Hand-off of in-flight work | Permanent stance shift → **edit CLAUDE.md** |
| Asking a peer to review your design | Reviewing someone's PR → **`gh pr comment`** |
| "Pause your pushes for 10min" broadcast | Filing a bug → **`chump gap reserve`** |

**Heuristic.** If the message would still be useful to a *different* agent
picking up next week, file a gap. If it's a real-time need between two
specific Opus instances today, DM.

## Read protocol — every iter

The SessionStart hook (INFRA-1797) surfaces unread count + 3 latest
previews automatically. The operator-discipline of reading + acting on
them is the agent's job.

```bash
# At the start of each iter (after `tail .chump-locks/ambient.jsonl`):
scripts/coord/chump-inbox.sh read --unread

# Or read from a specific session-id:
scripts/coord/chump-inbox.sh read --unread --session "$CHUMP_SESSION_ID"

# Reading auto-advances the cursor (chump-inbox.sh updates
# .chump-locks/inbox/<session>.cursor). Use --no-advance to peek.
```

For each unread message (canonical INFRA-1115 wire shape:
`{event, session, ts, corr_id, urgency, reason, to}`):

1. **Read the body** (`reason` field) — what's being asked / shared.
2. **Decide scope**: `event` tells you the urgency band (WARN / INTENT /
   STUCK / DONE / HANDOFF / ALERT) and `corr_id` ties it to a gap or
   branch.
3. **Act** based on the event kind:
   - `WARN` / `INTENT`: ack + decide if it changes your current direction.
   - `HANDOFF`: receive responsibility for the referenced gap.
   - `STUCK`: peer is blocked — see if you can unblock.
   - `DONE`: peer finished — no reply usually needed.
   - `ALERT`: something is broken in the fleet — investigate.
4. **Cursor auto-advances** when `chump-inbox.sh read` runs. To leave a
   message "unread" while inspecting, use `--no-advance`.
5. **If a reply is warranted**, send one with the original event's
   `corr_id` so the audit trail threads:
   ```bash
   scripts/coord/broadcast.sh \
       --to <sender-session-id> \
       WARN "<your reply, referencing corr_id:branch:foo or gap:INFRA-NNNN>"
   ```

**Critical rule:** do not `--no-advance` and forget to follow up — the
canonical cursor model treats "read but didn't advance" as your bookmark,
not a freshness signal.

## Send protocol — three example patterns

### Pattern 1: hand-off

Use when you're wrapping up but didn't finish; another Opus is picking up.

```bash
scripts/coord/broadcast.sh \
    --to gap:INFRA-1820 \
    HANDOFF INFRA-1820 curator-opus-decompose-2026-05-23
```

(`HANDOFF` is one of the built-in event kinds in broadcast.sh; the recipient
is resolved via the lease holding INFRA-1820 at send-time, with the explicit
`--to gap:<ID>` form.)

### Pattern 2: broadcast warning

Use when you're about to do something that will conflict with peer work.
broadcast.sh's `--to` accepts glob expansion against live lease files:

```bash
scripts/coord/broadcast.sh \
    --to 'curator-opus-*' \
    WARN "Rebasing main aggressively next 10min — expect DIRTY churn on PRs that touch src/main.rs"
```

### Pattern 3: RFC / design review

Use when you want a peer's eyes on a design you're working on.

```bash
scripts/coord/broadcast.sh \
    --to orchestrator-opus-2026-05-23 \
    WARN "RFC: A2A scratchpad keys (INFRA-1761) — proposed 5 seed keys + conflict policies in docs/design/A2A_SCRATCHPAD_KEYS.md. Feedback welcome before slice 2 lands."
```

## Audit trail

Every send dual-publishes:
1. Per-recipient inbox: `.chump-locks/inbox/<recipient>.jsonl`
2. Ambient stream: `.chump-locks/ambient.jsonl` (with the event-type kind
   so other agents see fleet-wide activity)

Query history:

```bash
# What DMs landed in my inbox today?
scripts/coord/chump-inbox.sh read --since 2026-05-23T00:00:00Z --no-advance

# What did I broadcast today?
tail -2000 .chump-locks/ambient.jsonl \
  | grep "\"session\":\"$CHUMP_SESSION_ID\"" \
  | grep -E "\"event\":\"(WARN|INTENT|HANDOFF|STUCK|DONE|ALERT)\""
```

## Bypass / disable

- `CHUMP_OPUS_INBOX_HOOK=0` — disable the SessionStart inbox surfacing
  block (operator-quiet sessions only; doesn't affect the broadcast/inbox
  CLIs).
- No CLI bypass for `broadcast.sh send` — sends always go through; if you
  don't want to send, don't run it.
- `chump-inbox.sh read --no-advance` — peek without consuming.

## What this is *not*

- **Not sync RPC.** No deadlines, no request-response wait. For that →
  INFRA-1759 (Layer 2b RPC).
- **Not durable cross-machine.** Inbox is file-backed in `.chump-locks/`.
  Multi-machine A2A → INFRA-1758 (NATS-primary, dual-publish handled by
  broadcast.sh today when chump-coord is reachable).
- **Not a presence/capability registry.** "Who's online with skill X?" →
  INFRA-1760 (capability manifest).
- **Not a CAS scratchpad.** Shared mutable state with conflict resolution →
  INFRA-1761 (Layer 3d scratchpad).

Today's protocol uses INFRA-1115 file + ambient. The v1 swap (file-inbox →
NATS subjects) lands as INFRA-1759 / INFRA-1758 slice 2/4 follow-ups — the
broadcast.sh + chump-inbox.sh CLI surface stays identical for backward
compat.

## Related

- **INFRA-1115** — broadcast.sh + chump-inbox.sh (the canonical mechanism)
- [INFRA-1797](../gaps/INFRA-1797.yaml) — SessionStart auto-surface hook
- [INFRA-1758](../gaps/INFRA-1758.yaml) — A2A Layer 1a pub/sub foundation
- [INFRA-1759](../gaps/INFRA-1759.yaml) — A2A Layer 2b RPC (v1 sync successor)
- [INFRA-1760](../gaps/INFRA-1760.yaml) — A2A Layer 2c capability manifest
- [INFRA-1761](../gaps/INFRA-1761.yaml) — A2A Layer 3d shared KV scratchpad
- [META-061](../design/A2A_ROADMAP.md) — full 6-layer A2A frontier roadmap
