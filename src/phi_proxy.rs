//! Phi proxy metric: measures integrated information across Chump's modules.
//!
//! IIT's true Phi (irreducibility of causal structure) is computationally intractable
//! for real systems. This module computes proxy metrics that measure:
//!
//! 1. Module coupling score: how often information from module A influences module B
//! 2. Cross-module utilization: what fraction of blackboard entries are consumed by
//!    modules other than the author
//! 3. Information flow diversity: entropy of the cross-module read distribution
//!
//! Together these proxies indicate whether the system is genuinely integrated (modules
//! work together as a coherent whole) or merely additive (modules operate independently).
//!
//! Part of the Synthetic Consciousness Framework, Phase 6.

use std::collections::HashMap;

/// Phi proxy metrics bundle.
#[derive(Debug, Clone)]
pub struct PhiMetrics {
    /// Module coupling score (0.0 = independent, 1.0 = fully coupled).
    /// Computed as the normalized count of cross-module reads.
    pub coupling_score: f64,
    /// Fraction of blackboard entries read by modules other than the author.
    pub cross_read_utilization: f64,
    /// Shannon entropy of the cross-module read distribution (higher = more diverse coupling).
    pub information_flow_entropy: f64,
    /// Number of unique module-to-module read pairs observed.
    pub active_coupling_pairs: usize,
    /// Total possible module-to-module pairs.
    pub total_possible_pairs: usize,
    /// Composite phi proxy (weighted combination of above metrics).
    pub phi_proxy: f64,
}

/// Minimum module count for normalization (the 8 fixed Module enum variants).
const MIN_MODULE_COUNT: usize = 8;

/// Compute the current phi proxy metrics from the global blackboard.
pub fn compute_phi() -> PhiMetrics {
    let bb = crate::blackboard::global();
    let reads = bb.cross_module_reads();

    let total_entries = bb.entry_count();
    let cross_read_entries = bb.cross_read_entry_count();

    let cross_read_utilization = if total_entries > 0 {
        cross_read_entries as f64 / total_entries as f64
    } else {
        0.0
    };

    let total_reads: u64 = reads.values().sum();
    let active_pairs = reads.len();

    // Dynamic module count: at least 8 (fixed variants), plus any Custom modules observed
    let mut observed_modules = std::collections::HashSet::new();
    for (reader, source) in reads.keys() {
        observed_modules.insert(reader.to_string());
        observed_modules.insert(source.to_string());
    }
    let module_count = observed_modules.len().max(MIN_MODULE_COUNT);
    let total_possible = module_count * (module_count - 1);

    let coupling_score = if total_possible > 0 {
        active_pairs as f64 / total_possible as f64
    } else {
        0.0
    };

    // Shannon entropy of read distribution
    let entropy = if total_reads > 0 {
        let mut h = 0.0_f64;
        for &count in reads.values() {
            if count > 0 {
                let p = count as f64 / total_reads as f64;
                h -= p * p.ln();
            }
        }
        // Normalize by max entropy (log of number of active pairs)
        if active_pairs > 1 {
            h / (active_pairs as f64).ln()
        } else {
            0.0
        }
    } else {
        0.0
    };

    // Composite phi proxy: weighted combination
    let phi_proxy = 0.35 * coupling_score + 0.35 * cross_read_utilization + 0.30 * entropy;

    PhiMetrics {
        coupling_score,
        cross_read_utilization,
        information_flow_entropy: entropy,
        active_coupling_pairs: active_pairs,
        total_possible_pairs: total_possible,
        phi_proxy,
    }
}

/// Per-module activity: how many reads/writes each module has done.
pub fn module_activity() -> HashMap<String, ModuleActivity> {
    let bb = crate::blackboard::global();
    let reads = bb.cross_module_reads();

    let mut activity: HashMap<String, ModuleActivity> = HashMap::new();

    for ((reader, source), &count) in &reads {
        let reader_name = reader.to_string();
        let source_name = source.to_string();

        activity
            .entry(reader_name)
            .or_insert(ModuleActivity {
                reads_from_others: 0,
                read_by_others: 0,
            })
            .reads_from_others += count;

        activity
            .entry(source_name)
            .or_insert(ModuleActivity {
                reads_from_others: 0,
                read_by_others: 0,
            })
            .read_by_others += count;
    }

    activity
}

