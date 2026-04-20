# Reasoning Mode (`CHUMP_REASONING_MODE`)

Frontier models (o3, Gemini Deep Think, Claude extended thinking) expose
test-time compute via model-specific "thinking" parameters. Chump's
`reasoning_mode` module adds detection, parameter building, and env-var
control so these parameters can be injected into API calls.

## Environment variables

| Variable | Values | Default | Purpose |
|---|---|---|---|
| `CHUMP_REASONING_MODE` | `off` / `auto` / `always` | `off` | Master switch |
| `CHUMP_REASONING_BUDGET_TOKENS` | positive integer | `10000` | Claude / Gemini thinking budget (tokens) |
| `CHUMP_REASONING_EFFORT` | `low` / `medium` / `high` | `high` | OpenAI o-series `reasoning_effort` |

### `CHUMP_REASONING_MODE`

- **`off`** (default) — never inject reasoning parameters. Safe for all models and providers.
- **`auto`** — inject reasoning parameters only when the task looks complex (prompt > 500 chars, or contains keywords like `prove`, `algorithm`, `derive`, `step by step`, etc.). Falls through to `off` for simple prompts.
- **`always`** — inject reasoning parameters for every call to a supported model. Use with caution on high-traffic agents: thinking tokens count toward context and billing.

## Supported models

`model_supports_reasoning(model_id)` returns `true` for model IDs containing:

| Family | Example model IDs |
|---|---|
| Claude extended thinking | `claude-3-7-sonnet-*`, `claude-opus-4-*`, `claude-sonnet-4-*`, `claude-haiku-4-*`, `claude-3-5-sonnet-*` |
| OpenAI reasoning | `o1`, `o1-mini`, `o1-preview`, `o3`, `o3-mini`, `o4`, `o4-mini` |
| Gemini thinking | `gemini-2.0-flash-thinking-*`, `gemini-2.5-flash-thinking-*`, `gemini-2.5-pro-*` |
| DeepSeek reasoning | `deepseek-r1-*`, `deepseek-r2-*`, `deepseek-reasoner` |

Matching is case-insensitive substring, so revision suffixes (e.g. `-20250219`) do not break detection.

## Parameters emitted per family

### Claude

```json
{
  "thinking": {
    "type": "enabled",
    "budget_tokens": 10000
  }
}
```

Budget is read from `CHUMP_REASONING_BUDGET_TOKENS` (clamped 1 024 – 100 000).

### OpenAI o-series

```json
{ "reasoning_effort": "high" }
```

Effort level is read from `CHUMP_REASONING_EFFORT` (`low` / `medium` / `high`).

### Gemini thinking

```json
{
  "thinkingConfig": {
    "thinkingBudget": 10000
  }
}
```

Budget is read from `CHUMP_REASONING_BUDGET_TOKENS` (clamped 1 024 – 32 768).

### DeepSeek-R1 / Reasoner

```json
{ "temperature": 0.6 }
```

DeepSeek documentation recommends temperature ≤ 1.0 for reasoning models.

## Wiring into provider calls

`build_reasoning_params(model_id)` returns an `Option<serde_json::Value>` (a JSON
object). To inject into an existing request body:

```rust
use crate::reasoning_mode::{build_reasoning_params, should_use_reasoning};

if should_use_reasoning(&model_id, Some(&task_description)) {
    if let Some(params) = build_reasoning_params(&model_id) {
        if let Some(obj) = params.as_object() {
            for (k, v) in obj {
                body[k] = v.clone();
            }
        }
    }
}
```

`should_use_reasoning` checks both `CHUMP_REASONING_MODE` and whether the model
is on the supported list, so the call site can be unconditional.

**Current status:** the module is implemented and tested (`src/reasoning_mode.rs`).
Wiring into `local_openai.rs` / `provider_cascade.rs` is the next step; it is
deferred because it requires provider-specific body shape knowledge and is a
separate change. See the module doc comment for the merge snippet.
