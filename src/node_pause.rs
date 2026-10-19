//! RESILIENT-1652 / RESILIENT-1653 (PHASE-R R6): the ONE paused predicate.
//!
//! Before this module the fleet detected a node pause in three places that did
//! not agree:
//!   * `farmer_status::node_is_paused` read `node.env` for `CHUMP_NODE_MODE=paused`
//!     ONLY — it did not recognise the legacy `control-plane` + `WORK_ENABLED=0`
//!     form cuphead was actually paused with, so the farmer gate saw the node as
//!     UN-paused and walled every bot-merge re-entry (RESILIENT-1652 evidence);
//!   * `node_mode::is_paused` read `node.env` directly;
//!   * `node-converge.sh` had a fourth, shell-only rule.
//!
//! This module owns the invariant (Rust-owns-invariants, PHASE-R R6): one
//! predicate that both the farmer gate (`farmer_status`) and the pause detector
//! (`node_mode`) call. It reads:
//!   1. `node.env` `CHUMP_NODE_MODE` in BOTH line forms (bare `KEY=VALUE` and
//!      the shell `export KEY=VALUE` form), and the legacy
//!      `CHUMP_NODE_MODE=control-plane` + `CHUMP_NODE_WORK_ENABLED=0` pause form;
//!   2. the repo `.chump/fleet-paused` sentinel (the kill switch every reader —
//!      farmer, FLEET-054 workers, self-rescue, node-converge — shares).
//!
//! The two pause CONCEPTS stay distinct and must not be conflated:
//!   * an operator node pause (`chump node pause`) is durably expressed as
//!     `node.env CHUMP_NODE_MODE=paused`. The farmer gate excuses its (expected)
//!     stale heartbeat and ADMITS re-entry of already-claimed ship work
//!     (RESILIENT-1636) — the cuphead ship-wall fix;
//!   * the `.chump/fleet-paused` kill switch is owned by the ci-health-gate /
//!     waste-SLO path. It is a HARD RED the farmer gate never relaxes (the
//!     RESILIENT-1636 RED2 invariant). `chump node pause` therefore MUST NOT
//!     write it — doing so would wall every re-entry on a verb-paused node
//!     (see `node_mode.rs`).
//!
//! Reading the kill-switch sentinel here as a pause SIGNAL only affects
//! reporting (`farmer status` prints PAUSED, the stale heartbeat is attributed
//! to the pause); admission still refuses because the sentinel independently
//! drives `sentinel_absent=false` in the farmer gate.

use std::path::{Path, PathBuf};

/// Why a node reads as paused. The farmer gate uses this to attribute the
/// refusal reason accurately (node-env pause vs. the kill-switch sentinel).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PauseSignal {
    /// `node.env` expresses the pause (`CHUMP_NODE_MODE=paused`, or the legacy
    /// `control-plane` + `CHUMP_NODE_WORK_ENABLED=0` form).
    NodeEnv,
    /// the repo `.chump/fleet-paused` kill-switch sentinel is present.
    Sentinel,
}

/// The single `.chump/fleet-paused` kill-switch sentinel path EVERY reader
/// shares: the repo root's `.chump/fleet-paused`. This is where the
/// ci-health-gate writes, where the farmer (`farmer_status::check_sentinel`),
/// FLEET-054 workers, and the self-rescue conductor read. `chump node pause`
/// does NOT write here (it would self-wall); its durable signal is `node.env`.
pub fn sentinel_path(repo_root: &Path) -> PathBuf {
    repo_root.join(".chump").join("fleet-paused")
}

/// Pure parse of a `node.env` body for a pause, in BOTH line forms:
///   * `CHUMP_NODE_MODE=paused` or `export CHUMP_NODE_MODE=paused`; OR
///   * the legacy `CHUMP_NODE_MODE=control-plane` (bare or `export`) together
///     with `CHUMP_NODE_WORK_ENABLED=0` (bare or `export`) — the 2026-10-17
///     hand-edit cuphead carried.
///
/// Pure (no fs/env) so it is deterministically unit-testable.
pub fn node_env_is_paused(content: &str) -> bool {
    let mut mode: Option<&str> = None;
    let mut work_enabled: Option<&str> = None;
    for line in content.lines() {
        let t = line.trim();
        // Accept the shell `export ` prefix (shells source node.env); systemd
        // EnvironmentFile units read the bare form (INFRA-8588). Honour both.
        let t = t.strip_prefix("export ").map(str::trim_start).unwrap_or(t);
        if let Some(v) = t.strip_prefix("CHUMP_NODE_MODE=") {
            mode = Some(v.trim());
        } else if let Some(v) = t.strip_prefix("CHUMP_NODE_WORK_ENABLED=") {
            work_enabled = Some(v.trim());
        }
    }
    if mode == Some("paused") {
        return true;
    }
    // Legacy control-plane pause: BOTH the mode and the work-enabled=0 knob.
    mode == Some("control-plane") && work_enabled == Some("0")
}

