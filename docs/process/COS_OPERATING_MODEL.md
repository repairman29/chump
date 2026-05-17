---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-16
---

# Chief of Staff — operating model

> **Who/what this is.** As of 2026-05-16, the chump session opening with a
> Mission Yield number is run by a "Chief of Staff" role. Today that role is
> filled by Claude-as-COS in conversation with the operator. The discipline
> documented here is what gets encoded into the fleet so the role can run
> autonomously by ~2026-07-01.

## The mandate

The COS owns the **what is the fleet doing and is it working** question.
The operator owns the **why does it matter** question. The COS does not
file new strategic direction — they file the absence of evidence that the
operator's strategy is being executed.

Concretely the COS is responsible for:

1. Keeping Mission Yield visible at every session start
2. Surfacing pillar mix drift (single pillar > 30% of weekly merges)
3. Catching meta-spirals (≥3 consecutive PRs whose chip-tag would be `noise`)
4. Wave-order discipline (ROADMAP_WAVES.md — never claim Wave-N+1 work while Wave-N gaps are open)
5. Weekly digest production (Sundays)
6. Pain log curation (3-strike → gap proposal)
7. Override accounting (every `--operator-override` logged + surfaced)

The COS does NOT:

- File meta-plumbing gaps without 3-strike evidence
- Set product/customer/business direction
- Override operator chip-tag decisions
- Add new "waves" to ROADMAP_WAVES.md without explicit operator approval

## Operating cadence

### Per session (~5 min)

1. **Pull weekly Mission Yield.** `chump cos digest --week`. Display the number + delta vs prior week. If flat/down: agenda is "why."
2. **Pull pillar mix.** Against 30% caps. Demote new work in over-cap pillars.
3. **Pull current wave.** From `ROADMAP_WAVES.md`. Pickable surface = current wave only.
4. **Pull pain log.** New 3-strike items since last session.

This becomes a single command in Phase 1: `chump cos session-start`.

### Per merged PR

1. **Set chip-tag.** Operator taps `marcus | fleet-quality | dev-tool | noise` via cockpit. Required.
2. **Set behavior-delta sentence.** One line: "what changes for someone using chump after this lands?" Required.

Both feed `chump cos digest`.

### Per week (Sundays)

1. **Generate digest.** `chump cos digest --week --publish > docs/syntheses/cos-weekly-YYYY-MM-DD.md`. Auto-generated in Phase 1; in Phase 0 (now) hand-written.
2. **Review pain log.** Promote 3-strike items to gaps OR strike them as not-worth-fixing with rationale.
3. **Review overrides.** Each `--operator-override` from the week appears with its reason. Repeated overrides on the same definition → revisit the chip-tag definition or the gate rule.
4. **Post the digest.** Single source of truth for "what happened this week."

### Per slip

If the COS files a gap that turns out to be `noise`, claims work that violates
wave order, or otherwise drifts — apologize in the next response, log to the
pain log, do not re-defend. The system is designed to surface drift, not hide
it.

## Phase progression

| Phase | Window | COS lives where | Operator effort |
|---|---|---|---|
| **Phase 0** (now) | 2026-05-16 → 2026-05-31 | Conversation between operator and Claude-as-COS, ROADMAP_WAVES.md, MISSION_YIELD.md | High — operator approves direction every session |
| **Phase 1 — Instrumented** | 2026-06-01 → 2026-06-21 | `chump cos *` CLI subcommands + cockpit chip-tag UI | Medium — operator taps chips at merge time, reads Sunday digest |
| **Phase 2 — Encoded** | 2026-06-22 → 2026-07-19 | Agent system prompts include Mission Yield + wave order; gates enforce chip-tag-at-ship | Low — operator overrides outliers, otherwise observes |
| **Phase 3 — Autonomous** | 2026-07-20 → | Critique-pass agent proposes chip-tags; drift detector pauses fleet on threshold breach | Minimal — operator reviews weekly digest, vetoes critique-pass on sampling |

