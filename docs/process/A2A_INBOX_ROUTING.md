---
doc_tag: operator-guide
last_audited: 2026-05-30
audience: operator, fleet agents
purpose: How sessions identify themselves and how inbox routing maps sender targets to reader files
implements: INFRA-2006 (A2A inbox-routing bug root cause + fix)
---
# A2A Inbox Routing — session identity and file conventions

## The Bug (INFRA-2006)

On 2026-05-29 the curator-opus-shepherd saw 17 consecutive cycles of empty inbox
reads while 11+ sibling sessions were active. Root cause: the sender addressed
messages to the recipient's **lease session-id** (e.g.
`claim-infra-2006-19765-1780118959`) while the receiver's `chump-inbox.sh`
read from its **environment session-id** (e.g. `curator-opus-shepherd-2026-05-29`).
Those two ids differ → message lands in the wrong file → silent loss.

---

## The 3 Ways a Session Identifies Itself

A running session can have **three distinct identifiers**, and they do not always agree:

| # | Identifier | Source | Example |
|---|---|---|---|
| 1 | **CHUMP_SESSION_ID** | Environment variable set by the session launcher or the operator | `curator-opus-shepherd-2026-05-29` |
| 2 | **Lease session_id** | Written by `chump claim` into `.chump-locks/claim-<gap>-<pid>-<ts>.json` at `.session_id` | `claim-infra-2006-19765-1780118959` |
| 3 | **Gap-derived** | Sometimes used by broadcast.sh senders who know the gap but not the session | `INFRA-2006` (gap id used as address) |

`chump-inbox.sh` resolves the *reader* identity via priority:
1. `CHUMP_SESSION_ID` / `CLAUDE_SESSION_ID` env vars
2. `.chump-locks/.wt-session-id` file
3. `~/.chump/session_id` file

`broadcast.sh --to <target>` writes to `.chump-locks/inbox/<target>.jsonl`.
When the sender uses the **lease session-id** (identifier #2) as `<target>`, the
file is written to `.chump-locks/inbox/claim-infra-2006-19765-1780118959.jsonl`.
The reader resolves via identifier #1 (`CHUMP_SESSION_ID`) and opens
`.chump-locks/inbox/curator-opus-shepherd-2026-05-29.jsonl` — **wrong file**.

---

## File Naming Conventions

### Writer (`broadcast.sh --to <recipient>`)

```
.chump-locks/inbox/<recipient>.jsonl
```

`<recipient>` is whatever the sender passes as `--to`. No validation against
live leases (except for glob expansion). A sender who passes the lease id gets
the lease-id filename; a sender who passes the env session id gets the env-id
filename.

### Reader (`chump-inbox.sh read`)

After INFRA-2006 fix, the reader checks **all** of the following and unions them:

```
.chump-locks/inbox/<env-session-id>.jsonl            # primary (CHUMP_SESSION_ID etc.)
.chump-locks/inbox/<lease-session-id>.jsonl          # alias: each lease owned by current process
.chump-locks/inbox/opus-inbox/session_<lease-session-id>.jsonl  # legacy opus-inbox path
```

Deduplication is by `message_id` field (falls back to ts+session+kind triple).

---

## Alias Resolution

`scripts/coord/lib/inbox-routing.sh` provides a `resolve_inbox_targets` function
that returns all inbox file paths a given session should read, derived from:
- the session's primary env-id, AND
- all leases in `.chump-locks/claim-*.json` whose `session_id` matches the
  primary env-id OR whose `gap_id` matches the current `CHUMP_GAP_ID` env.

Senders can call `resolve_inbox_target <session-or-gap-id>` to get the
canonical inbox path for writing. This returns the env-session-id path when
a live lease maps the input to a known session, otherwise returns the literal
input as the path (safe fallback).

---

## Ambient Events

| kind | When emitted |
|---|---|
| `a2a_inbox_alias_resolved` | Reader found messages in an alias (lease-id) inbox; carries `primary_session`, `alias_session`, `message_count` |
| `a2a_inbox_message_orphan` | Message found in an inbox with no matching live lease or env session; carries `inbox_file`, `message_count` (advisory; not fatal) |

---

## Quick Reference

```bash
# Send a targeted message (sender knows lease id):
broadcast.sh --to claim-infra-2006-19765-1780118959 WARN "your PR went dirty"

# Receive all messages (after fix: reader checks lease-id alias too):
chump-inbox.sh read          # union of env-id + lease-id inboxes

# Inspect which inbox files a session should read:
source scripts/coord/lib/inbox-routing.sh
resolve_inbox_targets       # prints one path per line
```

---

## Follow-up Work

- **INFRA-2034** — broadcast.sh positional-arg footgun (sender-side fix)
- **INFRA-2061** — migrate to chump-messaging Rust binary (full replacement)
