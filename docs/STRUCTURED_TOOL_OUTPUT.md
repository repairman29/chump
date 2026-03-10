# Structured tool output (Phase 2)

**Goal:** Reduce malformed tool-call JSON (e.g. invalid `function.arguments`) so the agent does not need retry loops or fallback parsing.

## Current state

- We send `tools` (name, description, parameters schema) in the chat completion request and rely on the model to return valid JSON in `tool_calls[].function.arguments`.
- We do not send `tool_choice`; the provider does not use `response_format` for tool rounds.
- Malformed arguments are handled by `serde_json::from_str` in `local_openai.rs` (fallback to `{}`) and by per-tool validation; the agent may retry or produce poor results when the model emits invalid JSON.

## Server-side options

- **OpenAI:** Structured Outputs (`response_format` with `json_schema`) apply to **message content**, not to tool-call arguments. Tool-call shape is enforced by the API and model training.
- **vLLM (upstream):** Tool calling uses a **structured outputs backend** when `tool_choice` is set (e.g. `"auto"`, `"required"`, or a named function). With `--enable-auto-tool-choice` and a suitable `--tool-call-parser`, vLLM ensures the response matches the tool parameter schema. See [vLLM Tool Calling](https://docs.vllm.ai/en/stable/features/tool_calling.html).
- **vLLM-MLX:** May support a subset of vLLM’s tool-calling and structured-output flags; if so, passing `tool_choice: "auto"` from our provider can help when the server is started with the right options.

## What we do

- **LocalOpenAIProvider** sends `tool_choice: "auto"` when `tools` is present so that servers that support it (e.g. vLLM with tool calling enabled) can use structured output for tool calls. This is a hint; behavior depends on the server.
- If the server does not support tool_choice or structured tool output, behavior is unchanged (model output only).
- **Limitation:** vLLM-MLX may not yet support `--enable-auto-tool-choice` or the same tool parsers as upstream vLLM; in that case, we keep current validation and error handling. When vLLM-MLX adds full tool-calling support, our requests are already compatible.

## Future

- If a server exposes a way to constrain **only** tool-call arguments via a dedicated parameter (e.g. per-tool JSON schema enforcement), we can add it here.
- Log or metrics for malformed tool JSON can help decide whether to prioritize server-side structured output (e.g. vLLM-MLX feature parity).
