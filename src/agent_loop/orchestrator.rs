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

use crate::agent_loop::state::AgentState;
use crate::agent_loop::{
    AgentEvent, AgentLoopContext, AgentRunOutcome, IterationController, PerceptionLayer,
    PromptAssembler, ToolRunner,
};
use crate::agent_session;
use crate::agent_turn;
#[allow(unused_imports)]
use crate::blackboard::{Module, SalienceFactors};
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
    ///
    /// A fresh [`CancellationToken`] is created internally and registered in the global
    /// [`cancel_registry`] so `/api/stop` can interrupt it. Use [`run_with_cancel`] when
    /// the caller (e.g. `platform_router`) already holds a token it wants to fire.
    #[instrument(skip(self, user_prompt), fields(prompt_len = user_prompt.len()))]
    pub async fn run(&self, user_prompt: &str) -> Result<AgentRunOutcome> {
        self.run_inner(user_prompt, None).await
    }

    /// Like [`run`] but uses an externally-provided [`CancellationToken`].
    ///
    /// The token is also registered in the global [`cancel_registry`] under the turn's
    /// `request_id` so `/api/stop` still works. Callers should hold the token and cancel
    /// it directly (e.g. when a [`SensorKind::NewMessage`] event fires in the platform
    /// router's peripheral-sensor loop).
    ///
    /// [`SensorKind::NewMessage`]: crate::peripheral_sensor::SensorKind::NewMessage
    pub async fn run_with_cancel(
        &self,
        user_prompt: &str,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<AgentRunOutcome> {
        self.run_inner(user_prompt, Some(cancel)).await
    }

    #[instrument(skip(self, user_prompt, external_cancel), fields(prompt_len = user_prompt.len()))]
    async fn run_inner(
        &self,
        user_prompt: &str,
        external_cancel: Option<tokio_util::sync::CancellationToken>,
    ) -> Result<AgentRunOutcome> {
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

        // COG-019: compact old turns into a summary when the session grows large.
        // Runs after the new user message is appended so keep-tail always includes it.
        let compact_session_id = if let Some(ref sm) = self.file_session_manager {
            sm.get_session().to_string()
        } else {
            "stateless".to_string()
        };
        // INFRA-185: time the compaction phase (it can itself be an LLM call
        // summarizing old turns, so it's worth attributing — was a silent
        // stall in the INFRA-183 PWA-latency probe).
        let compaction_start = if crate::agent_loop::phase_timing_enabled() {
            Some(Instant::now())
        } else {
            None
        };
        crate::session_compact::maybe_compact(
            &mut session,
            self.provider.as_ref(),
            &compact_session_id,
        )
        .await;
        let compaction_ms = compaction_start
            .map(|t| t.elapsed().as_millis())
            .unwrap_or(0);

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
            phase_timings: crate::agent_loop::PhaseTimings {
                compaction_ms,
                ..Default::default()
            },
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
                // INFRA-182 (2026-05-01): tool routing. The web PWA path
                // previously sent ALL ~46 chump tool schemas (~5 KB) on
                // every turn, adding 15-60 s of prefill per round on
                // local 14B models. Now we route by perception — only
                // the 3-15 tools likely needed for this input.
                //
                // Safety net: if the routed subset doesn't satisfy the
                // model (e.g. it tried a tool we filtered out), the
                // narration-detection retry at iteration_controller:245
                // fires the next round with the FULL tool set. So worst
                // case = today's cost; common case is 3-10× faster.
                //
                // CHUMP_TOOL_ROUTING=0 disables this path and reverts
                // to "send all tools" — useful for harness sweeps that
                // need to compare against the v1 baseline.
                if std::env::var("CHUMP_TOOL_ROUTING").ok().as_deref() == Some("0") {
                    raw
                } else {
                    // Compute routed set as owned Strings so we can move
                    // `raw` into the filter below without keeping a borrow.
                    let total = raw.len();
                    let routed: std::collections::HashSet<String> = {
                        let names: Vec<&str> = raw.iter().map(|t| t.name.as_str()).collect();
                        chump_perception::route_tools(&perception, &names)
                            .into_iter()
                            .map(String::from)
                            .collect()
                    };
                    if routed.is_empty() {
                        // No routing rule matched (and !Meta — Meta returns
                        // empty for "no tools needed", but we know tools
                        // ARE expected at this point because
                        // skip_tools_first_call gates on
                        // !needs_tools_hint earlier). Fall back to all
                        // tools so we don't starve the model.
                        raw
                    } else {
                        let kept: Vec<_> = raw
                            .into_iter()
                            .filter(|t| routed.contains(&t.name))
                            .collect();
                        tracing::debug!(
                            target: "chump",
                            "tool routing: {} of {} sent (perception={:?})",
                            kept.len(),
                            total,
                            perception.task_type
                        );
                        kept
                    }
                }
            }
        };

        // INFRA-180 (2026-05-01): was `ctx.light && !needs_tools_hint`. The
        // ctx.light requirement made this gate dead code for the web PWA
        // path (light only fires for explicit "light mode" callers; web is
        // heavy). Every PWA chat turn shipped all 46 tool schemas (~5KB) to
        // the model, adding 15-60s of prefill on local 14B models — observed
        // 53s end-to-end for "what kind of cool tricks can you do?". With
        // the gate dropped to just !needs_tools_hint, conversational and
        // capability questions skip tools on the first call. If the model
        // actually wanted tools (StopReason::ToolUse with empty tool_calls,
        // or narration detected via response_wanted_tools), the loop
        // retries with tools — see iteration_controller line 245.
        let skip_tools_first_call = !needs_tools_hint;

        let tool_runner = ToolRunner {
            executor: &executor,
            registry: &self.registry,
            task_executor: self.executor.clone(),
        };
        let mut controller = IterationController {
            max_iterations: self.max_iterations,
            provider: self.provider.as_ref(),
            state: AgentState::Idle,
        };

        // AGT-002 / AGT-006: Register a cancellation token for this turn so
        // both /api/stop and the peripheral-sensor loop (platform_router) can
        // interrupt it. If the caller already created a token (run_with_cancel),
        // reuse it; otherwise create a fresh one.
        let cancel = if let Some(ec) = external_cancel {
            crate::cancel_registry::register(&request_id, ec.clone());
            ec
        } else {
            crate::cancel_registry::create_and_register(&request_id)
        };
        let outcome = controller
            .execute(
                &mut ctx,
                tools,
                effective_system,
                skip_tools_first_call,
                &tool_runner,
                &prompt_assembler,
                &perception,
                cancel,
            )
            .await;
        // Always remove the token from the registry when the turn ends,
        // regardless of outcome (success, error, or cancellation).
        crate::cancel_registry::unregister(&request_id);
        let outcome = outcome?;

        if let Some(ref sm) = self.file_session_manager {
            sm.save(&ctx.session).map_err(anyhow::Error::from)?;
        }

        // INFRA-185: emit one structured end-of-turn event with all phase ms
        // summed. The "other_ms" field is the un-attributed remainder
        // (perception, prompt assembly, event dispatch, session save) — useful
        // when total_ms drifts from phases_total_ms unexpectedly.
        if crate::agent_loop::phase_timing_enabled() {
            let total_ms = ctx.turn_start.elapsed().as_millis();
            let phases = ctx.phase_timings.phases_total_ms();
            let other_ms = total_ms.saturating_sub(phases);
            tracing::info!(
                request_id = %request_id,
                compaction_ms = ctx.phase_timings.compaction_ms,
                provider_ms = ctx.phase_timings.provider_ms,
                tools_ms = ctx.phase_timings.tools_ms,
                other_ms = other_ms,
                rounds = ctx.phase_timings.rounds,
                total_ms = total_ms,
                "phase timings (INFRA-185)"
            );
        }

        maybe_suggest_skill(&outcome);
        Ok(outcome)
    }
}

