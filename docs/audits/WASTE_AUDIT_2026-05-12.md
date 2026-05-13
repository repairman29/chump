# Waste Audit — 2026-05-12

> META-055 deliverable. Numbers computed against `.chump-locks/ambient.jsonl`
> using the WASTE_KINDS extensions from [INFRA-950](https://github.com/repairman29/chump/pull/1632) and the
> `default_tokens_per_kind` table from [INFRA-951](https://github.com/repairman29/chump/pull/1634).
> All token estimates are conservative lower-bounds.

## TL;DR

Over the last **7 days**, the 6 newly-classified waste kinds account for
**~352k tokens (~$1.06)** at the unknown-tier price. That's small in
absolute terms but it's also lower-bound — token counts here are heuristic
defaults, not measured. The point of this audit is **distribution**, not
the dollar figure: **71.5% of countable token waste comes from one kind.**

## Numbers

### 24h window (rolling)

| Kind | Events | Tokens | % of token total |
|---|---|---|---|
| missing_attribution | 58 | 0 | 0.0% |
| bot_merge_hot_file | 1 | 3 000 | 37.5% |
| pr_stuck_cluster | 1 | 5 000 | 62.5% |
| **Total** | **60** | **8 000** | — |

### 7d window

| Kind | Events | Tokens | % of token total |
|---|---|---|---|
| **bot_merge_hot_file** | **84** | **252 000** | **71.5%** |
| bot_merge_hang | 4 | 60 000 | 17.0% |
| slo_breach | 3 | 27 000 | 7.7% |
| fleet_auth_fallback | 42 | 8 400 | 2.4% |
| pr_stuck_cluster | 1 | 5 000 | 1.4% |
| missing_attribution | 106 | 0 | 0.0% |
| **Total** | **240** | **352 400** | — |

## Findings

### 1. `bot_merge_hot_file` is the dominant token bleeder (71.5%)

84 events in 7d. Each event represents a PR touching a "hot file" that
other open PRs also touch, forcing a rebase round. Each rebase round
typically costs the agent ~3k tokens to re-evaluate conflict resolution.
Hot files seen today: `AGENTS.md`, `.github/workflows/*`, `scripts/coord/*`.

**Root cause hypothesis:** the fleet runs 4+ workers in parallel, picking
gaps independently. Many gaps need to touch the same shared
documentation/config files, leading to predictable collisions. The current
mitigation (bot-merge auto-rebase) works but charges 3k tokens per round.

**Fix candidates:**
- Hot-file lock: serialize PRs that touch declared hot files.
- Better merge driver for the most-collided files (especially AGENTS.md).
- Detect-and-batch: if N gaps each need to add a line to file X, file
  a single "batch hot-file update" gap.

### 2. `bot_merge_hang` — 4 events / 60k tokens (17.0%)

Personally witnessed today: the COG-054 ship spent ~15 min wedged on a
post-clippy phase, twice. Each hang means a `claude -p` invocation has
loaded the full system prompt + tools but produced no output before
timing out. The input tokens are paid for and produce nothing.

**Root cause hypothesis:** cargo build wedges or network connection
resets (saw GitHub API connection reset today). bot-merge.sh's heartbeat
keeps the script alive but the inner subprocess is stuck.

**Fix candidates:**
- Tighter timeout on bot-merge inner phases (currently lenient).
- INFRA-845's wedge handler should kill these earlier — verify it does.
- Pre-fetch model warm-up so `claude -p` doesn't sit on first-token latency.

### 3. `slo_breach` — 3 events / 27k tokens (7.7%)

Curator audits emit `slo_breach` when `chump health --slo-check` returns
non-zero. Each one likely triggers downstream curator decisions worth
~9k input tokens for the audit run. Frequency is low but per-event cost
is high.

**Root cause hypothesis:** unclear without inspecting the SLO that
breached. Likely either pillar imbalance or stale-PR cluster.

**Fix candidates:**
- Quote which SLO breached in the event payload (currently just `severity`).
- Suppress duplicate emissions when the same SLO is in continuous breach.

### Honourable mention: `missing_attribution` (106 events, 0 tokens)

Half of all waste events in 7d are `missing_attribution` — sessions
spawned without `CHUMP_AGENT_HARNESS` set, so telemetry can't classify
them. Zero direct token cost but a measurement blind spot. Filed as a
separate hygiene gap rather than a top-3 fix.

## Follow-up gaps filed

| Token rank | Gap | Title |
|---|---|---|
| 1 (71.5%) | — | (filed below) bot_merge_hot_file: hot-file collision dampening |
| 2 (17.0%) | — | (filed below) bot_merge_hang: tighter timeouts + verify INFRA-845 kill path |
| 3 (7.7%)  | — | (filed below) slo_breach: name the breached SLO + dedupe |
| (hygiene) | — | (filed below) missing_attribution: ensure CHUMP_AGENT_HARNESS at spawn |

## Caveats

- Token numbers above are **defaults** (`default_tokens_per_kind`), not
  measured. INFRA-951 is the first cut at attribution; refining these
  numbers with real session_end correlation is a future gap.
- The ambient log rolls; 7d is the maximum visible window today.
- `chump waste-tally --since 7d` returns 0 due to an internal bug;
  numbers here come from a direct Python query against `ambient.jsonl`
  (will file a follow-up to fix the CLI parser).
