---
doc_tag: pointer
owner_gap: DOC-011
last_audited: 2026-04-26
---

# Work Queue → use the CLI

This document is intentionally a stub. Don't curate a parallel list here.

**Canonical source:** `.chump/state.db` (mirror at [`docs/gaps.yaml`](../gaps.yaml)).

```bash
chump gap list --status open                        # all open work
chump gap list --status open --json | jq '...'      # filter by priority/domain
chump --briefing <GAP-ID>                            # full per-gap context
```

## Why this is a stub

A hand-maintained "active work" table is lossy and drifts within hours of being
written (see DOC-008, DOC-009 for prior fixes; the doc was stale again the same
day each time). The system already has:

- **`chump gap list`** — live canonical query, never drifts
- **[`docs/gaps.yaml`](../gaps.yaml)** — regenerated human-readable mirror
- **[`docs/audits/RED_LETTER.md`](../audits/RED_LETTER.md)** — adversarial blockers/debt
- **[`docs/strategy/ROADMAP.md`](../strategy/ROADMAP.md)** — operational backlog

A WORK_QUEUE.md that copies subsets of those is a fourth surface that adds drift,
not signal. DOC-011 tracks the redirect.

## How to pick work

```bash
scripts/gap-preflight.sh <gap-id> && scripts/gap-claim.sh <gap-id>
```

Read [`docs/audits/RED_LETTER.md`](../audits/RED_LETTER.md) first for current blockers.
