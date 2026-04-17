use crate::agent_loop::AgentEvent;
use crate::agent_loop::{
    joined_thinking_option, parse_text_tool_calls, push_thinking_segment, rescue_raw_diff_as_patch,
    response_wanted_tools,
};
use crate::agent_loop::{AgentLoopContext, AgentRunOutcome, BatchOutcome, ToolRunner};
use crate::thinking_strip;
use anyhow::Result;
use axonerai::provider::{Provider, StopReason, Tool};

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

/// Decide whether a tool batch outcome should trip the fail-storm breaker.
///
/// Returns `Some(error_msg)` when `counter` has reached `max_consecutive_fails`
/// after counting this outcome as a fail. Returns `None` otherwise.
///
/// Mutates `counter`:
///   - increment on `outcome.all_failed()`
///   - reset to 0 when the batch has at least one successful tool call
///   - leave unchanged on empty batches (no tools called = not a storm signal)
///
/// Extracted from an inner closure so it can be unit-tested without spinning
/// up a full `IterationController::execute` harness.
pub(crate) fn track_batch_outcome(
    outcome: BatchOutcome,
    counter: &mut u32,
    max_consecutive_fails: u32,
) -> Option<String> {
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
}

pub struct IterationController<'a> {
    pub max_iterations: usize,
    pub provider: &'a dyn Provider,
}

