//! META-076: Basic predictive collision detection (mock inputs).
//!
//! First implementation of the predictive-collision layer described in
//! docs/design/COLLISION_PREDICTION_SCHEMA.md (META-075). This slice validates
//! the schema against a minimal, self-contained trajectory model: agents are
//! represented by a mock 2D position + velocity, projected forward in time,
//! and flagged when their projected paths pass within a collision radius of
//! each other before the lookahead window elapses.
//!
//! Real position/velocity inputs (lease graph, PR graph, gap-dependency graph)
//! are future work (META-081 integration slice) — this module only needs to
//! prove the detection + emission plumbing works end-to-end.
//!
//! EFFECTIVE-1336 (EFFECTIVE-510 slice): a predicted collision is a predicted
//! *breakage* — two agents on course to edit overlapping ground before either
//! ships. Logging it to ambient is not enough to act on between check-ins, so
//! [`top_escalation_action`] / [`escalate_and_file_incident`] wire the
//! highest-confidence prediction to a dispatch/escalate action that
//! auto-files a P0 incident gap via `chump gap reserve`, mirroring the
//! shell-out pattern in `crates/chump-fleet-server/src/mission.rs`.

use std::fs;
use std::io::Write as IoWrite;
use std::process::Command;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Mock agent kinematic state: 2D position + velocity, updated per tick.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct AgentTrajectory {
    pub session: &'static str,
    pub position: (f64, f64),
    pub velocity: (f64, f64),
}

impl AgentTrajectory {
    fn position_at(&self, t: f64) -> (f64, f64) {
        (
            self.position.0 + self.velocity.0 * t,
            self.position.1 + self.velocity.1 * t,
        )
    }
}

/// A detected predicted collision between two agent trajectories.
#[derive(Debug, Clone, Serialize)]
pub struct CollisionPrediction {
    pub agent_a: String,
    pub agent_b: String,
    pub predicted_ts_offset_s: f64,
    pub confidence: f64,
}

/// Tunable parameters for the detector.
#[derive(Debug, Clone, Copy)]
pub struct DetectorConfig {
    /// Minimum confidence required to report a collision (ACs: "configurable").
    pub confidence_threshold: f64,
    /// Distance below which two agents are considered colliding.
    pub collision_radius: f64,
    /// How far forward (seconds) to project trajectories.
    pub lookahead_s: f64,
    /// Number of discrete samples taken across the lookahead window.
    pub samples: u32,
}

impl Default for DetectorConfig {
    fn default() -> Self {
        Self {
            confidence_threshold: 0.5,
            collision_radius: 1.0,
            lookahead_s: 10.0,
            samples: 20,
        }
    }
}

/// Confidence falls off linearly from 1.0 (agents already overlapping) to 0.0
/// (agents exactly `collision_radius` apart) at the closest approach found.
fn confidence_from_distance(distance: f64, collision_radius: f64) -> f64 {
    if collision_radius <= 0.0 {
        return 0.0;
    }
    (1.0 - (distance / collision_radius)).clamp(0.0, 1.0)
}

/// Scan all pairs of agent trajectories for a predicted overlap within
/// `config.lookahead_s`, returning every pair whose confidence clears
/// `config.confidence_threshold`.
pub fn predict_collisions(
    agents: &[AgentTrajectory],
    config: &DetectorConfig,
) -> Vec<CollisionPrediction> {
    let mut predictions = Vec::new();
    let samples = config.samples.max(1);

    for i in 0..agents.len() {
        for j in (i + 1)..agents.len() {
            let a = &agents[i];
            let b = &agents[j];

            let mut best_distance = f64::MAX;
            let mut best_t = 0.0;

            for s in 0..=samples {
                let t = config.lookahead_s * (s as f64) / (samples as f64);
                let (ax, ay) = a.position_at(t);
                let (bx, by) = b.position_at(t);
                let distance = ((ax - bx).powi(2) + (ay - by).powi(2)).sqrt();
                if distance < best_distance {
                    best_distance = distance;
                    best_t = t;
                }
            }

            if best_distance <= config.collision_radius {
                let confidence = confidence_from_distance(best_distance, config.collision_radius);
                if confidence >= config.confidence_threshold {
                    predictions.push(CollisionPrediction {
                        agent_a: a.session.to_string(),
                        agent_b: b.session.to_string(),
                        predicted_ts_offset_s: best_t,
                        confidence,
                    });
                }
            }
        }
    }

    predictions
}

