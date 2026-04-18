use crate::perception::{PerceivedInput, TaskType};

pub struct PerceptionLayer;

/// COG-005 gate: when `CHUMP_PERCEPTION_ENABLED=0|false|off`, return a
/// minimal "empty" PerceivedInput that downstream consumers treat as
/// no-signal. The full perception pipeline (entity extraction, ambiguity
/// scoring, blackboard posts) is bypassed. Used by the perception A/B
/// harness to compare with-vs-without-perception task success.
pub fn perception_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_PERCEPTION_ENABLED").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

fn empty_perception(text: &str) -> PerceivedInput {
    PerceivedInput {
        raw_text: text.to_string(),
        likely_needs_tools: false,
        detected_entities: vec![],
        detected_constraints: vec![],
        ambiguity_level: 0.0,
        risk_indicators: vec![],
        question_count: 0,
        task_type: TaskType::Unclear,
    }
}

impl PerceptionLayer {
    pub fn perceive(&self, user_prompt: &str, needs_tools_hint: bool) -> PerceivedInput {
        if !perception_enabled() {
            // A/B-disable path: emit an empty perception so downstream
            // (PromptAssembler, belief_state, blackboard) sees no signal.
            return empty_perception(user_prompt);
        }
        let perception = crate::perception::perceive(user_prompt, needs_tools_hint);
        tracing::debug!(
            task_type = %perception.task_type,
            ambiguity = perception.ambiguity_level,
            entities = perception.detected_entities.len(),
            risks = perception.risk_indicators.len(),
            "perceived input"
        );

        // Feed high ambiguity into belief state trajectory confidence
        if perception.ambiguity_level > 0.7 {
            crate::belief_state::nudge_trajectory(-(perception.ambiguity_level as f64) * 0.2);
        }

        // Post risk indicators to blackboard for downstream awareness
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

        perception
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial(perception_env)]
    fn perception_enabled_default_on() {
        std::env::remove_var("CHUMP_PERCEPTION_ENABLED");
        assert!(perception_enabled());
    }

    #[test]
    #[serial(perception_env)]
    fn perception_enabled_off_via_env() {
        for v in ["0", "false", "off"] {
            std::env::set_var("CHUMP_PERCEPTION_ENABLED", v);
            assert!(!perception_enabled(), "expected off for {v}");
        }
        std::env::remove_var("CHUMP_PERCEPTION_ENABLED");
    }

    #[test]
    #[serial(perception_env)]
    fn perception_disabled_returns_empty() {
        std::env::set_var("CHUMP_PERCEPTION_ENABLED", "0");
        let layer = PerceptionLayer;
        // Use a prompt that would normally produce non-trivial perception.
        let p = layer.perceive("Patch src/foo.rs to fix the URGENT BUG", true);
        assert!(p.detected_entities.is_empty());
        assert!(p.detected_constraints.is_empty());
        assert!(p.risk_indicators.is_empty());
        assert_eq!(p.ambiguity_level, 0.0);
        assert_eq!(p.task_type, TaskType::Unclear);
        std::env::remove_var("CHUMP_PERCEPTION_ENABLED");
    }
}
