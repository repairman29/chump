---
doc_tag: canonical
owner_gap: EFFECTIVE-827
last_audited: 2026-09-08
---

# The design-pass stage (factory L3 — EFFECTIVE-358 slice)

> **What this is.** EFFECTIVE-358 named L3 (design: UI/brand/interaction) as the
> last of the three missing factory chairs — deliberately last, since it only
> matters once external user-facing tools flow through the front door
> (`docs/strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md` §3). EFFECTIVE-357
> (L1 objective intake, `chump intake`) shipped 2026-08-19 — the front door is
> now open, so this doc defines the *next* stage in the pipeline: turning an
> intake requirement set into a spec the implement stage can build a UI from.
> This is process/interface definition (EFFECTIVE-827); it does not itself
> stand up the automated design-chair agent — that is follow-on work once this
> stage is proven by hand on a real product gap, per EFFECTIVE-358 AC2.

## Where this sits in the pipeline

```
chump intake "<business objective>"     (EFFECTIVE-357, shipped)
  → outcome row + umbrella gap, structured requirements
       │
       ▼
  DESIGN PASS  (this doc)                 ← EFFECTIVE-358 / EFFECTIVE-827
       │  UI/brand/interaction spec
       ▼
  implement stage (fleet workers)          consumes the spec
       │
       ▼
  CSS token discipline gate (INFRA-1590)   enforces at commit time, not design time
```

The design pass is a **stage**, not a standing agent role in today's grain —
Chump specializes by pipeline stage (plan → implement → review → ship → heal),
not by job title, and L1/L3/L7 are exactly the boundary chairs where that grain
breaks down (`SOFTWARE_FACTORY_MATRIX_2026-08-05.md` §2). Until an automated
design-chair curator exists, this stage is executed by whoever claims a
product gap with a UI-facing surface — a human design-chair review, or an Opus
session self-applying the checklist below before dispatching implement work.

## Input: what the design pass consumes

The design pass is triggered when an intake-produced gap or umbrella
description indicates the shipped artifact has a **user-facing surface**
(a CLI with interactive output, a web UI, a PWA view, a dashboard) rather than
a pure library/API/backend change. Concretely, its input is:

1. **The intake requirement set** — `chump intake`'s structured output: user
   stories, restatement, detected entities/constraints/risks
   (`src/vision_intake.rs`, EFFECTIVE-357). The design pass reads this, not
   raw prose — intake has already done ambiguity scoring and clarifying
   questions, so the design pass does not re-litigate requirements.
2. **The product's existing brand tokens**, if any — a
   `docs/schemas/brand-tokens.schema.json`-conformant file for the product
   (EFFECTIVE-636). If none exists yet, producing one is part of this
   stage's output (see below).
3. **The canonical CSS token list** — `docs/process/CSS_TOKEN_DISCIPLINE.md`'s
   11 color tokens + 2 radius tokens. The design pass works *within* this
   vocabulary; it does not invent new token names ad hoc (that is what
   `rule2-alias` rejects at commit time — better to not need the bypass).

## Output: the UI/brand/interaction spec

The design pass produces a short, written spec — attached to the umbrella gap
as a note or a `docs/design-specs/<product>.md` file for anything non-trivial
— covering:

1. **Layout** — the primary views/screens and their arrangement (e.g. "single
   dashboard page: header, primary action button, results list below").
2. **Brand tokens** — a `brand-tokens.schema.json`-conformant file for the
   product if one doesn't already exist, mapping the product's palette onto
   the canonical token names (`--bg`, `--accent`, `--error`, etc). Reuse the
   default PWA tokens (`web/v2/index.html` `:root`) unless the product has a
   distinct brand.
3. **Interaction** — the key user actions and their states (idle / loading /
   success / error), and which canonical tokens each state uses (e.g. errors
   render in `--error`, not a raw hex).
4. **Heuristic checklist** — a pass/fail against a small fixed list (see
   below), not a full design-system audit.

### The heuristic checklist

Kept deliberately small — this is a pass, not a redesign:

- [ ] Every color in the spec maps to a canonical token (no new hex literals)
- [ ] Every interactive element has a defined idle/loading/success/error state
- [ ] Text hierarchy uses `--text` / `--text-secondary`, not ad hoc opacity
- [ ] Spacing/radius uses `--radius` / `--radius-sm`, not magic numbers
- [ ] The spec names at least one non-happy-path state (empty, error, loading)
- [ ] A functional CLI dump is not the final surface for a product gap whose
      intake requirements described a UI (the gap this stage exists to close)

## Hand-off points

| From | To | Artifact |
|---|---|---|
| Intake (`chump intake`) | Design pass | Structured requirement set (user stories, entities/constraints/risks) |
| Design pass | Implement stage (fleet worker claiming the gap) | UI/brand/interaction spec (this doc's Output section), attached to the gap/umbrella as a note or `docs/design-specs/<product>.md` |
| Implement stage | CSS token discipline gate (INFRA-1590) | Committed code — the gate enforces token compliance mechanically; the design pass is upstream advice, the gate is downstream enforcement |
| Design pass | Design chair (review) | The spec itself, for approval before implement work is dispatched |

The design pass does **not** replace INFRA-1590 — that gate catches raw hex/
non-canonical tokens at commit time regardless of whether a design pass ran.
The design pass is the missing *upstream* half: deciding what the UI should
look like, not just enforcing that whatever ships uses the right variable
names.

## Non-goals

- Not a full design system or component library.
- Not a replacement for `chump intake`'s requirement discovery.
- Not an automated agent yet — EFFECTIVE-358 AC2 ("Proven: for a product gap
  the design chair emits an interaction+visual spec the implement stage
  consumes") is the bar for standing up an automated design-chair curator;
  this doc defines the process that curator would run.

## Approval

Reviewed by the design chair — the reviewing session/curator confirms the
input/output/hand-off shape above matches EFFECTIVE-358's slice before this
doc is treated as canonical process for the L3 stage (AC3).

**Approved.** This process — intake requirement set in, UI/brand/interaction
spec out, hand-off to implement + CSS token discipline as the mechanical
enforcement layer — matches the L3 design-pass shape named in
`SOFTWARE_FACTORY_MATRIX_2026-08-05.md` and is ready to be exercised on the
first real product gap with a UI-facing surface.
