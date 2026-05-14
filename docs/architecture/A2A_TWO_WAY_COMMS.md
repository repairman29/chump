---
id: DOC-049
purpose: |
  Design for two-way operator ↔ fleet communications over the A2A layer.
  Covers identity, severity/urgency, reach hierarchy, filter rules, and the
  correlation_id reply contract built on INFRA-1255. Each row in the
  use-case matrix maps to one implementation gap so the chain is fully
  traceable.
audience: operator, fleet engineers, PWA contributors
status: approved — implementation chain INFRA-1296..1302 + PRODUCT-103..105
---

# A2A Two-Way Operator Communications

> **TL;DR** The fleet can already *emit* events to the operator (ambient.jsonl,
> NATS). This document specifies the missing half: the operator sending
> structured messages *to* the fleet, plus the routing layer that decides how
> urgently each message reaches its recipient. Together these form a
> bidirectional A2A channel between a human operator and their running agents.

## Background

`scripts/coord/broadcast.sh` gives agents INTENT / HANDOFF / STUCK / DONE /
WARN / ALERT / FEEDBACK events. `INFRA-1255` added `correlation_id` so reply
chains are traceable. What is missing:

1. **Operator → fleet direction** — no structured endpoint for the operator
   to send a message *to* a running session.
2. **Urgency routing** — all events land in `ambient.jsonl` equally; there
   is no tier that says "wake the operator now" vs. "batch this to tomorrow's
   digest."
3. **Identity** — who is sending the message? Agent session IDs are ephemeral;
   operator identity is not persisted across browser tabs.
4. **Filter rules** — the operator should be able to say "I only want STUCK
   messages from P0 gaps on my MacBook."

---

## 1. Use-Case Matrix

Each row describes a flow direction, trigger, and the implementation gap that
delivers it.

### 1a. Operator → Fleet

| Use Case | Trigger | Fields | Gap |
|---|---|---|---|
| Compose + send any a2a event from PWA | Operator clicks "Send message" in fleet UI | `event`, `subject`, `recipient?`, `rationale`, `urgency?` | **INFRA-1296** (POST /api/broadcast) |
| Assign urgency tier to an outbound event | Operator sets urgency dropdown before send | `urgency: now \| hours \| digest` | **INFRA-1299** (severity + urgency fields) |
| Set operator-side filter rules | Operator edits `.chump/operator-rules.yaml` | `rules: [{match, event, source, action}]` | **INFRA-1300** (filter rules) |
| Compose message from PWA compose component | Operator fills the compose form | Event type, recipient session, rationale body, vote | **PRODUCT-103** (compose component) |

### 1b. Fleet → Operator

| Use Case | Trigger | Fields | Gap |
|---|---|---|---|
| Deliver event to operator inbox | Any `broadcast.sh` call with `recipient=operator` | `event`, `subject`, `corr_id`, `urgency` | **INFRA-1298** (GET /api/inbox + ack) |
| Route urgent events as in-app toast | urgency=now, operator tab open | Toast payload: subject, event type, ack CTA | **PRODUCT-105** (toast + unread badge) |
| Route urgent events as Web Push | urgency=now, operator tab closed | Web Push API payload | **INFRA-1301** (service-worker push) |
| Batch non-urgent events as daily digest | urgency=digest, 9 AM cron | Grouped FEEDBACK + STUCK clusters | **INFRA-1302** (Discord + ambient digest) |
| Operator reads inbox, acks messages | Operator opens PWA inbox view | `session`, `event_id`, `ack_ts` | **PRODUCT-104** (inbox view with ack) |

---

## 2. Identity Model

### 2a. Operator Identity

The operator has a **stable machine-scoped identity** that persists across
browser sessions:

```
operator-<machine-id>
  e.g. operator-macbook-pro-5a3f
```

- **Persistence:** stored in two places in parallel:
  - `localStorage["chump_operator_id"]` (browser-side, survives tab close)
  - `.chump/operator_id` (file, survives browser clear)
