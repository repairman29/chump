//! Own agent run loop with optional event streaming. Replaces axonerai Agent::run when we need
//! SSE (web) or a single place to add keepalive/streaming. Uses Session + FileSessionManager
//! and the same message format (format_tool_use / format_tool_results) as axonerai.
//! When CHUMP_TOOLS_ASK is set, tools in that set require approval before execution.

use anyhow::Result;
use axonerai::executor::ToolExecutor;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{Message, Provider};
use std::sync::Arc;
use std::time::Instant;
use tracing::instrument;

use crate::agent_session;
use crate::agent_turn;
use crate::agent_loop::{AgentLoopContext, PerceptionLayer, PromptAssembler, ToolRunner, IterationController, AgentRunOutcome, AgentEvent};
use crate::cluster_mesh;

struct ClearWebSessionOnDrop;
impl Drop for ClearWebSessionOnDrop {
    fn drop(&mut self) {
        agent_session::set_active_session_id(None);
    }
}

pub struct ChumpAgent {
    pub provider: Box<dyn Provider + Send + Sync>,
    pub registry: axonerai::tool::ToolRegistry,
    pub system_prompt: Option<String>,
    pub file_session_manager: Option<FileSessionManager>,
    pub event_tx: Option<crate::stream_events::EventSender>,
    pub max_iterations: usize,
    pub executor: Arc<dyn crate::task_executor::TaskExecutor + Send + Sync>,
}

impl ChumpAgent {
    pub fn new(
        provider: Box<dyn Provider + Send + Sync>,
        registry: axonerai::tool::ToolRegistry,
        system_prompt: Option<String>,
        file_session_manager: Option<FileSessionManager>,
        event_tx: Option<crate::stream_events::EventSender>,
        max_iterations: usize,
    ) -> Self {
        Self {
            provider,
            registry,
            system_prompt,
            file_session_manager,
            event_tx,
            max_iterations: max_iterations.clamp(1, 50),
            executor: crate::task_executor::default_task_executor(),
        }
    }

    fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }

    /// Run one user turn; load session, append user message, loop complete/tools, save, return final text and thinking.
    #[instrument(skip(self, user_prompt), fields(prompt_len = user_prompt.len()))]
    pub async fn run(&self, user_prompt: &str) -> Result<AgentRunOutcome> {
        cluster_mesh::ensure_probed_once().await;
        let _clear_web_session = ClearWebSessionOnDrop;
        let _turn_id = agent_turn::begin_turn();
        let request_id = uuid::Uuid::new_v4().to_string();
        tracing::info!(request_id = %request_id, "agent_turn started");
        let turn_start = Instant::now();

        let mut session = if let Some(ref sm) = self.file_session_manager {
            if sm.exists() {
                sm.load()?
            } else {
                crate::agent_loop::AgentSession::new(sm.get_session().to_string())
            }
        } else {
            crate::agent_loop::AgentSession::new("stateless".to_string())
        };

        session.add_message(Message {
            role: "user".to_string(),
            content: user_prompt.to_string(),
        });

        if let Some(ref sm) = self.file_session_manager {
            agent_session::set_active_session_id(Some(sm.get_session()));
        } else {
            agent_session::set_active_session_id(None);
        }

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

        let light = crate::env_flags::light_interactive_active();
        let mut ctx = AgentLoopContext {
            request_id: request_id.clone(),
            turn_start,
            session,
            event_tx: self.event_tx.clone(),
            light,
        };

        let perception_layer = PerceptionLayer;
        let prompt_assembler = PromptAssembler {
            base_system_prompt: self.system_prompt.clone(),
        };

        // ── Structured perception: extract task type, entities, constraints, risk ──
        let needs_tools_hint = crate::agent_loop::message_likely_needs_tools_neuromod(user_prompt);
        let perception = perception_layer.perceive(user_prompt, needs_tools_hint);

        let effective_system = prompt_assembler.assemble(&perception);

        let executor = ToolExecutor::new(&self.registry);
        let tools = {
            let raw = self.registry.get_all_for_llm();
            if ctx.light {
                crate::agent_loop::compact_tools_for_light(raw)
            } else {
                raw
            }
        };

        let skip_tools_first_call = ctx.light && !needs_tools_hint;

        let tool_runner = ToolRunner {
            executor: &executor,
            registry: &self.registry,
            task_executor: self.executor.clone(),
        };
        let controller = IterationController {
            max_iterations: self.max_iterations,
            provider: self.provider.as_ref(),
        };

        let outcome = controller.execute(
            &mut ctx,
            tools,
            effective_system,
            skip_tools_first_call,
            &tool_runner,
            &prompt_assembler,
        ).await?;

        if let Some(ref sm) = self.file_session_manager {
            sm.save(&ctx.session).map_err(anyhow::Error::from)?;
        }

        Ok(outcome)
    }
}
