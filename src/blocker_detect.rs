//! FLEET-012 — blocker detection: agent recognizes when it is stuck and
//! emits a help-request signal to `.chump-locks/ambient.jsonl`.
//!
//! Four detection paths:
//!
//! 1. `ExecutionTimer` — wall-clock budget with explicit progress checkpoints.
//! 2. `CompileFailureCounter` — consecutive `cargo check` failures.
//! 3. `check_resource_exhaustion` — caller passes measured free RAM.
//! 4. `check_capability_gap` — required model family vs known fleet caps.
//!
//! Detection is pure (no I/O); only `emit_blocker_alert` touches the
//! filesystem, mirroring `adversary::emit_ambient_alert` so the same ambient
//! stream surfaces both kinds of signal. FLEET-010 will turn these alerts
//! into proper help requests; until then the ambient ALERT line is the
//! standby.

use std::time::{Duration, Instant};

use crate::fleet_capability::AgentCapability;

/// Why the agent thinks it is stuck.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockerKind {
    ExecutionTimeout,
    CompileFailureLoop,
    ResourceExhaustion,
    CapabilityGap,
}

impl BlockerKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            BlockerKind::ExecutionTimeout => "execution_timeout",
            BlockerKind::CompileFailureLoop => "compile_failure_loop",
            BlockerKind::ResourceExhaustion => "resource_exhaustion",
            BlockerKind::CapabilityGap => "capability_gap",
        }
    }
}

/// One detected blocker — what kind, optional gap context, human detail.
#[derive(Debug, Clone)]
pub struct Blocker {
    pub kind: BlockerKind,
    pub gap_id: Option<String>,
    pub detail: String,
}

/// Default timeout: 60 min with no progress.
pub const DEFAULT_TIMEOUT_SECS: u64 = 60 * 60;
/// Default compile-loop threshold: 3 consecutive failures.
pub const DEFAULT_COMPILE_FAILURE_THRESHOLD: u32 = 3;

/// Tracks wall-clock time since last `mark_progress`.
pub struct ExecutionTimer {
    started_at: Instant,
    last_progress_at: Instant,
    timeout: Duration,
}

impl ExecutionTimer {
    pub fn new(timeout_secs: u64) -> Self {
        let now = Instant::now();
        Self {
            started_at: now,
            last_progress_at: now,
            timeout: Duration::from_secs(timeout_secs),
        }
    }

    pub fn mark_progress(&mut self) {
        self.last_progress_at = Instant::now();
    }

    /// Returns a blocker if the no-progress duration exceeds the timeout.
    pub fn check(&self, gap_id: Option<&str>) -> Option<Blocker> {
        self.check_against(Instant::now(), gap_id)
    }

    /// Test seam — caller supplies "now".
    pub fn check_against(&self, now: Instant, gap_id: Option<&str>) -> Option<Blocker> {
        let stalled = now.saturating_duration_since(self.last_progress_at);
        if stalled < self.timeout {
            return None;
        }
        let total = now.saturating_duration_since(self.started_at);
        Some(Blocker {
            kind: BlockerKind::ExecutionTimeout,
            gap_id: gap_id.map(|s| s.to_string()),
            detail: format!(
                "no progress for {}s (total runtime {}s, timeout {}s)",
                stalled.as_secs(),
                total.as_secs(),
                self.timeout.as_secs()
            ),
        })
    }
}

/// Counts consecutive failures of an operation (e.g. `cargo check`).
pub struct CompileFailureCounter {
    consecutive: u32,
    threshold: u32,
}

impl CompileFailureCounter {
    pub fn new(threshold: u32) -> Self {
        Self {
            consecutive: 0,
            threshold,
        }
    }

    /// Record a result. Returns a blocker if the consecutive-failure count
    /// hits the threshold.
    pub fn record(&mut self, success: bool, gap_id: Option<&str>) -> Option<Blocker> {
        if success {
            self.consecutive = 0;
            return None;
        }
        self.consecutive += 1;
        if self.consecutive < self.threshold {
            return None;
        }
        Some(Blocker {
            kind: BlockerKind::CompileFailureLoop,
            gap_id: gap_id.map(|s| s.to_string()),
            detail: format!(
                "{} consecutive cargo check failures (threshold {})",
                self.consecutive, self.threshold
            ),
        })
    }

    pub fn consecutive(&self) -> u32 {
        self.consecutive
    }
}

/// Pure check: caller measures `available_mb` (e.g. via `sysctl` /
/// `/proc/meminfo`) and the threshold below which we consider the agent
/// resource-starved.
pub fn check_resource_exhaustion(
    available_mb: u64,
    min_mb: u64,
    gap_id: Option<&str>,
) -> Option<Blocker> {
    if available_mb >= min_mb {
        return None;
    }
    Some(Blocker {
        kind: BlockerKind::ResourceExhaustion,
        gap_id: gap_id.map(|s| s.to_string()),
        detail: format!("available RAM {available_mb}MB below threshold {min_mb}MB"),
    })
}

/// Pure check: returns a blocker iff none of the supplied capabilities matches
/// the required model family. `caps` typically comes from
/// `fleet_capability::read_all_local`.
pub fn check_capability_gap(
    required_family: &str,
    caps: &[AgentCapability],
    gap_id: Option<&str>,
) -> Option<Blocker> {
    if caps.iter().any(|c| c.model_family == required_family) {
        return None;
    }
    let available: Vec<&str> = caps.iter().map(|c| c.model_family.as_str()).collect();
    Some(Blocker {
        kind: BlockerKind::CapabilityGap,
        gap_id: gap_id.map(|s| s.to_string()),
        detail: format!(
            "required model family '{required_family}' not in fleet (available: {:?})",
            available
        ),
    })
}

