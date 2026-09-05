//! FLEET-009 — structured agent capability + task requirement schema
//! with a transport-agnostic `fit_score()` matcher.
//!
//! Local-first by design: each agent serializes its [`AgentCapability`] to
//! `.chump-locks/capabilities/<session>.json` on startup; peer agents read
//! those files to evaluate fit. A future transport gap (FLEET-006/007) can
//! republish the same JSON onto NATS / WebSocket without changing the
//! schema or the matcher.
//!
//! This is additive to [`crate::fleet::FleetPeer`] (which uses a free-form
//! `Vec<String>` of capability tags). Structured capabilities live here;
//! the legacy tags remain for backward compatibility until callers migrate.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Structured capability declaration published by an agent.
///
/// Fields are intentionally narrow: model identity, hardware budget,
/// throughput, and the task classes the agent has been trained / tested on.
/// Reliability is a learned scalar in `[0.0, 1.0]` tracking past success rate
/// (defaults to `0.5` for a fresh agent — neither trusted nor distrusted).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentCapability {
    pub agent_id: String,
    pub model_family: String,
    pub model_name: String,
    pub vram_gb: f32,
    pub inference_speed_tok_per_sec: f32,
    pub supported_task_classes: Vec<String>,
    #[serde(default = "default_reliability")]
    pub reliability_score: f32,
}

fn default_reliability() -> f32 {
    0.5
}

/// Requirements declared by a task (subset of [`AgentCapability`]).
///
/// `min_*` floors are hard constraints — an agent that misses a floor scores
/// `0.0` (will not be matched). `task_class` is hard if `Some`; `None`
/// means "any class is acceptable" (caller is doing free-form work).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskRequirement {
    pub task_id: String,
    #[serde(default)]
    pub required_model_family: Option<String>,
    #[serde(default)]
    pub min_vram_gb: f32,
    #[serde(default)]
    pub min_inference_speed_tok_per_sec: f32,
    #[serde(default)]
    pub task_class: Option<String>,
}

/// Fitness in `[0.0, 1.0]`. Hard misses (model family, VRAM, speed, class)
/// short-circuit to `0.0`. Soft fit weights structured capability headroom
/// against reliability so an oversized + reliable agent scores higher than
/// a barely-passing flaky one.
///
/// Weights:
///   * 0.40 — task class match (hard, 1.0 if class in `supported_task_classes`
///     or no class required; 0.0 otherwise)
///   * 0.30 — reliability score (passed through directly)
///   * 0.20 — VRAM headroom (saturates at 2× the floor)
///   * 0.10 — speed headroom (saturates at 2× the floor)
///
/// Caller threshold per FLEET-009 acceptance: `>= 0.5` means "claim this work."
pub fn fit_score(cap: &AgentCapability, req: &TaskRequirement) -> f32 {
    if let Some(family) = &req.required_model_family {
        if !cap.model_family.eq_ignore_ascii_case(family) {
            return 0.0;
        }
    }
    if cap.vram_gb < req.min_vram_gb {
        return 0.0;
    }
    if cap.inference_speed_tok_per_sec < req.min_inference_speed_tok_per_sec {
        return 0.0;
    }

    let class_score = match &req.task_class {
        None => 1.0,
        Some(c) => {
            if cap
                .supported_task_classes
                .iter()
                .any(|s| s.eq_ignore_ascii_case(c))
            {
                1.0
            } else {
                return 0.0;
            }
        }
    };

    let vram_headroom = if req.min_vram_gb <= 0.0 {
        1.0
    } else {
        ((cap.vram_gb / req.min_vram_gb - 1.0) / 1.0).clamp(0.0, 1.0)
    };
    let speed_headroom = if req.min_inference_speed_tok_per_sec <= 0.0 {
        1.0
    } else {
        ((cap.inference_speed_tok_per_sec / req.min_inference_speed_tok_per_sec - 1.0) / 1.0)
            .clamp(0.0, 1.0)
    };
    let reliability = cap.reliability_score.clamp(0.0, 1.0);

    0.40 * class_score + 0.30 * reliability + 0.20 * vram_headroom + 0.10 * speed_headroom
}

