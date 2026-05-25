---
name: fleet-brief
description: 60-second Chump fleet operator briefing — 24h ship count and rate, pillar mix from shipped PR titles, open PR stalls (BLOCKED > 4h), auto-fixed CI events, manual rescues, and a suggested next operator action. Use when starting a session and wanting a quick "what's the fleet doing" read, OR when an alert has fired and you want context before diagnosing. Thin wrapper over harness-neutral CLI at `scripts/dispatch/fleet-brief.sh` (INFRA-721); same call works from any harness. Per `.claude/README.md` pattern — capability lives in the script, this skill just exposes it as a slash command.
user-invocable: true
allowed-tools:
  - Bash
---

# /fleet-brief — Chump Fleet 60-Second Briefing

Canonical surface: [`scripts/dispatch/fleet-brief.sh`](../../../scripts/dispatch/fleet-brief.sh) (INFRA-721). Any harness invokes the same script; this skill is the Claude Code adapter.

## Routing

Arguments passed: `$ARGUMENTS` (typically empty — the brief takes no required args).

```bash
scripts/dispatch/fleet-brief.sh $ARGUMENTS
```

Surface stdout to the user verbatim. The script outputs ≤ 30 lines of plain text designed for scannability — don't re-paraphrase.

## When the user asks "what's the fleet doing?"

This is the right tool. The brief covers:
- 24h ship count + rate trend
- Pillar mix from shipped PR titles (RESILIENT / EFFECTIVE / CREDIBLE / ZERO-WASTE / MISSION)
- Open PR stalls (BLOCKED > 4h)
- Auto-fixed CI events (lint / flake reruns) — count of saved operator interventions
- Manual rescue events
- Suggested next operator action

## When NOT to use this

- For pure health pass/fail (use `/fleet-doctor` — exit code is the answer)
- For "is feature X shipped?" lookups (use `/verify-existence`)
- For alert response (use `/operator-recall --check-only` first)

## Related capability

The SessionStart hook (FLEET-019) already invokes `fleet-brief.sh` at session start, so the briefing shows up in your session prompt automatically. This skill exists for **on-demand re-runs** — when you want a fresh read mid-session.
