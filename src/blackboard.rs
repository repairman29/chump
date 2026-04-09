//! Global Workspace / Blackboard: shared in-memory workspace for inter-module coordination.
//!
//! Implements Global Workspace Theory (GWT): specialized modules post entries to the
//! blackboard with a salience score. Entries above the broadcast threshold are injected
//! into context_assembly, making high-salience information available to all modules.
//!
//! Part of the Synthetic Consciousness Framework, Phase 3.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

/// Source module that posted an entry.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Module {
    Memory,
    Episode,
    Task,
    ToolMiddleware,
    SurpriseTracker,
    Provider,
    Brain,
    Autonomy,
    Custom(String),
}

impl std::fmt::Display for Module {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Module::Memory => write!(f, "memory"),
            Module::Episode => write!(f, "episode"),
            Module::Task => write!(f, "task"),
            Module::ToolMiddleware => write!(f, "tool_middleware"),
            Module::SurpriseTracker => write!(f, "surprise_tracker"),
            Module::Provider => write!(f, "provider"),
            Module::Brain => write!(f, "brain"),
            Module::Autonomy => write!(f, "autonomy"),
            Module::Custom(name) => write!(f, "{}", name),
        }
    }
}

/// A single entry on the blackboard.
#[derive(Debug, Clone)]
pub struct Entry {
    pub id: u64,
    pub source: Module,
    pub content: String,
    pub salience: f64,
    pub posted_at: Instant,
    /// Modules that have read this entry (for phi proxy metric).
    pub read_by: Vec<Module>,
    /// Number of times this entry was broadcast.
    pub broadcast_count: u32,
}

/// Salience factors for computing entry importance.
#[derive(Debug, Clone)]
pub struct SalienceFactors {
    /// Is this information new? (0.0 = stale, 1.0 = novel)
    pub novelty: f64,
    /// Does this resolve an open question? (0.0 = no, 1.0 = fully resolves)
    pub uncertainty_reduction: f64,
    /// Is this relevant to the current task/goal? (0.0 = irrelevant, 1.0 = critical)
    pub goal_relevance: f64,
    /// How urgent is this? (0.0 = can wait, 1.0 = immediate)
    pub urgency: f64,
}

impl SalienceFactors {
    /// Compute weighted salience score.
    pub fn score(&self) -> f64 {
        let weights = [0.3, 0.25, 0.30, 0.15];
        let values = [
            self.novelty,
            self.uncertainty_reduction,
            self.goal_relevance,
            self.urgency,
        ];
        weights
            .iter()
            .zip(values.iter())
            .map(|(w, v)| w * v)
            .sum()
    }
}

/// The global blackboard: thread-safe shared workspace.
pub struct Blackboard {
    entries: RwLock<Vec<Entry>>,
    next_id: RwLock<u64>,
    /// Content hashes of recently posted entries for novelty detection.
    recent_hashes: RwLock<Vec<u64>>,
    /// Threshold above which entries are broadcast.
    broadcast_threshold: f64,
    /// Maximum number of entries to retain.
    max_entries: usize,
    /// Maximum age before entries are evicted.
    max_age: Duration,
    /// Cross-module read tracking for phi proxy.
    read_counts: RwLock<HashMap<(Module, Module), u64>>,
}

impl Blackboard {
    pub fn new() -> Self {
        let max_age_secs = std::env::var("CHUMP_BLACKBOARD_MAX_AGE_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .unwrap_or(600);
        let threshold = std::env::var("CHUMP_BLACKBOARD_BROADCAST_THRESHOLD")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|&v| v >= 0.0 && v <= 1.0)
            .unwrap_or(0.4);
        Self {
            entries: RwLock::new(Vec::new()),
            next_id: RwLock::new(1),
            recent_hashes: RwLock::new(Vec::new()),
            broadcast_threshold: threshold,
            max_entries: 100,
            max_age: Duration::from_secs(max_age_secs),
            read_counts: RwLock::new(HashMap::new()),
        }
    }

