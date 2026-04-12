//! In-process inference via [mistral.rs](https://github.com/EricLBuehler/mistral.rs) (`mistralrs` crate).
//! Enable with `--features mistralrs-infer` and set `CHUMP_INFERENCE_BACKEND=mistralrs` + `CHUMP_MISTRALRS_MODEL`.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool, ToolCall};
use mistralrs::{
    ChatCompletionResponse, Function, IsqBits, PagedAttentionMetaBuilder, RequestBuilder,
    Response as MistralResponse, TextMessageRole, TextModelBuilder, Tool as MistralTool,
    ToolCallResponse, ToolChoice, ToolType,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

use crate::local_openai::{apply_sliding_window_to_messages_async, strip_think_blocks};
use crate::stream_events::{AgentEvent, EventSender};

fn map_role(role: &str) -> TextMessageRole {
    match role {
        "assistant" => TextMessageRole::Assistant,
        "system" => TextMessageRole::System,
        "tool" => TextMessageRole::Tool,
        _ => TextMessageRole::User,
    }
}

fn axon_tools_to_mistral(tools: &[Tool]) -> Vec<MistralTool> {
    tools
        .iter()
        .map(|t| {
            let parameters: Option<HashMap<String, Value>> = t
                .input_schema
                .as_object()
                .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect());
            MistralTool {
                tp: ToolType::Function,
                function: Function {
                    description: Some(t.description.clone()),
                    name: t.name.clone(),
                    parameters,
                },
            }
        })
        .collect()
}

fn tool_calls_to_axon(calls: &[ToolCallResponse]) -> Vec<ToolCall> {
    calls
        .iter()
        .map(|c| ToolCall {
            id: c.id.clone(),
            name: c.function.name.clone(),
            input: serde_json::from_str(&c.function.arguments)
                .unwrap_or_else(|_| json!({ "raw_arguments": c.function.arguments.clone() })),
        })
        .collect()
}

fn isq_bits_from_env() -> IsqBits {
    let s = std::env::var("CHUMP_MISTRALRS_ISQ_BITS").unwrap_or_else(|_| "8".to_string());
    match s.trim() {
        "2" => IsqBits::Two,
        "3" => IsqBits::Three,
        "4" => IsqBits::Four,
        "5" => IsqBits::Five,
        "6" => IsqBits::Six,
        "8" => IsqBits::Eight,
        _ => IsqBits::Eight,
    }
}

/// `Ok(None)` = leave builder default; `Ok(Some(None))` = disable prefix cache; `Ok(Some(Some(n)))` = set *n* slots.
fn interpret_prefix_cache_env(raw: &str) -> Result<Option<Option<usize>>> {
    let t = raw.trim();
    if t.is_empty() {
        return Ok(None);
    }
    let lowered = t.to_ascii_lowercase();
    if lowered == "off" || lowered == "none" || lowered == "disable" {
        return Ok(Some(None));
    }
    let n: usize = t.parse().map_err(|_| {
        anyhow!("CHUMP_MISTRALRS_PREFIX_CACHE_N: expected integer or off/none/disable")
    })?;
    Ok(Some(Some(n)))
}

fn prefix_cache_n_from_env() -> Result<Option<Option<usize>>> {
    match std::env::var("CHUMP_MISTRALRS_PREFIX_CACHE_N") {
        Ok(raw) => interpret_prefix_cache_env(&raw),
        Err(_) => Ok(None),
    }
}

async fn build_mistral_model(model_id: &str) -> Result<mistralrs::Model> {
    let mut b = TextModelBuilder::new(model_id).with_auto_isq(isq_bits_from_env());

    if let Ok(rev) = std::env::var("CHUMP_MISTRALRS_HF_REVISION") {
        let rev = rev.trim();
        if !rev.is_empty() {
            b = b.with_hf_revision(rev);
        }
    }

    match prefix_cache_n_from_env()? {
        None => {}
        Some(n) => {
            b = b.with_prefix_cache_n(n);
        }
    }

    if std::env::var("CHUMP_MISTRALRS_MOQE")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_mixture_qexperts_isq();
    }

    if std::env::var("CHUMP_MISTRALRS_PAGED_ATTN")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        let cfg = PagedAttentionMetaBuilder::default()
            .build()
            .map_err(|e| anyhow!("mistral.rs PagedAttentionMetaBuilder: {}", e))?;
        b = b.with_paged_attn(cfg);
    }

    if std::env::var("CHUMP_MISTRALRS_THROUGHPUT_LOGGING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_throughput_logging();
    }

    if std::env::var("CHUMP_MISTRALRS_FORCE_CPU")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_force_cpu();
    }
    if std::env::var("CHUMP_MISTRALRS_LOGGING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_logging();
    }
    b.build()
        .await
        .map_err(|e| anyhow!("mistral.rs model load failed: {}", e))
}

