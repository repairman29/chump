# Preregistration: INFRA-1004 — CHUMP_LOCAL_ONLY=1 cascade routing gate

## Change description
Adds `CHUMP_LOCAL_ONLY=1` env var that makes `ProviderCascade` refuse all
cloud slots and hard-error rather than fall back silently. Also emits a
`cascade_routed` ambient event on every successful LLM call.

## Hypothesis
When `CHUMP_LOCAL_ONLY=1` is set, zero requests should reach any cloud
provider slot (Anthropic API, OpenAI, Gemini, Together, etc.), and any
attempt that exhausts local slots should return a hard error rather than
silently routing to cloud.

## Measurement
This is a routing correctness gate, not an A/B model-quality experiment.
Pass/fail is binary and deterministic:

1. **Unit tests** (5): `cascade_local_only_*` and `cascade_routed_event_emitted`
   assert cloud slots are skipped and the hard error fires when no local slot
   is available.
2. **CI script** (`scripts/ci/test-local-only-mode.sh`): static guards confirm
   string literals, health endpoint wiring, and EVENT_REGISTRY entry.
3. **Ambient observability**: `cascade_routed` events with `cascade_mode=local-only`
   must appear in `.chump-locks/ambient.jsonl` on every successful local call
   when `CHUMP_LOCAL_ONLY=1`.

## Non-goals
This preregistration is not for a model-quality or preference A/B test.
No learned or bandit evaluation is needed — the correctness invariant is
structural (cloud slots excluded from selection path entirely).
