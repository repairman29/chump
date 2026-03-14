//! Wraps a Provider to emit AgentEvents (ModelCallStart, Thinking keepalive, TextComplete, TurnError).
//! Sprint 2: keepalive only; Sprint 3 will add real Ollama SSE and TextDelta.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

use crate::chump_log;
use crate::stream_events::{AgentEvent, EventSender};

pub struct StreamingProvider {
    inner: Box<dyn Provider + Send + Sync>,
    event_tx: EventSender,
    round: AtomicU32,
}

impl StreamingProvider {
    pub fn new(inner: Box<dyn Provider + Send + Sync>, event_tx: EventSender) -> Self {
        Self {
            inner,
            event_tx,
            round: AtomicU32::new(0),
        }
    }

    fn send(&self, event: AgentEvent) {
        let _ = self.event_tx.send(event);
    }
}

#[async_trait]
impl Provider for StreamingProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let r = self.round.fetch_add(1, Ordering::Relaxed);
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

        let result = self
            .inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await;

        keepalive.abort();

        match &result {
            Ok(resp) => {
                if let Some(ref text) = resp.text {
                    if !text.is_empty() {
                        self.send(AgentEvent::TextComplete {
                            text: text.clone(),
                        });
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