/// Returns true when env selects mistral.rs (same predicate as [`crate::env_flags::chump_inference_backend_mistralrs_env`]).
/// This module is only compiled with `--features mistralrs-infer`; without the feature, use env_flags + HTTP providers only.
pub fn mistralrs_backend_configured() -> bool {
    crate::env_flags::chump_inference_backend_mistralrs_env()
}

/// When `1`/`true`, web/RPC [`StreamingProvider`](crate::streaming_provider::StreamingProvider) forwards mistral.rs **chunk text** as [`AgentEvent::TextDelta`](crate::stream_events::AgentEvent::TextDelta) before the turn finishes.
pub fn chump_mistralrs_stream_text_deltas_env() -> bool {
    std::env::var("CHUMP_MISTRALRS_STREAM_TEXT_DELTAS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn chat_response_to_completion(
    choice_finish: String,
    msg: mistralrs::ResponseMessage,
) -> CompletionResponse {
    let finish = choice_finish.to_lowercase();

    if let Some(ref tcalls) = msg.tool_calls {
        if !tcalls.is_empty() {
            return CompletionResponse {
                text: msg.content.clone(),
                tool_calls: tool_calls_to_axon(tcalls),
                stop_reason: StopReason::ToolUse,
            };
        }
    }

    let text = msg
        .content
        .map(|s| strip_think_blocks(&s))
        .filter(|s| !s.is_empty());

    let stop_reason = if finish.contains("length") {
        StopReason::MaxTokens
    } else if finish.contains("tool") {
        StopReason::ToolUse
    } else {
        StopReason::EndTurn
    };

    CompletionResponse {
        text,
        tool_calls: vec![],
        stop_reason,
    }
}

fn completion_from_chat_response(resp: ChatCompletionResponse) -> Result<CompletionResponse> {
    let choice = resp
        .choices
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("mistral.rs: empty choices"))?;
    Ok(chat_response_to_completion(
        choice.finish_reason,
        choice.message,
    ))
}

/// Wraps [`Arc<MistralRsProvider>`] so we can use it as `Box<dyn Provider>` alongside a clone of the same `Arc` for streaming (orphan rule blocks `impl Provider for Arc<...>`).
pub struct SharedMistralProvider(pub Arc<MistralRsProvider>);

#[async_trait]
impl Provider for SharedMistralProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        self.0
            .complete(messages, tools, max_tokens, system_prompt)
            .await
    }
}

pub struct MistralRsProvider {
    model_id: String,
    inner: Mutex<Option<Arc<mistralrs::Model>>>,
}

