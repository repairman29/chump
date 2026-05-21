//! INFRA-1486: per-gap agent execution budgets — trust gate for Marcus.
//!
//! Marcus's stated disqualifying behavior (2026-05-15 interview): "By the
//! time I checked back in after two hours, it had modified 14 different
//! files, introduced three brand-new dependencies I would never allow in
//! our codebase, and completely distorted the original intent." This module
//! is the structural prevention for that compounding-failure mode.
//!
//! Tracks four budget dimensions per gap:
//!   - max_wallclock_minutes  (default 30)
//!   - max_file_touches       (default 10)
//!   - max_dep_adds           (default 0)
//!   - max_llm_cost_usd       (tier-derived: see [`tier_default_cost_usd`])
//!
//! Two thresholds:
//!   - 75% → emit `kind=gap_budget_warn` (soft warning; agent keeps going)
//!   - 100% → emit `kind=gap_budget_breach` + return [`BudgetAction::SoftPause`]
//!            (caller must pause and emit `kind=agent_soft_pause`)
//!
//! Bypass: `CHUMP_BUDGET_ENFORCE=0` short-circuits all checks to Pass.
//!
//! Integration shape (follow-up gap, NOT in this MVP):
//!   - `chump claim` reads gap notes + .chump/budgets.toml + effort-default,
//!     constructs [`Budget`], writes it into the lease file.
//!   - Agent harness consults `BudgetTracker` on every file touch / cargo
//!     add / wallclock tick / LLM call, pauses on `SoftPause`.
//!   - `chump nudge --extend-budget` raises a ceiling at operator request
//!     (separate gap — needs INFRA-1476).

use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::debug;

// ── public types ──────────────────────────────────────────────────────────────

