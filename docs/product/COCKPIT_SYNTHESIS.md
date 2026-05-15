# Cockpit Synthesis Algorithm

**Status:** spec v1 (PRODUCT-120 — implemented in `web/v2/cockpit.js`)
**Audience:** anyone debugging cockpit cards, claiming false reads, or proposing new card types
**Date:** 2026-05-15

---

## Why this doc exists

The cockpit center zone shows a synthesized "read" + a few signal cards. This is the **intelligence layer** — pattern extraction the operator would otherwise do by hand.

**This synthesis is biased.** Every choice — which patterns count, which threshold triggers, what counter-evidence to surface — embeds an editorial position. You can't remove the bias. You *can* make it inspectable. This doc is the inspectability surface.

Read this when:

- A cockpit card surfaces something you think is wrong
- You want to file a new card-type gap and need to know where it slots
- You're auditing the synthesis for unintended bias
- You're explaining "why did the cockpit say X" to another operator

---

## Inputs

Three live API fetches, parallel, on every synthesize() pass (page load + 1.5-2.5s after every action button click):

| Endpoint | Returns | Used for |
|---|---|---|
| `GET /api/ambient/recent?limit=200` | Last 200 ambient events with `kind`, `ts`, optional `pr_number`, `subject`, `body` | Ship detection, anomaly detection, feedback detection, raw noise drill |
| `GET /api/gap-queue` | All gaps with `id`, `priority`, `status`, `effort`, `acceptance_criteria`, `closed_pr` | Next-decision card, drift detection, dispatch candidate |
| `GET /api/autopilot/status` | `{actual_state, desired_enabled, last_error, ...}` | Wake-fleet read variant selection |

If any fetch fails, that input is `[]` or `null` and the synthesis degrades gracefully — confidence drops, dependent cards omit, the Read says so.

---

## Output structure

```
{
  read: "<one sentence>",
  confidence: "high" | "medium" | "low",
  evidenceCount: <int>,
  cards: [
    { id, icon, title, detail, actions: [...], counter?: bool },
    ...
  ]
}
```

