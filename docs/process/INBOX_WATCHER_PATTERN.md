# Inbox Watcher Pattern — Real-Time Wake on A2A DMs

> **Status**: shipped 2026-05-24 (INFRA-1936). Precedented by curator-opus-target via Claude Code Monitor `bo2mnd8z0` (0s wake vs prior 5m cron poll).
> **Owner**: every productized curator role (target / harvester / shepherd / ci-audit / handoff / decompose / md-links / orchestrator).
> **Replaces**: the operator-as-messenger antipattern where wizard/operator had to ping each curator manually because curators only checked inbox on cron tick.

## What this pattern fixes

Before INFRA-1936, the curator wake model was:

| Wake source | Latency |
|---|---|
| 5m work-your-lane cron tick | up to ~300s |
| Operator manual ping | depends on operator availability |
| Subagent completion notification | only if the curator dispatched it |

Inbox DMs from wizards / operators / sibling curators **had no real-time wake**. Curators discovered them only when the next cron tick fired `scripts/coord/chump-inbox.sh read`. Deadline-bound dispatches with 5-minute response windows routinely missed the window. Wizards had to broadcast multiple times. Operators noticed and called it out (`SUB-AGENT DISPATCH HYGIENE` WARN 2026-05-23T23:28Z; `SELF-LOOP DIRECTIVE` 2026-05-23T23:53Z; INFRA-1860 / INFRA-1879 inbox-poll hook follow-ups).

## What the pattern does

Every curator-* session, as its **FIRST action**, arms a long-lived file watcher on its own session inbox at `.chump-locks/inbox/<session-id>.jsonl`. Each new line appended to that file (a new DM from a sibling, wizard, or operator) emits an event to the harness's wake stream — the curator wakes immediately and processes the DM.

## Harness-agnostic contract

| Element | Value |
|---|---|
| **Inbox path** | `.chump-locks/inbox/<session-id>.jsonl` (relative to repo root; main worktree) |
| **Line format** | One JSON object per line; schema is `{event, session, to, ts, reason, ...}` per `scripts/coord/broadcast.sh` |
| **Wake semantic** | New line appended ⇒ wake the curator (immediately, not on next poll) |
| **File creation** | The file may not exist at session start; the watcher MUST `touch` it or use a watch primitive that handles file creation (`tail -F`, `inotifywait -m`, `fswatch -0`) |

## Per-harness implementation

### Claude Code (the Anthropic harness)

Arm a `Monitor` tool with `persistent: true`:

```
Monitor(
  description: "Watch curator-opus-<role> inbox for new messages",
  persistent: true,
  timeout_ms: 3600000,
  command: "touch .chump-locks/inbox/<SESSION-ID>.jsonl 2>/dev/null; tail -F -n 0 .chump-locks/inbox/<SESSION-ID>.jsonl 2>/dev/null | grep --line-buffered -v '^$'"
)
```

Each new line becomes a `<task-notification>` message. The curator processes it as a wake event (not a user reply). To stop early, call `TaskStop`. Otherwise the watcher runs for the session lifetime.

### opencode / codex / other harnesses

Spawn an equivalent file-watcher process before any work:

```bash
# Linux
inotifywait -m -e modify,create --format '%w%f' .chump-locks/inbox/ \
  | grep --line-buffered "<SESSION-ID>.jsonl" \
  | while read -r path; do
      # Route each new line to harness wake stream
      tail -n 1 "$path" | <harness-wake-injector>
    done

# macOS
fswatch -0 .chump-locks/inbox/<SESSION-ID>.jsonl \
  | xargs -0 -n 1 -I {} sh -c 'tail -n 1 {} | <harness-wake-injector>'
```

### Manual operator (no harness)

`tail -F .chump-locks/inbox/<session-id>.jsonl` in a terminal pane. New lines arrive in real time; operator reads + responds.

## Why every curator should arm one

- **Operator-as-messenger antipattern** — without real-time wake, wizards/operators must hand-broadcast the same DM N times to N curators. With this pattern, one DM wakes the addressee in 0s.
- **Deadline-bound dispatches** — wizards routinely set 5-minute reply windows on ROLL-CALL probes. Pre-watcher, a curator on a 5m cron tick might miss the window entirely. Post-watcher, the wake is sub-second.
- **Fleet velocity** — sibling-to-sibling DMs (e.g. HANDOFF/STUCK/ACK between curators) no longer wait for inbox-poll. Coordination loops tighten.

## When NOT to use this pattern

- **One-off scripts**, not curator sessions. The watcher is overhead if the session has no inbox.
- **Sessions explicitly designed to ignore inbox** (e.g. a one-shot batch processor). These don't have a session-id and have no inbox file.

## Cross-references

- [`docs/process/AGENT_API.md`](AGENT_API.md) — harness contract (INFRA-1050); inbox-watch listed under Wake signals.
- [`docs/process/OPUS_MESSAGE_PROTOCOL.md`](OPUS_MESSAGE_PROTOCOL.md) — the addressed DM protocol the watcher tails.
- [`scripts/coord/broadcast.sh`](../../scripts/coord/broadcast.sh) — the DM writer; defines the jsonl line schema.
- [`scripts/coord/chump-inbox.sh`](../../scripts/coord/chump-inbox.sh) — the inbox reader (still needed for cursor advancement; the watcher tails, doesn't advance cursor).
- `.claude/agents/target.md` + `.claude/agents/harvester.md` — first two productized roles to bake the pattern into their session-start block.
- `INFRA-1860` / `INFRA-1879` — operator-as-messenger fix sibling work (PostToolUse hook approach).
- Precedent: Monitor `bo2mnd8z0` armed by curator-opus-target-2026-05-23 at 2026-05-24T16:45Z; wizard DM landed 2026-05-24T16:47Z with 0s wake.