- On first load the PWA checks `.chump/operator_id` via the `/api/config`
  endpoint; if absent, generates a UUID4 and writes both.
- The machine-id suffix comes from `system_profiler SPHardwareDataType` (macOS)
  or `/etc/machine-id` (Linux); fallback to `hostname`.
- **Implemented by:** INFRA-1297

### 2b. Per-Tab Session Children

Each open browser tab generates an ephemeral child identity:

```
operator-<machine-id>-tab-<short-uuid>
  e.g. operator-macbook-pro-5a3f-tab-b7c2
```

- Generated on `DOMContentLoaded`; stored in `sessionStorage` only.
- Used as the `sender` in PWA-initiated broadcast calls so multi-tab activity
  is distinguishable in the ambient log.
- Tab identity does **not** persist; it is purely for within-session
  disambiguation.

### 2c. Agent Session Identity

Unchanged from today: `claim-<gap>-<pid>-<ts>`. The operator identity system
does not replace or rename agent sessions.

---

## 3. Severity + Urgency Schema

### 3a. Fields

Every A2A event may carry:

| Field | Type | Description |
|---|---|---|
| `urgency` | `now \| hours \| digest` | How fast the operator needs to see this |
| `severity` | `critical \| warn \| info` | Semantic weight of the event |

### 3b. Defaults by Event Type

| Event | Default urgency | Default severity |
|---|---|---|
| `ALERT` | `now` | `critical` |
| `STUCK` | `hours` | `warn` |
| `HANDOFF` | `hours` | `info` |
| `FEEDBACK` | `digest` | `info` |
| `DONE` | `digest` | `info` |
| `INTENT` | `digest` | `info` |
| `WARN` | `hours` | `warn` |

Senders may override either field explicitly via `--urgency` and `--severity`
flags on `broadcast.sh`.

### 3c. Reach Classifier

`scripts/coord/reach-classifier.sh` (INFRA-1299) reads an event envelope +
operator rules and outputs a JSON reach decision:

```json
{ "channels": ["inbox", "toast", "push"] }
```

Channel selection rules (evaluated in order; first match wins):

1. **inbox** — always included for every event regardless of urgency.
2. **toast** — included if `urgency=now` AND operator has PWA tab open.
3. **push** — included if `urgency=now` AND operator has no open tab
   (detected via Service Worker registration state).
4. **discord** — included if `urgency=now` AND `CHUMP_DISCORD_WEBHOOK` is
   set in operator rules.
5. **digest** — included if `urgency=digest`; aggregated by the 9 AM cron.

---

## 4. Reach Hierarchy

From highest to lowest urgency tier:

```
  ┌──────────────────────────────────────────────────────┐
  │  push (Web Push API, background, urgency=now)         │
  ├──────────────────────────────────────────────────────┤
  │  toast (in-app, tab open, urgency=now)                │
  ├──────────────────────────────────────────────────────┤
  │  inbox (always; PWA /inbox view)                      │
  ├──────────────────────────────────────────────────────┤
  │  discord webhook (opt-in, urgency=now/hours)          │
  ├──────────────────────────────────────────────────────┤
  │  digest (daily 9 AM, urgency=digest)                  │
  └──────────────────────────────────────────────────────┘
```

All channels write to `ambient.jsonl` so the full delivery record is
queryable regardless of which channel was active.

---

## 5. Filter-Rule Schema

Stored in `.chump/operator-rules.yaml` (INFRA-1300). The file is read at
startup and on SIGHUP / hot-reload.

```yaml
# .chump/operator-rules.yaml
version: 1
rules:
  # Rule evaluation order: first match wins.
  # Fields: match (optional), event (optional), source (optional), action.
  # match: glob against subject / gap-id
  # event: event type or list of event types
  # source: agent session glob
  # action: inbox | toast | push | discord | digest | suppress

  - match: "P0*"
    event: [STUCK, ALERT]
    action: push           # P0 stucks always push regardless of urgency default

  - event: FEEDBACK
    action: digest         # all feedback to digest

  - source: "claim-infra-*"
    event: DONE
    action: inbox          # INFRA gaps done: inbox only

  - action: inbox          # default: inbox for everything else
```