/// Resolve the pause signal from `node.env` at `node_env_path` and the repo
/// kill-switch sentinel at `repo_root`. `node.env` wins the attribution when
/// both are present, so a node paused via the verb reports "by node mode".
pub fn pause_signal(repo_root: &Path, node_env_path: &Path) -> Option<PauseSignal> {
    if let Ok(body) = std::fs::read_to_string(node_env_path) {
        if node_env_is_paused(&body) {
            return Some(PauseSignal::NodeEnv);
        }
    }
    if sentinel_path(repo_root).exists() {
        return Some(PauseSignal::Sentinel);
    }
    None
}

/// The ONE paused predicate: true when `node.env` expresses a pause (both line
/// forms + the legacy control-plane form) OR the repo kill-switch sentinel
/// exists. Used by the farmer gate (`farmer_status`) and the pause detector
/// (`node_mode`).
pub fn is_paused(repo_root: &Path, node_env_path: &Path) -> bool {
    pause_signal(repo_root, node_env_path).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_paused_both_line_forms() {
        assert!(node_env_is_paused("CHUMP_NODE_MODE=paused"));
        assert!(node_env_is_paused("export CHUMP_NODE_MODE=paused\n"));
        assert!(node_env_is_paused("  export CHUMP_NODE_MODE=paused  \n"));
        assert!(node_env_is_paused(
            "# header\nCHUMP_STATE_DIR=/x\nCHUMP_NODE_MODE=paused\n"
        ));
    }

    #[test]
    fn work_ready_is_not_paused() {
        assert!(!node_env_is_paused("CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("export CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("# comment\nexport FOO=bar\n"));
        assert!(!node_env_is_paused(""));
    }

    #[test]
    fn legacy_control_plane_plus_work_disabled_is_paused() {
        // The cuphead form (set 2026-10-17, before the pause verb existed).
        assert!(node_env_is_paused(
            "CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=0\n"
        ));
        assert!(node_env_is_paused(
            "export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n"
        ));
    }

    #[test]
    fn control_plane_without_work_disabled_is_not_paused() {
        // control-plane ALONE (work still enabled) is a running control node,
        // NOT a pause — the legacy form needs BOTH halves.
        assert!(!node_env_is_paused("CHUMP_NODE_MODE=control-plane\n"));
        assert!(!node_env_is_paused(
            "CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=1\n"
        ));
        // WORK_ENABLED=0 without the control-plane mode is likewise not the
        // legacy pause form this predicate recognises.
        assert!(!node_env_is_paused(
            "CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=0\n"
        ));
    }

    #[test]
    fn sentinel_path_is_repo_dot_chump_never_doubled() {
        // Writer (ci-health-gate) and readers (farmer/predicate) share exactly
        // this path — never a doubled `.chump/.chump` (RESILIENT-1653).
        let p = sentinel_path(Path::new("/srv/repo"));
        assert_eq!(p, PathBuf::from("/srv/repo/.chump/fleet-paused"));
        assert!(!p.to_string_lossy().contains(".chump/.chump"));
    }

    #[test]
    fn pause_signal_reads_node_env_and_sentinel() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path();
        std::fs::create_dir_all(repo.join(".chump")).unwrap();
        let ne = repo.join("node.env");

        // Nothing paused yet.
        assert_eq!(pause_signal(repo, &ne), None);
        assert!(!is_paused(repo, &ne));

        // node.env pause → NodeEnv (attribution wins over sentinel).
        std::fs::write(&ne, "export CHUMP_NODE_MODE=paused\n").unwrap();
        assert_eq!(pause_signal(repo, &ne), Some(PauseSignal::NodeEnv));
        assert!(is_paused(repo, &ne));

        // sentinel only → Sentinel.
        std::fs::write(&ne, "CHUMP_NODE_MODE=work-ready\n").unwrap();
        std::fs::write(sentinel_path(repo), "x").unwrap();
        assert_eq!(pause_signal(repo, &ne), Some(PauseSignal::Sentinel));
        assert!(is_paused(repo, &ne));

        // both present → NodeEnv attribution.
        std::fs::write(&ne, "CHUMP_NODE_MODE=paused\n").unwrap();
        assert_eq!(pause_signal(repo, &ne), Some(PauseSignal::NodeEnv));
    }

    #[test]
    fn writer_and_reader_agree_on_sentinel_path() {
        // RESILIENT-1653 AC2 / task (3): the path the predicate reads is the
        // repo `.chump/fleet-paused`. A sentinel written exactly there is seen.
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path();
        std::fs::create_dir_all(repo.join(".chump")).unwrap();
        let ne = repo.join("node.env");
        // Write where the predicate reads → the predicate sees it.
        std::fs::write(sentinel_path(repo), "slo_breach").unwrap();
        assert_eq!(pause_signal(repo, &ne), Some(PauseSignal::Sentinel));
        // A doubled `.chump/.chump/fleet-paused` is NOT where the reader looks.
        std::fs::remove_file(sentinel_path(repo)).unwrap();
        let doubled = repo.join(".chump").join(".chump").join("fleet-paused");
        std::fs::create_dir_all(doubled.parent().unwrap()).unwrap();
        std::fs::write(&doubled, "slo_breach").unwrap();
        assert_eq!(pause_signal(repo, &ne), None);
    }
}