    /// Post a new entry to the blackboard. Returns the entry ID.
    pub fn post(&self, source: Module, content: String, factors: SalienceFactors) -> u64 {
        let salience = factors.score();
        let content_hash = simple_hash(&content);

        // Novelty adjustment: reduce salience if very similar content was recently posted
        let novelty_penalty = if let Ok(hashes) = self.recent_hashes.read() {
            if hashes.contains(&content_hash) {
                0.5
            } else {
                1.0
            }
        } else {
            1.0
        };
        let salience = salience * novelty_penalty;

        let id = {
            let mut next = self.next_id.write().unwrap_or_else(|e| e.into_inner());
            let id = *next;
            *next += 1;
            id
        };

        let entry = Entry {
            id,
            source,
            content,
            salience,
            posted_at: Instant::now(),
            read_by: Vec::new(),
            broadcast_count: 0,
        };

        if let Ok(mut entries) = self.entries.write() {
            entries.push(entry);
            self.evict_stale(&mut entries);
        }

        if let Ok(mut hashes) = self.recent_hashes.write() {
            hashes.push(content_hash);
            if hashes.len() > 200 {
                hashes.drain(..100);
            }
        }

        id
    }

    /// Get all entries above the broadcast threshold, sorted by salience descending.
    pub fn broadcast_entries(&self) -> Vec<Entry> {
        let entries = match self.entries.read() {
            Ok(e) => e,
            Err(_) => return Vec::new(),
        };
        let mut above: Vec<Entry> = entries
            .iter()
            .filter(|e| e.salience >= self.broadcast_threshold)
            .filter(|e| e.posted_at.elapsed() < self.max_age)
            .cloned()
            .collect();
        above.sort_by(|a, b| b.salience.partial_cmp(&a.salience).unwrap_or(std::cmp::Ordering::Equal));
        above
    }

    /// Format broadcast entries for context injection. Returns empty string if nothing to broadcast.
    pub fn broadcast_context(&self, max_entries: usize, max_chars: usize) -> String {
        let entries = self.broadcast_entries();
        if entries.is_empty() {
            return String::new();
        }
        let mut out = String::from("Global workspace (high-salience):\n");
        let mut chars = out.len();
        let mut broadcast_ids = Vec::new();
        for entry in entries.iter().take(max_entries) {
            let line = format!(
                "  [{}] ({:.2}) {}\n",
                entry.source, entry.salience, entry.content
            );
            if chars + line.len() > max_chars {
                break;
            }
            chars += line.len();
            out.push_str(&line);
            broadcast_ids.push(entry.id);
        }
        // Single write-lock pass to update all broadcast counts
        if !broadcast_ids.is_empty() {
            if let Ok(mut all) = self.entries.write() {
                for e in all.iter_mut() {
                    if broadcast_ids.contains(&e.id) {
                        e.broadcast_count += 1;
                    }
                }
            }
        }
        out.push('\n');
        out
    }

    /// Record that a module read an entry from another module (for phi proxy).
    pub fn record_read(&self, reader: Module, entry_source: Module) {
        if reader == entry_source {
            return;
        }
        if let Ok(mut counts) = self.read_counts.write() {
            *counts.entry((reader, entry_source)).or_default() += 1;
        }
    }

    /// Read entries posted by a specific module.
    pub fn read_from(&self, reader: Module, source_filter: &Module) -> Vec<Entry> {
        let entries = match self.entries.read() {
            Ok(e) => e,
            Err(_) => return Vec::new(),
        };
        let result: Vec<Entry> = entries
            .iter()
            .filter(|e| e.source == *source_filter)
            .filter(|e| e.posted_at.elapsed() < self.max_age)
            .cloned()
            .collect();

        for entry in &result {
            self.record_read(reader.clone(), entry.source.clone());
        }
        result
    }

