# COS decision log and interrupt tags

**Purpose:** Lightweight governance for chief-of-staff work: where to record decisions, and how to tag **interrupt-worthy** DMs when heartbeat **notify suppression** is on.

**Brain path (gitignored by default):** under `CHUMP_BRAIN_PATH` (usually `chump-brain/`), create:

`cos/decisions/YYYY-MM-DD.md`

One file per day is enough; append new decisions as bullets. This directory is **not** shipped in the main repo (see `.gitignore` on `chump-brain/`); create it on the machine that owns the brain checkout.

---

## Decision entry template

Paste under the day’s file:

```markdown
## <HH:MM> UTC — <short title>

- **Context:** …
- **Decision:** …
- **Alternatives considered:** …
- **Owner:** Jeff | Chump | joint
- **Follow-ups:** task #… or `[COS] …` if tracked in task DB
```

Use `memory_brain write_file` with path `cos/decisions/2026-04-09.md` (adjust date) when you want Chump to persist without opening an editor.

---

## Interrupt policy (`CHUMP_INTERRUPT_NOTIFY_POLICY=restrict`)

When **restrict** is set **and** `CHUMP_HEARTBEAT_TYPE` is non-empty, the **`notify`** tool only queues a DM if the message contains at least one of the following (case-insensitive), or a substring from **`CHUMP_NOTIFY_INTERRUPT_EXTRA`** (comma-separated):

| Tag / phrase | Use when |
|--------------|----------|
| `[interrupt:approval_timeout]` or `approval timeout` / `approval timed out` | Tool approval timed out waiting for human |
| `[interrupt:ship_blocked]` or `ship blocked` | Ship/playbook step cannot proceed |
| `[interrupt:playbook_blocked]` or `playbook blocked` | Same as above, explicit playbook wording |
| `[interrupt:circuit]` or `circuit open` / `circuit breaker` | Model/provider circuit is open / unhealthy |
| `[human]` | You explicitly need a human judgment call |

**Recommended:** Prefer explicit `[interrupt:reason]` prefixes so filtering stays obvious in logs.

**Bypass:** Internal system DMs (e.g. git push auth failure) use an unfiltered path and are **not** subject to this policy.

**Docs:** [OPERATIONS.md](OPERATIONS.md) (tool approval / notify), [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) wave W2.2–W2.3.