impl MistralRsProvider {
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            inner: Mutex::new(None),
        }
    }

    async fn ensure_model(&self) -> Result<Arc<mistralrs::Model>> {
        let mut guard = self.inner.lock().await;
        if let Some(m) = guard.as_ref() {
            return Ok(Arc::clone(m));
        }
        info!(model = %self.model_id, "mistralrs loading model (cold start)");
        let load_start = std::time::Instant::now();
        let m = Arc::new(build_mistral_model(&self.model_id).await?);
        info!(
            model = %self.model_id,
            elapsed_ms = load_start.elapsed().as_millis() as u64,
            "mistralrs model loaded",
        );
        *guard = Some(Arc::clone(&m));
        Ok(m)
    }

    fn build_request(
        messages: &[Message],
        tools: Option<&[Tool]>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> RequestBuilder {
        let temperature: f64 = std::env::var("CHUMP_TEMPERATURE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.3_f64)
            .clamp(0.0, 2.0);

        let mut req = RequestBuilder::new().set_sampler_temperature(temperature);
        if let Some(sys) = system_prompt {
            if !sys.is_empty() {
                req = req.add_message(TextMessageRole::System, sys);
            }
        }
        for m in messages {
            req = req.add_message(map_role(&m.role), &m.content);
        }
        if let Some(mt) = max_tokens {
            req = req.set_sampler_max_len(mt as usize);
        }
        if let Some(tls) = tools {
            if !tls.is_empty() {
                let mistral_tools = axon_tools_to_mistral(tls);
                req = req
                    .set_tools(mistral_tools)
                    .set_tool_choice(ToolChoice::Auto);
            }
        }
        req
    }

    /// Like [`Provider::complete`], but emits [`AgentEvent::TextDelta`] for each streamed text chunk.
    pub async fn complete_with_text_deltas(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
        delta_tx: &EventSender,
    ) -> Result<CompletionResponse> {
        let model = self.ensure_model().await?;
        let messages =
            apply_sliding_window_to_messages_async(messages, system_prompt.as_deref()).await;
        let req = Self::build_request(&messages, tools.as_deref(), max_tokens, system_prompt);

        let stream_start = std::time::Instant::now();
        let mut stream = model
            .stream_chat_request(req)
            .await
            .map_err(|e| anyhow!("mistral.rs stream: {}", e))?;

        while let Some(resp) = stream.next().await {
            match resp {
                MistralResponse::Chunk(chunk) => {
                    for ch in chunk.choices {
                        if let Some(c) = ch.delta.content.filter(|s| !s.is_empty()) {
                            let _ = delta_tx.send(AgentEvent::TextDelta { delta: c });
                        }
                    }
                }
                MistralResponse::Done(done) => {
                    let out = completion_from_chat_response(done)?;
                    crate::llm_backend_metrics::record_mistralrs(&self.model_id, true);
                    info!(
                        model = %self.model_id,
                        elapsed_ms = stream_start.elapsed().as_millis() as u64,
                        streaming = true,
                        "mistralrs chat complete",
                    );
                    return Ok(out);
                }
                MistralResponse::InternalError(e) | MistralResponse::ValidationError(e) => {
                    return Err(anyhow!("mistral.rs stream: {}", e));
                }
                MistralResponse::ModelError(msg, _partial) => {
                    return Err(anyhow!("mistral.rs stream model error: {}", msg));
                }
                _ => {}
            }
        }

        Err(anyhow!("mistral.rs stream ended without Done"))
    }
}

#[async_trait]
impl Provider for MistralRsProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let model = self.ensure_model().await?;
        let messages =
            apply_sliding_window_to_messages_async(messages, system_prompt.as_deref()).await;
        let req = Self::build_request(&messages, tools.as_deref(), max_tokens, system_prompt);

        let inf_start = std::time::Instant::now();
        let response = model
            .send_chat_request(req)
            .await
            .map_err(|e| anyhow!("mistral.rs inference: {}", e))?;

        let out = completion_from_chat_response(response)?;
        crate::llm_backend_metrics::record_mistralrs(&self.model_id, false);
        info!(
            model = %self.model_id,
            elapsed_ms = inf_start.elapsed().as_millis() as u64,
            streaming = false,
            "mistralrs chat complete",
        );
        Ok(out)
    }
}

#[cfg(test)]
mod mistral_env_tests {
    use super::interpret_prefix_cache_env;

    #[test]
    fn prefix_cache_off_disables() {
        assert_eq!(interpret_prefix_cache_env("off").unwrap(), Some(None));
        assert_eq!(interpret_prefix_cache_env(" NONE ").unwrap(), Some(None));
    }

    #[test]
    fn prefix_cache_number() {
        assert_eq!(interpret_prefix_cache_env("32").unwrap(), Some(Some(32)));
    }

    #[test]
    fn prefix_cache_empty_omits() {
        assert_eq!(interpret_prefix_cache_env("").unwrap(), None);
        assert_eq!(interpret_prefix_cache_env("  ").unwrap(), None);
    }
}
