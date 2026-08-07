---
name: almanac-mastery
description: >-
  The orchestrator's fleet-memory discipline: answer ANY question about code that
  exists across the ~95-repo fleet — "have we built X", "which repo does Y",
  "what's the exact signature", "what breaks if I touch this", "how is repo Z
  shaped" — by asking Almanac FIRST (grounded index, repo:path:line receipts on
  every hit) instead of grep/agent fan-outs, and by trusting or distrusting what
  comes back correctly (staleness, fallback notes, known blind spots). Includes
  the voice contract for spoken (Siri) turns: verdict aloud, receipts to the log,
  never speak a file:line. Use on every fleet-code question, before any
  cross-repo grep, before writing code that calls a fleet API, and for all
  voice-mode fleet answers.
---

# /almanac-mastery — Claude Code adapter

Per [`.claude/README.md`](../../README.md): this file is a thin adapter. The
capability is the Almanac CLI/MCP; the protocol is
[`docs/ALMANAC.md`](../../../docs/ALMANAC.md). **Read that doc now and follow
it** — tool selection by question shape, the seven trust rules, latency
shaping, and the voice contract all live there, not here.

## Routing

- MCP-wired sessions: use the `almanac` MCP tools (`almanac_search_fleet`,
  `almanac_search`, `almanac_api`, `almanac_impact`, `almanac_architecture`,
  `almanac_neighbors`, `almanac_status`).
- Otherwise shell out to the harness-neutral CLI:

```bash
~/Projects/almanac/target/release/almanac --help
```

`$ARGUMENTS`, if present, is the fleet question itself — answer it per the
protocol doc (Almanac first, receipts always, `almanac_status` before
load-bearing answers).
