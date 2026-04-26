---
doc_tag: decision-record
owner_gap:
last_audited: 2026-04-25
---

# Chief-of-Staff Decision Log

Running log of significant decisions made by or relayed through the Chief-of-Staff agent. Part of Wave 2 (W2.3) of the COS roadmap.

## Integration

The COS decision log is stored in the brain directory at `cos/decisions/YYYY-MM-DD.md` (one file per decision or per day). The context assembly (`assemble_context`) injects recent decision log entries on `weekly_cos` heartbeat rounds.

**`CHUMP_INTERRUPT_NOTIFY_POLICY=restrict`** gates which interrupts trigger decision log entries. When an interrupt is tagged `[COS]`, the agent creates a decision entry. Set `CHUMP_NOTIFY_INTERRUPT_EXTRA` to add channels for high-priority decisions.

## Format (brain/cos/decisions/YYYY-MM-DD.md)

```markdown
# [Date] [Short decision title]

**Decision:** [What was decided]
**Rationale:** [Why — constraint, opportunity, or stakeholder ask]
**Alternatives considered:** [What else was evaluated]
**Outcome:** [Result if known, or PENDING]
**Tags:** [cos] [domain] [priority:high|medium|low]
```

## Recent decisions

<!-- Decisions are stored in chump-brain/cos/decisions/ and injected by context assembly.
     This file is the index; the content lives in the brain. -->

See `chump-brain/cos/decisions/` for the full log.

## Querying decisions

```bash
# All decisions from the last 30 days
ls -lt "$CHUMP_BRAIN_PATH/cos/decisions/" | head -30

# Search by topic
grep -r "authentication\|auth" "$CHUMP_BRAIN_PATH/cos/decisions/"

# Via Chump memory search
chump --chump "what decisions have been logged about the inference stack"
```

## See Also

- [Roadmap](ROADMAP.md) — Wave 2 COS roadmap (W2.3)
- [Operations](OPERATIONS.md) — `CHUMP_INTERRUPT_NOTIFY_POLICY`, `CHUMP_NOTIFY_INTERRUPT_EXTRA`
