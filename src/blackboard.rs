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

/// Salience weight profile: determines how factors are combined.
#[derive(Debug, Clone)]
pub struct SalienceWeights {
    pub novelty: f64,
    pub uncertainty_reduction: f64,
    pub goal_relevance: f64,
    pub urgency: f64,
}

impl SalienceWeights {
    pub fn default_weights() -> Self {
        Self {
            novelty: 0.30,
            uncertainty_reduction: 0.25,
            goal_relevance: 0.30,
            urgency: 0.15,
        }
    }

    /// Exploration-oriented: favors novelty and uncertainty reduction.
    pub fn explore() -> Self {
        Self {
            novelty: 0.40,
            uncertainty_reduction: 0.30,
            goal_relevance: 0.15,
            urgency: 0.15,
        }
    }

    /// Exploitation-oriented: favors goal relevance, suppresses novelty.
    pub fn exploit() -> Self {
        Self {
            novelty: 0.15,
            uncertainty_reduction: 0.15,
            goal_relevance: 0.50,
            urgency: 0.20,
        }
    }

    /// Conservative: favors urgency and goal relevance for cautious operation.
    pub fn conservative() -> Self {
        Self {
            novelty: 0.10,
            uncertainty_reduction: 0.20,
            goal_relevance: 0.35,
            urgency: 0.35,
        }
    }
}

/// The active salience policy: regime-aware weight selection.
static SALIENCE_OVERRIDE: std::sync::OnceLock<std::sync::Mutex<Option<SalienceWeights>>> =
    std::sync::OnceLock::new();

fn salience_override() -> &'static std::sync::Mutex<Option<SalienceWeights>> {
    SALIENCE_OVERRIDE.get_or_init(|| std::sync::Mutex::new(None))
}

/// Override the salience weights globally (e.g. from a config or runtime decision).
pub fn set_salience_weights(w: SalienceWeights) {
    if let Ok(mut guard) = salience_override().lock() {
        *guard = Some(w);
    }
}

/// Clear the override; fall back to regime-adaptive weights.
pub fn clear_salience_override() {
    if let Ok(mut guard) = salience_override().lock() {
        *guard = None;
    }
}

/// Get the active salience weights, considering manual override and current regime.
pub fn active_weights() -> SalienceWeights {
    if let Ok(guard) = salience_override().lock() {
        if let Some(ref w) = *guard {
            return w.clone();
        }
    }
    match crate::precision_controller::current_regime() {
        crate::precision_controller::PrecisionRegime::Exploit => SalienceWeights::exploit(),
        crate::precision_controller::PrecisionRegime::Balanced => {
            SalienceWeights::default_weights()
        }
        crate::precision_controller::PrecisionRegime::Explore => SalienceWeights::explore(),
        crate::precision_controller::PrecisionRegime::Conservative => {
            SalienceWeights::conservative()
        }
    }
}

fn neuromod_salience_on_factors() -> bool {
    !matches!(
        std::env::var("CHUMP_NEUROMOD_SALIENCE_WEIGHTS")
            .map(|v| v.trim() == "0")
            .unwrap_or(false),
        true,
    )
}

impl SalienceFactors {
    /// Compute weighted salience score using the active regime-aware weights.
    ///
    /// When neuromodulation is enabled (default), [`crate::neuromodulation::salience_modulation`]
    /// scales each factor's contribution. Set `CHUMP_NEUROMOD_SALIENCE_WEIGHTS=0` for legacy
    /// behavior (weights × factors only).
    pub fn score(&self) -> f64 {
        let w = active_weights();
        let (mn, mu, mg, mur) = if neuromod_salience_on_factors() {
            crate::neuromodulation::salience_modulation()
        } else {
            (1.0, 1.0, 1.0, 1.0)
        };
        w.novelty * mn.max(0.0) * self.novelty
            + w.uncertainty_reduction * mu.max(0.0) * self.uncertainty_reduction
            + w.goal_relevance * mg.max(0.0) * self.goal_relevance
            + w.urgency * mur.max(0.0) * self.urgency
    }
}

