---
doc_tag: canonical
owner_gap: EFFECTIVE-358
---

# Per-product brand tokens (compatible with CSS token discipline)

> Companion to [`DESIGN_PASS_CHECKLIST.md`](./DESIGN_PASS_CHECKLIST.md) and
> [`docs/process/CSS_TOKEN_DISCIPLINE.md`](../process/CSS_TOKEN_DISCIPLINE.md)
> (INFRA-1590). Chump ships tools *for other products* (per EFFECTIVE-357
> intake); each shipped product may want its own brand identity without
> forking the token-discipline gate.

## The problem

INFRA-1590's canonical token list (`--bg`, `--accent`, `--text`, …) is
Chump's own PWA identity. A product the fleet ships for someone else needs
its **own** brand — but the lint gate rejects new `--*-primary` /
`--*-secondary` aliases and any raw hex outside `:root`.

## The pattern: product namespace, not aliasing

Define product tokens under a **product-namespaced prefix**, in the
product's own `:root` block, each one resolving through the canonical
semantic role it plays — never named `-primary`/`-secondary`:

```css
:root {
  /* Canonical Chump tokens (unchanged, INFRA-1590) */
  --bg: #0d1117;
  --accent: #58a6ff;
  --text: #e6edf3;

  /* Product brand layer — namespaced, semantic names, NOT -primary/-secondary */
  --acme-cta-bg: #ff5a1f;      /* product's call-to-action color */
  --acme-cta-text: #ffffff;
  --acme-wordmark: #1a1a1a;
}
```

Rules that keep this compatible with the lint gate (rule1/rule2/rule3):

1. **Namespace every product token** with the product's short slug
   (`--acme-*`), never `--primary`/`--secondary` verbatim — satisfies
   rule2-alias.
2. **Define values only inside `:root` / `[data-theme]` blocks** — satisfies
   rule1-hex/rule1-fn. Component code always uses `var(--acme-cta-bg)`,
   never the hex literal.
3. **When a product token falls back to a canonical one**
   (`var(--acme-cta-bg, var(--accent))`), the fallback must match the
   canonical token's actual value — satisfies rule3-fallback. Prefer this
   fallback form for any product token that doesn't need a truly distinct
   color, so the product inherits Chump's theming (dark/light/high-contrast)
   for free.
4. **Register the namespace once** per product in this file (table below)
   so the design-pass spec and the lint baseline agree on which prefixes
   are expected.

## Registered product namespaces

| Prefix | Product | Owner gap |
|---|---|---|
| _(none registered yet — first product to ship through EFFECTIVE-357 intake adds a row here)_ | | |

Add a row when a new product's design-pass spec introduces its first
`--<prefix>-*` token so `scripts/design/design-pass.sh` and reviewers can
check for prefix collisions.
