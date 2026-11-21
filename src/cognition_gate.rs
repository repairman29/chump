//! Compile-time (`--features experimental-cognition`) and runtime
//! (`CHUMP_COGNITION_ENABLED=1|0`) gate for experimental Synthetic Consciousness
//! hooks inside `agent_loop`.
//!
//! All cognitive modules (`blackboard`, `precision_controller`, `phi_proxy`,
//! `neuromodulation`, `belief_state`, `counterfactual`, `consciousness_traits`)
//! remain 100% compiled and unit-tested in every build. By default (when the
//! `experimental-cognition` Cargo feature is disabled and `CHUMP_COGNITION_ENABLED`
//! is unset), `agent_loop` invokes deterministic, zero-surprisal no-op hooks here
//! so core turn execution is never coupled to experimental consciousness state.

use axonerai::provider::ToolCall;

use crate::perception::PerceivedInput;

/// Returns `true` when experimental cognition hooks should run inside `agent_loop`.
///
/// Precedence:
/// 1. Runtime env override `CHUMP_COGNITION_ENABLED`:
///    - `"1" | "true" | "on" | "yes"` (case-insensitive) -> `true`
///    - `"0" | "false" | "off" | "no"` (case-insensitive) -> `false`
/// 2. Compile-time Cargo feature `cfg!(feature = "experimental-cognition")`.
pub fn cognition_enabled() -> bool {
    if let Ok(raw) = std::env::var("CHUMP_COGNITION_ENABLED") {
        let trimmed = raw.trim();
        if trimmed.eq_ignore_ascii_case("1")
            || trimmed.eq_ignore_ascii_case("true")
            || trimmed.eq_ignore_ascii_case("on")
            || trimmed.eq_ignore_ascii_case("yes")
        {
            return true;
        }
        if trimmed.eq_ignore_ascii_case("0")
            || trimmed.eq_ignore_ascii_case("false")
            || trimmed.eq_ignore_ascii_case("off")
            || trimmed.eq_ignore_ascii_case("no")
        {
            return false;
        }
    }
    cfg!(feature = "experimental-cognition")
}

/// Perception-stage hook (`perception_layer.rs`): feed ambiguity into belief
/// trajectory and post risk indicators to the global workspace when enabled.
pub fn on_perceived_input(perception: &PerceivedInput) {
    if !cognition_enabled() {
        return;
    }

    if perception.ambiguity_level > 0.7 {
        crate::belief_state::nudge_trajectory(-(perception.ambiguity_level as f64) * 0.2);
    }

    if !perception.risk_indicators.is_empty() {
        crate::blackboard::post(
            crate::blackboard::Module::Custom("perception".into()),
            format!(
                "Risk indicators in user input: {}",
                perception.risk_indicators.join(", ")
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.6,
                uncertainty_reduction: 0.3,
                goal_relevance: 0.8,
                urgency: 0.5,
            },
        );
    }
}

/// Tool-ordering hook (`types.rs::efe_order_tool_calls`): reorder tool calls by
/// Expected Free Energy (`belief_state` + `precision_controller` epsilon-greedy)
/// when cognition is enabled; otherwise preserve the model's deterministic call order.
pub fn order_tool_calls_efe(calls: &[ToolCall]) -> Vec<ToolCall> {
    if !cognition_enabled() {
        return calls.to_vec();
    }

    let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
    let scores = crate::belief_state::score_tools(&names);
    if scores.is_empty() {
        return calls.to_vec();
    }
    let mut ordered: Vec<ToolCall> = scores
        .iter()
        .filter_map(|s| calls.iter().find(|c| c.name == s.tool_name))
        .cloned()
        .collect();
    if ordered.len() > 1 {
        let selected = crate::precision_controller::epsilon_greedy_select(ordered.len());
        if selected != 0 {
            ordered.swap(0, selected);
        }
    }
    ordered
}

/// Per-tool outcome hook (`tool_runner.rs`): update tool reliability belief.
pub fn record_tool_outcome(tool_name: &str, ok: bool, duration_ms: u64) {
    if !cognition_enabled() {
        return;
    }
    crate::belief_state::update_tool_belief(tool_name, ok, duration_ms);
}

/// Post-synthetic-batch hook (`tool_runner.rs`): check epistemic escalation.
pub fn after_synthetic_batch() {
    if !cognition_enabled() {
        return;
    }
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
}

/// Post-native-batch hook (`tool_runner.rs`): update neuromodulation, precision
/// regime, and epistemic escalation.
pub fn after_native_batch() {
    if !cognition_enabled() {
        return;
    }
    let sub = crate::consciousness_traits::substrate();
    sub.neuromod.update_from_turn();
    crate::precision_controller::check_regime_change();

    if sub.belief.should_escalate() {
        crate::blackboard::post(
            crate::blackboard::Module::Custom("belief_state".to_string()),
            format!(
                "Epistemic uncertainty is critically high (task uncertainty={:.2}). \
                 Consider asking the user to clarify the goal or confirm the approach before continuing.",
                sub.belief.task_uncertainty()
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.7,
                uncertainty_reduction: 0.8,
                goal_relevance: 0.9,
                urgency: 0.8,
            },
        );
    }
}

/// Post-schema-failure hook (`tool_runner.rs`): update neuromodulation on schema error.
pub fn after_schema_failure_batch() {
    if !cognition_enabled() {
        return;
    }
    let sub = crate::consciousness_traits::substrate();
    sub.neuromod.update_from_turn();
}

/// Speculative-execution rollback hook (`tool_runner.rs`): post rollback notice to blackboard.
pub fn on_speculative_rollback(count: u32, failures: &[String]) {
    if !cognition_enabled() {
        return;
    }
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
}

