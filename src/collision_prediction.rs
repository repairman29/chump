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

use std::fs;
use std::io::Write as IoWrite;

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
}
