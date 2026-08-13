---
doc_tag: canonical
owner_gap: RESILIENT-312
parent: RESILIENT-310
outcome: FLEET-RADIO
last_audited: 2026-08-13
---

# The Discord Operator Console — you ↔ the fleet, from your phone

**Scaffold, not a pile.** Today the Discord DM capability is ~23 gaps scattered across 5
domains and two code layers with no owner and no single definition. This is the unifying
spec: what the operator console **is**, the surfaces it needs, their grounded current
state, and the done-bar. It is the operator-IO arm of the **Observe + Escalate** links in
[CHUMPOS_OPERATIONAL_PLAN.md](CHUMPOS_OPERATIONAL_PLAN.md) — a child of RESILIENT-310, not
a competing effort. Outcome: **FLEET-RADIO** (ChumpOS speaks; the operator hears the
fleet without opening a screen). Gaps implement this; ATC executes.

## What it is
**One Discord DM where the operator runs the entire fleet from a phone** — asks and gets
grounded answers, is briefed in one curated voice (never spam), taps to approve, is paged
only when truly stuck, and can issue an order the fleet then executes. One operator (Jeff),
one transport, one setup.

## The surfaces (grounded state 2026-08-13)

| # | Surface | What it is | State | Owns it |
|---|---------|-----------|-------|---------|
| 1 | **Converse** | DM a question → a grounded, almanac-backed answer | 🔴 **BROKEN** — the real Advisor errors on invoke (INFRA-3602); only a Groq fast-reply band-aid works (this session). INFRA-3597 marked done but false. | INFRA-3602, INFRA-3597 |
| 2 | **Briefed** | one curated "the ONE thing that matters" — never a firehose | 🟡 PARTIAL — curated briefing + CEO-briefing exist (INFRA-3601/3590 done; firehose killed); the deterministic board-cycle daemon is open | RESILIENT-304 |
| 3 | **Approve** | tap ✅/❌ to merge a PR or authorize an action | 🟢 **BUILT** — approval-before-close + pr-approval timer + buttons; olive#19 tap verified this session | RESILIENT-265 |
| 4 | **Escalated-to** | the fleet pages the operator ONLY when truly stuck | 🔴 **MISSING** — the fleet drops hard work silently instead of paging (INFRA-3605 sat 22h) | RESILIENT-309 |
| 5 | **Operate** | issue an order in DM → the fleet files + works it | 🔴 **OPEN** — operate-the-whole-thing-from-Discord is unbuilt; this is the headline gap | INFRA-3589 |
| 6 | **Setup** | one clean onboarding, not hidden gates | 🟡 PARTIAL — the gateway has FOUR independent opt-in gates, each invisible until it fails | DOC-094 |
| — | **Transport** | ONE canonical path, not two | 🟡 UNDECIDED — a Rust in-binary integration AND a separate Python gateway both exist; default transport never decided | RESILIENT-270 |

**Verdict:** the console is **half-built and unowned.** Approve works; briefing mostly
works; **Converse is broken, Escalate and Operate are missing, and there are two competing
transports.** No single artifact defined the experience — until this one.

## The two-layer problem (decide first)
There is a Rust in-binary Discord layer (`src/discord*.rs`, `crates/chump-messaging`) and a
Python receive gateway (`scripts/ops/discord-gateway.py`). They overlap. **RESILIENT-270
must pick the canonical transport** before surfaces are hardened onto the wrong one — this
is the ordering constraint for everything below.

## Critical path (order to close)
1. **Decide the transport** (RESILIENT-270) — canonical path; retire or clearly subordinate the other.
2. **Fix Converse** (INFRA-3602) — the Advisor must actually answer, grounded in almanac; retire the false-done.
3. **Wire Escalate** (RESILIENT-309) — the fleet pages here when stuck (the console's whole point of trust).
4. **Build Operate** (INFRA-3589) — order-from-DM → gap filed + worked → result reported back.
5. **One-command Setup** (DOC-094) — collapse the four hidden gates into one legible onboarding.
6. **Board-cycle daemon** (RESILIENT-304) — the deterministic curated briefing on a timer.

## Done-bar (proof, on a fresh deploy)
From one Discord DM on a phone, the operator can, unattended and reliably:
- **ask** a question and get a grounded answer in <10s;
- **receive** exactly one curated briefing a day, plus a page **only** when the fleet is truly stuck;
- **tap** to approve a product PR and see it merge, with fresh confirmation;
- **order** a change in plain language and watch the fleet file + work + report it;
- all over **one** transport, reachable after **one** setup step.

When those five pass sustained and unattended, the operator console is real.

## Pass to ATC — the gaps
| Gap | Surface | Job |
|-----|---------|-----|
| **RESILIENT-312** | epic | Deliver the operator console per this doc (child of RESILIENT-310) |
| RESILIENT-270 | transport | Decide + enforce the canonical DM transport |
| INFRA-3602 | converse | Fix the false-done Advisor; grounded almanac answers |
| RESILIENT-309 | escalate | Fleet pages the operator when stuck (escalate-don't-drop) |
| INFRA-3589 | operate | Operate the fleet from a Discord DM |
| DOC-094 | setup | Collapse the four opt-in gates into one onboarding |
| RESILIENT-304 | briefed | Deterministic board-cycle briefing daemon |

The board owns this scaffold; the fleet owns the gaps. Re-audited each board cycle.
