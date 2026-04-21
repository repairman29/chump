use crate::agent_loop::{
    efe_order_tool_calls, format_tool_results, format_tool_use, is_failed_tool_result,
    speculative_batch_enabled, AgentEvent, AgentLoopContext, BatchOutcome,
};
use anyhow::Result;
use axonerai::executor::ToolExecutor;
use axonerai::provider::{Message, ToolCall};
use axonerai::tool::ToolRegistry;
use std::sync::Arc;
use std::time::Instant;

pub struct ToolRunner<'a> {
    pub executor: &'a ToolExecutor<'a>,
    pub registry: &'a ToolRegistry,
    pub task_executor: Arc<dyn crate::task_executor::TaskExecutor + Send + Sync>,
}

impl<'a> ToolRunner<'a> {
    /// Take `&mut ctx` rather than `(&ctx, &mut ctx.session)` so the borrow
    /// checker doesn't see two simultaneous borrows. Internal destructuring
    /// (or sequential reads) splits the fields cleanly.
    ///
    /// Returns the batch's success/failure breakdown so the iteration
    /// controller can detect "fast-failing tool" storms (every call in the
    /// batch returned an error).
    pub async fn run_synthetic_batch(
        &self,
        ctx: &mut AgentLoopContext,
        synthetic_calls: Vec<ToolCall>,
        tool_calls_count: &mut u32,
    ) -> Result<BatchOutcome> {
        ctx.send(AgentEvent::TextComplete {
            text: String::new(),
        });
        for tc in &synthetic_calls {
            ctx.send(AgentEvent::ToolCallStart {
                tool_name: tc.name.clone(),
                tool_input: tc.input.clone(),
                call_id: tc.id.clone(),
            });
        }
        let exec_start = Instant::now();
        let tool_results = self
            .task_executor
            .execute_all(ctx.event_tx.as_ref(), self.executor, &synthetic_calls)
            .await?;
        let total_exec_ms = exec_start.elapsed().as_millis() as u64;
        *tool_calls_count += tool_results.len() as u32;

        let mut outcome = BatchOutcome::default();
        for tr in &tool_results {
            let failed = is_failed_tool_result(&tr.result);
            if failed {
                outcome.fail_count += 1;
                // COG-009b: track the last-failed tool name so the next
                // iteration's prompt assembly can call out "hey, you just
                // errored on X — consider reading before retrying."
                outcome.last_failed_tool = Some(tr.tool_name.clone());
            } else {
                outcome.success_count += 1;
            }
            ctx.send(AgentEvent::ToolCallResult {
                call_id: tr.tool_call_id.clone(),
                tool_name: tr.tool_name.clone(),
                result: tr.result.clone(),
                duration_ms: total_exec_ms / tool_results.len().max(1) as u64,
                success: !failed,
            });
        }

        ctx.session.add_message(Message {
            role: "assistant".to_string(),
            content: format_tool_use(&synthetic_calls),
        });
        ctx.session.add_message(Message {
            role: "user".to_string(),
            content: format_tool_results(&tool_results),
        });

        let sub = crate::consciousness_traits::substrate();
        if sub.belief.should_escalate() {
            crate::blackboard::post(
                crate::blackboard::Module::Custom("belief_state".to_string()),
                "Epistemic uncertainty is critically high after synthetic tool calls. \
                 Consider asking the user for guidance."
                    .to_string(),
                crate::blackboard::SalienceFactors {
                    novelty: 0.7,
                    uncertainty_reduction: 0.8,
                    goal_relevance: 0.9,
                    urgency: 0.8,
                },
            );
        }
        Ok(outcome)
    }