/// Append one `event=blocker_alert` line to `.chump-locks/ambient.jsonl`.
/// Mirrors the format used by `adversary::emit_ambient_alert` so war-room /
/// musher tooling can surface it. Best-effort — never panics.
pub fn emit_blocker_alert(blocker: &Blocker) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());

    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let kind = blocker.kind.as_str();
    let gap = blocker.gap_id.as_deref().unwrap_or("");
    let detail = json_escape(&blocker.detail);

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"blocker_alert\",\"kind\":\"{kind}\",\"gap\":\"{gap}\",\
         \"detail\":\"{detail}\"}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

fn json_escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c if (c as u32) < 0x20 => format!("\\u{:04x}", c as u32).chars().collect(),
            c => vec![c],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn timer_no_progress_under_timeout_returns_none() {
        let t = ExecutionTimer::new(60);
        assert!(t.check(None).is_none());
    }

    #[test]
    fn timer_no_progress_over_timeout_fires() {
        let t = ExecutionTimer::new(1);
        let future = Instant::now() + Duration::from_secs(2);
        let b = t.check_against(future, Some("FLEET-012")).unwrap();
        assert_eq!(b.kind, BlockerKind::ExecutionTimeout);
        assert_eq!(b.gap_id.as_deref(), Some("FLEET-012"));
        assert!(b.detail.contains("no progress"));
    }

    #[test]
    fn timer_progress_resets_clock() {
        let mut t = ExecutionTimer::new(1);
        std::thread::sleep(Duration::from_millis(10));
        t.mark_progress();
        // Right after a progress mark, even if started_at is old, last_progress is now.
        let now = Instant::now() + Duration::from_millis(100);
        assert!(t.check_against(now, None).is_none());
    }

    #[test]
    fn compile_loop_under_threshold_does_not_fire() {
        let mut c = CompileFailureCounter::new(3);
        assert!(c.record(false, None).is_none());
        assert!(c.record(false, None).is_none());
        assert_eq!(c.consecutive(), 2);
    }

    #[test]
    fn compile_loop_at_threshold_fires() {
        let mut c = CompileFailureCounter::new(3);
        c.record(false, None);
        c.record(false, None);
        let b = c.record(false, Some("FLEET-012")).unwrap();
        assert_eq!(b.kind, BlockerKind::CompileFailureLoop);
        assert!(b.detail.contains("3 consecutive"));
    }

    #[test]
    fn compile_loop_success_resets() {
        let mut c = CompileFailureCounter::new(2);
        c.record(false, None);
        assert!(c.record(true, None).is_none());
        assert_eq!(c.consecutive(), 0);
        // Need fresh threshold-many failures.
        assert!(c.record(false, None).is_none());
    }

    #[test]
    fn resource_above_threshold_returns_none() {
        assert!(check_resource_exhaustion(2048, 1024, None).is_none());
    }

    #[test]
    fn resource_below_threshold_fires() {
        let b = check_resource_exhaustion(512, 1024, Some("FLEET-012")).unwrap();
        assert_eq!(b.kind, BlockerKind::ResourceExhaustion);
        assert!(b.detail.contains("512MB"));
        assert!(b.detail.contains("1024MB"));
    }

    fn cap(family: &str) -> AgentCapability {
        AgentCapability {
            agent_id: format!("agent-{family}"),
            model_family: family.to_string(),
            model_name: format!("{family}-test"),
            vram_gb: 8.0,
            inference_speed_tok_per_sec: 50.0,
            supported_task_classes: vec!["test".into()],
            reliability_score: 0.5,
        }
    }

    #[test]
    fn capability_gap_match_returns_none() {
        let caps = vec![cap("qwen"), cap("llama")];
        assert!(check_capability_gap("qwen", &caps, None).is_none());
    }

    #[test]
    fn capability_gap_no_match_fires() {
        let caps = vec![cap("llama")];
        let b = check_capability_gap("qwen", &caps, Some("FLEET-012")).unwrap();
        assert_eq!(b.kind, BlockerKind::CapabilityGap);
        assert!(b.detail.contains("qwen"));
        assert!(b.detail.contains("llama"));
    }

    /// Acceptance test: timeout-driven blocker → ambient.jsonl line appears.
    #[test]
    fn timeout_emits_ambient_alert_line() {
        let tmp = tempfile::tempdir().unwrap();
        let log = tmp.path().join("ambient.jsonl");
        // SAFETY: tests run single-threaded by default in this module
        // (test functions don't share env state intentionally), and we set
        // CHUMP_AMBIENT_LOG before any concurrent access.
        unsafe {
            std::env::set_var("CHUMP_AMBIENT_LOG", &log);
            std::env::set_var("CHUMP_SESSION_ID", "test-session");
        }

        let t = ExecutionTimer::new(0);
        let future = Instant::now() + Duration::from_secs(1);
        let b = t.check_against(future, Some("FLEET-012")).unwrap();
        emit_blocker_alert(&b);

        let contents = std::fs::read_to_string(&log).unwrap();
        assert!(contents.contains("\"event\":\"blocker_alert\""));
        assert!(contents.contains("\"kind\":\"execution_timeout\""));
        assert!(contents.contains("\"gap\":\"FLEET-012\""));
        assert!(contents.contains("\"session\":\"test-session\""));

        unsafe {
            std::env::remove_var("CHUMP_AMBIENT_LOG");
            std::env::remove_var("CHUMP_SESSION_ID");
        }
    }
}