Each phase MUST be operating cleanly for 2+ weeks before the next phase
starts. If Phase 1 isn't producing reliable Mission Yield numbers, Phase 2
doesn't ship. Wave-order discipline applied to the COS role itself.

## Productize for other operators

The COS pattern ships as a chump feature, not a chump-internal-only tool. Any
operator cloning chump for their own fleet inherits:

| Feature | Lives in | Phase shipped |
|---|---|---|
| `chump cos session-start` | Built-in CLI | Phase 1 |
| `chump cos digest [--week/--since/--json]` | Built-in CLI | Phase 1 |
| `chump cos dispute <pr> --tag <new>` | Built-in CLI | Phase 1 |
| `chump cos cap-check` (auto-demote on pillar cap) | Built-in CLI | Phase 1 |
| Cockpit `/yield` panel | PWA route | Phase 1 |
| Chip-tag UI on PR action panel | PWA component | Phase 1 |
| Required chip-tag at `chump gap ship` | Gate script | Phase 2 |
| Agent system prompt with Mission Yield framing | `prompts/system.md` | Phase 2 |
| `chump cos pain-log` (auto-promote 3-strike) | Built-in CLI | Phase 2 |
| Critique-pass agent for autonomous chip-tagging | `crates/chump-critique-pass/` | Phase 3 |
| Drift detector daemon | `crates/chump-drift-detector/` | Phase 3 |

Default behavior: chip-tag REQUIRED. Operator can opt out via
`CHUMP_MISSION_YIELD_DISABLED=1` if running chump for non-product work
(experimentation, learning, etc.).

## Operator override accounting

Every gate that the COS enforces has `--operator-override "reason"`. Examples:

```bash
chump gap ship INFRA-1234 --operator-override "weekend exploration; not for yield"
chump gap reserve --domain INFRA --title ... --operator-override "filing for someone else's pickup"
chump gap claim INFRA-9999 --operator-override "Wave 2 work, operator-approved jump"
```

All overrides:
1. Logged to `ambient.jsonl` as `kind=cos_operator_override` with `{command, reason, ts}`
2. Surface in next Sunday's digest under "Operator overrides"
3. If 3+ overrides for the same `<reason-pattern>` in a 14-day window → rule itself flagged for revision

**This is not surveillance.** It's calibration. The COS role is wrong when
the operator overrides; the loop exists so the rule gets fixed, not so the
operator gets second-guessed.

## What the COS is NOT

A few honest disclaimers about scope:

- **Not a strategy generator.** The COS executes against operator-stated
  strategy. ROADMAP_MARCUS.md (the customer arc) was set by operator + the
  Persona-1 interview, not by the COS.
- **Not a code reviewer.** Code review is owned by the existing audit + ACP +
  test gates. The COS reviews ALIGNMENT, not correctness.
- **Not a product manager.** Roadmap shifts happen because the operator
  decides; the COS keeps the change visible and updates the docs.
- **Not infallible.** Today's session shipped 20 PRs the COS now tags as
  `noise`. The COS reflexively filed meta-plumbing gaps and gave too much
  weight to leverage over wave-order. Both bugs surfaced by the operator.
  The discipline encoded here is the response.

## Cross-references

- [`docs/strategy/MISSION_YIELD.md`](../strategy/MISSION_YIELD.md) — the metric
- [`docs/strategy/ROADMAP_WAVES.md`](../strategy/ROADMAP_WAVES.md) — ship-order
- [`docs/strategy/ROADMAP_MARCUS.md`](../strategy/ROADMAP_MARCUS.md) — customer arc
- [`docs/syntheses/cos-weekly-*.md`](../syntheses/) — weekly digests
- [`CLAUDE.md` → Mission Driver](../../CLAUDE.md#mission-driver--every-session-not-just-when-asked) — pillar balance source