/// Effort tier → default LLM cost ceiling (USD). Defaults baked in; can be
/// overridden per-gap via budgets.toml or chump claim --max-llm-cost-usd.
///
/// AC #10 "TIER-DEFAULT POLICY". AC #12 "CEILINGS NOT FLOORS": any gap can
/// claim any tier, but this ceiling caps how much it spends. An xs gap on
/// opus is allowed — the $0.50 cap just halts it fast.
pub fn tier_default_cost_usd(effort: &str) -> f64 {
    match effort {
        "xs" => 0.50,
        "s" => 2.00,
        "m" => 5.00,
        "l" => 20.00,
        _ => 5.00, // unknown → m default
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Budget {
    pub max_wallclock_minutes: u64,
    pub max_file_touches: u64,
    pub max_dep_adds: u64,
    pub max_llm_cost_usd: f64,
}

impl Budget {
    /// Effort-tier defaults: xs=$0.50 cap, s=$2, m=$5, l=$20; same wallclock/file/dep ceilings.
    pub fn for_effort(effort: &str) -> Self {
        Self {
            max_wallclock_minutes: 30,
            max_file_touches: 10,
            max_dep_adds: 0,
            max_llm_cost_usd: tier_default_cost_usd(effort),
        }
    }
}

impl Default for Budget {
    fn default() -> Self {
        Self::for_effort("m")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BudgetAction {
    /// All budgets under 75% — continue normally.
    Pass,
    /// At least one budget crossed 75% — emit warn, continue.
    Warn,
    /// At least one budget reached 100% — emit breach, caller must pause.
    SoftPause { dimension: &'static str },
}

/// One running track-record for a gap's execution. The tracker is the
/// authority on "are we still inside budget?" and emits ambient events when
/// thresholds cross.
#[derive(Debug, Clone)]
pub struct BudgetTracker {
    pub gap_id: String,
    pub budget: Budget,
    pub started_at: u64, // unix seconds
    pub file_touches: u64,
    pub dep_adds: u64,
    pub llm_cost_usd: f64,

    // Track which thresholds we've already emitted (so we don't spam events).
    warn_emitted: BudgetFlags,
    breach_emitted: BudgetFlags,
}

#[derive(Debug, Clone, Default)]
struct BudgetFlags {
    wallclock: bool,
    file_touches: bool,
    dep_adds: bool,
    llm_cost: bool,
}

impl BudgetTracker {
    pub fn new(gap_id: impl Into<String>, budget: Budget) -> Self {
        let started_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Self {
            gap_id: gap_id.into(),
            budget,
            started_at,
            file_touches: 0,
            dep_adds: 0,
            llm_cost_usd: 0.0,
            warn_emitted: BudgetFlags::default(),
            breach_emitted: BudgetFlags::default(),
        }
    }

    /// Returns elapsed wallclock minutes since started_at.
    pub fn wallclock_minutes(&self) -> u64 {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(self.started_at);
        now.saturating_sub(self.started_at) / 60
    }

    /// Record a file touch. Returns the action the caller should take.
    pub fn record_file_touch(&mut self) -> BudgetAction {
        self.file_touches += 1;
        self.evaluate()
    }

    /// Record a dependency added (Cargo.toml etc).
    pub fn record_dep_add(&mut self) -> BudgetAction {
        self.dep_adds += 1;
        self.evaluate()
    }

    /// Record incremental LLM cost (USD).
    pub fn record_llm_cost(&mut self, delta_usd: f64) -> BudgetAction {
        self.llm_cost_usd += delta_usd;
        self.evaluate()
    }

    /// Check wallclock without recording any new event; used by periodic ticker.
    pub fn check_wallclock(&mut self) -> BudgetAction {
        self.evaluate()
    }

    /// Aggregate evaluation across all dimensions. Returns the strictest
    /// applicable action.
    fn evaluate(&mut self) -> BudgetAction {
        debug!(
            gap_id = %self.gap_id,
            file_touches = self.file_touches,
            dep_adds = self.dep_adds,
            llm_cost_usd = self.llm_cost_usd,
            "budget_tracker: evaluate"
        );
        // Bypass via env (test/op override).
        if std::env::var("CHUMP_BUDGET_ENFORCE").as_deref() == Ok("0") {
            return BudgetAction::Pass;
        }

        let mut strictest = BudgetAction::Pass;

        // file_touches
        if self.budget.max_file_touches > 0 {
            let used = self.file_touches;
            let max = self.budget.max_file_touches;
            if used > max {
                if !self.breach_emitted.file_touches {
                    self.breach_emitted.file_touches = true;
                    emit_breach(&self.gap_id, "file_touches", used as f64, max as f64);
                }
                return BudgetAction::SoftPause {
                    dimension: "file_touches",
                };
            } else if used * 4 >= max * 3 {
                if !self.warn_emitted.file_touches {
                    self.warn_emitted.file_touches = true;
                    emit_warn(&self.gap_id, "file_touches", used as f64, max as f64);
                }
                strictest = BudgetAction::Warn;
            }
        }

        // dep_adds (default ceiling 0 → ANY dep_add breaches)
        let used = self.dep_adds;
        let max = self.budget.max_dep_adds;
        if max == 0 && used > 0 {
            if !self.breach_emitted.dep_adds {
                self.breach_emitted.dep_adds = true;
                emit_breach(&self.gap_id, "dep_adds", used as f64, max as f64);
            }
            return BudgetAction::SoftPause {
                dimension: "dep_adds",
            };
        } else if max > 0 {
            if used > max {
                if !self.breach_emitted.dep_adds {
                    self.breach_emitted.dep_adds = true;
                    emit_breach(&self.gap_id, "dep_adds", used as f64, max as f64);
                }
                return BudgetAction::SoftPause {
                    dimension: "dep_adds",
                };
            } else if used * 4 >= max * 3 {
                if !self.warn_emitted.dep_adds {
                    self.warn_emitted.dep_adds = true;
                    emit_warn(&self.gap_id, "dep_adds", used as f64, max as f64);
                }
                strictest = BudgetAction::Warn;
            }
        }

        // wallclock
        let used = self.wallclock_minutes();
        let max = self.budget.max_wallclock_minutes;
        if max > 0 {
            if used > max {
                if !self.breach_emitted.wallclock {
                    self.breach_emitted.wallclock = true;
                    emit_breach(&self.gap_id, "wallclock_minutes", used as f64, max as f64);
                }
                return BudgetAction::SoftPause {
                    dimension: "wallclock_minutes",
                };
            } else if used * 4 >= max * 3 {
                if !self.warn_emitted.wallclock {
                    self.warn_emitted.wallclock = true;
                    emit_warn(&self.gap_id, "wallclock_minutes", used as f64, max as f64);
                }
                strictest = BudgetAction::Warn;
            }
        }

        // llm_cost
        let used = self.llm_cost_usd;
        let max = self.budget.max_llm_cost_usd;
        if max > 0.0 {
            if used > max {
                if !self.breach_emitted.llm_cost {
                    self.breach_emitted.llm_cost = true;
                    emit_breach(&self.gap_id, "llm_cost_usd", used, max);
                }
                return BudgetAction::SoftPause {
                    dimension: "llm_cost_usd",
                };
            } else if used * 4.0 >= max * 3.0 {
                if !self.warn_emitted.llm_cost {
                    self.warn_emitted.llm_cost = true;
                    emit_warn(&self.gap_id, "llm_cost_usd", used, max);
                }
                strictest = BudgetAction::Warn;
            }
        }

        strictest
    }
}

// ── ambient emission ─────────────────────────────────────────────────────────

/// Best-effort write to .chump-locks/ambient.jsonl. Honors $CHUMP_AMBIENT_LOG
/// override for tests. Silently no-ops on I/O failure (telemetry must NEVER
/// break the calling agent's main path).
fn emit_kind(kind: &str, gap_id: &str, dimension: &str, used: f64, max: f64) {
    let path = std::env::var("CHUMP_AMBIENT_LOG").unwrap_or_else(|_| {
        let root = std::env::var("REPO_ROOT").unwrap_or_else(|_| ".".to_string());
        format!("{root}/.chump-locks/ambient.jsonl")
    });
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let pct = if max > 0.0 { (used / max) * 100.0 } else { 0.0 };
    let line = format!(
        r#"{{"ts":"{ts}","kind":"{kind}","gap_id":"{gap_id}","dimension":"{dimension}","used":{used},"max":{max},"pct":{pct:.1}}}{newline}"#,
        newline = "\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

fn emit_warn(gap_id: &str, dimension: &str, used: f64, max: f64) {
    let kind = "gap_budget_warn"; // INFRA-1287 registry scanner hook
    emit_kind(kind, gap_id, dimension, used, max);
}

fn emit_breach(gap_id: &str, dimension: &str, used: f64, max: f64) {
    let kind = "gap_budget_breach"; // INFRA-1287 registry scanner hook
    emit_kind(kind, gap_id, dimension, used, max);
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    use std::sync::{Mutex, MutexGuard, OnceLock};

    /// Process-wide lock for env-var mutations during tests. Without this,
    /// concurrent tests racing on CHUMP_AMBIENT_LOG / CHUMP_BUDGET_ENFORCE
    /// produce flaky results (one test's setup clobbers another's emit
    /// target). Acquired by every test that touches setup_ambient_log.
    fn ambient_test_lock() -> MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    /// Returned guard pairs the tempdir lifetime with the env-var lock so
    /// the lock is held for the duration of each test's read_ambient call.
    struct AmbientGuard {
        _dir: tempfile::TempDir,
        _lock: MutexGuard<'static, ()>,
        path: std::path::PathBuf,
    }

    impl AmbientGuard {
        fn path(&self) -> &std::path::Path {
            &self.path
        }
    }

    fn setup_ambient_log() -> AmbientGuard {
        let lock = ambient_test_lock();
        let dir = tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        // Touch the file so writes work
        std::fs::File::create(&path).unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", &path);
        std::env::remove_var("CHUMP_BUDGET_ENFORCE");
        AmbientGuard {
            _dir: dir,
            _lock: lock,
            path,
        }
    }

    fn read_ambient(guard: &AmbientGuard) -> String {
        std::fs::read_to_string(guard.path()).unwrap_or_default()
    }

    #[test]
    fn tier_defaults_are_ceilings_not_floors() {
        assert_eq!(tier_default_cost_usd("xs"), 0.50);
        assert_eq!(tier_default_cost_usd("s"), 2.00);
        assert_eq!(tier_default_cost_usd("m"), 5.00);
        assert_eq!(tier_default_cost_usd("l"), 20.00);
        // unknown defaults to m
        assert_eq!(tier_default_cost_usd("xl"), 5.00);
    }

    #[test]
    fn file_touch_breach_at_max() {
        let _g = setup_ambient_log();
        let budget = Budget {
            max_file_touches: 10,
            ..Budget::for_effort("m")
        };
        let mut t = BudgetTracker::new("INFRA-TEST", budget);

        // Touches 1..=10 should not breach; 8 (75% of 10 = 7.5; ceil = 8) crosses warn.
        let mut warned = false;
        for i in 1..=10 {
            let action = t.record_file_touch();
            if matches!(action, BudgetAction::Warn) {
                warned = true;
            }
            assert!(
                !matches!(action, BudgetAction::SoftPause { .. }),
                "touch {i} should not breach (max=10)"
            );
        }
        assert!(warned, "should have warned at 75% threshold");

        // 11th touch breaches
        match t.record_file_touch() {
            BudgetAction::SoftPause { dimension } => assert_eq!(dimension, "file_touches"),
            other => panic!("expected SoftPause, got {other:?}"),
        }
    }

    #[test]
    fn dep_add_with_zero_ceiling_breaches_immediately() {
        let _g = setup_ambient_log();
        let mut t = BudgetTracker::new("INFRA-TEST", Budget::default()); // max_dep_adds = 0
        match t.record_dep_add() {
            BudgetAction::SoftPause { dimension } => assert_eq!(dimension, "dep_adds"),
            other => panic!("expected SoftPause on first dep_add with max=0, got {other:?}"),
        }
    }

    #[test]
    fn llm_cost_breach_emits_event() {
        let g = setup_ambient_log();
        let budget = Budget {
            max_llm_cost_usd: 5.00,
            ..Budget::default()
        };
        let mut t = BudgetTracker::new("INFRA-TEST", budget);
        t.record_llm_cost(2.0); // 40% — no event
        t.record_llm_cost(2.0); // 80% — warn
        let action = t.record_llm_cost(2.0); // 120% — breach
        assert!(matches!(action, BudgetAction::SoftPause { .. }));
        let log = read_ambient(&g);
        assert!(log.contains("gap_budget_warn"), "warn event missing");
        assert!(log.contains("gap_budget_breach"), "breach event missing");
    }

    #[test]
    fn bypass_env_short_circuits() {
        let _g = setup_ambient_log();
        std::env::set_var("CHUMP_BUDGET_ENFORCE", "0");
        let mut t = BudgetTracker::new("INFRA-TEST", Budget::default());
        for _ in 0..100 {
            assert_eq!(t.record_file_touch(), BudgetAction::Pass);
        }
        std::env::remove_var("CHUMP_BUDGET_ENFORCE");
    }

    #[test]
    fn event_emit_is_idempotent_per_threshold() {
        let g = setup_ambient_log();
        let mut t = BudgetTracker::new(
            "INFRA-TEST",
            Budget {
                max_file_touches: 4,
                ..Budget::default()
            },
        );
        t.record_file_touch(); // 1
        t.record_file_touch(); // 2
        t.record_file_touch(); // 3 — 75% threshold
        t.record_file_touch(); // 4 — breach
                               // Subsequent touches should NOT re-emit (idempotent flag)
        let extra = t.record_file_touch();
        assert!(matches!(
            extra,
            BudgetAction::SoftPause { .. } | BudgetAction::Warn
        ));
        let log = read_ambient(&g);
        let warns = log.matches("gap_budget_warn").count();
        let breaches = log.matches("gap_budget_breach").count();
        assert_eq!(warns, 1, "warn should fire exactly once per dimension");
        assert_eq!(breaches, 1, "breach should fire exactly once per dimension");
    }
}