/// Emit a `collision_prediction` event to ambient.jsonl for each detected
/// collision. Path is overridable via `CHUMP_AMBIENT_LOG` (test/CI hook).
pub fn emit_collision_prediction_events(predictions: &[CollisionPrediction]) -> Result<()> {
    if predictions.is_empty() {
        return Ok(());
    }

    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    for prediction in predictions {
        let entry = serde_json::json!({
            "ts": ts,
            "kind": "collision_prediction",
            "agent_a": prediction.agent_a,
            "agent_b": prediction.agent_b,
            "predicted_ts_offset_s": prediction.predicted_ts_offset_s,
            "confidence": prediction.confidence,
        });
        writeln!(file, "{}", entry)
            .with_context(|| format!("writing ambient log at {ambient_path}"))?;
    }
    Ok(())
}

/// Confidence above which the top predicted collision is escalated to a
/// dispatch/escalate action rather than left as an ambient-only signal.
pub const ESCALATION_CONFIDENCE_THRESHOLD: f64 = 0.85;

/// A dispatch/escalate action derived from the single highest-confidence
/// predicted collision, once it clears [`ESCALATION_CONFIDENCE_THRESHOLD`].
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct EscalationAction {
    pub agent_a: String,
    pub agent_b: String,
    pub confidence: f64,
    pub title: String,
}

/// Pick the highest-confidence predicted collision and, if it clears
/// [`ESCALATION_CONFIDENCE_THRESHOLD`], build the dispatch/escalate action
/// for it. Returns `None` when there is nothing worth escalating.
pub fn top_escalation_action(predictions: &[CollisionPrediction]) -> Option<EscalationAction> {
    let top = predictions.iter().max_by(|a, b| {
        a.confidence
            .partial_cmp(&b.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    })?;
    if top.confidence < ESCALATION_CONFIDENCE_THRESHOLD {
        return None;
    }
    Some(EscalationAction {
        agent_a: top.agent_a.clone(),
        agent_b: top.agent_b.clone(),
        confidence: top.confidence,
        title: format!(
            "Predicted collision breakage: {} x {} (confidence {:.2})",
            top.agent_a, top.agent_b, top.confidence
        ),
    })
}

/// Resolve the `chump` binary: `CHUMP_BIN` env (test/CI hook) else bare
/// `chump` on `PATH`, mirroring `chump-fleet-server::mission::resolve_chump_bin`.
fn resolve_chump_bin() -> String {
    std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string())
}

/// Pull a `DOMAIN-NNN`-shaped gap id out of `chump gap reserve` stdout.
fn parse_gap_id(stdout: &str) -> Option<String> {
    stdout.lines().rev().find_map(|line| {
        line.split_whitespace().find_map(|w| {
            let w = w.trim();
            let (prefix, suffix) = w.split_once('-')?;
            (!prefix.is_empty()
                && prefix.chars().all(|c| c.is_ascii_uppercase())
                && !suffix.is_empty()
                && suffix.chars().all(|c| c.is_ascii_digit()))
            .then(|| w.to_string())
        })
    })
}

/// Take the dispatch/escalate action for a predicted breakage: file a P0
/// incident gap via `chump gap reserve` and emit a `collision_escalation`
/// ambient event recording what was done. Returns the reserved gap id, or
/// `Ok(None)` when `chump gap reserve` ran but its output didn't parse (the
/// escalation event is still emitted either way, so the miss is observable).
pub fn escalate_and_file_incident(action: &EscalationAction) -> Result<Option<String>> {
    let chump_bin = resolve_chump_bin();
    let notes = format!(
        "Auto-filed by collision_prediction (EFFECTIVE-1336 / EFFECTIVE-510 slice): \
         predicted breakage between {} and {} at confidence {:.2}. \
         Dispatch/escalate action taken automatically — no human in the loop.",
        action.agent_a, action.agent_b, action.confidence
    );
    let output = Command::new(&chump_bin)
        .args([
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--priority",
            "P0",
            "--title",
            &action.title,
            "--notes",
            &notes,
        ])
        .output()
        .with_context(|| {
            format!("spawning `{chump_bin} gap reserve` for predicted-breakage escalation")
        })?;

    let gap_id = output
        .status
        .success()
        .then(|| parse_gap_id(&String::from_utf8_lossy(&output.stdout)))
        .flatten();

    emit_escalation_event(action, gap_id.as_deref())?;
    Ok(gap_id)
}

