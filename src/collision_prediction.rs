//! META-076 (META-073 slice): basic predictive collision detection.
//!
//! Takes mock agent position/velocity samples, projects each agent's
//! trajectory forward over a lookahead window, and checks whether any
//! pair of trajectories comes within a configurable distance threshold.
//! When they do, emits `kind=collision_prediction` to ambient.jsonl per
//! `docs/design/COLLISION_PREDICTION_SCHEMA.md`. This is the first
//! (mock-input) implementation the schema doc calls for — a real
//! lease/PR-graph predictor is later fleet-coordination work.

use std::path::PathBuf;

#[derive(Debug, Clone, Copy)]
pub struct Vec2 {
    pub x: f64,
    pub y: f64,
}

impl Vec2 {
    pub fn distance(&self, other: &Vec2) -> f64 {
        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
    }
}

/// A mock agent's kinematic state at prediction time.
#[derive(Debug, Clone)]
pub struct AgentState {
    pub session: String,
    pub position: Vec2,
    pub velocity: Vec2,
}

impl AgentState {
    fn position_at(&self, t: f64) -> Vec2 {
        Vec2 {
            x: self.position.x + self.velocity.x * t,
            y: self.position.y + self.velocity.y * t,
        }
    }
}

/// A predicted collision between two agents' trajectories.
#[derive(Debug, Clone)]
pub struct CollisionPrediction {
    pub agent_a: String,
    pub agent_b: String,
    pub predicted_collision_s: f64,
    pub min_distance: f64,
    pub confidence: f64,
}

/// Detector config. `distance_threshold` is how close two agents' projected
/// positions must come to count as a collision; `confidence_threshold` is
/// the minimum confidence required for a prediction to be reported
/// (AC#3 — configurable).
#[derive(Debug, Clone, Copy)]
pub struct DetectorConfig {
    pub distance_threshold: f64,
    pub confidence_threshold: f64,
    pub lookahead_s: f64,
    pub steps: u32,
}

impl Default for DetectorConfig {
    fn default() -> Self {
        Self {
            distance_threshold: 1.0,
            confidence_threshold: 0.5,
            lookahead_s: 10.0,
            steps: 20,
        }
    }
}

/// Confidence rises as the closest approach gets tighter relative to the
/// threshold — a graze at exactly the threshold scores low, a direct
/// overlap scores near 1.0.
fn confidence_from_distance(min_distance: f64, threshold: f64) -> f64 {
    if threshold <= 0.0 {
        return if min_distance <= 0.0 { 1.0 } else { 0.0 };
    }
    let ratio = (threshold - min_distance) / threshold;
    ratio.clamp(0.0, 1.0)
}

/// Projects every pair of agents forward over `lookahead_s` and reports
/// any pair whose closest approach is within `distance_threshold` AND
/// whose resulting confidence clears `confidence_threshold`.
pub fn detect_collisions(
    agents: &[AgentState],
    config: DetectorConfig,
) -> Vec<CollisionPrediction> {
    let mut out = Vec::new();
    let steps = config.steps.max(1);
    for i in 0..agents.len() {
        for j in (i + 1)..agents.len() {
            let a = &agents[i];
            let b = &agents[j];
            let mut min_distance = f64::MAX;
            let mut min_t = 0.0;
            for step in 0..=steps {
                let t = config.lookahead_s * (step as f64) / (steps as f64);
                let d = a.position_at(t).distance(&b.position_at(t));
                if d < min_distance {
                    min_distance = d;
                    min_t = t;
                }
            }
            if min_distance <= config.distance_threshold {
                let confidence = confidence_from_distance(min_distance, config.distance_threshold);
                if confidence >= config.confidence_threshold {
                    out.push(CollisionPrediction {
                        agent_a: a.session.clone(),
                        agent_b: b.session.clone(),
                        predicted_collision_s: min_t,
                        min_distance,
                        confidence,
                    });
                }
            }
        }
    }
    out
}

fn ambient_path() -> PathBuf {
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(root).join(".chump-locks/ambient.jsonl")
}

/// Emits `kind=collision_prediction` for each detected prediction.
pub fn emit_predictions(predictions: &[CollisionPrediction]) {
    let path = ambient_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    else {
        return;
    };
    use std::io::Write;
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    for p in predictions {
        let event = serde_json::json!({
            "ts": now,
            "kind": "collision_prediction",
            "schema_version": "collision-prediction-v1",
            "agents": [p.agent_a, p.agent_b],
            "predicted_collision_s": p.predicted_collision_s,
            "min_distance": p.min_distance,
            "confidence": p.confidence,
        });
        let _ = writeln!(f, "{event}");
    }
}

/// Mock agent fixture used by `chump collision-predict --demo` and tests.
pub fn mock_agents() -> Vec<AgentState> {
    vec![
        AgentState {
            session: "session-a".to_string(),
            position: Vec2 { x: 0.0, y: 0.0 },
            velocity: Vec2 { x: 1.0, y: 0.0 },
        },
        AgentState {
            session: "session-b".to_string(),
            position: Vec2 { x: 10.0, y: 0.0 },
            velocity: Vec2 { x: -1.0, y: 0.0 },
        },
        AgentState {
            session: "session-c".to_string(),
            position: Vec2 { x: 0.0, y: 100.0 },
            velocity: Vec2 { x: 0.0, y: 1.0 },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn head_on_agents_predict_collision() {
        let agents = mock_agents();
        let config = DetectorConfig::default();
        let predictions = detect_collisions(&agents, config);
        assert_eq!(predictions.len(), 1);
        assert_eq!(predictions[0].agent_a, "session-a");
        assert_eq!(predictions[0].agent_b, "session-b");
        assert!(predictions[0].confidence >= config.confidence_threshold);
    }

    #[test]
    fn diverging_agent_not_included() {
        let agents = mock_agents();
        let predictions = detect_collisions(&agents, DetectorConfig::default());
        assert!(!predictions
            .iter()
            .any(|p| p.agent_a == "session-c" || p.agent_b == "session-c"));
    }

    #[test]
    fn confidence_threshold_is_configurable() {
        let agents = mock_agents();
        let loose = DetectorConfig {
            confidence_threshold: 0.0,
            ..DetectorConfig::default()
        };
        let strict = DetectorConfig {
            confidence_threshold: 0.99,
            ..DetectorConfig::default()
        };
        let loose_predictions = detect_collisions(&agents, loose);
        let strict_predictions = detect_collisions(&agents, strict);
        assert!(loose_predictions.len() >= strict_predictions.len());
    }

    #[test]
    fn distance_threshold_zero_requires_exact_overlap() {
        let agents = vec![
            AgentState {
                session: "x".to_string(),
                position: Vec2 { x: 0.0, y: 0.0 },
                velocity: Vec2 { x: 0.0, y: 0.0 },
            },
            AgentState {
                session: "y".to_string(),
                position: Vec2 { x: 5.0, y: 0.0 },
                velocity: Vec2 { x: 0.0, y: 0.0 },
            },
        ];
        let config = DetectorConfig {
            distance_threshold: 0.0,
            confidence_threshold: 0.0,
            ..DetectorConfig::default()
        };
        assert!(detect_collisions(&agents, config).is_empty());
    }
}