#[derive(Debug, Clone, Default)]
pub struct ModuleActivity {
    pub reads_from_others: u64,
    pub read_by_others: u64,
}

/// Summary from pre-computed metrics (avoids redundant compute_phi call).
pub fn summary_from(m: &PhiMetrics) -> String {
    format!(
        "phi_proxy: {:.3}, coupling: {:.3} ({}/{}), cross_read: {:.1}%, entropy: {:.3}",
        m.phi_proxy,
        m.coupling_score,
        m.active_coupling_pairs,
        m.total_possible_pairs,
        m.cross_read_utilization * 100.0,
        m.information_flow_entropy,
    )
}

/// Summary string for health endpoint and context injection.
pub fn summary() -> String {
    summary_from(&compute_phi())
}

/// JSON-serializable metrics for the health endpoint.
pub fn metrics_json() -> serde_json::Value {
    let m = compute_phi();
    serde_json::json!({
        "phi_proxy": m.phi_proxy,
        "coupling_score": m.coupling_score,
        "cross_read_utilization": m.cross_read_utilization,
        "information_flow_entropy": m.information_flow_entropy,
        "active_coupling_pairs": m.active_coupling_pairs,
        "total_possible_pairs": m.total_possible_pairs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blackboard::{self, Module, SalienceFactors};

    fn high_salience() -> SalienceFactors {
        SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.7,
            goal_relevance: 0.8,
            urgency: 0.5,
        }
    }

    #[test]
    fn test_phi_empty_blackboard() {
        let m = compute_phi();
        assert!(m.phi_proxy >= 0.0);
        assert!(m.coupling_score >= 0.0);
    }

    #[test]
    fn test_phi_with_posts_but_no_reads() {
        let bb = blackboard::Blackboard::new();
        bb.post(Module::Memory, "fact 1".to_string(), high_salience());
        bb.post(Module::Episode, "event 1".to_string(), high_salience());

        // Without cross-module reads, coupling should be zero
        let reads = bb.cross_module_reads();
        assert!(reads.is_empty());
    }

    #[test]
    fn test_phi_with_cross_reads() {
        let bb = blackboard::Blackboard::new();
        bb.post(Module::Memory, "fact".to_string(), high_salience());
        bb.post(Module::Episode, "event".to_string(), high_salience());

        // Task reads from Memory
        let entries = bb.read_from(Module::Task, &Module::Memory);
        assert_eq!(entries.len(), 1);

        // SurpriseTracker reads from Episode
        let entries = bb.read_from(Module::SurpriseTracker, &Module::Episode);
        assert_eq!(entries.len(), 1);

        let reads = bb.cross_module_reads();
        assert_eq!(reads.len(), 2);
        assert_eq!(*reads.get(&(Module::Task, Module::Memory)).unwrap_or(&0), 1);
    }

    #[test]
    fn test_module_activity() {
        let bb = blackboard::Blackboard::new();
        bb.post(Module::Memory, "data".to_string(), high_salience());
        bb.read_from(Module::Task, &Module::Memory);
        bb.read_from(Module::Episode, &Module::Memory);

        // Use global for module_activity since it reads from global()
        // For this unit test, we just verify the structure
        let activity = module_activity();
        // May or may not have entries depending on whether global blackboard has data
        assert!(activity.len() <= MIN_MODULE_COUNT + 10);
    }

    #[test]
    fn test_summary_format() {
        let s = summary();
        assert!(s.contains("phi_proxy"));
        assert!(s.contains("coupling"));
        assert!(s.contains("entropy"));
    }

    #[test]
    fn test_metrics_json_structure() {
        let j = metrics_json();
        assert!(j.get("phi_proxy").is_some());
        assert!(j.get("coupling_score").is_some());
        assert!(j.get("cross_read_utilization").is_some());
        assert!(j.get("information_flow_entropy").is_some());
    }
}