/// Threshold at and above which an agent should claim work (FLEET-009 AC).
pub const CLAIM_THRESHOLD: f32 = 0.5;

/// Returns true if `cap` should claim a task with `req`.
pub fn should_claim(cap: &AgentCapability, req: &TaskRequirement) -> bool {
    fit_score(cap, req) >= CLAIM_THRESHOLD
}

/// A node's hardware-derived fit list plus the POLICY layer that can veto or
/// pin a role regardless of fit (RESILIENT-1032, Node Fabric component #2).
///
/// `roles_fit` (populated by `scripts/dispatch/node-describe.sh`) answers
/// "can this node's hardware run this role" — necessary but not sufficient.
/// `roles_veto` and `pinned_role` answer "should it": closetjunky (CJ) FITS
/// `build-worker` on paper (4 cores, 46G free) but its 7GB of RAM OOMs during
/// a real build, so policy vetoes `build-worker` and pins CJ to `gpu-embed`
/// only. `fit != assignment`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct NodeProfile {
    pub node_id: String,
    #[serde(default)]
    pub roles_fit: Vec<String>,
    #[serde(default)]
    pub roles_veto: Vec<String>,
    #[serde(default)]
    pub pinned_role: Option<String>,
}

/// Returns true if `role` may be assigned to `node`. A role must both fit
/// (`roles_fit`) and clear the policy layer: if `pinned_role` is set, only
/// that exact role is assignable regardless of what else fits; otherwise any
/// fitting role not present in `roles_veto` is assignable.
pub fn role_assignable(node: &NodeProfile, role: &str) -> bool {
    if !node.roles_fit.iter().any(|r| r.eq_ignore_ascii_case(role)) {
        return false;
    }
    if let Some(pinned) = &node.pinned_role {
        return pinned.eq_ignore_ascii_case(role);
    }
    !node.roles_veto.iter().any(|v| v.eq_ignore_ascii_case(role))
}

/// The subset of `roles_fit` that actually clears policy — what the
/// placement engine may assign to this node right now.
pub fn assigned_roles(node: &NodeProfile) -> Vec<String> {
    node.roles_fit
        .iter()
        .filter(|r| role_assignable(node, r))
        .cloned()
        .collect()
}

/// Load a node's fit + policy profile from a `docs/fleet/nodes/<id>.json`
/// registry file. Unknown fields (hardware, services_running, capability)
/// are ignored — this reads only the placement-policy slice of the schema.
pub fn load_node_profile(path: &Path) -> Result<NodeProfile> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading node profile {}", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("parsing node profile {}", path.display()))
}

/// Default location for a session's capability publication.
/// `<repo-root>/.chump-locks/capabilities/<session_id>.json`.
pub fn capability_path(repo_root: &Path, session_id: &str) -> PathBuf {
    repo_root
        .join(".chump-locks")
        .join("capabilities")
        .join(format!("{session_id}.json"))
}

/// Serialize and atomically write a capability declaration to the
/// session-scoped path under `.chump-locks/capabilities/`.
pub fn publish_local(cap: &AgentCapability, repo_root: &Path) -> Result<PathBuf> {
    let dir = repo_root.join(".chump-locks").join("capabilities");
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("creating capability dir {}", dir.display()))?;
    let path = capability_path(repo_root, &cap.agent_id);
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(cap)?;
    std::fs::write(&tmp, json).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, &path).with_context(|| format!("renaming {}", path.display()))?;
    Ok(path)
}

