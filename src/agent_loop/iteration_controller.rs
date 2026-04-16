use anyhow::Result;
use axonerai::provider::{Provider, StopReason, Tool};
use crate::agent_loop::{AgentLoopContext, AgentRunOutcome, BatchOutcome, ToolRunner};
use crate::agent_loop::{push_thinking_segment, joined_thinking_option, response_wanted_tools, parse_text_tool_calls, rescue_raw_diff_as_patch};
use crate::agent_loop::AgentEvent;
use crate::thinking_strip;

/// Max consecutive iterations where every tool call returned a hard failure
/// (DENIED / Tool error:) before the controller short-circuits with a clear
/// error. The qwen3:8b 2026-04-15 regression produced 25 consecutive
/// `patch_file` parse failures — each returning in 1-3ms — which burned the
/// whole iteration budget. 3 consecutive all-failed batches is a strong
/// signal the model is storming, not making progress.
///
/// Overridable via `CHUMP_MAX_CONSECUTIVE_TOOL_FAILS` for operators tuning
/// against flaky providers.
const DEFAULT_MAX_CONSECUTIVE_TOOL_FAILS: u32 = 3;

fn max_consecutive_tool_fails() -> u32 {
    std::env::var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS")
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .filter(|n| *n >= 1)
        .unwrap_or(DEFAULT_MAX_CONSECUTIVE_TOOL_FAILS)
}

pub struct IterationController<'a> {
    pub max_iterations: usize,
    pub provider: &'a dyn Provider,
}