/// Post a blackboard suggestion to create a skill when the turn used enough tool calls
/// to indicate a repeatable workflow. Threshold tunable via CHUMP_SKILL_SUGGEST_THRESHOLD
/// (default 5, matching Hermes's trigger point). Set to 0 to disable.
fn maybe_suggest_skill(outcome: &AgentRunOutcome) {
    let threshold = std::env::var("CHUMP_SKILL_SUGGEST_THRESHOLD")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(5);
    if threshold == 0 || outcome.total_tool_calls < threshold {
        return;
    }
    let msg = format!(
        "This turn used {} tool calls — consider capturing the workflow as a reusable skill \
         via skill_manage(action=create, name=<kebab-name>, description=<one line>, content=<SKILL.md body>). \
         Skills help Chump repeat successful patterns without re-deriving them each time.",
        outcome.total_tool_calls
    );
    crate::blackboard::post(
        crate::blackboard::Module::Custom("agent_loop".to_string()),
        msg,
        crate::blackboard::SalienceFactors {
            novelty: 0.8,
            uncertainty_reduction: 0.2,
            goal_relevance: 0.7,
            urgency: 0.3,
        },
    );
    tracing::info!(
        tool_calls = outcome.total_tool_calls,
        threshold,
        "skill suggestion posted to blackboard"
    );
}

