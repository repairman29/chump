# State of the Union — 2026-05-08

Operator-facing meta-review at end of a high-throughput cycle. Honest read of
where the fleet stands, what it can do unattended, what still needs human
eyes, and what's next.

---

## TL;DR

In one cycle (≈ 14 hours) the fleet went from **wedged, hand-held, no cost
visibility** to **self-running with multi-layer auto-heal, cost-measurement
infrastructure landing, mission balance enforced at the picker level, and
operator-paging channel ready**.

- **Ships landed**: ~50 PRs
- **Pillar mix**: 22 RESILIENT, 8 ZERO-WASTE, 7 CREDIBLE, 6 EFFECTIVE/MISSION,
  ~5 PRODUCT
- **Open queue**: ~5 PRs in flight (mostly downstream of just-merged work)
- **Manual rescues required**: 2 substantive (PR #1328 merge conflict, PR
  #1339 test bug). Both resolved by Opus this session.
- **Recurring failure modes that are now structurally impossible**:
  stdin-wedge, speculative dupe-shipping, SWARM-/PRIVATE- leak path, ghost
  status, lock-zombie buildup (with PID-alive check), clippy lint storm
  flooding, Cargo.toml movement starving cascade-rebase
- **What still needs human eye**: model-class refactors (INFRA-687 split,
  INFRA-688 src reorg), drift-audit calls (INFRA-736 opus/deepseek rate
  correction), credit-spend decisions (Together / DeepSeek pilot)

---

## Where we started (morning of 2026-05-08)

- Fleet had been silent for ~10h overnight after shipping 2 PRs at ~02:23.
- Workers' `claude -p` invocations were producing 0-byte cycle logs — looked
  wedged, was actually `claude -p` waiting on stdin in subshell context.
- Speculative-execution race mode was hardcoded `True` in
  `_pick_and_claim_gap.py`, producing dupe-shipping (CREDIBLE-003 #1286 and
  #1288 from same agent, two cycles racing).
- Manual cleanup was the recovery path for: 38 zombie bot-merge processes
  (1–4 days old), `.gap-*.lock` zombies, INFRA-664 ghost-status orphan,
  syspolicyd binary wedge.
- Cost data: estimated, not measured. Flat $3-in/$15-out Sonnet rate hardcoded
  for ALL backends (overstated 3-∞× for non-Sonnet usage).

## What landed today (selected; full list in git log)

### Auto-heal infrastructure (RESILIENT)

- **INFRA-674** ghost-status reaper (closes gaps whose PR merged but state
  didn't update)
- **INFRA-675** syspolicyd auto-doctor heartbeat (binary wedge self-heals
  every 30 min)
- **INFRA-676 + INFRA-732** stale `.gap-*.lock` reaper, with PID-alive check
  (cleans zombies the launchd job would otherwise miss)
- **INFRA-678** make `chump gap ship` failure fatal in `bot-merge.sh` (no
  more INFRA-664-style ghosts)
- **INFRA-669** auto-rerun on class=flake CI failures (no more manual
  `gh run rerun --failed` cycles)
- **INFRA-670 + INFRA-711** post-merge cascade rebase, extended to src/
  paths (open PRs auto-rebase when main moves on workspace-wide files)
- **INFRA-621** fleet auth-check at launch (refuses to start if OAUTH /
  API_KEY misconfigured)
- **INFRA-663** auto-restart fleet on critical worker.sh changes
- **FLEET-042** per-worker heartbeat
- **FLEET-043** exponential backoff + circuit breaker for fleet workers
- **INFRA-682** CI path-filter coverage detector

### Mission/operator-experience (EFFECTIVE / MISSION)

- **INFRA-721** `chump fleet brief` on SessionStart — operator gets 60-sec
  briefing (ships/pillars/stalls/auto-fixes/suggestions) at session open
- **INFRA-720** pillar-aware picker bias — fleet self-balances 4 pillars
  in a 4h rolling window
- **INFRA-471** model-class-aware fleet routing — Sonnet for `m`/`l`,
  haiku for `xs`/`s`
- **INFRA-665** wire operator-recall to actual paging channel (Discord)
- **PRODUCT-028/029/030/031/037/039/040/044** PWA polish, end-user docs,
  Discord bot UX, briefing prettifier

### Cost measurement (CREDIBLE / ZERO-WASTE)

- **INFRA-714** `--output-format stream-json --verbose` wired so token
  parser actually consumes structured events
- **INFRA-731** `docs/pricing/model_rates.yaml` + LiteLLM-upstream weekly
  drift detector (alerts on > 5% rate shifts; refuses cost computation
  when rates >30 days stale)
- **INFRA-730** per-model rate lookup (in flight #1334)
- **INFRA-729** `chump kpi report --tokens-per-ship` (in flight #1336)
- **INFRA-736** filed: audit drifted opus-4.7 + deepseek-v3 rates the
  refresh script flagged on first run

### Privacy / scope (RESILIENT)

- **INFRA-710** picker excludes `SWARM-/PRIVATE-/INTERNAL-` prefixes
  (defense in depth alongside agent-side refusal in INFRA-718)
- **INFRA-718** dispatch prompt scope guardrails — agents refuse out-of-
  scope edits at the prompt layer

### Structural fixes (RESILIENT)

- Stdin wedge (`< /dev/null` on `claude -p`) — cycle logs no longer 0-byte
- **INFRA-713** speculative is opt-in (`CHUMP_SPECULATIVE=1` env), not
  default-on; race mode preserved for local testing but never auto-engaged
- **INFRA-734** stream-json regression patched (required `--verbose`)
- Clippy lint storm waves 1-4 relaxed at workspace level
  (INFRA-664/668/712/715) — `manual_strip`, `manual_split_once`,
  `lines_filter_map_ok`, `manual_is_multiple_of`, `doc_overindented_list`,
  `never_loop`, `manual_clamp`, `field_reassign_with_default`,
  `manual_range_contains`, `collapsible_match`,
  `manual_pattern_char_comparison`, `redundant_closure`
- **INFRA-666** workers run `cargo clippy --workspace --fix` BEFORE
  `bot-merge.sh` (catches lints before CI does)

---

## Current capabilities (what runs without you and Opus)

### Layer 1 — Scripts (no LLM, $0/day)

These are running on launchd / cron / git hooks right now:

| Daemon | Purpose | Cadence |
|---|---|---|
| `dev.chump.stale-gap-lock-reaper` | Zombie lock cleanup with PID check | every 5 min |
| `dev.chump.stale-pr-reaper` | Auto-close PRs whose gaps shipped | hourly |
| `dev.chump.stale-branch-reaper` | Delete merged remote branches | per `stale-branch-reaper.sh` schedule |
| `dev.chump.stale-worktree-reaper` | Remove orphan worktrees | hourly |
| `dev.chump.reaper-watchdog` | Heartbeat-grade the other reapers | every 30 min |
| `dev.chump.stuck-pr-filer` | File cleanup gaps for stuck PRs | hourly |
| `dev.chump.pr-watch-shepherd` | Watch armed PRs, auto-rebase DIRTY | continuous |
| `dev.chump.ci-flake-rerun` | Re-trigger flake-class CI | per cadence |
| `dev.chump.ambient-rotate` | Rotate `ambient.jsonl` daily | 03:00 |
| `dev.chump.overnight-research` | Eval/A-B sweeps | 02:00 |
| `dev.chump.soak-checkpoint` | Long-running soak metrics | per cadence |
| `pr-triage-bot` (workflow) | Auto-fix lint, file gap on real failures | per CI completion |
| `post-merge-cascade-rebase` (workflow) | Rebase open PRs on workspace-file landings | per push to main |

### Layer 2 — Sonnet operator-agent (filed, not yet shipped)

**INFRA-737 (P0)**: cron-driven Sonnet review loop. Bounded tools (gap reserve/set/ship, PR rebase, run rerun, dup close, paging Send). Refused tools (git push, gh pr create, edit CLAUDE.md, branch protection). Audit log (`kind=operator_agent_action`). Cost cap (`CHUMP_OPERATOR_AGENT_DAILY_USD`). Opus escalation cap (`CHUMP_OPERATOR_AGENT_OPUS_PER_DAY=3`). Until INFRA-737 lands, this layer is empty.

### Layer 3 — Opus (this session, on demand)

Reserved for: architectural design, cross-cutting decisions, "should we kill speculative?" judgment, model strategy, cost analysis, ambiguous policy. NOT on cron.

### Layer 4 — Operator (you)

Reserved for: branch-protection changes, paid-credit additions, mission pivots, INFRA-687-class refactors, signing off on Layer 2 → 3 escalation when daily caps trip.

---

## Pillar grade (honest)

- **Resilient**: A. The fleet shipped most of its babysitting eliminators
  to itself today. Failure modes that recurred 2-3 times this morning are
  now structurally impossible.
- **Effective**: B+. PWA polish landed; offline-first docs landed;
  end-user model-selection guide landed; operator briefing landed.
  Pillar bias enforcer (INFRA-720) means this stays balanced going
  forward instead of starving while RESILIENT runs hot.
- **Credible**: B-. Cost-measurement infra is in flight (INFRA-729/730/731
  shipping or shipped); pricing-drift detection caught two errors in my
  initial yaml; per-module test coverage gaps started landing
  (CREDIBLE-007/008/009). But the actual ship-quality grade per worker
  (CREDIBLE-002 / FLEET-044) is partial; we don't yet know which workers
  produce half-impls vs. clean ships.
- **Zero-Waste**: B. Cerebras pilot evaluated and parked (free tier RPM
  kills throughput). Groq evaluated, INFRA-733 filed for the chump-local
  tool-call adapter that would unlock free-tier shipping. Together kept
  disabled (paid risk caught in time). Per-model rates land within 24h
  → real $/ship measurements replace estimates.

---

## What still needs human / Opus eye

### Architecture-class

1. **INFRA-687/688** — split `src/main.rs` and reorganize `src/` into
   subdirectories. Marked too-big-for-fleet. Fleet correctly deferred
   INFRA-687 by decomposing into 5 phased subgaps; analogous needed
   for INFRA-688.
2. **INFRA-693** — extract `gap_store.rs` (4421 LOC) as standalone
   crate. Design note added to gap; needs Opus to define API surface
   before fleet picks it up.
3. **INFRA-733** — chump-local tool-call adapter for free-tier LLMs.
   Real engineering problem (Anthropic protocol vs OpenAI-compat
   function calling). Filed P1, awaits architecture pass.

### Strategy-class

1. **Together DeepSeek-V3 pilot** — operator decision: add $10 credit
   and run a 24h A/B vs. Sonnet on `s`/`m` mechanical work.
   Decision deferred until Groq-via-INFRA-733 results are in.
2. **Pricing drift audit** — INFRA-736 captured two errors in the
   initial `model_rates.yaml`: claude-opus-4.7 may actually be $5/$25
   not $15/$75; together-deepseek-v3 is $1.25/M not $0.85.
   Operator should verify against vendor docs before INFRA-731's
   weekly refresh runs in production.
3. **Operator-agent rollout** — INFRA-737 has full ACs. When it ships
   the question becomes: how aggressive should the Sonnet daily budget
   be? Default $1/day will likely cover 24h of routine work; if more
   aggressive, raise. Cap on Opus escalations per day (3 default) is
   the right safety knob.

### Open PR list (as of writing)

- **#1328** PRODUCT-044 PWA phase 3 — Opus resolved merge conflict,
  re-pushed, awaiting CI
- **#1339** CREDIBLE-009 test fixture — Opus fixed assertion bug, awaiting CI
- **#1334** INFRA-730 per-model lookup (rebased)
- **#1336** INFRA-729 kpi report --tokens-per-ship (depends on #1334)
- **#1327** FLEET-050 shipped-but-not-valuable outcome class (rebased)

When all five land, cost-measurement chain is end-to-end functional within 24h
of session_end token data flowing.

---

## Strategic posture

The system today inverted from **operator-driven, Opus-rescued** to
**self-driven, Opus-escalated**. The remaining manual work is:

- **Daily**: review the SessionStart fleet brief (INFRA-721 already
  surfaces it), demote inflated P0s, accept the picker-suggested
  pillar-rebalance gaps.
- **Weekly**: review `pricing_drift` ALERTs from INFRA-731's refresh,
  audit any `kind=operator_agent_action` patterns the audit log surfaces.
- **As-needed**: respond to Discord pings from INFRA-665 paging
  channel for genuinely-hard escalations.

When INFRA-737 (operator-agent) ships, even the daily cadence becomes
optional — operator becomes the policy-setter rather than the babysitter.

The 4-pillar mission is now MEASURABLE end-to-end:
- ship rate trends (24h/7d) via fleet brief
- pillar mix tracked in 4h rolling windows
- per-model cost via INFRA-729 (24h after stream-json data flows)
- ship quality via FLEET-050 outcome classifier
- waste via the existing `chump waste-tally` (now token-aware after INFRA-714)

---

## Open risk register

1. **No real cost data yet.** Estimates are within ~2× but not measured.
   Resolves when INFRA-729 + INFRA-730 land + 24h of session_end data.
2. **GitHub API rate limit (5K/hr personal)** is the visible bottleneck on
   high-monitor sessions like today. If operator-agent (INFRA-737) runs
   hourly + already-running shepherd queries, may need to switch to a
   GitHub App PAT (10K/hr).
3. **Pricing drifts uncaught** for 2 entries until refresh script catches
   them on first weekly run. INFRA-736 audit will fix; risk is one full
   week of incorrect cost reports if refresh doesn't fire.
4. **`scripts/discord.sh start` not yet invoked.** Bot daemon is not
   running. INFRA-665 paging path won't deliver until the daemon is up.
5. **Fleet ship rate tapered late in cycle** as the easy queue drained.
   Healthy sign (P0 backlog mostly cleared) but means next cycle's pillar
   distribution depends on what gets refilled.

---

## Closing

Today's leverage came from:

1. Identifying recurring failure modes (clippy storms, lock zombies,
   stdin wedges) and shipping permanent fixes instead of one-time rescues.
2. Building observation infrastructure (fleet brief, pricing freshness,
   pillar bias, ghost reaper) that makes the system honest about its own
   state.
3. Filing gaps with explicit ACs so the fleet shipped the structural fixes
   rather than Opus-as-monkey-patcher.

What you should expect: ship rate stays steady; manual interventions taper;
SessionStart brief surfaces what would otherwise need a "ping me check
status." The next Opus session should look meaningfully different —
strategy and architecture, not babysitting.

— Opus, end of cycle 2026-05-08