impl<'a> IterationController<'a> {
    pub async fn execute(
        &self,
        ctx: &mut AgentLoopContext,
        tools: Vec<Tool>,
        effective_system: Option<String>,
        skip_tools_first_call: bool,
        tool_runner: &ToolRunner<'_>,
        prompt_assembler: &crate::agent_loop::PromptAssembler,
    ) -> Result<AgentRunOutcome> {
        let mut model_calls_count: u32 = 0;
        let mut tool_calls_count: u32 = 0;
        let mut consecutive_failed_batches: u32 = 0;
        let max_consecutive_fails = max_consecutive_tool_fails();
        let mut thinking_segments: Vec<String> = Vec::new();
        let completion_cap = crate::env_flags::agent_completion_max_tokens();

        // Local helper: update the consecutive-fail counter from a BatchOutcome
        // and return Some(error_msg) when the threshold's been crossed.
        let track_outcome = |outcome: BatchOutcome,
                             counter: &mut u32|
         -> Option<String> {
            if outcome.all_failed() {
                *counter += 1;
                if *counter >= max_consecutive_fails {
                    return Some(format!(
                        "Aborting: {} consecutive tool batches with no successful calls \
                         (latest batch had {} failure{}). The model appears to be storming \
                         on bad tool inputs without making progress. Inspect the recent \
                         tool errors and either fix the inputs by hand or re-prompt with \
                         clearer guidance. Override the threshold via \
                         CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=<N>.",
                        counter,
                        outcome.fail_count,
                        if outcome.fail_count == 1 { "" } else { "s" }
                    ));
                }
            } else if outcome.total() > 0 {
                // Any successful batch resets the counter.
                *counter = 0;
            }
            None
        };

        for _iter in 1..=self.max_iterations {
            crate::belief_state::decay_turn();

            let tools_for_call = if skip_tools_first_call && model_calls_count == 0 {
                None
            } else {
                Some(tools.clone())
            };

            let system_for_call = if tools_for_call.is_none() {
                prompt_assembler.assemble_no_tools_guard(effective_system.clone())
            } else {
                effective_system.clone()
            };

            let response = self.provider.complete(
                ctx.session.get_messages().to_vec(),
                tools_for_call,
                completion_cap,
                system_for_call,
            ).await?;

            model_calls_count += 1;

            match response.stop_reason {
                StopReason::EndTurn => {
                    let text = response.text.clone().unwrap_or_else(|| "(No response from agent)".to_string());
                    let (plan_opt, thinking_opt, payload) = thinking_strip::peel_plan_and_thinking_for_tools(&text);
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    if let Some(synthetic_calls) = parse_text_tool_calls(payload, &tools) {
                        if !synthetic_calls.is_empty() {
                            let outcome = tool_runner
                                .run_synthetic_batch(ctx, synthetic_calls, &mut tool_calls_count)
                                .await?;
                            if let Some(err) = track_outcome(outcome, &mut consecutive_failed_batches)
                            {
                                ctx.send(AgentEvent::TurnError {
                                    request_id: ctx.request_id.clone(),
                                    error: err.clone(),
                                });
                                return Ok(AgentRunOutcome {
                                    reply: err,
                                    thinking_segments,
                                });
                            }
                            continue;
                        }
                    }

                    if model_calls_count <= 2 && response_wanted_tools(payload) {
                        tracing::info!("narration detected: retrying with tools");
                        continue;
                    }

                    // Strip <think>/<thinking>/<plan> blocks before storing in conversation
                    // history — otherwise Qwen3's verbose reasoning accumulates across turns and
                    // pushes tool-call context out of the window (dogfood T1.1 regression).
                    let content_for_history = thinking_strip::strip_for_public_reply(&text);
                    ctx.session.add_message(axonerai::provider::Message {
                        role: "assistant".to_string(),
                        content: content_for_history,
                    });

                    let display_text = thinking_strip::strip_for_streaming_preview(&text);
                    let turn_duration_ms = ctx.turn_start.elapsed().as_millis() as u64;
                    crate::precision_controller::record_turn_metrics(tool_calls_count, 0, turn_duration_ms);

                    ctx.send(AgentEvent::TurnComplete {
                        request_id: ctx.request_id.clone(),
                        full_text: display_text.clone(),
                        duration_ms: turn_duration_ms,
                        tool_calls_count,
                        model_calls_count,
                        thinking_monologue: joined_thinking_option(&thinking_segments),
                    });

                    return Ok(AgentRunOutcome {
                        reply: display_text,
                        thinking_segments,
                    });
                }
                StopReason::ToolUse => {
                    let text_content = response.text.clone().unwrap_or_default();
                    let (plan_opt, thinking_opt, payload) = thinking_strip::peel_plan_and_thinking_for_tools(&text_content);
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    if response.tool_calls.is_empty() {
                        let parse_src = if payload.is_empty() { &text_content } else { payload };
                        if let Some(synthetic_calls) = parse_text_tool_calls(parse_src, &tools) {
                            if !synthetic_calls.is_empty() {
                                let outcome = tool_runner
                                    .run_synthetic_batch(ctx, synthetic_calls, &mut tool_calls_count)
                                    .await?;
                                if let Some(err) =
                                    track_outcome(outcome, &mut consecutive_failed_batches)
                                {
                                    ctx.send(AgentEvent::TurnError {
                                        request_id: ctx.request_id.clone(),
                                        error: err.clone(),
                                    });
                                    return Ok(AgentRunOutcome {
                                        reply: err,
                                        thinking_segments,
                                    });
                                }
                                continue;
                            }
                        }
                        if let Some(synthetic_patch) = rescue_raw_diff_as_patch(payload) {
                            let outcome = tool_runner
                                .run_synthetic_batch(
                                    ctx,
                                    vec![synthetic_patch],
                                    &mut tool_calls_count,
                                )
                                .await?;
                            if let Some(err) = track_outcome(outcome, &mut consecutive_failed_batches)
                            {
                                ctx.send(AgentEvent::TurnError {
                                    request_id: ctx.request_id.clone(),
                                    error: err.clone(),
                                });
                                return Ok(AgentRunOutcome {
                                    reply: err,
                                    thinking_segments,
                                });
                            }
                            continue;
                        }

                        let msg = crate::user_error_hints::append_agent_error_hints("Agent wanted tools but didn't specify any.");
                        ctx.send(AgentEvent::TurnError { request_id: ctx.request_id.clone(), error: msg.clone() });
                        return Ok(AgentRunOutcome { reply: msg, thinking_segments });
                    }

                    let outcome = tool_runner
                        .run_native_batch(ctx, &response.tool_calls, &mut tool_calls_count)
                        .await?;
                    if let Some(err) = track_outcome(outcome, &mut consecutive_failed_batches) {
                        ctx.send(AgentEvent::TurnError {
                            request_id: ctx.request_id.clone(),
                            error: err.clone(),
                        });
                        return Ok(AgentRunOutcome {
                            reply: err,
                            thinking_segments,
                        });
                    }
                    continue;
                }
                _ => {
                    let msg = crate::user_error_hints::append_agent_error_hints(&format!("Agent stopped with reason: {:?}", response.stop_reason));
                    ctx.send(AgentEvent::TurnError { request_id: ctx.request_id.clone(), error: msg.clone() });
                    return Ok(AgentRunOutcome { reply: msg, thinking_segments });
                }
            }
        }

        let msg = format!("Exceeded max iterations ({})", self.max_iterations);
        ctx.send(AgentEvent::TurnError { request_id: ctx.request_id.clone(), error: msg.clone() });
        Ok(AgentRunOutcome { reply: msg, thinking_segments })
    }
}
