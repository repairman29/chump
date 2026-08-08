---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
---

# The Factory Vision — what ChumpOS is for

**This is the anchor.** One statement of purpose, the outcomes that carry it, and
pointers to the audits that say how far along it is. It is deliberately **not a
roadmap** — there are already 17 of those plus `MASTER_PLAN.md`, and an 18th
would be the opposite of consolidating. Everything else points here.

## The vision

> **An autonomous software factory where anyone with an idea or a dream — no
> matter what state that idea is in — can get ChumpOS on board, helping them
> succeed.**
>
> — the operator, 2026-08-07

The load-bearing phrase is **"no matter what state that idea is in."** A dream, a
paragraph, a broken repo, a spreadsheet, a half-built product someone abandoned
two years ago. The factory meets the idea where it is. That is the whole
distinction between this and "an agent that writes code when handed a well-formed
ticket" — the well-formed ticket is the part most people cannot produce, and
requiring it is how software has always excluded them.

## This is not a new direction

It is the fleet's own **COTG** outcome, stated plainly:

> *ChumpOS Outta The Gate — a non-technical person with a vision gets a finished,
> honest, in-their-hands tool, zero-touch.* (62 gaps)

with **CHUMPOS** as its engine (*"an agentic OS that turns problems into shipped
tools, hands-off"*, 56 gaps). Nothing here asks the fleet to change course. It
gives the course a single place to be read from.

## Where the gap is — and it is not the code

Every open factory-chair gap is already bound to one of those two outcomes:

| Gap | Chair | Outcome |
|---|---|---|
| EFFECTIVE-357 | L1 intake — business conversation → requirements | COTG |
| EFFECTIVE-358 | L3 design — UI / brand / interaction | COTG |
| EFFECTIVE-364 | publication stage after ship | COTG |
| EFFECTIVE-365 | publisher co-pilot (`PUBLISHER.md`, workspace root) | COTG |
| EFFECTIVE-356 | L7 growth — release notes, telling people | CHUMPOS |
| EFFECTIVE-363 | `artifact_type` + per-type quality gates | CHUMPOS |

**Read the Outcome column.** Four of the six missing chairs are COTG chairs, and
they sit at the two ends: **intake** and **publication**. The factory floor
itself — L4 engineering, L5 quality, L6 ops, L8 improvement — is ✅.

So what is missing is precisely the **"anyone with an idea"** half and the
**"in their hands"** half. The vision and the gap list already agreed with each
other; nobody had put them side by side. That is the single most useful thing
this document does.

## The audits that measure it

Both `done`, both 2026-08-05, both `canonical` — read these before proposing new
factory work:

- **[SOFTWARE_FACTORY_MATRIX_2026-08-05.md](strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md)**
  (DOC-079) — the 8-layer audit, L0–L8, status plus receipt per layer. Verdict on
  "autonomous software company": **❌ overall, missing L1 / L3 / L7.**
- **[ARTIFACT_ORGANIZATION_2026-08-05.md](strategy/ARTIFACT_ORGANIZATION_2026-08-05.md)**
  (DOC-083) — the second thesis: *if the mission is turning ideas into successful
  software, code is only 25–35% of the work.* Surveys 13 departments and finds 12
  of 13 already exist somewhere in the fleet as dormant claimed capability. Only
  **Publishing** is genuinely empty — and `PUBLISHER.md` (2026-07-19, at the
  `~/Projects` workspace root rather than in this repo) is already a complete
  design for that one chair.

## How to read the strategy corpus

`docs/strategy/` holds **70 documents**. As of 2026-08-08 every one carries a
`doc_tag`, and the tag is the only thing you need to know how to read it:

| `doc_tag` | Means | Count |
|---|---|---|
| `canonical` | Currently true, owned, audited. Trust it. | 15 |
| `log` | A record of what we thought **then**. Explicitly **not** current. | 48 |
| `decision-record` | A decision that was made and still binds. Not a plan. | 4 |
| *(other)* | `strategy-rubric`, `strategy-roadmap`, `coordination` | 3 |

**`log` is the important bucket, and it is the largest by far.** Most of it is
aspiration documents from May and June 2026 — genuine thinking at the time,
superseded since. Before 2026-08-08 an untagged 2026-05 aspiration and a live
2026-08 audit looked *identical* to a reader and to a search. Forty-three
documents (61%) carried no frontmatter at all. Saying "this was what we thought
then" out loud is the highest-value act in this whole exercise, and it is now
said in the file itself rather than in someone's memory.

Classification receipts: `canonical` and `decision-record` docs were read
individually and stamped `last_audited: 2026-08-08`. `log` docs keep their real
last-touch date, because for a log document an old date is **correct** — it
records when the doc was last true, not when someone glanced at it.

## The honest caveat — this is legibility, not steering

Consolidating the paper trail **does not change what the fleet works on next.**

The scheduler reads none of it. Outcomes contribute nothing to gap picking, and
`roadmap_alignment` — the largest single constant in the scorer at 100.0 — can
never fire, because `roadmap_refs` is `None` on every production run
(**CREDIBLE-224**, with code citations).

So this document makes the vision **legible and maintained**. It does not make it
**operative**. CREDIBLE-224 is what turns a plan into direction, and it should
land alongside this work — otherwise the consolidated trail is one more
beautifully maintained document that the factory floor never reads.

Stating that plainly is the point. A vision doc that implied it was steering the
fleet would be exactly the kind of thing this corpus already has too many of.
