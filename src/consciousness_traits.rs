//! Trait-based interfaces for all consciousness modules.
//!
//! Ensures every module exposes a stable, substrate-agnostic interface that
//! could be backed by an alternative implementation (e.g., hardware accelerator,
//! distributed runtime, neuromorphic chip).
//!
//! The concrete singleton implementations remain in their respective modules;
//! these traits define the contract.
//!
//! Part of the Synthetic Consciousness Framework, Section 3.7 (Abstraction Audit).

use std::collections::HashMap;

// ---------- 1. Surprise Tracking ----------

/// Source of surprise / prediction error signals.
pub trait SurpriseSource: Send + Sync {
    fn record(&self, tool_name: &str, outcome: &str, latency_ms: u64, expected_latency_ms: u64);
    fn current_ema(&self) -> f64;
    fn total_predictions(&self) -> u64;
    fn summary(&self) -> String;
}

/// Default implementation backed by the global surprise_tracker.
pub struct DefaultSurpriseSource;

impl SurpriseSource for DefaultSurpriseSource {
    fn record(&self, tool_name: &str, outcome: &str, latency_ms: u64, expected_latency_ms: u64) {
        crate::surprise_tracker::record_prediction(
            tool_name,
            outcome,
            latency_ms,
            expected_latency_ms,
        );
    }
    fn current_ema(&self) -> f64 {
        crate::surprise_tracker::current_surprisal_ema()
    }
    fn total_predictions(&self) -> u64 {
        crate::surprise_tracker::total_predictions()
    }
    fn summary(&self) -> String {
        crate::surprise_tracker::summary()
    }
}

// ---------- 2. Belief State ----------

/// Maintains per-tool confidence and task-level uncertainty.
pub trait BeliefTracker: Send + Sync {
    fn update_tool(&self, tool_name: &str, success: bool, latency_ms: u64);
    fn decay_turn(&self);
    fn task_uncertainty(&self) -> f64;
    fn tool_reliability(&self, tool_name: &str) -> Option<f64>;
    fn should_escalate(&self) -> bool;
    fn context_summary(&self) -> String;
}

pub struct DefaultBeliefTracker;

impl BeliefTracker for DefaultBeliefTracker {
    fn update_tool(&self, tool_name: &str, success: bool, latency_ms: u64) {
        crate::belief_state::update_tool_belief(tool_name, success, latency_ms);
    }
    fn decay_turn(&self) {
        crate::belief_state::decay_turn();
    }
    fn task_uncertainty(&self) -> f64 {
        crate::belief_state::task_belief().uncertainty()
    }
    fn tool_reliability(&self, tool_name: &str) -> Option<f64> {
        crate::belief_state::tool_belief(tool_name).map(|b| b.reliability())
    }
    fn should_escalate(&self) -> bool {
        crate::belief_state::should_escalate_epistemic()
    }
    fn context_summary(&self) -> String {
        crate::belief_state::context_summary()
    }
}

// ---------- 3. Precision Control ----------

/// Controls exploration/exploitation trade-off and energy budget.
pub trait PrecisionPolicy: Send + Sync {
    fn current_regime(&self) -> String;
    fn recommended_max_tool_calls(&self) -> u32;
    fn exploration_epsilon(&self) -> f64;
    fn token_budget_remaining(&self) -> f64;
    fn budget_critical(&self) -> bool;
    fn summary(&self) -> String;
}

pub struct DefaultPrecisionPolicy;

impl PrecisionPolicy for DefaultPrecisionPolicy {
    fn current_regime(&self) -> String {
        crate::precision_controller::current_regime().to_string()
    }
    fn recommended_max_tool_calls(&self) -> u32 {
        crate::precision_controller::recommended_max_tool_calls()
    }
    fn exploration_epsilon(&self) -> f64 {
        crate::precision_controller::exploration_epsilon()
    }
    fn token_budget_remaining(&self) -> f64 {
        crate::precision_controller::token_budget_remaining()
    }
    fn budget_critical(&self) -> bool {
        crate::precision_controller::budget_critical()
    }
    fn summary(&self) -> String {
        crate::precision_controller::summary()
    }
}

