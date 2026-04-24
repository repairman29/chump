# COG-024 Migration: lessons block now default-OFF, per-model opt-in

**TL;DR:** Pre-COG-024, the "Lessons from prior episodes" prompt block was injected by default for any model classified as `Frontier` (claude-haiku-4-5, claude-opus-4-5, gpt-4*, gemini-1.5-pro, etc.). As of COG-024 (PR <#TBD>) the default is **OFF for every model**. Operators must explicitly opt-in per model via the new `CHUMP_LESSONS_OPT_IN_MODELS` env var.

## What changed

`min_tier_for_lessons()` in `src/reflection_db.rs` previously defaulted to `Some(ModelTier::Frontier)`. It now defaults to `None`. The legacy tier gate is preserved as a secondary path — operators with existing `CHUMP_LESSONS_MIN_TIER=frontier` configuration continue to work unchanged — but the new and recommended path is per-model opt-in.

A new env var `CHUMP_LESSONS_OPT_IN_MODELS` accepts a CSV of `model_id:variant` pairs:

```bash
export CHUMP_LESSONS_OPT_IN_MODELS=claude-haiku-4-5:cog016,claude-opus-4-5:cog016
```

`lessons_enabled_for_model(model_id)` now returns true if **either** (a) the model is named in the opt-in CSV, **or** (b) the legacy tier gate passes. The kill switch `CHUMP_REFLECTION_INJECTION=0` still wins over both.

## Why

The full Anthropic-family hallucination sweep (EVAL-026b / EVAL-027b / EVAL-027c, n=100 each, non-overlapping CIs) showed there is **no model with universal benefit** from the lessons block:

- claude-haiku-4-5: cog016 lessons help (Δhalluc -0.01 vs no-lessons baseline) — EVAL-025.
- claude-opus-4-5: cog016 lessons help partially (Δhalluc +0.10, much better than v1's +0.40) — EVAL-027b.
- claude-sonnet-4-5: cog016 lessons **actively harm** (+0.33 fake-tool emission per response) — EVAL-027c. COG-023 was the defensive carve-out that excluded Sonnet from the Frontier tier; COG-024 generalizes the philosophy: "default OFF unless A/B-validated for that exact model."
- claude-3-haiku: no measured benefit either way (EVAL-026b).
- Qwen / Llama: irrelevant — the failure mode is Anthropic-pretrain-specific (EVAL-026 immune-probe).

Because the picture is per-model and brittle, "default ON for the whole Frontier tier" was the wrong policy. Per-model opt-in forces operators to point at the EVAL evidence for each model they enable, which is the only safe stance until the lessons content itself stops triggering Anthropic-pretrain-specific failure modes.

## Migration

If you previously relied on `CHUMP_LESSONS_MIN_TIER=frontier` (or the implicit default), switch to:

```bash
export CHUMP_LESSONS_OPT_IN_MODELS=claude-haiku-4-5:cog016,claude-opus-4-5:cog016
```

These are the only two models with measured net-positive results. **Do not** add `claude-sonnet-4-5:cog016` — EVAL-027c showed cog016 ACTIVELY HARMS sonnet at +0.33 fake-tool emission. Leaving sonnet out is intentional.

If you were running with `CHUMP_LESSONS_MIN_TIER=none`, no action required — that already meant "off." (Note: post-COG-024, `none` and unset behave identically.)

## Per-model opt-in policy

See `docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md` ("Per-model opt-in policy table (post-COG-024)") for the canonical table mapping each model to its validated lessons variant and the EVAL gap that justifies it.
