# Cockpit Action Model — proposal queue, not dashboard

**Status:** doctrine v1 (PRODUCT-120)
**Audience:** anyone reviewing or filing a PWA cockpit gap
**Date:** 2026-05-15

---

## The principle

The cockpit is a **proposal queue**, not a dashboard.

| Dashboard | Proposal queue |
|---|---|
| Shows you what's happening | Proposes what to do about it |
| Operator does synthesis | Machine does synthesis |
| Operator does action lookup | Machine does action lookup |
| Buttons say "see more" / "view details" | Buttons say "Wake fleet" / "Release leases" / "Dispatch gap" |
| Operator's cognitive load is high | Operator's cognitive load is one decision |
| Empty states say "no data" | Empty states **are the action button** |

**The shift in one sentence:** *Computer does pattern extraction. Human does interpretation. Then the computer proposes the action, the human approves.*

---

## Why this matters

The operator's attention is the bottleneck. Every second spent parsing data instead of deciding is wasted capacity. Dashboards optimize for *information density*; proposal queues optimize for *time-to-action*.

The honest stress test: **does the operator reach for this surface instead of the CLI?**

- If the surface tells them "8 PRs merged today" → they still have to decide what that means → they reach for the CLI to investigate → **product fails**
- If the surface tells them "Phase 1 cockpit is 60% shipped; your reaction 3 min ago is reshaping the center zone" and offers a button → they approve, the fleet acts, no CLI needed → **product wins**

---

## Rules every PWA cockpit gap must follow

When reviewing or filing a cockpit gap, check each rule. Failure on any single rule should block the gap or force a redesign before picking.

### Rule 1 — Every signal card has a direct-action button

Not "see more." Not "open details." Not "view in another tab."

A **direct action** mutates state, dispatches work, or unblocks the operator. Examples:

- `[Wake fleet]` → POST /api/autopilot/start (real state mutation)
- `[Release expired leases]` → POST /api/lease/release-expired (real cleanup)
- `[Dispatch INFRA-1335]` → POST /api/gap/work/INFRA-1335 (real worker spawn)
- `[Repair drift]` → POST /api/gap/dep-clean (real reconciliation)
- `[Draft outreach]` → clipboard the outreach template (writes operator's clipboard)

Counter-examples that **fail** this rule:

- `[See ships]` — navigation, not action
- `[Check fleet]` — scroll, not action  
- `[Show events]` — drill-down, not action
- `[See PRODUCT-119]` — link, not action

**Exception:** evidence drill-down via `[show events]` *is* allowed under the **Noise** layer (collapsed by default). It's the bias-mitigation escape hatch — operator must always be able to verify the synthesis. But it's never the *primary* action.

### Rule 2 — Every empty state IS an action button

If the cockpit's state is "no workers running," the empty state is not text saying "dispatch a gap to start." The empty state **is the dispatch button**.

| Empty state | Wrong | Right |
|---|---|---|
| No workers | "Dispatch a gap to start" | **`[Dispatch top P1 gap]`** button |
| No ships in 24h | "Quiet day" | **`[Wake fleet]`** button |
| No drift | (nothing) | (nothing — no action needed, hide the card) |

The principle: if there's nothing to do, the card should not render. If there's something to do, the card is the button.

### Rule 3 — Synthesis must be inspectable

Every "intelligent" surface (a Read sentence, an anomaly card, a counter-evidence card) must:

- Be derived from data via a published formula — **not LLM-generated prose**
- Have a confidence indicator (high/medium/low) on the Read
- Have an evidence link that opens the raw events feeding the synthesis
- Be operator-overridable via a 🚩 button → emits `FEEDBACK kind=preference vote=-1`

The bias is real. We can't eliminate it. We can make it visible.

### Rule 4 — Counter-evidence is mandatory

Every cockpit synthesis must include a card that **contradicts** the dominant read. If the fleet is shipping well, surface the counter-evidence: maybe 0 external dogfooders, maybe pillar imbalance, maybe cost trending up.

If the synthesis can't find counter-evidence, it must say so explicitly: "Counter-evidence: none surfaced in the last 24h." Never silently drop it.

This stops the cockpit from becoming an echo chamber. Operator should never see "everything is great" without also seeing "and here's what isn't."

### Rule 5 — Action confirmation must be in-place + recoverable

After click:
- Button text changes to verb-progressive ("Starting…", "Dispatching…", "Repairing…")
- Button disables while in flight
- On success → "✓ <result>" (e.g., "✓ Autopilot starting", "✓ Released 3/19 leases")
- On failure → "✗ <reason>"; re-enables after 4-5s so operator can retry
- After 1.5-2.5s of success → re-synthesize the cockpit so the read reflects new state

Operator is never stuck wondering "did that work?" Every action has a visible outcome.

### Rule 6 — Three first-thing questions, no more

The cockpit's left/center/right zones answer exactly three operator questions:

1. **What needs me?** (left — operator-attention)
2. **What did the fleet do?** (center — read/signal/noise synthesis)
3. **What's running?** (right — fleet roster + ambient drill)

If a new gap proposes a fourth zone or a different question, **it doesn't belong on the cockpit**. File it as a sub-view reachable from one of the three.

### Rule 7 — Surveillance dedup at the source

If a card surfaces N copies of the same alert, the picker/emitter is broken, not the cockpit. Fix the source.

But while the source bug exists, the cockpit must dedup within-kind: identical alerts collapse to one bucket with a `N×` count. Per-row Defer/Dismiss applies to the whole bucket. Group-level actions like `[Defer all]` / `[Repair]` are first-class.

---

## How to apply these rules to a new cockpit gap

```
For each card / empty state in the proposed gap:

  □ Does it have a direct-action button (Rule 1)?
    □ If empty state: IS it the button (Rule 2)?
  □ Is the synthesis inspectable (Rule 3)?
    □ Templated, not LLM?
    □ Confidence indicator?
    □ Evidence drill-down?
    □ 🚩 override?
  □ Is counter-evidence rendered explicitly (Rule 4)?
  □ Does the action have in-place + recoverable feedback (Rule 5)?
  □ Does it answer one of the three first-thing questions (Rule 6)?
  □ Does it dedup within-kind (Rule 7)?

If any □ is unchecked, redesign before picking.
```

This checklist is part of the AC for every cockpit gap going forward.

---

## What this doctrine replaces

Before PRODUCT-120, the implicit cockpit principle was:
> *Surface useful information so the operator can decide.*

After PRODUCT-120, the principle is:
> *Propose useful actions so the operator can approve.*

The first sentence sounds reasonable. It's not — it offloads work onto the human. The second sentence loads work onto the machine, which is what we built the machine for.

Information density without action is dashboarding. Dashboarding is the easy thing to ship and the wrong thing to ship.

---

## Related docs

- [`COCKPIT_SYNTHESIS.md`](COCKPIT_SYNTHESIS.md) — the synthesis algorithm (what the Read/Signal/Noise framework actually computes)
- [`PWA_ROADMAP.md`](PWA_ROADMAP.md) — phased UX spec; this doctrine governs Phase 1+ work
- PRs that demonstrate the model: #2024 (roadmap), #2030 (shell), #2063 (action-first cards + new endpoints), #2066 (dedup)