    pub async fn run_native_batch(
        &self,
        ctx: &mut AgentLoopContext,
        tool_calls: &[ToolCall],
        tool_calls_count: &mut u32,
    ) -> Result<BatchOutcome> {
        for tc in tool_calls {
            ctx.send(AgentEvent::ToolCallStart {
                tool_name: tc.name.clone(),
                tool_input: tc.input.clone(),
                call_id: tc.id.clone(),
            });
        }

        let schema_failures = crate::tool_input_schema_validate::collect_schema_validation_failures(
            self.registry,
            tool_calls,
        );

        if !schema_failures.is_empty() {
            let n_failed = schema_failures.len();
            // COG-009b: schema-failed tool name is the last one in the batch
            // that didn't pass pre-flight validation. Hand it to the retry
            // prompt so the model knows which call shape to fix.
            let last_failed_tool = tool_calls.last().map(|tc| tc.name.clone());
            self.handle_schema_failures(ctx, tool_calls, schema_failures, tool_calls_count);
            // Schema failures count as fast-fails (synthetic, sub-millisecond).
            return Ok(BatchOutcome {
                success_count: 0,
                fail_count: n_failed,
                last_failed_tool,
            });
        }

        let ordered_tool_calls = efe_order_tool_calls(tool_calls);
        let use_speculative = speculative_batch_enabled() && ordered_tool_calls.len() >= 3;
        let spec_snapshot = if use_speculative {
            Some(crate::speculative_execution::fork())
        } else {
            None
        };

        let exec_start = Instant::now();
        let tool_results = self
            .task_executor
            .execute_all(ctx.event_tx.as_ref(), self.executor, &ordered_tool_calls)
            .await?;
        let total_exec_ms = exec_start.elapsed().as_millis() as u64;
        *tool_calls_count += tool_results.len() as u32;

        let mut spec_failures = Vec::new();
        for (idx, tr) in tool_results.iter().enumerate() {
            let tc = &ordered_tool_calls[idx];
            let ok = !tr.result.starts_with("DENIED:") && !tr.result.starts_with("Tool error:");
            if !ok {
                spec_failures.push(tr.tool_name.clone());
            }

            let per_tool_ms = total_exec_ms / tool_results.len().max(1) as u64;
            crate::belief_state::update_tool_belief(&tc.name, ok, per_tool_ms);

            ctx.send(AgentEvent::ToolCallResult {
                call_id: tr.tool_call_id.clone(),
                tool_name: tr.tool_name.clone(),
                result: tr.result.clone(),
                duration_ms: per_tool_ms,
                success: ok,
            });

            if let Some(verification) = crate::tool_middleware::take_last_verification() {
                ctx.send(AgentEvent::ToolVerificationResult {
                    call_id: tr.tool_call_id.clone(),
                    tool_name: tr.tool_name.clone(),
                    verified: verification.verified,
                    detail: format!(
                        "{:?}: {}",
                        verification.actual_outcome, verification.proposed_action
                    ),
                });
            }
        }

        if let Some(snapshot) = spec_snapshot {
            // INFRA-001a-wire: capture write-tool calls that succeeded inside
            // the spec batch BEFORE rollback decision so we can count them
            // (their FS / network side effects won't be undone).
            let succeeded_writes: Vec<String> = tool_results
                .iter()
                .filter(|tr| {
                    !tr.result.starts_with("DENIED:") && !tr.result.starts_with("Tool error:")
                })
                .filter(|tr| crate::tool_middleware::is_write_tool(&tr.tool_name))
                .map(|tr| tr.tool_name.clone())
                .collect();
            // handle_speculative_resolution will commit-or-rollback; if it
            // rolls back, the writes above are unrolled. Bump the counter
            // and surface via tracing::warn for each.
            let pre_resolution = !spec_failures.is_empty();
            self.handle_speculative_resolution(snapshot, tool_results.len() as u32, &spec_failures);
            if pre_resolution {
                // Failures present → handle_speculative_resolution chose
                // rollback (mirror its conditional). Count the writes.
                for tn in &succeeded_writes {
                    crate::speculative_execution::record_unrolled_side_effect(tn);
                }
            }
        }

        ctx.session.add_message(Message {
            role: "assistant".to_string(),
            content: format_tool_use(&ordered_tool_calls),
        });

        // Strict failure count for the verify-prompt + BatchOutcome accounting:
        // matches what `is_failed_tool_result` considers a real tool failure
        // (DENIED:/Tool error:). Note: the verify message also surfaces empty
        // results and "not found" content for the model's benefit, but those
        // don't count toward the consecutive-fail breaker — only hard tool
        // errors do.
        let strict_fail_count = tool_results
            .iter()
            .filter(|tr| is_failed_tool_result(&tr.result))
            .count();
        let lenient_fail_count = tool_results
            .iter()
            .filter(|tr| {
                is_failed_tool_result(&tr.result)
                    || tr.result.contains("not found")
                    || tr.result.is_empty()
            })
            .count();

        let results_content = if lenient_fail_count > 0 {
            format!(
                "{}\n\n[VERIFY] {} of {} tool call(s) had errors. Review the results above and retry with corrected parameters if needed.",
                format_tool_results(&tool_results),
                lenient_fail_count,
                tool_results.len()
            )
        } else {
            format_tool_results(&tool_results)
        };

        ctx.session.add_message(Message {
            role: "user".to_string(),
            content: results_content,
        });

        let sub = crate::consciousness_traits::substrate();
        sub.neuromod.update_from_turn();
        crate::precision_controller::check_regime_change();

        if sub.belief.should_escalate() {
            crate::blackboard::post(
                crate::blackboard::Module::Custom("belief_state".to_string()),
                format!("Epistemic uncertainty is critically high (task uncertainty={:.2}). Consider asking the user to clarify the goal or confirm the approach before continuing.", sub.belief.task_uncertainty()),
                crate::blackboard::SalienceFactors { novelty: 0.7, uncertainty_reduction: 0.8, goal_relevance: 0.9, urgency: 0.8 },
            );
        }

        // COG-009b: walk tool_results in reverse to find the last failed
        // tool name for the retry hint.
        let last_failed_tool = tool_results
            .iter()
            .rev()
            .find(|tr| is_failed_tool_result(&tr.result))
            .map(|tr| tr.tool_name.clone());

        Ok(BatchOutcome {
            success_count: tool_results.len() - strict_fail_count,
            fail_count: strict_fail_count,
            last_failed_tool,
        })
    }

