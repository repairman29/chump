# Opus Message Protocol (INFRA-1798)

> **TL;DR.** Cross-Opus DMs via `scripts/coord/opus-message.sh` (INFRA-1796).
> Every Claude Code SessionStart auto-shows unread (INFRA-1797). Every agent
> processes its inbox **before** acting on a new gap. This doc is the
> read/process/reply protocol every Opus instance follows.

## Why this exists

The Chump fleet runs multiple Opus instances concurrently. Until INFRA-1759
(A2A Layer 2b RPC) ships, the only addressed-async channel between sessions
is `opus-message.sh`. This protocol defines:

1. **When** to send (vs use ambient or PR comments)
2. **When** to read (every iter; auto-surfaced at SessionStart)
3. **How** to process and reply

Discipline matters — if agents skip inbox processing, the channel rots and
operators stop trusting it.

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

Every Opus session, including subagents and autopilot-loop iterations,
**must** check the inbox between "Glance" (ambient tail) and "Pick" (gap
selection). The SessionStart hook (INFRA-1797) surfaces unread count + 3
latest previews automatically — but the operator-discipline of reading +
acting on them remains the agent's job.

```bash
# At the start of each iter (after `tail .chump-locks/ambient.jsonl`):
scripts/coord/opus-message.sh list --unread

# Or filter to messages addressed to me specifically:
scripts/coord/opus-message.sh list --unread --for "$CHUMP_SESSION_ID"
```

For each unread message:

1. **Read the body** — what's being asked / shared.
2. **Decide scope**: is this `--to session:<me>`, `--to gap:<X>` (where I hold
   lease), or `--to all-opus`?
3. **Act** (or note the action):
   - `--to session:<me>`: the message is for me directly. Process inline if
     trivial; if the request is bigger than this iter, file a gap and reply
     with the gap ID.
   - `--to gap:<X>` where I hold lease: same as session-direct — the sender
     thinks I'm the right person.
   - `--to all-opus` (broadcast): note + adjust if relevant (e.g. pause
     pushes if someone is rebasing main). No reply needed unless asked.
4. **Mark read**:
   ```bash
   scripts/coord/opus-message.sh mark-read <msg-id>
   ```
5. **If a reply is warranted**, send one with the original `msg-id` in the
   ref field so the audit trail threads:
   ```bash
   scripts/coord/opus-message.sh send \
       --to session:<sender-id> \
       --from "$CHUMP_SESSION_ID" \
       --body "<your response>" \
       --ref "msg:<original-msg-id>"
   ```

**Critical rule:** never `mark-read` before processing. A restarted session
should still see unprocessed messages.

## Send protocol — three example patterns

### Pattern 1: hand-off

Use when you're wrapping up but didn't finish; another Opus is picking up.

```bash
scripts/coord/opus-message.sh send \
    --to gap:INFRA-1820 \
    --from "$CHUMP_SESSION_ID" \
    --body "I started outlining at /tmp/chump-infra-1820/docs/design/X.md. \
Continue from §3 (integration sketch). cargo gate green; preflight skipped. \
Lease expires in ~15min." \
    --ref "pr:0"
```

Pairs well with: ambient `intent_handoff` emit (when that kind exists per
INFRA-1119 RPC ask-handoff).

### Pattern 2: broadcast warning

Use when you're about to do something that will conflict with peer work.

```bash
scripts/coord/opus-message.sh send \
    --to all-opus \
    --from "$CHUMP_SESSION_ID" \
    --body "Rebasing main aggressively next 10min — expect DIRTY churn on \
PRs that touch src/main.rs or src/atomic_claim.rs. Hold non-critical pushes."
```

### Pattern 3: RFC / design review

Use when you want a peer's eyes on a design you're working on.

```bash
scripts/coord/opus-message.sh send \
    --to all-opus \
    --from "$CHUMP_SESSION_ID" \
    --body "RFC: A2A scratchpad keys (INFRA-1761) — proposed 5 seed keys + \
conflict policies in docs/design/A2A_SCRATCHPAD_KEYS.md. Feedback welcome \
before slice 2 lands." \
    --ref "pr:2391"
```

## Audit trail

Every send emits `kind=opus_message_sent {to, from, ref, msg_id}` to
`.chump-locks/ambient.jsonl`. Query history:

```bash
# What DMs were sent in the last 30 min?
tail -500 .chump-locks/ambient.jsonl | grep opus_message_sent

# What did I send today?
tail -2000 .chump-locks/ambient.jsonl \
  | grep opus_message_sent \
  | grep "\"from\":\"$CHUMP_SESSION_ID\""
```

The `--ref` field threads conversations — search by it to see the full chain
across messages and PRs.

## Bypass / disable

- `CHUMP_OPUS_INBOX_HOOK=0` — disable the SessionStart inbox surfacing block
  (operator-quiet sessions only; doesn't affect the CLI).
- No CLI bypass for `send` — sends always go through; if you don't want to
  send, don't run it.
- `mark-read` is operator-only; the SessionStart hook is intentionally
  read-only to prevent missed messages on restart.

## What this is *not*

- **Not sync RPC.** No deadlines, no request-response wait. For that → INFRA-1759.
- **Not durable across machines.** Inbox is file-backed in `.chump-locks/`.
  Multi-machine A2A → INFRA-1758 (NATS-primary).
- **Not a presence/capability registry.** "Who's online with skill X?" →
  INFRA-1760 (capability manifest).
- **Not a CAS scratchpad.** Shared mutable state with conflict resolution →
  INFRA-1761.

This is the v0 paved-cow path. It works today. The v1 swap (file-inbox →
NATS subjects) is INFRA-1759's responsibility; the CLI surface stays
identical for backward compat.

## Related

- [INFRA-1796](../gaps/INFRA-1796.yaml) — the CLI (`opus-message.sh`)
- [INFRA-1797](../gaps/INFRA-1797.yaml) — SessionStart auto-surface hook
- [INFRA-1758](../gaps/INFRA-1758.yaml) — A2A Layer 1a pub/sub foundation
- [INFRA-1759](../gaps/INFRA-1759.yaml) — A2A Layer 2b RPC (v1 successor)
- [INFRA-1760](../gaps/INFRA-1760.yaml) — A2A Layer 2c capability manifest
- [INFRA-1761](../gaps/INFRA-1761.yaml) — A2A Layer 3d shared KV scratchpad
- [META-061](../design/A2A_ROADMAP.md) — full 6-layer A2A frontier roadmap