### 5a. Rule Precedence

Rules are evaluated top-to-bottom; the first match sets the action. A rule with
no `match`, `event`, or `source` field acts as a catch-all default.

Operators may set `CHUMP_OPERATOR_RULES=0` to disable file-based rules and
fall back to the urgency-default routing table in §3b.

---

## 6. Correlation ID Reply Contract

Built on **INFRA-1255** (`correlation_id` schema + inbox-reap auto-clear).

### 6a. Event Chain Shape

```
Operator → broadcast.sh  INTENT  corr_id=<gap-id>
Agent    → broadcast.sh  STUCK   corr_id=<gap-id>  ← reply to operator
Operator → broadcast.sh  HANDOFF corr_id=<gap-id>  ← operator responds
Agent    → broadcast.sh  DONE    corr_id=<gap-id>  ← closes the chain
```

- Every outbound event **must** carry `corr_id`.
- Default `corr_id` when not specified: current gap-id (if in a gap worktree),
  else current branch name, else ISO timestamp.
- The PWA compose component (PRODUCT-103) pre-fills `corr_id` from the
  selected gap-id or inbox thread being replied to.

### 6b. Reply Threading in the Inbox

The inbox view (PRODUCT-104) groups messages by `corr_id` as a thread:

```
Thread: INFRA-1282  [3 messages]
  INTENT  (agent, 2026-05-14T18:00Z)  ← original
  STUCK   (agent, 2026-05-14T19:30Z)  ← agent asked for help
  HANDOFF (operator, 2026-05-14T20:00Z)  ← operator replied
```

### 6c. Auto-Reap

`inbox-reap.sh` (already shipped, INFRA-1255) auto-clears messages when:
- A `DONE` event with the same `corr_id` appears, OR
- The message is older than `CHUMP_INBOX_TTL_DAYS` (default 7).

---

## 7. Implementation Gap Chain

The 10 gaps below implement this spec end-to-end. They are ordered by
dependency:

```
INFRA-1297 (stable identity)
  ↓
INFRA-1299 (urgency + severity fields)
  ↓
INFRA-1300 (filter rules)
  ↓
INFRA-1296 (POST /api/broadcast)   INFRA-1298 (GET /api/inbox + ack)
  ↓                                    ↓
PRODUCT-103 (compose component)    PRODUCT-104 (inbox view + ack)
                                         ↓
                               INFRA-1301 (web push)
                               INFRA-1302 (digest cron)
                               PRODUCT-105 (toast + badge)
```

| Gap | Title | Effort |
|---|---|---|
| INFRA-1296 | POST /api/broadcast REST endpoint | s |
| INFRA-1297 | operator-id stable identity | s |
| INFRA-1298 | GET /api/inbox + ack endpoints | s |
| INFRA-1299 | severity + urgency fields; reach-classifier | s |
| INFRA-1300 | operator filter rules (.chump/operator-rules.yaml) | s |
| INFRA-1301 | PWA service-worker Web Push for urgency=now | s |
| INFRA-1302 | daily 9 AM digest (Discord + ambient) | s |
| PRODUCT-103 | PWA compose component | s |
| PRODUCT-104 | PWA inbox view with ack/reply | s |
| PRODUCT-105 | PWA toast + unread badge | s |

---

## 8. Related Documents

- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — six-layer A2A
  frontier roadmap (NATS-primary delivery → signed provenance)
- [`docs/architecture/OPERATOR_AGENT.md`](./OPERATOR_AGENT.md) — the
  operator-agent design (Sonnet-class continuous operator proxy)
- `scripts/coord/broadcast.sh` — event emission entry point
- `scripts/coord/lib/github_cache.sh` — cache layer used by coordination
  scripts
