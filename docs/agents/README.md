---
doc_tag: convention
owner_gap: INFRA-136
---

# Adversarial / scheduled agent prompts

Source-of-truth mirrors of the prompts that run as **remote scheduled agents**
on `claude.ai/code/scheduled`. The trigger config is the live deployment;
**this directory is the source**.

## Why

Until 2026-04-26, every adversarial agent (Cold Water, Frontier Scientist,
Scribe, tech-writer, doc-gardener) lived only in trigger config. A trigger
migration, accidental reset, or operator error would lose the prompt with no
git history. The 2026-04-26 Cold Water rewrite — Step -1 sandbox preflight,
Step 0 prior-issue reconcile, five lenses, mandatory gap-filing — was
particularly large and had zero version control.

INFRA-136 mandates docs-are-source: edit the doc, then push the change to the
trigger via `/schedule update`.

## Convention

Every file in this directory has frontmatter:

```yaml
---
doc_tag: agent
trigger_id: trig_XXXXX
schedule_cron: "0 15 * * 1"
schedule_human: "Mondays 15:00 UTC = 09:00 MDT"
enabled: true
allowed_tools: [Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch]
model: claude-sonnet-4-6
---
```

The body is the **verbatim prompt** sent to the trigger.

## Sync workflow

1. Edit `docs/agents/<name>.md`
2. Open a PR — review like any code change
3. After merge, run `/schedule update <trigger_id>` and paste the new prompt
4. Confirm via `/schedule list` that `updated_at` advanced

Never edit a trigger directly. If you do, immediately update this directory
and open a PR with the change so the source-of-truth catches up.

## Cross-cutting rules

These apply to **every** adversarial / diagnostic agent:

- [`RED_TEAM_VERIFICATION.md`](./RED_TEAM_VERIFICATION.md) — any "no movement"
  / "still open" / "stalled" claim must cite `git log origin/main --grep=<ID>`
  output. Filed as META-001 after a 2026-04-26 diagnostic pass made eight
  inactivity claims that git-log refuted.

## Current agents

| Name | Schedule | Trigger | Doc |
|---|---|---|---|
| Cold Water | Mon 15:00 UTC | `trig_01GA2XVbAZtpkBaWfrEo1CrP` | [cold-water.md](./cold-water.md) |
| Frontier Scientist | Wed 15:00 UTC | `trig_01BqhJMF7jyjGps7GEBtCnQq` | [frontier-scientist.md](./frontier-scientist.md) |
| Scribe | Sun 14:00 UTC | `trig_01K5vWmxr1pJMcTeijNvZHyB` | [scribe.md](./scribe.md) |
| Tech writer (hourly) | hourly | `trig_01QZUM4t2Xr4ZtXSahNPpwnt` | [tech-writer.md](./tech-writer.md) |
| Doc gardener (daily) | 09:00 UTC daily | `trig_01Bd9q8oadn66VBCBPNqp2WN` | [doc-gardener.md](./doc-gardener.md) |

Only Cold Water is currently `enabled: true`. The others are armed prompts
ready to re-enable when the operator decides.