/// Subscription: a module's interest in entries from specific sources.
#[derive(Debug, Clone)]
pub struct Subscription {
    pub subscriber: Module,
    pub interested_in: Vec<Module>,
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
    /// Registered subscriptions for filtered reads.
    subscriptions: RwLock<Vec<Subscription>>,
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
            subscriptions: RwLock::new(Vec::new()),
        }
    }

    /// Register a subscription: the subscriber will only see entries from interested_in modules.
    pub fn subscribe(&self, subscriber: Module, interested_in: Vec<Module>) {
        if let Ok(mut subs) = self.subscriptions.write() {
            subs.retain(|s| s.subscriber != subscriber);
            subs.push(Subscription {
                subscriber,
                interested_in,
            });
        }
    }

    /// Get entries matching a subscriber's registered interests. If no subscription
    /// is registered, returns all broadcast-eligible entries.
    pub fn read_subscribed(&self, subscriber: &Module) -> Vec<Entry> {
        let filter = if let Ok(subs) = self.subscriptions.read() {
            subs.iter()
                .find(|s| &s.subscriber == subscriber)
                .map(|s| s.interested_in.clone())
        } else {
            None
        };

        let entries = match self.entries.read() {
            Ok(e) => e,
            Err(_) => return Vec::new(),
        };

        let result: Vec<Entry> = entries
            .iter()
            .filter(|e| e.salience >= self.broadcast_threshold)
            .filter(|e| e.posted_at.elapsed() < self.max_age)
            .filter(|e| match &filter {
                Some(sources) => sources.contains(&e.source),
                None => true,
            })
            .cloned()
            .collect();

        for entry in &result {
            self.record_read(subscriber.clone(), entry.source.clone());
        }
        result
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
        above.sort_by(|a, b| {
            b.salience
                .partial_cmp(&a.salience)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
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

// --- Async channel for non-blocking blackboard writes ---

/// A pending post that will be processed by the async drain task.
#[derive(Debug)]
pub struct AsyncPost {
    pub source: Module,
    pub content: String,
    pub factors: SalienceFactors,
}

static ASYNC_TX: std::sync::OnceLock<tokio::sync::mpsc::UnboundedSender<AsyncPost>> =
    std::sync::OnceLock::new();

/// Initialize the async posting channel. Call once at startup (in a tokio context).
/// Returns a JoinHandle for the drain task.
pub fn init_async_channel() -> tokio::task::JoinHandle<()> {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<AsyncPost>();
    let _ = ASYNC_TX.set(tx);
    tokio::spawn(async move {
        while let Some(ap) = rx.recv().await {
            post(ap.source, ap.content, ap.factors);
        }
    })
}

/// Non-blocking post via the async channel. Falls back to synchronous post
/// if the channel hasn't been initialized.
pub fn post_async(source: Module, content: String, factors: SalienceFactors) {
    if let Some(tx) = ASYNC_TX.get() {
        let _ = tx.send(AsyncPost {
            source,
            content,
            factors,
        });
    } else {
        post(source, content, factors);
    }
}

/// Convenience: get broadcast context from the global blackboard.
pub fn broadcast_context(max_entries: usize, max_chars: usize) -> String {
    global().broadcast_context(max_entries, max_chars)
}

/// Persist high-salience entries to SQLite for cross-session continuity.
/// Called at session close; entries above threshold are saved, older persisted entries pruned.
pub fn persist_high_salience() {
    let bb = global();
    let entries = bb.broadcast_entries();
    if entries.is_empty() {
        return;
    }
    let conn = match crate::db_pool::get() {
        Ok(c) => c,
        Err(_) => return,
    };
    for entry in &entries {
        if let Err(e) = conn.execute(
            "INSERT INTO chump_blackboard_persist (source, content, salience) VALUES (?1, ?2, ?3)",
            rusqlite::params![entry.source.to_string(), entry.content, entry.salience],
        ) {
            tracing::warn!(error = %e, "blackboard persist insert failed");
        }
    }
    if let Err(e) = conn.execute(
        "DELETE FROM chump_blackboard_persist WHERE id NOT IN (SELECT id FROM chump_blackboard_persist ORDER BY salience DESC LIMIT 50)",
        [],
    ) {
        tracing::warn!(error = %e, "blackboard persist prune failed");
    }
}

/// Restore persisted entries into the blackboard on startup.
pub fn restore_persisted() {
    let conn = match crate::db_pool::get() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut stmt = match conn.prepare(
        "SELECT source, content, salience FROM chump_blackboard_persist ORDER BY salience DESC LIMIT 20"
    ) {
        Ok(s) => s,
        Err(_) => return,
    };
    let rows = match stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, f64>(2)?,
        ))
    }) {
        Ok(r) => r,
        Err(_) => return,
    };
    let bb = global();
    for row in rows.flatten() {
        let (source_str, content, salience) = row;
        let source = match source_str.as_str() {
            "memory" => Module::Memory,
            "episode" => Module::Episode,
            "task" => Module::Task,
            "tool_middleware" => Module::ToolMiddleware,
            "surprise_tracker" => Module::SurpriseTracker,
            "provider" => Module::Provider,
            "brain" => Module::Brain,
            "autonomy" => Module::Autonomy,
            other => Module::Custom(other.to_string()),
        };
        let goal_relevance = (salience / 0.85).min(1.0);
        bb.post(
            source,
            content,
            SalienceFactors {
                novelty: 0.5,
                uncertainty_reduction: 0.3,
                goal_relevance,
                urgency: 0.1,
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn test_salience_scoring() {
        let factors = SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.5,
            goal_relevance: 0.8,
            urgency: 0.3,
        };
        let score = factors.score();
        assert!(
            score > 0.5 && score < 1.0,
            "score should be moderate-high: {}",
            score
        );
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

    #[test]
    #[serial]
    fn salience_factors_respect_neuromod_goal_bias() {
        clear_salience_override();
        let _ = std::env::remove_var("CHUMP_NEUROMOD_SALIENCE_WEIGHTS");
        set_salience_weights(SalienceWeights::default_weights());
        crate::neuromodulation::reset();
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 2.0,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        let f = SalienceFactors {
            novelty: 0.0,
            uncertainty_reduction: 0.0,
            goal_relevance: 1.0,
            urgency: 0.0,
        };
        let s_high = f.score();
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 0.5,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        let s_low = f.score();
        clear_salience_override();
        crate::neuromodulation::reset();
        assert!(
            s_high > s_low + 1e-6,
            "high dopamine should increase goal-weighted salience: {} vs {}",
            s_high,
            s_low
        );
    }

    #[test]
    #[serial]
    fn salience_legacy_env_disables_neuromod_modulation() {
        clear_salience_override();
        std::env::set_var("CHUMP_NEUROMOD_SALIENCE_WEIGHTS", "0");
        set_salience_weights(SalienceWeights::default_weights());
        let f = SalienceFactors {
            novelty: 0.3,
            uncertainty_reduction: 0.4,
            goal_relevance: 0.5,
            urgency: 0.2,
        };
        crate::neuromodulation::reset();
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 2.0,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        let a = f.score();
        crate::neuromodulation::restore(crate::neuromodulation::NeuromodState {
            dopamine: 0.5,
            noradrenaline: 1.0,
            serotonin: 1.0,
        });
        let b = f.score();
        std::env::remove_var("CHUMP_NEUROMOD_SALIENCE_WEIGHTS");
        clear_salience_override();
        crate::neuromodulation::reset();
        assert!(
            (a - b).abs() < 1e-9,
            "CHUMP_NEUROMOD_SALIENCE_WEIGHTS=0: neuromod should not change score ({} vs {})",
            a,
            b
        );
    }
}