// ---------- 4. Global Workspace ----------

/// Shared workspace for inter-module coordination (GWT).
pub trait GlobalWorkspace: Send + Sync {
    fn post(&self, source: &str, content: String, salience: f64) -> u64;
    fn broadcast_context(&self, max_entries: usize, max_chars: usize) -> String;
    fn entry_count(&self) -> usize;
}

pub struct DefaultGlobalWorkspace;

impl GlobalWorkspace for DefaultGlobalWorkspace {
    fn post(&self, source: &str, content: String, salience: f64) -> u64 {
        let module = match source {
            "memory" => crate::blackboard::Module::Memory,
            "episode" => crate::blackboard::Module::Episode,
            "task" => crate::blackboard::Module::Task,
            "tool_middleware" => crate::blackboard::Module::ToolMiddleware,
            "surprise_tracker" => crate::blackboard::Module::SurpriseTracker,
            "provider" => crate::blackboard::Module::Provider,
            "brain" => crate::blackboard::Module::Brain,
            "autonomy" => crate::blackboard::Module::Autonomy,
            other => crate::blackboard::Module::Custom(other.to_string()),
        };
        let factors = crate::blackboard::SalienceFactors {
            novelty: salience,
            uncertainty_reduction: 0.5,
            goal_relevance: salience,
            urgency: 0.5,
        };
        crate::blackboard::post(module, content, factors)
    }

    fn broadcast_context(&self, max_entries: usize, max_chars: usize) -> String {
        crate::blackboard::broadcast_context(max_entries, max_chars)
    }

    fn entry_count(&self) -> usize {
        crate::blackboard::global().entry_count()
    }
}

// ---------- 5. Integration Metric ----------

/// Measures the integration (coupling) between consciousness modules.
pub trait IntegrationMetric: Send + Sync {
    fn compute_phi(&self) -> f64;
    fn summary(&self) -> String;
    fn metrics_json(&self) -> serde_json::Value;
}

pub struct DefaultIntegrationMetric;

impl IntegrationMetric for DefaultIntegrationMetric {
    fn compute_phi(&self) -> f64 {
        crate::phi_proxy::compute_phi().phi_proxy
    }
    fn summary(&self) -> String {
        crate::phi_proxy::summary()
    }
    fn metrics_json(&self) -> serde_json::Value {
        crate::phi_proxy::metrics_json()
    }
}

// ---------- 6. Causal Reasoning ----------

/// Stores and retrieves causal lessons from counterfactual analysis.
pub trait CausalReasoner: Send + Sync {
    fn store_lesson(
        &self,
        episode_id: Option<i64>,
        task_type: Option<&str>,
        action_taken: &str,
        alternative: Option<&str>,
        lesson: &str,
        confidence: f64,
    ) -> anyhow::Result<i64>;
    fn find_relevant(
        &self,
        task_type: Option<&str>,
        keywords: &[&str],
        limit: usize,
    ) -> anyhow::Result<Vec<String>>;
    fn lesson_count(&self) -> anyhow::Result<i64>;
}

pub struct DefaultCausalReasoner;

impl CausalReasoner for DefaultCausalReasoner {
    fn store_lesson(
        &self,
        episode_id: Option<i64>,
        task_type: Option<&str>,
        action_taken: &str,
        alternative: Option<&str>,
        lesson: &str,
        confidence: f64,
    ) -> anyhow::Result<i64> {
        crate::counterfactual::store_lesson(
            episode_id,
            task_type,
            action_taken,
            alternative,
            lesson,
            confidence,
        )
    }

    fn find_relevant(
        &self,
        task_type: Option<&str>,
        keywords: &[&str],
        limit: usize,
    ) -> anyhow::Result<Vec<String>> {
        let lessons = crate::counterfactual::find_relevant_lessons(task_type, keywords, limit)?;
        Ok(lessons.iter().map(|l| l.lesson.clone()).collect())
    }