impl<'a> IterationController<'a> {
    // Internal call site (orchestrator). Refactoring 8 args into an Args
    // struct would just shuffle them; the orchestrator already passes them
    // by name. Skip the lint here rather than add boilerplate.
    #[allow(clippy::too_many_arguments)]
    pub async fn execute(
        &self,
        ctx: &mut AgentLoopContext,
        tools: Vec<Tool>,
        effective_system: Option<String>,
        skip_tools_first_call: bool,
        tool_runner: &ToolRunner<'_>,
        prompt_assembler: &crate::agent_loop::PromptAssembler,
        perception: &crate::perception::PerceivedInput,
    ) -> Result<AgentRunOutcome> {
        let mut model_calls_count: u32 = 0;
        let mut tool_calls_count: u32 = 0;
        let mut consecutive_failed_batches: u32 = 0;
        let max_consecutive_fails = max_consecutive_tool_fails();
        let mut thinking_segments: Vec<String> = Vec::new();
        let completion_cap = crate::env_flags::agent_completion_max_tokens();

        // COG-009b: tracks the last tool name that failed in the most recent
        // batch. When set, we re-assemble the system prompt with a retry hint
        // so the model gets "you just errored on X — consider reading before
        // retrying" instead of having to infer the failure from raw text.
        let mut last_failed_tool: Option<String> = None;

        // Capture max fails up-front so the per-call helper doesn't re-read env.
        let track_outcome = |outcome: BatchOutcome, counter: &mut u32| -> Option<String> {
            track_batch_outcome(outcome, counter, max_consecutive_fails)
        };

        for _iter in 1..=self.max_iterations {
            crate::belief_state::decay_turn();

            let tools_for_call = if skip_tools_first_call && model_calls_count == 0 {
                None
            } else {
                Some(tools.clone())
            };

            // Re-assemble the system prompt with the retry hint when we have
            // one, otherwise reuse the initial effective_system. The
            // assemble_with_hint path is only active when DB-backed hint
            // snippets exist; otherwise it's a cheap passthrough.
            let system_for_call = if tools_for_call.is_none() {
                prompt_assembler.assemble_no_tools_guard(effective_system.clone())
            } else if last_failed_tool.is_some() {
                prompt_assembler.assemble_with_hint(perception, last_failed_tool.as_deref())
            } else {
                effective_system.clone()
            };

            let response = self
                .provider
                .complete(
                    ctx.session.get_messages().to_vec(),
                    tools_for_call,
                    completion_cap,
                    system_for_call,
                )
                .await?;

            model_calls_count += 1;

            match response.stop_reason {
                StopReason::EndTurn => {
                    let text = response
                        .text
                        .clone()
                        .unwrap_or_else(|| "(No response from agent)".to_string());
                    let (plan_opt, thinking_opt, payload) =
                        thinking_strip::peel_plan_and_thinking_for_tools(&text);
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    if let Some(synthetic_calls) = parse_text_tool_calls(payload, &tools) {
                        if !synthetic_calls.is_empty() {
                            let outcome = tool_runner
                                .run_synthetic_batch(ctx, synthetic_calls, &mut tool_calls_count)
                                .await?;
                            last_failed_tool = outcome.last_failed_tool.clone();
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
                                    total_tool_calls: tool_calls_count,
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
                    crate::precision_controller::record_turn_metrics(
                        tool_calls_count,
                        0,
                        turn_duration_ms,
                    );

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
                        total_tool_calls: tool_calls_count,
                    });
                }
                StopReason::ToolUse => {
                    let text_content = response.text.clone().unwrap_or_default();
                    let (plan_opt, thinking_opt, payload) =
                        thinking_strip::peel_plan_and_thinking_for_tools(&text_content);
                    push_thinking_segment(&mut thinking_segments, plan_opt);
                    push_thinking_segment(&mut thinking_segments, thinking_opt);

                    if response.tool_calls.is_empty() {
                        let parse_src = if payload.is_empty() {
                            &text_content
                        } else {
                            payload
                        };
                        if let Some(synthetic_calls) = parse_text_tool_calls(parse_src, &tools) {
                            if !synthetic_calls.is_empty() {
                                let outcome = tool_runner
                                    .run_synthetic_batch(
                                        ctx,
                                        synthetic_calls,
                                        &mut tool_calls_count,
                                    )
                                    .await?;
                                last_failed_tool = outcome.last_failed_tool.clone();
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
                                        total_tool_calls: tool_calls_count,
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
                            last_failed_tool = outcome.last_failed_tool.clone();
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
                                    total_tool_calls: tool_calls_count,
                                });
                            }
                            continue;
                        }

                        let msg = crate::user_error_hints::append_agent_error_hints(
                            "Agent wanted tools but didn't specify any.",
                        );
                        ctx.send(AgentEvent::TurnError {
                            request_id: ctx.request_id.clone(),
                            error: msg.clone(),
                        });
                        return Ok(AgentRunOutcome {
                            reply: msg,
                            thinking_segments,
                            total_tool_calls: tool_calls_count,
                        });
                    }

                    let outcome = tool_runner
                        .run_native_batch(ctx, &response.tool_calls, &mut tool_calls_count)
                        .await?;
                    last_failed_tool = outcome.last_failed_tool.clone();
                    if let Some(err) = track_outcome(outcome, &mut consecutive_failed_batches) {
                        ctx.send(AgentEvent::TurnError {
                            request_id: ctx.request_id.clone(),
                            error: err.clone(),
                        });
                        return Ok(AgentRunOutcome {
                            reply: err,
                            thinking_segments,
                            total_tool_calls: tool_calls_count,
                        });
                    }
                    continue;
                }
                _ => {
                    let msg = crate::user_error_hints::append_agent_error_hints(&format!(
                        "Agent stopped with reason: {:?}",
                        response.stop_reason
                    ));
                    ctx.send(AgentEvent::TurnError {
                        request_id: ctx.request_id.clone(),
                        error: msg.clone(),
                    });
                    return Ok(AgentRunOutcome {
                        reply: msg,
                        thinking_segments,
                        total_tool_calls: tool_calls_count,
                    });
                }
            }
        }

        let msg = format!("Exceeded max iterations ({})", self.max_iterations);
        ctx.send(AgentEvent::TurnError {
            request_id: ctx.request_id.clone(),
            error: msg.clone(),
        });
        Ok(AgentRunOutcome {
            reply: msg,
            thinking_segments,
            total_tool_calls: tool_calls_count,
        })
    }
}

#[cfg(test)]
mod tests {
    //! Unit tests for the fail-storm circuit breaker. The `execute` method itself
    //! needs an integration harness (provider + ToolRunner + session), but the
    //! critical safety logic is extracted into `track_batch_outcome` so we can
    //! exercise the state machine directly.

    use super::*;

    fn ok_batch(n: usize) -> BatchOutcome {
        BatchOutcome {
            success_count: n,
            fail_count: 0,
            last_failed_tool: None,
        }
    }
    fn fail_batch(n: usize) -> BatchOutcome {
        BatchOutcome {
            success_count: 0,
            fail_count: n,
            last_failed_tool: None,
        }
    }
    fn mixed_batch(ok: usize, fail: usize) -> BatchOutcome {
        BatchOutcome {
            success_count: ok,
            fail_count: fail,
            last_failed_tool: None,
        }
    }