`read` is the headline. `cards` are the supporting narratives, fixed-order (not ranked — order isn't an editorial choice).

---

## The Read — selection ladder

The Read is a **priority ladder** of conditions. First match wins. Order documented here so a wrong Read can be traced to which branch fired.

```
1. If recentFb.length > 0 (last 10 min has ambient feedback):
   → "Your <subj> feedback (<ago>) is reshaping current work."
   → confidence = high

2. Elif ships24h.length > 0:
   → "<N> ship(s) in the last 24h. Most recent <ago>."
   → confidence = high if N >= 3, medium otherwise

3. Elif lastShip exists (any ship at any time):
   → "Fleet idle — no ships in 24h. Last ship was <ago>."
   → confidence = medium

4. Else:
   → "No recent activity in ambient. Either the fleet hasn't shipped yet,
      or ambient.jsonl isn't being read here."
   → confidence = low
```

**Why this ladder:** the most operator-relevant signal is whichever is freshest. Recent feedback > recent ships > "fleet idle" > "ambient blank." Edit this ladder by editing `#computeSynthesis` in `cockpit.js`.

**Confidence calibration:**

| Confidence | Condition |
|---|---|
| high | ≥3 ships in window AND ≥12h of data, OR active feedback present |
| medium | ≥1 ship OR fleet idle but ambient has data |
| low | Empty ambient stream |

The dot color in the Read UI (green/yellow/red) reflects this. Operator can disagree with the confidence label by clicking 🚩 on any card; future synthesis demotes the pattern.

---

## Signal cards — fixed order

Cards render in this fixed order. Order is **not** a ranking signal — it's a stable visual layout so the operator's eye learns where each story type lives.

### Card 1: Today's arc (PRODUCT-128)

**Variant A — Ships >0 in 24h:**
- icon: 📈
- title: "Today's arc — N ships"
- detail: "Most recent: #<pr1> + #<pr2>"
- actions: `[see ships]`

**Variant B — Ships=0 AND autopilot off:**
- icon: 📈
- title: "Today's arc — zero ships, autopilot off"
- detail: "Fleet is parked. Wake autopilot to start the dispatch loop."
- actions: **`[Wake fleet]`** (primary, POST /api/autopilot/start), `[see fleet panel]`

**Variant C — Ships=0 BUT autopilot on:**
- icon: 📈
- title: "Today's arc — zero ships (autopilot on)"
- detail: "Autopilot on but nothing's shipping. Picker may be wedged." + last_error
- actions: **`[Stop + restart]`** (primary, sequenced POSTs), `[see fleet panel]`

### Card 1b: No-workers + queue ready (PRODUCT-130)

Only renders when:
- `autopilotRunning === false`
- AND no worker events in `autopilot.recent_events`
- AND queue has a P0/P1 with non-empty AC, unclaimed

Renders:
- icon: 🚀
- title: "No workers running — top <P0|P1> ready to dispatch"
- detail: "<GAP-ID>: <truncated title>"
- actions: **`[Dispatch <GAP-ID>]`** (primary, POST /api/gap/work/<id>), `[see gap]`

### Card 1c: Gap-store drift (PRODUCT-127)

Only renders when ≥3 gaps in queue have `closed_pr` set AND `status='open'`.

Renders:
- icon: 🧹
- title: "Gap-store drift — N gaps shipped but state.db still 'open'"
- detail: "These gaps have closed_pr set but status=open. Picker may re-pick them."
- actions: **`[Repair drift]`** (primary, POST /api/gap/dep-clean), `[see gaps]`

### Card 2: Active reshape

Only renders if `recentFb.length > 0`:
- icon: 🔄
- title: "Active reshape — '<subj>'"
- detail: "Feedback emitted <ago>. Synthesis demoting this card if you 🚩 it."
- actions: `[see feedback]`

This card explicitly tells the operator the synthesis is feedback-responsive, which itself surfaces the bias-correction mechanism.

### Card 2b: Anomaly (PRODUCT-129)

Only renders when ≥3 events of an anomaly-kind detected in window. Anomaly kinds:

| Kind | Friendly label | Action button |
|---|---|---|
| `fleet_state_lock_timeout` | Lock contention spike | **`[Release expired leases]`** (POST /api/lease/release-expired) |
| `silent_agent` | Silent agent(s) | **`[Release expired leases]`** |
| `fleet_wedge` | Fleet wedge detected | `[show events]` |
| `pr_stuck` | PR stuck cluster | `[show events]` |
| `cache_drift` | Cache thrashing | `[show events]` |
| `slo_breach` | SLO breach | `[show events]` |

Threshold = 3 events. Below that, the anomaly card doesn't render (avoids alarm fatigue). Adjustable in the `topAnomaly[1] >= 3` line.

### Card 3: Counter-evidence (PRODUCT-131 + Rule 4)

**Always renders.** Even when ships > 0, autopilot is healthy, no anomalies. Required by Rule 4 of the Action Model.

Currently hard-coded:
- icon: 🟡
- title: "Counter-evidence — 0 external dogfooders"
- detail: "Phase 1 ships don't matter if no operator outside Jeff opens the cockpit. PRODUCT-119 is the recruitment gap; today it sits at P2."
- actions: **`[Draft outreach]`** (clipboard template), `[Bump P2→P1]` (CLI command clipboard), `[see gap]`

Future work: counter-evidence should rotate through a registry of anti-patterns based on which phase is currently active. PRODUCT-133 (right-zone treatment) plus a follow-up gap should generalize this.

### Card 4: Next decision

Only renders if a clear candidate exists (open P0/P1 with non-empty AC, unclaimed):
- icon: ⏭
- title: "Next decision — <GAP-ID> (<P0|P1>)"
- detail: truncated gap title
- actions: `[see gap]`, **`[pick it]`** (primary, POST /api/gap/work/<id>)

---

## Noise — collapsed by default

The bottom collapsed section. Click toggle → shows all 200 raw events feeding the synthesis. Always one click away from any card via `[show events]` or the Read's "show evidence ↓" link.

This is the **bias-mitigation escape hatch**. Operator can always verify the synthesis against raw data.

---

## Anti-patterns the synthesis explicitly avoids

These were considered and rejected. Reasons documented so future agents don't re-litigate.

| Anti-pattern | Why rejected |
|---|---|
| LLM-generate the Read sentence | Bias becomes invisible; operator can't predict or verify |
| Rank cards by importance | Importance is editorial; operator's eye should learn fixed layout instead |
| Hide counter-evidence on good days | Echo chamber; defeats the purpose |
| Auto-act without operator click | Removes the consent step; the cockpit is a *proposal* queue, not an *action* queue |
| Animate card transitions | Distracts from the read; operator's eye should land instantly |
| Show >5 cards at once | Cognitive overload; if synthesis would emit 6, the 6th is hiding noise |

---

## How to add a new card type

1. Decide which existing card it slots near (the fixed order is load-bearing — don't reorder).
2. Add the synthesis condition + card construction in `#computeSynthesis` in `cockpit.js`.
3. Add the action handler in `#onCardAction`. Use the verb-progressive → success/failure pattern documented in [`COCKPIT_ACTION_MODEL.md`](COCKPIT_ACTION_MODEL.md) Rule 5.
4. Update this doc's "Signal cards — fixed order" section with the new card's variant table.
5. File the gap referencing this doc + the action model.

---

## How to debug a wrong card

1. Open DevTools → Console.
2. Click the cockpit's Read → "show evidence ↓" — the Noise section opens with the 200 raw events.
3. Match the wrong card against `#computeSynthesis`'s logic in `cockpit.js`. Which `if` branch fired?
4. If the branch is wrong: file a gap to refine the condition.
5. If the branch is right but the input was wrong: file a gap on the data source (likely `/api/ambient/recent` or `/api/gap-queue`).
6. Either way: 🚩 the card so this session's feedback signal is captured for future re-rank.

---

## Related docs

- [`COCKPIT_ACTION_MODEL.md`](COCKPIT_ACTION_MODEL.md) — the rules every card must follow
- [`PWA_ROADMAP.md`](PWA_ROADMAP.md) — phased plan; this doc covers Phase 1 synthesis
- `web/v2/cockpit.js` — the implementation (`#computeSynthesis` method is canonical)
