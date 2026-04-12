//! Wraps a Provider to emit AgentEvents (ModelCallStart, Thinking keepalive, TextComplete, TurnError).
//! With **`mistralrs-infer`** + **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`**, forwards in-process mistral.rs chunk text as **TextDelta** (see [`crate::mistralrs_provider`]).
//! Used by web/RPC SSE and Discord **tool-approval** turns; HTTP providers (Ollama / vLLM / cascade) still use one-shot `complete` + **TextComplete** at end unless extended later.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

use crate::chump_log;
use crate::stream_events::{AgentEvent, EventSender};
use crate::thinking_strip;
use tracing::instrument;

pub struct StreamingProvider {
    inner: Box<dyn Provider + Send + Sync>,
    event_tx: EventSender,
    round: AtomicU32,
    #[cfg(feature = "mistralrs-infer")]
    mistral_for_stream: Option<std::sync::Arc<crate::mistralrs_provider::MistralRsProvider>>,
}

impl StreamingProvider {
    pub fn new(inner: Box<dyn Provider + Send + Sync>, event_tx: EventSender) -> Self {
        Self {
            inner,
            event_tx,
            round: AtomicU32::new(0),
            #[cfg(feature = "mistralrs-infer")]
            mistral_for_stream: None,
        }
    }

    /// Web/RPC: pass `mistral_for_stream` from [`crate::provider_cascade::build_provider_with_mistral_stream`] when using in-process mistral.rs.
    #[cfg(feature = "mistralrs-infer")]
    pub fn new_with_mistral_stream(
        inner: Box<dyn Provider + Send + Sync>,
        mistral_for_stream: Option<std::sync::Arc<crate::mistralrs_provider::MistralRsProvider>>,
        event_tx: EventSender,
    ) -> Self {
        Self {
            inner,
            event_tx,
            round: AtomicU32::new(0),
            mistral_for_stream,
        }
    }

    fn send(&self, event: AgentEvent) {
        let _ = self.event_tx.send(event);
    }
}

#[async_trait]
impl Provider for StreamingProvider {
    #[instrument(
        skip(self, messages, tools, system_prompt),
        fields(
            msg_count = messages.len(),
            tools_count = tools.as_ref().map(|t| t.len()).unwrap_or(0),
            round = tracing::field::Empty
        )
    )]
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let r = self.round.fetch_add(1, Ordering::Relaxed);
        tracing::Span::current().record("round", r);
        self.send(AgentEvent::ModelCallStart { round: r });

        let start = Instant::now();
        let event_tx = self.event_tx.clone();
        let keepalive = tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_millis(500));
            loop {
                interval.tick().await;
                if event_tx
                    .send(AgentEvent::Thinking {
                        elapsed_ms: start.elapsed().as_millis() as u64,
                    })
                    .is_err()
                {
                    break;
                }
            }
        });

        #[cfg(feature = "mistralrs-infer")]
        let (result, skip_text_complete) =
            if crate::mistralrs_provider::chump_mistralrs_stream_text_deltas_env() {
                if let Some(ref m) = self.mistral_for_stream {
                    match m
                        .complete_with_text_deltas(
                            messages.clone(),
                            tools.clone(),
                            max_tokens,
                            system_prompt.clone(),
                            &self.event_tx,
                        )
                        .await
                    {
                        Ok(resp) => (Ok(resp), true),
                        Err(e) => {
                            tracing::warn!(
                                target: "chump",
                                "mistral.rs stream failed (falling back to non-streaming): {}",
                                e
                            );
                            (
                                self.inner
                                    .complete(messages, tools, max_tokens, system_prompt)
                                    .await,
                                false,
                            )
                        }
                    }
                } else {
                    (
                        self.inner
                            .complete(messages, tools, max_tokens, system_prompt)
                            .await,
                        false,
                    )
                }
            } else {
                (
                    self.inner
                        .complete(messages, tools, max_tokens, system_prompt)
                        .await,
                    false,
                )
            };

        #[cfg(not(feature = "mistralrs-infer"))]
        let (result, skip_text_complete) = (
            self.inner
                .complete(messages, tools, max_tokens, system_prompt)
                .await,
            false,
        );

        keepalive.abort();

        match &result {
            Ok(resp) => {
                if !skip_text_complete {
                    if let Some(ref text) = resp.text {
                        if !text.is_empty() {
                            let preview = thinking_strip::strip_for_streaming_preview(text);
                            if !preview.is_empty() {
                                self.send(AgentEvent::TextComplete { text: preview });
                            }
                        }
                    }
                }
            }
            Err(e) => {
                self.send(AgentEvent::TurnError {
                    request_id: String::new(),
                    error: chump_log::redact(&e.to_string()),
                });
            }
        }

        result
    }
}