    fn handle_schema_failures(
        &self,
        ctx: &mut AgentLoopContext,
        tool_calls: &[ToolCall],
        schema_failures: Vec<(usize, String)>,
        tool_calls_count: &mut u32,
    ) {
        tracing::warn!(
            count = schema_failures.len(),
            "schema pre-flight: tool executor skipped"
        );
        let tool_results =
            crate::tool_input_schema_validate::synthetic_tool_results_for_schema_failures(
                tool_calls,
                &schema_failures,
            );
        *tool_calls_count += tool_results.len() as u32;

        for tr in &tool_results {
            ctx.send(AgentEvent::ToolCallResult {
                call_id: tr.tool_call_id.clone(),
                tool_name: tr.tool_name.clone(),
                result: tr.result.clone(),
                duration_ms: 0,
                success: false,
            });
        }
        ctx.session.add_message(Message {
            role: "assistant".to_string(),
            content: format_tool_use(tool_calls),
        });
        ctx.session.add_message(Message {
            role: "user".to_string(),
            content: format_tool_results(&tool_results),
        });
        let sub = crate::consciousness_traits::substrate();
        sub.neuromod.update_from_turn();
    }

    fn handle_speculative_resolution(
        &self,
        snapshot: crate::speculative_execution::Snapshot,
        count: u32,
        failures: &[String],
    ) {
        let result = crate::speculative_execution::evaluate(&snapshot, count, failures);
        let resolution = if result.success {
            crate::speculative_execution::commit(snapshot);
            crate::speculative_execution::Resolution::Committed
        } else {
            crate::speculative_execution::rollback(snapshot);
            crate::blackboard::post(
                crate::blackboard::Module::Custom("speculative_execution".to_string()),
                format!(
                    "Multi-tool plan rolled back ({} failures out of {} tools).",
                    failures.len(),
                    count
                ),
                crate::blackboard::SalienceFactors {
                    novelty: 0.8,
                    uncertainty_reduction: 0.7,
                    goal_relevance: 0.9,
                    urgency: 0.7,
                },
            );
            crate::speculative_execution::Resolution::RolledBack
        };
        crate::speculative_execution::record_last_speculative_batch(resolution, result);
    }
}