/// Read every published capability file under `.chump-locks/capabilities/`,
/// silently skipping malformed entries (logged via stderr). Used by peer
/// agents evaluating who is alive and what they can do.
pub fn read_all_local(repo_root: &Path) -> Result<Vec<AgentCapability>> {
    let dir = repo_root.join(".chump-locks").join("capabilities");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for entry in std::fs::read_dir(&dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("fleet_capability: skip unreadable {}: {e}", path.display());
                continue;
            }
        };
        match serde_json::from_str::<AgentCapability>(&text) {
            Ok(cap) => {
                if seen.insert(cap.agent_id.clone()) {
                    out.push(cap);
                }
            }
            Err(e) => {
                eprintln!("fleet_capability: skip malformed {}: {e}", path.display());
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn cap(name: &str, family: &str, vram: f32, speed: f32, classes: &[&str]) -> AgentCapability {
        AgentCapability {
            agent_id: name.into(),
            model_family: family.into(),
            model_name: format!("{family}-test"),
            vram_gb: vram,
            inference_speed_tok_per_sec: speed,
            supported_task_classes: classes.iter().map(|s| (*s).to_string()).collect(),
            reliability_score: 0.8,
        }
    }

    fn req(class: Option<&str>, family: Option<&str>, vram: f32, speed: f32) -> TaskRequirement {
        TaskRequirement {
            task_id: "T1".into(),
            required_model_family: family.map(String::from),
            min_vram_gb: vram,
            min_inference_speed_tok_per_sec: speed,
            task_class: class.map(String::from),
        }
    }

    #[test]
    fn family_mismatch_is_zero() {
        let c = cap("a1", "qwen", 24.0, 50.0, &["rust"]);
        let r = req(Some("rust"), Some("llama"), 8.0, 10.0);
        assert_eq!(fit_score(&c, &r), 0.0);
        assert!(!should_claim(&c, &r));
    }

    #[test]
    fn vram_below_floor_is_zero() {
        let c = cap("a1", "qwen", 4.0, 50.0, &["rust"]);
        let r = req(Some("rust"), Some("qwen"), 8.0, 10.0);
        assert_eq!(fit_score(&c, &r), 0.0);
    }

    #[test]
    fn unknown_task_class_is_zero() {
        let c = cap("a1", "qwen", 24.0, 50.0, &["docs"]);
        let r = req(Some("rust"), Some("qwen"), 8.0, 10.0);
        assert_eq!(fit_score(&c, &r), 0.0);
    }

    #[test]
    fn happy_path_above_threshold() {
        let c = cap("a1", "qwen", 24.0, 50.0, &["rust"]);
        let r = req(Some("rust"), Some("qwen"), 8.0, 10.0);
        let s = fit_score(&c, &r);
        assert!(s >= CLAIM_THRESHOLD, "score {s}");
        assert!(should_claim(&c, &r));
    }

    #[test]
    fn no_required_class_or_family_still_scores() {
        let c = cap("a1", "qwen", 24.0, 50.0, &["rust"]);
        let r = req(None, None, 0.0, 0.0);
        let s = fit_score(&c, &r);
        // class=1.0 (none required), reliability=0.8, vram_headroom=1.0 (floor=0), speed=1.0
        // = 0.40 + 0.30*0.8 + 0.20 + 0.10 = 0.94
        assert!((s - 0.94).abs() < 1e-3, "score {s}");
    }

    #[test]
    fn two_agents_only_one_claims() {
        // FLEET-009 acceptance test: mismatched capabilities → only one claims.
        let strong = cap("strong", "qwen", 24.0, 60.0, &["rust", "docs"]);
        let weak = cap("weak", "qwen", 4.0, 60.0, &["rust"]);
        let r = req(Some("rust"), Some("qwen"), 8.0, 10.0);
        assert!(should_claim(&strong, &r), "strong should claim");
        assert!(
            !should_claim(&weak, &r),
            "weak should NOT claim (vram floor)"
        );
    }

    #[test]
    fn publish_and_read_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let c = cap("sess-a", "qwen", 24.0, 50.0, &["rust"]);
        let path = publish_local(&c, tmp.path()).unwrap();
        assert!(path.exists());

        let all = read_all_local(tmp.path()).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0], c);
    }

    #[test]
    fn read_all_local_skips_malformed() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join(".chump-locks").join("capabilities");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("good.json"),
            serde_json::to_string(&cap("g", "q", 8.0, 10.0, &["x"])).unwrap(),
        )
        .unwrap();
        std::fs::write(dir.join("broken.json"), "{not json").unwrap();
        std::fs::write(dir.join("ignored.txt"), "hello").unwrap();

        let all = read_all_local(tmp.path()).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].agent_id, "g");
    }

    #[test]
    fn read_all_local_missing_dir_is_empty() {
        let tmp = TempDir::new().unwrap();
        let all = read_all_local(tmp.path()).unwrap();
        assert!(all.is_empty());
    }

    #[test]
    fn fit_without_policy_is_unrestricted() {
        let node = NodeProfile {
            node_id: "n1".into(),
            roles_fit: vec!["build-worker".into(), "ci-runner".into()],
            roles_veto: vec![],
            pinned_role: None,
        };
        assert!(role_assignable(&node, "build-worker"));
        assert!(role_assignable(&node, "ci-runner"));
        assert!(!role_assignable(&node, "gpu-embed")); // not in roles_fit
    }

    #[test]
    fn veto_blocks_a_role_that_fits() {
        // RESILIENT-1032: roles_fit lists build-worker, but policy vetoes it.
        let node = NodeProfile {
            node_id: "closetjunky".into(),
            roles_fit: vec!["gpu-embed".into(), "build-worker".into()],
            roles_veto: vec!["build-worker".into()],
            pinned_role: None,
        };
        assert!(
            !role_assignable(&node, "build-worker"),
            "hardware fit must not override policy veto"
        );
        assert!(role_assignable(&node, "gpu-embed"));
        assert_eq!(assigned_roles(&node), vec!["gpu-embed".to_string()]);
    }

    #[test]
    fn pinned_role_overrides_fit_even_without_explicit_veto() {
        let node = NodeProfile {
            node_id: "closetjunky".into(),
            roles_fit: vec![
                "gpu-embed".into(),
                "build-worker".into(),
                "ci-runner".into(),
            ],
            roles_veto: vec![],
            pinned_role: Some("gpu-embed".into()),
        };
        assert!(role_assignable(&node, "gpu-embed"));
        assert!(!role_assignable(&node, "build-worker"));
        assert!(!role_assignable(&node, "ci-runner"));
        assert_eq!(assigned_roles(&node), vec!["gpu-embed".to_string()]);
    }

    #[test]
    fn pinned_role_not_in_roles_fit_is_never_assignable() {
        // Pin can only narrow what fits, never grant a role hardware can't do.
        let node = NodeProfile {
            node_id: "n1".into(),
            roles_fit: vec!["build-worker".into()],
            roles_veto: vec![],
            pinned_role: Some("gpu-embed".into()),
        };
        assert!(!role_assignable(&node, "gpu-embed"));
        assert!(!role_assignable(&node, "build-worker"));
        assert!(assigned_roles(&node).is_empty());
    }

    #[test]
    fn closetjunky_registry_pins_gpu_embed_never_muscle() {
        // Loads the real node-registry fixture and proves CJ (4-core, 7GB
        // RAM) is barred from build-worker despite roles_fit listing it.
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("docs/fleet/nodes/closetjunky.json");
        let node = load_node_profile(&path).expect("closetjunky.json must parse");
        assert!(node.roles_fit.iter().any(|r| r == "build-worker"));
        assert!(
            !role_assignable(&node, "build-worker"),
            "CJ must never be assigned build-worker (7GB RAM OOMs on build)"
        );
        assert!(role_assignable(&node, "gpu-embed"));
    }
}