#[cfg(test)]
mod tests {
    //! Narrow tests for the pure pieces of orchestrator — the async `run`
    //! path needs a provider + registry + session manager, which is
    //! integration-territory. What we can (and should) test:
    //!   - `ChumpAgent::new` clamps `max_iterations` correctly (off-by-one
    //!     magnet; 0 would cause infinite-loop-by-zero in the controller).
    //!   - `ClearWebSessionOnDrop` clears the web-session id on drop (safety
    //!     invariant: otherwise a stale session id leaks across turns).

    use super::*;

    /// Minimal Provider stub for constructor tests. Never called.
    struct StubProvider;
    #[async_trait::async_trait]
    impl Provider for StubProvider {
        async fn complete(
            &self,
            _messages: Vec<Message>,
            _tools: Option<Vec<axonerai::provider::Tool>>,
            _max_tokens: Option<u32>,
            _system: Option<String>,
        ) -> Result<axonerai::provider::CompletionResponse> {
            unreachable!("stub provider")
        }
    }

    fn make_agent(max_iter: usize) -> ChumpAgent {
        ChumpAgent::new(
            Box::new(StubProvider),
            axonerai::tool::ToolRegistry::new(),
            None,
            None,
            None,
            max_iter,
        )
    }

    #[test]
    fn max_iterations_clamps_zero_to_one() {
        let a = make_agent(0);
        assert_eq!(
            a.max_iterations, 1,
            "zero iterations would never run the loop; must clamp to 1"
        );
    }

    #[test]
    fn max_iterations_clamps_above_50_down() {
        let a = make_agent(500);
        assert_eq!(
            a.max_iterations, 50,
            "iteration cap protects against runaway loops"
        );
    }

    #[test]
    fn max_iterations_preserves_mid_range() {
        assert_eq!(make_agent(1).max_iterations, 1);
        assert_eq!(make_agent(25).max_iterations, 25);
        assert_eq!(make_agent(50).max_iterations, 50);
    }

    #[test]
    #[serial_test::serial]
    fn clear_web_session_on_drop_nulls_active_session_id() {
        // Setup: pretend a web request set an active session id.
        agent_session::set_active_session_id(Some("session-xyz"));
        assert!(
            agent_session::active_session_id().is_some(),
            "setup should leave a session id set"
        );
        // Invariant: when the guard drops, the active session id is cleared.
        {
            let _guard = ClearWebSessionOnDrop;
            // Still set inside the scope.
            assert!(agent_session::active_session_id().is_some());
        }
        assert!(
            agent_session::active_session_id().is_none(),
            "drop must clear active session id to prevent cross-turn leakage"
        );
    }
}