    /// Get cross-module read counts for phi proxy computation.
    pub fn cross_module_reads(&self) -> HashMap<(Module, Module), u64> {
        self.read_counts
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    /// Total entries currently on the blackboard.
    pub fn entry_count(&self) -> usize {
        self.entries.read().map(|e| e.len()).unwrap_or(0)
    }

    /// Total entries that have been read by a module other than the author.
    pub fn cross_read_entry_count(&self) -> usize {
        self.entries
            .read()
            .map(|entries| {
                entries
                    .iter()
                    .filter(|e| e.broadcast_count > 0 || !e.read_by.is_empty())
                    .count()
            })
            .unwrap_or(0)
    }

    fn evict_stale(&self, entries: &mut Vec<Entry>) {
        entries.retain(|e| e.posted_at.elapsed() < self.max_age);
        if entries.len() > self.max_entries {
            entries.sort_by(|a, b| {
                b.salience
                    .partial_cmp(&a.salience)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            entries.truncate(self.max_entries);
        }
    }
}

fn simple_hash(s: &str) -> u64 {
    let mut hash: u64 = 5381;
    for byte in s.bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(byte as u64);
    }
    hash
}

/// Global singleton blackboard instance.
static GLOBAL_BLACKBOARD: std::sync::OnceLock<Arc<Blackboard>> = std::sync::OnceLock::new();

/// Get the global blackboard instance.
pub fn global() -> Arc<Blackboard> {
    GLOBAL_BLACKBOARD
        .get_or_init(|| Arc::new(Blackboard::new()))
        .clone()
}

/// Convenience: post to the global blackboard.
pub fn post(source: Module, content: String, factors: SalienceFactors) -> u64 {
    global().post(source, content, factors)
}

/// Convenience: get broadcast context from the global blackboard.
pub fn broadcast_context(max_entries: usize, max_chars: usize) -> String {
    global().broadcast_context(max_entries, max_chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_salience_scoring() {
        let factors = SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.5,
            goal_relevance: 0.8,
            urgency: 0.3,
        };
        let score = factors.score();
        assert!(score > 0.5 && score < 1.0, "score should be moderate-high: {}", score);
    }

    #[test]
    fn test_post_and_broadcast() {
        let bb = Blackboard::new();
        let id = bb.post(
            Module::Memory,
            "Important discovery about system state".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.8,
                goal_relevance: 0.9,
                urgency: 0.5,
            },
        );
        assert!(id > 0);

        let entries = bb.broadcast_entries();
        assert_eq!(entries.len(), 1);
        assert!(entries[0].salience >= 0.4);
    }

    #[test]
    fn test_low_salience_not_broadcast() {
        let bb = Blackboard::new();
        bb.post(
            Module::Memory,
            "Mundane observation".to_string(),
            SalienceFactors {
                novelty: 0.1,
                uncertainty_reduction: 0.0,
                goal_relevance: 0.1,
                urgency: 0.0,
            },
        );

        let entries = bb.broadcast_entries();
        assert!(entries.is_empty(), "low salience should not broadcast");
    }

    #[test]
    fn test_novelty_penalty_for_duplicates() {
        let bb = Blackboard::new();
        let factors = SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.5,
            goal_relevance: 0.8,
            urgency: 0.5,
        };

        bb.post(Module::Memory, "same content".to_string(), factors.clone());
        bb.post(Module::Memory, "same content".to_string(), factors);

        let entries = bb.broadcast_entries();
        if entries.len() == 2 {
            assert!(
                entries[1].salience < entries[0].salience,
                "duplicate should have lower salience"
            );
        }
    }

    #[test]
    fn test_broadcast_context_format() {
        let bb = Blackboard::new();
        bb.post(
            Module::SurpriseTracker,
            "High prediction error detected on run_cli".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.6,
                goal_relevance: 0.7,
                urgency: 0.8,
            },
        );

        let ctx = bb.broadcast_context(5, 1000);
        assert!(ctx.contains("Global workspace"));
        assert!(ctx.contains("surprise_tracker"));
        assert!(ctx.contains("prediction error"));
    }

    #[test]
    fn test_cross_module_reads() {
        let bb = Blackboard::new();
        bb.post(
            Module::Memory,
            "A fact".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );

        let entries = bb.read_from(Module::Task, &Module::Memory);
        assert_eq!(entries.len(), 1);

        let counts = bb.cross_module_reads();
        assert_eq!(
            *counts.get(&(Module::Task, Module::Memory)).unwrap_or(&0),
            1
        );
    }
}
