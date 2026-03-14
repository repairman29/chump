//! Own agent run loop with optional event streaming. Replaces axonerai Agent::run when we need
//! SSE (web) or a single place to add keepalive/streaming. Uses Session + FileSessionManager
//! and the same message format (format_tool_use / format_tool_results) as axonerai.

use anyhow::Result;
use axonerai::executor::{ToolExecutor, ToolResult};
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{Message, Provider, StopReason, ToolCall};
use axonerai::session::Session;
use std::time::Instant;

use crate::stream_events::{AgentEvent, EventSender};

/// Mirror of axonerai agent format for assistant tool-use message.
fn format_tool_use(tool_calls: &[ToolCall]) -> String {
    tool_calls
        .iter()
        .map(|call| {
            format!(
                "Using tool '{}' with input: {}",
                call.name,
                serde_json::to_string(&call.input).unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Mirror of axonerai agent format for tool results fed back to the LLM.
fn format_tool_results(results: &[ToolResult]) -> String {
    results
        .iter()
        .map(|r| format!("Tool '{}' returned: {}", r.tool_name, r.result))
        .collect::<Vec<_>>()
        .join("\n")
}

pub struct ChumpAgent {
    provider: Box<dyn Provider + Send + Sync>,
    registry: axonerai::tool::ToolRegistry,
    system_prompt: Option<String>,
    file_session_manager: Option<FileSessionManager>,
    event_tx: Option<EventSender>,
    max_iterations: usize,
}

impl ChumpAgent {
    pub fn new(
        provider: Box<dyn Provider + Send + Sync>,
        registry: axonerai::tool::ToolRegistry,
        system_prompt: Option<String>,
        file_session_manager: Option<FileSessionManager>,
        event_tx: Option<EventSender>,
        max_iterations: usize,
    ) -> Self {
        Self {
            provider,
            registry,
            system_prompt,
            file_session_manager,
            event_tx,
            max_iterations: max_iterations.clamp(1, 50),
        }
    }

    fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }

    /// Run one user turn; load session, append user message, loop complete/tools, save, return final text.
    pub async fn run(&self, user_prompt: &str) -> Result<String> {
        let request_id = uuid::Uuid::new_v4().to_string();
        tracing::info!(request_id = %request_id, "agent_turn started");
        let turn_start = Instant::now();

        let mut session = if let Some(ref sm) = self.file_session_manager {
            if sm.exists() {
                sm.load()?
            } else {
                Session::new(sm.get_session().to_string())
            }
        } else {
            Session::new("stateless".to_string())
        };

        session.add_message(Message {
            role: "user".to_string(),
            content: user_prompt.to_string(),
        });

        self.send(AgentEvent::TurnStart {
            request_id: request_id.clone(),
            timestamp: format!(
                "{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
            ),
        });

        let executor = ToolExecutor::new(&self.registry);
        let tools = self.registry.get_all_for_llm();
        let mut model_calls_count: u32 = 0;
        let mut tool_calls_count: u32 = 0;

        for _iter in 1..=self.max_iterations {
            let response = self
                .provider
                .complete(
                    session.get_messages().to_vec(),
                    Some(tools.clone()),
                    None,
                    self.system_prompt.clone(),
                )
                .await?;

            model_calls_count += 1;

            match response.stop_reason {
                StopReason::EndTurn => {
                    let text = response
                        .text
                        .clone()
                        .unwrap_or_else(|| "(No response from agent)".to_string());
                    session.add_message(Message {
                        role: "assistant".to_string(),
                        content: text.clone(),
                    });
                    if let Some(ref sm) = self.file_session_manager {
                        sm.save(&session).map_err(anyhow::Error::from)?;
                    }
                    self.send(AgentEvent::TurnComplete {
                        request_id: request_id.clone(),
                        full_text: text.clone(),
                        duration_ms: turn_start.elapsed().as_millis() as u64,
                        tool_calls_count,
                        model_calls_count,
                    });
                    return Ok(text);
                }

                StopReason::ToolUse => {
                    if let Some(ref t) = response.text {
                        if !t.is_empty() {
                            // Optional thinking text
                        }
                    }
                    if response.tool_calls.is_empty() {
                        let msg = "Agent wanted to use tools but didn't specify any".to_string();
                        self.send(AgentEvent::TurnError {
                            request_id: request_id.clone(),
                            error: msg.clone(),
                        });
                        return Ok(msg);
                    }

                    for tc in &response.tool_calls {
                        self.send(AgentEvent::ToolCallStart {
                            tool_name: tc.name.clone(),
                            tool_input: tc.input.clone(),
                            call_id: tc.id.clone(),
                        });
                    }

                    let exec_start = Instant::now();
                    let tool_names: Vec<_> = response
                        .tool_calls
                        .iter()
                        .map(|tc| tc.name.as_str())
                        .collect();
                    tracing::info!(tools = ?tool_names, "tool_calls start");
                    let tool_results = executor.execute_all(&response.tool_calls).await?;
                    let exec_ms = exec_start.elapsed().as_millis() as u64;
                    tracing::info!(
                        duration_ms = exec_ms,
                        count = tool_results.len(),
                        "tools completed"
                    );
                    tool_calls_count += tool_results.len() as u32;

                    for tr in &tool_results {
                        self.send(AgentEvent::ToolCallResult {
                            call_id: tr.tool_call_id.clone(),
                            tool_name: tr.tool_name.clone(),
                            result: tr.result.clone(),
                            duration_ms: exec_ms / tool_results.len().max(1) as u64,
                            success: true,
                        });
                    }

                    session.add_message(Message {
                        role: "assistant".to_string(),
                        content: format_tool_use(&response.tool_calls),
                    });
                    session.add_message(Message {
                        role: "user".to_string(),
                        content: format_tool_results(&tool_results),
                    });
                }

                StopReason::MaxTokens => {
                    let msg = "Agent hit max tokens limit".to_string();
                    self.send(AgentEvent::TurnError {
                        request_id: request_id.clone(),
                        error: msg.clone(),
                    });
                    return Ok(msg);
                }

                _ => {
                    let msg = format!("Agent stopped with reason: {:?}", response.stop_reason);
                    self.send(AgentEvent::TurnError {
                        request_id: request_id.clone(),
                        error: msg.clone(),
                    });
                    return Ok(msg);
                }
            }
        }

        if let Some(ref sm) = self.file_session_manager {
            sm.save(&session).map_err(anyhow::Error::from)?;
        }
        let msg = format!("Agent reached max iterations ({})", self.max_iterations);
        self.send(AgentEvent::TurnComplete {
            request_id,
            full_text: msg.clone(),
            duration_ms: turn_start.elapsed().as_millis() as u64,
            tool_calls_count,
            model_calls_count,
        });
        Ok(msg)
    }
}