    fn lesson_count(&self) -> anyhow::Result<i64> {
        crate::counterfactual::lesson_count()
    }
}

// ---------- 7. Associative Memory ----------

/// HippoRAG-inspired memory graph for associative recall.
pub trait AssociativeMemory: Send + Sync {
    fn store_triples(&self, triples: &[(String, String, String)]) -> anyhow::Result<usize>;
    fn recall(
        &self,
        seed_entities: &[String],
        max_hops: usize,
        top_k: usize,
    ) -> anyhow::Result<Vec<(String, f64)>>;
    fn entity_gist(&self, entity: &str) -> anyhow::Result<String>;
    fn triple_count(&self) -> anyhow::Result<i64>;
}

pub struct DefaultAssociativeMemory;

impl AssociativeMemory for DefaultAssociativeMemory {
    fn store_triples(&self, triples: &[(String, String, String)]) -> anyhow::Result<usize> {
        crate::memory_graph::store_triples(triples, None, None)
    }
    fn recall(
        &self,
        seed_entities: &[String],
        max_hops: usize,
        top_k: usize,
    ) -> anyhow::Result<Vec<(String, f64)>> {
        crate::memory_graph::associative_recall(seed_entities, max_hops, top_k)
    }
    fn entity_gist(&self, entity: &str) -> anyhow::Result<String> {
        crate::memory_graph::entity_gist(entity)
    }
    fn triple_count(&self) -> anyhow::Result<i64> {
        crate::memory_graph::triple_count()
    }
}

// ---------- 8. Neuromodulation ----------

/// System-wide chemical meta-parameters.
pub trait Neuromodulator: Send + Sync {
    fn dopamine(&self) -> f64;
    fn noradrenaline(&self) -> f64;
    fn serotonin(&self) -> f64;
    fn update_from_turn(&self);
    fn reset(&self);
    fn context_summary(&self) -> String;
}

pub struct DefaultNeuromodulator;

impl Neuromodulator for DefaultNeuromodulator {
    fn dopamine(&self) -> f64 {
        crate::neuromodulation::levels().dopamine
    }
    fn noradrenaline(&self) -> f64 {
        crate::neuromodulation::levels().noradrenaline
    }
    fn serotonin(&self) -> f64 {
        crate::neuromodulation::levels().serotonin
    }
    fn update_from_turn(&self) {
        crate::neuromodulation::update_from_turn();
    }
    fn reset(&self) {
        crate::neuromodulation::reset();
    }
    fn context_summary(&self) -> String {
        crate::neuromodulation::context_summary()
    }
}

// ---------- 9. Holographic Workspace ----------

/// Distributed HRR-encoded workspace.
pub trait HolographicStore: Send + Sync {
    fn encode(&self, source: &str, id: u64, content: &str);
    fn query(&self, probe: &str) -> (f64, bool);
    fn capacity(&self) -> (usize, usize);
    fn sync_from_blackboard(&self);
}

pub struct DefaultHolographicStore;

impl HolographicStore for DefaultHolographicStore {
    fn encode(&self, source: &str, id: u64, content: &str) {
        crate::holographic_workspace::encode_entry(source, id, content);
    }
    fn query(&self, probe: &str) -> (f64, bool) {
        crate::holographic_workspace::query_similarity(probe)
    }
    fn capacity(&self) -> (usize, usize) {
        crate::holographic_workspace::capacity()
    }
    fn sync_from_blackboard(&self) {
        crate::holographic_workspace::sync_from_blackboard();
    }
}

// ---------- Composite: the full consciousness substrate ----------

/// The complete consciousness substrate: all modules unified under trait interfaces.
/// Alternative implementations can replace any or all of these.
pub struct ConsciousnessSubstrate {
    pub surprise: Box<dyn SurpriseSource>,
    pub belief: Box<dyn BeliefTracker>,
    pub precision: Box<dyn PrecisionPolicy>,
    pub workspace: Box<dyn GlobalWorkspace>,
    pub integration: Box<dyn IntegrationMetric>,
    pub causal: Box<dyn CausalReasoner>,
    pub memory: Box<dyn AssociativeMemory>,
    pub neuromod: Box<dyn Neuromodulator>,
    pub holographic: Box<dyn HolographicStore>,
}