    #[test]
    fn no_trip_on_single_all_failed_batch() {
        let mut counter = 0u32;
        assert!(track_batch_outcome(fail_batch(2), &mut counter, 3).is_none());
        assert_eq!(counter, 1);
    }

    #[test]
    fn trips_on_reaching_threshold() {
        let mut counter = 0u32;
        assert!(track_batch_outcome(fail_batch(1), &mut counter, 3).is_none());
        assert!(track_batch_outcome(fail_batch(1), &mut counter, 3).is_none());
        let err = track_batch_outcome(fail_batch(1), &mut counter, 3);
        assert!(
            err.is_some(),
            "expected storm breaker to trip on 3rd all-fail batch"
        );
        let msg = err.unwrap();
        assert!(msg.contains("3 consecutive"), "msg: {}", msg);
        assert!(
            msg.contains("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS"),
            "msg: {}",
            msg
        );
    }

    #[test]
    fn success_resets_the_counter() {
        let mut counter = 0u32;
        track_batch_outcome(fail_batch(1), &mut counter, 3);
        track_batch_outcome(fail_batch(1), &mut counter, 3);
        assert_eq!(counter, 2);
        // A successful batch — even with one success — resets.
        track_batch_outcome(ok_batch(1), &mut counter, 3);
        assert_eq!(counter, 0, "any success in batch must reset counter");
        // Then another all-fail should not trip immediately.
        let err = track_batch_outcome(fail_batch(1), &mut counter, 3);
        assert!(err.is_none());
        assert_eq!(counter, 1);
    }

    #[test]
    fn mixed_batch_also_resets() {
        let mut counter = 2u32;
        // 1 success + 5 failures: NOT all_failed, so counter resets.
        track_batch_outcome(mixed_batch(1, 5), &mut counter, 3);
        assert_eq!(
            counter, 0,
            "mixed batch must reset — the model made progress"
        );
    }

    #[test]
    fn empty_batch_does_not_reset_or_trip() {
        let mut counter = 2u32;
        // Empty batch = no tool calls this iteration; not a signal either way.
        track_batch_outcome(BatchOutcome::default(), &mut counter, 3);
        assert_eq!(counter, 2, "empty batch must leave counter unchanged");
    }

    #[test]
    fn grammar_singular_vs_plural_in_error_msg() {
        let mut counter = 2u32;
        // 1 failure → "1 failure" (no s).
        let err = track_batch_outcome(fail_batch(1), &mut counter, 3);
        assert!(
            err.as_ref().unwrap().contains("1 failure)"),
            "msg: {:?}",
            err
        );

        let mut counter = 2u32;
        // 5 failures → "5 failures" (with s).
        let err = track_batch_outcome(fail_batch(5), &mut counter, 3);
        assert!(
            err.as_ref().unwrap().contains("5 failures)"),
            "msg: {:?}",
            err
        );
    }

    #[test]
    fn custom_threshold_of_one_trips_immediately() {
        let mut counter = 0u32;
        // CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=1 → any all-fail batch should trip.
        let err = track_batch_outcome(fail_batch(2), &mut counter, 1);
        assert!(err.is_some());
    }

    // The next 4 tests all touch the CHUMP_MAX_CONSECUTIVE_TOOL_FAILS env var
    // and must run serially — `cargo test` parallelizes by default and would
    // otherwise race on `std::env::set_var`.

    #[test]
    #[serial_test::serial]
    fn max_consecutive_tool_fails_defaults_when_unset() {
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
        assert_eq!(
            max_consecutive_tool_fails(),
            DEFAULT_MAX_CONSECUTIVE_TOOL_FAILS
        );
    }

    #[test]
    #[serial_test::serial]
    fn max_consecutive_tool_fails_rejects_zero() {
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "0");
        // Zero is filtered out; we fall back to the default to keep the
        // breaker armed even if someone misconfigures.
        assert_eq!(
            max_consecutive_tool_fails(),
            DEFAULT_MAX_CONSECUTIVE_TOOL_FAILS
        );
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
    }

    #[test]
    #[serial_test::serial]
    fn max_consecutive_tool_fails_rejects_nonnumeric() {
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "not-a-number");
        assert_eq!(
            max_consecutive_tool_fails(),
            DEFAULT_MAX_CONSECUTIVE_TOOL_FAILS
        );
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
    }

    #[test]
    #[serial_test::serial]
    fn max_consecutive_tool_fails_honors_valid_override() {
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "7");
        assert_eq!(max_consecutive_tool_fails(), 7);
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
    }
}