/// Iteration-start hook (`iteration_controller.rs`): decay per-turn belief state.
pub fn on_iteration_start() {
    if !cognition_enabled() {
        return;
    }
    crate::belief_state::decay_turn();
}

/// Turn-completion hook (`iteration_controller.rs`): record precision turn metrics.
pub fn on_turn_complete(tool_calls_count: u32, turn_duration_ms: u64) {
    if !cognition_enabled() {
        return;
    }
    crate::precision_controller::record_turn_metrics(tool_calls_count, 0, turn_duration_ms);
}

/// System-prompt assembly hook (`prompt_assembler.rs`): prefetch persisted
/// entity-keyed blackboard entries when cognition is enabled.
pub fn prefetch_blackboard_entities(detected_entities: &[String]) -> Option<String> {
    if !cognition_enabled() {
        return None;
    }
    if !crate::env_flags::chump_bypass_blackboard()
        && crate::blackboard::entity_prefetch_enabled()
        && !detected_entities.is_empty()
    {
        crate::blackboard::query_persist_for_entities(
            detected_entities,
            crate::blackboard::ENTITY_PREFETCH_MAX_ENTRIES,
            crate::blackboard::ENTITY_PREFETCH_MAX_CHARS,
        )
    } else {
        None
    }
}

/// End-of-turn skill-capture suggestion hook (`orchestrator.rs`).
pub fn post_skill_suggestion(total_tool_calls: u32, threshold: u32) {
    if !cognition_enabled() {
        return;
    }
    let msg = format!(
        "This turn used {} tool calls — consider capturing the workflow as a reusable skill \
         via skill_manage(action=create, name=<kebab-name>, description=<one line>, content=<SKILL.md body>). \
         Skills help Chump repeat successful patterns without re-deriving them each time.",
        total_tool_calls
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
        tool_calls = total_tool_calls,
        threshold,
        "skill suggestion posted to blackboard"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::perception::TaskType;
    use serde_json::json;
    use serial_test::serial;

    #[test]
    #[serial(cognition_gate_env)]
    fn default_matches_compile_time_feature() {
        std::env::remove_var("CHUMP_COGNITION_ENABLED");
        assert_eq!(
            cognition_enabled(),
            cfg!(feature = "experimental-cognition")
        );
    }

    #[test]
    #[serial(cognition_gate_env)]
    fn runtime_env_overrides_both_directions() {
        for v in ["1", "true", "TRUE", "on", "yes"] {
            std::env::set_var("CHUMP_COGNITION_ENABLED", v);
            assert!(cognition_enabled(), "expected enabled for {v}");
        }
        for v in ["0", "false", "FALSE", "off", "no"] {
            std::env::set_var("CHUMP_COGNITION_ENABLED", v);
            assert!(!cognition_enabled(), "expected disabled for {v}");
        }
        std::env::remove_var("CHUMP_COGNITION_ENABLED");
    }

    #[test]
    #[serial(cognition_gate_env)]
    fn disabled_hooks_are_deterministic_noops() {
        std::env::set_var("CHUMP_COGNITION_ENABLED", "0");

        let calls = vec![
            ToolCall {
                id: "1".to_string(),
                name: "write_file".to_string(),
                input: json!({}),
            },
            ToolCall {
                id: "2".to_string(),
                name: "read_file".to_string(),
                input: json!({}),
            },
        ];
        let ordered = order_tool_calls_efe(&calls);
        assert_eq!(ordered[0].name, "write_file");
        assert_eq!(ordered[1].name, "read_file");

        let p = PerceivedInput {
            raw_text: "DROP TABLE users".to_string(),
            likely_needs_tools: true,
            detected_entities: vec!["users".to_string()],
            detected_constraints: vec![],
            ambiguity_level: 0.95,
            risk_indicators: vec!["drop".to_string()],
            question_count: 0,
            task_type: TaskType::Action,
        };
        let marker = format!("cognition-gate-noop-{}", uuid::Uuid::new_v4());
        let mut p_unique = p;
        p_unique.risk_indicators = vec![marker.clone()];
        on_perceived_input(&p_unique);
        let ctx = crate::blackboard::broadcast_context(50, 10_000);
        assert!(
            !ctx.contains(&marker),
            "disabled cognition gate must not post to blackboard"
        );
        assert!(prefetch_blackboard_entities(&["users".to_string()]).is_none());

        on_iteration_start();
        record_tool_outcome("read_file", true, 5);
        after_synthetic_batch();
        after_native_batch();
        after_schema_failure_batch();
        on_speculative_rollback(3, &["write_file".to_string()]);
        on_turn_complete(2, 50);
        post_skill_suggestion(10, 5);

        std::env::remove_var("CHUMP_COGNITION_ENABLED");
    }

    #[test]
    #[serial(cognition_gate_env)]
    fn enabled_hook_posts_risk_indicator_to_blackboard() {
        std::env::set_var("CHUMP_COGNITION_ENABLED", "1");
        let marker = format!("cognition-gate-live-{}", uuid::Uuid::new_v4());
        let p = PerceivedInput {
            raw_text: "delete cluster".to_string(),
            likely_needs_tools: true,
            detected_entities: vec![],
            detected_constraints: vec![],
            ambiguity_level: 0.8,
            risk_indicators: vec![marker.clone()],
            question_count: 0,
            task_type: TaskType::Action,
        };
        on_perceived_input(&p);
        let entries = crate::blackboard::global().read_from(
            crate::blackboard::Module::Brain,
            &crate::blackboard::Module::Custom("perception".into()),
        );
        assert!(
            entries.iter().any(|e| e.content.contains(&marker)),
            "enabled cognition gate must post risk indicator to blackboard"
        );
        std::env::remove_var("CHUMP_COGNITION_ENABLED");
    }
}
