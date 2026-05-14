---
doc_tag: operator-guide
last_audited: 2026-05-13
audience: operator, fleet agents
purpose: How to use the per-session mailbox for targeted agent-to-agent messages
implements: INFRA-1115 (META-061 Layer-1 tactical)
---
# A2A Mailbox — operator + agent guide

## What it is

A per-session, file-backed inbox that lets any agent send a **targeted** message to another live session — distinct from the broadcast ambient stream, where everyone sees everything.

Storage: `.chump-locks/inbox/<recipient-session-id>.jsonl`. Append-only JSONL, flock-protected, auto-archived on dead-session detection.

Use mailboxes for the cases where ambient-broadcast is too noisy:
- "Your PR went dirty against main, rebase + REST-merge"
- "I'm taking INFRA-XXX, stand down please"
- "ETA on the gap you're holding?"

For fleet-wide announcements, keep using bare `broadcast.sh` (no `--to`).

## Sending — `broadcast.sh --to <recipient>`

Every existing event type accepts a leading `--to <session-id>`:

```bash
# Targeted INTENT — tell session X you're about to touch their files
scripts/coord/broadcast.sh --to claim-infra-986-12345 INTENT INFRA-779 src/main.rs,scripts/coord/

# Targeted WARN with a free-form message
scripts/coord/broadcast.sh --to claim-credible-052-67890 WARN "Your PR #1764 went dirty; rebase + REST-merge to land"

# Targeted ALERT with a kind tag
scripts/coord/broadcast.sh --to claim-infra-1080-22222 ALERT kind=help_needed "Stuck on Cargo.lock conflict; pairing?"
```

`HANDOFF` still accepts the recipient as positional arg 2 (back-compat); other events require the `--to` flag.

### Glob recipients

`--to <pattern>` with shell glob characters expands at send-time against live session lease files in `.chump-locks/`:

```bash
# Send to every active fleet worker (lease file matches)
scripts/coord/broadcast.sh --to 'fleet-worker-*' WARN "Pause: rate limit incoming"
```

Empty expansion (no live matches) prints a WARN to stderr and writes nothing — the ambient.jsonl event is still preserved as audit trail.

### No `--to` = back-compat

Calls without `--to` work exactly as before: ambient.jsonl only, no inbox writes. Existing fleet scripts need no changes.

## Reading — `chump-inbox.sh read`

The recipient session reads its own inbox:

```bash
# Read new messages since last read (cursor-advancing)
scripts/coord/chump-inbox.sh read

# Read without advancing the cursor (for previewing)
scripts/coord/chump-inbox.sh read --no-advance

# Read everything since session start
scripts/coord/chump-inbox.sh read --since all

# Read since a specific timestamp
scripts/coord/chump-inbox.sh read --since 2026-05-13T22:00:00Z

# Filter by event kind / sender
scripts/coord/chump-inbox.sh read --filter kind=WARN
scripts/coord/chump-inbox.sh read --filter from=claim-infra-986-12345

# JSON output (for tooling)
scripts/coord/chump-inbox.sh read --json

# Count pending unread messages (cursor-aware)
scripts/coord/chump-inbox.sh count
```

Sessions normally read on their own behalf — `CHUMP_SESSION_ID` env (or the canonical resolver chain) picks the right inbox automatically. Operators can read another session's inbox with `--session <id>` for debugging.

### Cursor semantics

`.chump-locks/inbox/<session>.cursor` stores the last-read byte offset. After every successful `read`, the cursor advances and an `inbox_advance` event lands in ambient.jsonl with the count consumed.

The cursor is **atomic** (write-tmp-then-rename) — a killed reader mid-write cannot leave a corrupt cursor.

If the inbox file is archived (reaper ran) or truncated, the reader auto-resets to offset 0 — no manual recovery needed.

## Reaper — `inbox-reap.sh`

Stale inboxes belonging to dead sessions get archived periodically:

```bash
# Dry-run — see what would be archived
scripts/coord/inbox-reap.sh

# Apply — archive dead-session inboxes
scripts/coord/inbox-reap.sh --apply
```

"Dead" means: lease file expired AND outside the grace window (`CHUMP_INBOX_REAP_GRACE_S`, default 1h). Archives land at `.chump-locks/inbox-archive/<session>/<yyyy-mm>.jsonl.gz` (gzip-appended within month). Each archive emits an `inbox_archived` ambient event with the unread-message count, so operator-recall can see if time-sensitive work got missed.

The reaper is idempotent and safe to schedule (cron, launchd, or `chump fleet doctor`).

## Worker-loop integration

A worker that wants to be a good inbox citizen runs the reader at the top of each cycle:

```bash
# In worker.sh or equivalent loop entry
new_messages="$(scripts/coord/chump-inbox.sh count)"
if [[ "$new_messages" -gt 0 ]]; then
    printf '[worker] %d new inbox message(s):\n' "$new_messages" >&2
    scripts/coord/chump-inbox.sh read >&2
fi
```

This is opt-in for v0 — the mailbox is useful even without it (operator + cross-PR debug already benefit). Layer 1a (NATS-primary, INFRA-1118) will make inbox reads push-driven instead of poll-driven.

## When NOT to use a mailbox

- **Audit trail.** Everything in an inbox is ALSO in ambient.jsonl. Use ambient.jsonl for forensics.
- **Fleet-wide announcements.** Bare `broadcast.sh` (no `--to`) is the right tool.
- **Reliable RPC.** The mailbox has no acknowledgment / retry. Layer 2b (INFRA-1119) ships proper request-response.
- **Cross-machine messaging.** Today's mailbox is file-backed (single-host). Layer 1a + NATS unlocks cross-host delivery.

## Events emitted

- `inbox_advance` — recipient ran `read`; cursor advanced; carries `{session, messages_read, new_offset}`
- `inbox_archived` — reaper archived a dead-session inbox; carries `{session, unread_messages, archive}`

Both registered in `docs/observability/EVENT_REGISTRY.yaml`.

## See also

- [`docs/design/A2A_MAILBOX_SEMANTICS.md`](../design/A2A_MAILBOX_SEMANTICS.md) — formal semantics, edge-case handling, sunset criteria
- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — context: where mailboxes sit in the six-layer roadmap
- [`scripts/coord/broadcast.sh`](../../scripts/coord/broadcast.sh) — sender
- [`scripts/coord/chump-inbox.sh`](../../scripts/coord/chump-inbox.sh) — reader
- [`scripts/coord/inbox-reap.sh`](../../scripts/coord/inbox-reap.sh) — reaper