/// Emit a `collision_escalation` event to ambient.jsonl recording the
/// dispatch/escalate action taken (and the P0 gap id it filed, if any).
fn emit_escalation_event(action: &EscalationAction, gap_id: Option<&str>) -> Result<()> {
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let entry = serde_json::json!({
        "ts": ts,
        "kind": "collision_escalation",
        "agent_a": action.agent_a,
        "agent_b": action.agent_b,
        "confidence": action.confidence,
        "action": "dispatch_escalate",
        "gap_id": gap_id,
    });
    writeln!(file, "{}", entry)
        .with_context(|| format!("writing ambient log at {ambient_path}"))?;
    Ok(())
}

/// Wire predictions end-to-end: emit the per-pair ambient signal (existing
/// behavior), then escalate the top prediction if it clears
/// [`ESCALATION_CONFIDENCE_THRESHOLD`]. This is the entry point future
/// callers (real lease/PR-graph inputs, META-081) should use instead of
/// calling `emit_collision_prediction_events` alone.
pub fn handle_predictions(predictions: &[CollisionPrediction]) -> Result<Option<String>> {
    emit_collision_prediction_events(predictions)?;
    match top_escalation_action(predictions) {
        Some(action) => escalate_and_file_incident(&action),
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn head_on_agents_collide_within_lookahead() {
        let agents = vec![
            AgentTrajectory {
                session: "agent-a",
                position: (0.0, 0.0),
                velocity: (1.0, 0.0),
            },
            AgentTrajectory {
                session: "agent-b",
                position: (10.0, 0.0),
                velocity: (-1.0, 0.0),
            },
        ];
        let config = DetectorConfig::default();

        let predictions = predict_collisions(&agents, &config);

        assert_eq!(predictions.len(), 1);
        assert_eq!(predictions[0].agent_a, "agent-a");
        assert_eq!(predictions[0].agent_b, "agent-b");
        assert!(predictions[0].confidence >= config.confidence_threshold);
    }

    #[test]
    fn diverging_agents_do_not_collide() {
        let agents = vec![
            AgentTrajectory {
                session: "agent-a",
                position: (0.0, 0.0),
                velocity: (-1.0, 0.0),
            },
            AgentTrajectory {
                session: "agent-b",
                position: (10.0, 0.0),
                velocity: (1.0, 0.0),
            },
        ];
        let config = DetectorConfig::default();

        let predictions = predict_collisions(&agents, &config);

        assert!(predictions.is_empty());
    }

    #[test]
    fn confidence_threshold_is_configurable() {
        // Agents pass within 0.9 of each other — clears a lax threshold,
        // fails a strict one, at an unchanged collision_radius.
        let agents = vec![
            AgentTrajectory {
                session: "agent-a",
                position: (0.0, 0.0),
                velocity: (1.0, 0.0),
            },
            AgentTrajectory {
                session: "agent-b",
                position: (10.0, 0.9),
                velocity: (-1.0, 0.0),
            },
        ];

        let lax = DetectorConfig {
            confidence_threshold: 0.05,
            ..DetectorConfig::default()
        };
        let strict = DetectorConfig {
            confidence_threshold: 0.5,
            ..DetectorConfig::default()
        };

        assert_eq!(predict_collisions(&agents, &lax).len(), 1);
        assert!(predict_collisions(&agents, &strict).is_empty());
    }

    #[test]
    fn emits_collision_prediction_event_to_ambient_log() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        let predictions = vec![CollisionPrediction {
            agent_a: "agent-a".to_string(),
            agent_b: "agent-b".to_string(),
            predicted_ts_offset_s: 5.0,
            confidence: 0.9,
        }];

        emit_collision_prediction_events(&predictions).unwrap();

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"collision_prediction\""));
        assert!(contents.contains("\"agent_a\":\"agent-a\""));
        assert!(contents.contains("\"confidence\":0.9"));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn empty_predictions_do_not_create_ambient_file() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        emit_collision_prediction_events(&[]).unwrap();

        assert!(!ambient_path.exists());

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    /// Write an executable stub `chump` that prints `gap reserve`-shaped
    /// stdout so escalation tests never spawn the real binary.
    fn write_stub_chump(dir: &TempDir, gap_id: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.path().join("stub-chump.sh");
        fs::write(
            &path,
            format!("#!/bin/sh\necho 'reserving...'\necho '{gap_id}'\n"),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[test]
    fn top_escalation_action_picks_highest_confidence_above_threshold() {
        let predictions = vec![
            CollisionPrediction {
                agent_a: "agent-a".to_string(),
                agent_b: "agent-b".to_string(),
                predicted_ts_offset_s: 1.0,
                confidence: 0.6,
            },
            CollisionPrediction {
                agent_a: "agent-c".to_string(),
                agent_b: "agent-d".to_string(),
                predicted_ts_offset_s: 2.0,
                confidence: 0.95,
            },
        ];

        let action = top_escalation_action(&predictions).expect("should escalate");
        assert_eq!(action.agent_a, "agent-c");
        assert_eq!(action.agent_b, "agent-d");
        assert!(action.title.contains("agent-c"));
    }

    #[test]
    fn top_escalation_action_none_below_threshold() {
        let predictions = vec![CollisionPrediction {
            agent_a: "agent-a".to_string(),
            agent_b: "agent-b".to_string(),
            predicted_ts_offset_s: 1.0,
            confidence: 0.5,
        }];

        assert!(top_escalation_action(&predictions).is_none());
    }

    #[test]
    fn top_escalation_action_none_when_empty() {
        assert!(top_escalation_action(&[]).is_none());
    }

    #[test]
    fn parse_gap_id_finds_domain_number_token() {
        assert_eq!(
            parse_gap_id("reserving...\nINFRA-4242\n"),
            Some("INFRA-4242".to_string())
        );
        assert_eq!(parse_gap_id("no id here\n"), None);
    }

    #[test]
    fn escalate_and_file_incident_files_p0_and_emits_ambient_event() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        let stub = write_stub_chump(&dir, "INFRA-9001");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::set_var("CHUMP_BIN", &stub);

        let action = EscalationAction {
            agent_a: "agent-a".to_string(),
            agent_b: "agent-b".to_string(),
            confidence: 0.9,
            title: "Predicted collision breakage: agent-a x agent-b".to_string(),
        };

        let gap_id = escalate_and_file_incident(&action).unwrap();
        assert_eq!(gap_id.as_deref(), Some("INFRA-9001"));

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"collision_escalation\""));
        assert!(contents.contains("\"action\":\"dispatch_escalate\""));
        assert!(contents.contains("\"gap_id\":\"INFRA-9001\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        std::env::remove_var("CHUMP_BIN");
    }

    #[test]
    fn handle_predictions_auto_files_p0_for_predicted_breakage() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        let stub = write_stub_chump(&dir, "INFRA-9002");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::set_var("CHUMP_BIN", &stub);

        let predictions = vec![CollisionPrediction {
            agent_a: "agent-a".to_string(),
            agent_b: "agent-b".to_string(),
            predicted_ts_offset_s: 3.0,
            confidence: 0.9,
        }];

        let gap_id = handle_predictions(&predictions).unwrap();
        assert_eq!(gap_id.as_deref(), Some("INFRA-9002"));

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"collision_prediction\""));
        assert!(contents.contains("\"kind\":\"collision_escalation\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        std::env::remove_var("CHUMP_BIN");
    }

    #[test]
    fn handle_predictions_no_escalation_below_threshold() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::remove_var("CHUMP_BIN");

        let predictions = vec![CollisionPrediction {
            agent_a: "agent-a".to_string(),
            agent_b: "agent-b".to_string(),
            predicted_ts_offset_s: 3.0,
            confidence: 0.6,
        }];

        let gap_id = handle_predictions(&predictions).unwrap();
        assert_eq!(gap_id, None);

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"collision_prediction\""));
        assert!(!contents.contains("\"kind\":\"collision_escalation\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }
}
