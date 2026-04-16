use crate::perception::PerceivedInput;

pub struct PerceptionLayer;

impl PerceptionLayer {
    pub fn perceive(&self, user_prompt: &str, needs_tools_hint: bool) -> PerceivedInput {
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
                format!("Risk indicators in user input: {}", perception.risk_indicators.join(", ")),
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