impl ConsciousnessSubstrate {
    /// Create with all default (current) implementations.
    pub fn default_substrate() -> Self {
        Self {
            surprise: Box::new(DefaultSurpriseSource),
            belief: Box::new(DefaultBeliefTracker),
            precision: Box::new(DefaultPrecisionPolicy),
            workspace: Box::new(DefaultGlobalWorkspace),
            integration: Box::new(DefaultIntegrationMetric),
            causal: Box::new(DefaultCausalReasoner),
            memory: Box::new(DefaultAssociativeMemory),
            neuromod: Box::new(DefaultNeuromodulator),
            holographic: Box::new(DefaultHolographicStore),
        }
    }

    /// Number of trait-backed modules.
    pub fn module_count(&self) -> usize {
        9
    }

    /// List all module names (for diagnostics).
    pub fn module_names() -> &'static [&'static str] {
        &[
            "surprise_tracker",
            "belief_state",
            "precision_controller",
            "blackboard",
            "phi_proxy",
            "counterfactual",
            "memory_graph",
            "neuromodulation",
            "holographic_workspace",
        ]
    }
}

// ---------- Global substrate singleton ----------

static SUBSTRATE: std::sync::OnceLock<ConsciousnessSubstrate> = std::sync::OnceLock::new();

/// Get the global consciousness substrate (lazily initialized with defaults).
pub fn substrate() -> &'static ConsciousnessSubstrate {
    SUBSTRATE.get_or_init(ConsciousnessSubstrate::default_substrate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_substrate_creates() {
        let sub = ConsciousnessSubstrate::default_substrate();
        assert!(sub.surprise.current_ema() >= 0.0);
        assert!(sub.precision.recommended_max_tool_calls() > 0);
        let _ = sub.workspace.entry_count();
    }

    #[test]
    fn test_module_names_complete() {
        let names = ConsciousnessSubstrate::module_names();
        assert_eq!(names.len(), 9, "should have 9 consciousness modules");
        assert!(names.contains(&"surprise_tracker"));
        assert!(names.contains(&"neuromodulation"));
        assert!(names.contains(&"holographic_workspace"));
    }

    #[test]
    fn test_surprise_source_trait() {
        let src = DefaultSurpriseSource;
        let ema = src.current_ema();
        assert!(ema >= 0.0 && ema <= 1.0);
        assert!(!src.summary().is_empty());
    }

    #[test]
    fn test_belief_tracker_trait() {
        let bt = DefaultBeliefTracker;
        let unc = bt.task_uncertainty();
        assert!(unc >= 0.0 && unc <= 1.0);
    }

    #[test]
    fn test_precision_policy_trait() {
        let pp = DefaultPrecisionPolicy;
        let regime = pp.current_regime();
        assert!(!regime.is_empty());
        assert!(pp.recommended_max_tool_calls() >= 1);
    }

    #[test]
    fn test_neuromodulator_trait() {
        let nm = DefaultNeuromodulator;
        nm.reset();
        assert!((nm.dopamine() - 1.0).abs() < 0.2);
        assert!((nm.noradrenaline() - 1.0).abs() < 0.2);
        assert!((nm.serotonin() - 1.0).abs() < 0.2);
    }

    #[test]
    fn test_holographic_store_trait() {
        let hs = DefaultHolographicStore;
        let (items, cap) = hs.capacity();
        assert!(cap >= 40);
        assert!(items <= cap);
    }

    #[test]
    fn test_global_workspace_trait() {
        let gw = DefaultGlobalWorkspace;
        let id = gw.post("brain", "test message".to_string(), 0.8);
        assert!(id > 0);
    }

    #[test]
    fn test_causal_reasoner_trait() {
        let cr = DefaultCausalReasoner;
        let count = cr.lesson_count();
        assert!(count.is_ok());
    }
}
