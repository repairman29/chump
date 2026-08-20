---
doc_tag: canonical
owner_gap: EFFECTIVE-358
---

# Design-pass heuristic checklist (L3 design chair)

> Filled the missing chair identified in
> [`docs/strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md`](../strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md)
> (DOC-079): "the only design capability today is the CSS token lint gate
> (INFRA-1590) — a gate, not a designer." This checklist is what the design
> chair (`scripts/design/design-pass.sh`) grades a UI/brand/interaction spec
> against before the implement stage consumes it.

A design pass runs **after intake** (requirements + AC exist) and **before
implement** starts writing UI code. It does not touch code — it emits a
written spec that the implementing agent (human or fleet worker) treats as
part of the gap's acceptance criteria.

## The checklist

For any user-facing surface (CLI output, TUI, or `web/**`):

1. **Layout** — what's the primary action, and is it the visually dominant
   element? Secondary/tertiary actions demoted (position, weight, or both)?
2. **Spacing** — consistent rhythm (a single base unit, e.g. 4px/8px
   multiples for web; consistent blank-line/indent convention for CLI/TUI)?
   No ad-hoc one-off margins.
3. **Typography / output hierarchy** — for web: a defined type scale, not
   arbitrary `font-size` values. For CLI/TUI: a defined hierarchy of
   heading / body / dim / error text (color or weight), not raw `println!`
   dumps with no visual grouping.
4. **Interaction** — every state the user can be in is accounted for:
   empty, loading, success, error, and (if applicable) partial/streaming.
   Errors are actionable (say what to do next), not just "failed".
5. **Brand-token compliance** — for web surfaces, all colors resolve through
   `var(--token)` against the canonical list in
   [`docs/process/CSS_TOKEN_DISCIPLINE.md`](../process/CSS_TOKEN_DISCIPLINE.md)
   or a product's own token layer (see
   [`BRAND_TOKENS_TEMPLATE.md`](./BRAND_TOKENS_TEMPLATE.md)). No raw hex,
   no `--*-primary`/`--*-secondary` aliases.
6. **Consistency with the rest of the product** — does this surface look
   like it belongs next to the product's existing shipped surfaces, or does
   it look like a different tool bolted on?

## Spec format

`scripts/design/design-pass.sh spec <GAP-ID>` emits a markdown file at
`docs/design/specs/<GAP-ID>-design-spec.md` with one subsection per checklist
item above, plus a `## Consumed by implement` section naming the concrete
component/file the implement stage should treat as governed by this spec.

A spec is **not** optional narrative — every subsection must contain a
concrete, checkable statement ("primary action is the single filled button,
top-right of the panel"), not a restatement of the checklist question.

## Evidence

Per the gap's AC(c) rough shape, when a PR implements a spec'd surface, the
PR description should attach a before/after screenshot pair (or, for
CLI/TUI, a before/after transcript) so reviewers can verify the spec was
actually followed, not just written.

## Worked example (proves the implement stage consumes the spec)

Illustrative run for a hypothetical product gap that shipped an onboarding
wizard through the CLI, after `chump gap show COTG-EXAMPLE-1` returned
requirements from intake (EFFECTIVE-357):

```
$ scripts/design/design-pass.sh spec COTG-EXAMPLE-1
docs/design/specs/COTG-EXAMPLE-1-design-spec.md
```

The emitted spec's final section:

```markdown
## Consumed by implement
src/cli/onboarding_wizard.rs — the `render_step()` function must follow the
Layout/Spacing/Interaction sections above: one primary action per screen
(highlighted), a consistent 1-blank-line rhythm between prompt and input,
and an explicit empty/error/success state for every prompt instead of a
bare `println!` dump.
```

The implementing agent's brief (`chump --briefing COTG-EXAMPLE-1`) then
includes the spec path, and the PR that closes the gap is expected to
attach a before/after transcript per the Evidence section above — turning
"functional CLI output" into a reviewed, coherent interaction rather than a
raw dump.
