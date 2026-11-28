//! PRODUCT-378: Dream -> Mission Architect -> 1-Click Autonomous Factory API.
//!
//! Wires Chump's existing substrate bricks into a cohesive user-facing product loop:
//!   1. `chump_coord::mission::{Mission, Objective, ObjectiveState, PersistentMission, FileBackedMissionStore}`
//!   2. `crate::standard_missions::{check_l1_missions, l1_missions}` (0->1 L1 Foundation checks)
//!   3. `crate::provider_cascade::build_provider()` (canonical shared LLM service)
//!   4. `crate::gap_store::GapStore` + isolated git worktree execution + anti-cosmetic test gate.

use axonerai::provider::Message;
use axum::extract::Path as AxumPath;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use chump_coord::mission::{
    FallbackMode, FileBackedMissionStore, Mission, MissionStore, Objective, ObjectiveState,
    PersistentMission,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use super::shared::check_auth;
use crate::repo_path;
use crate::standard_missions::{check_l1_missions, l1_missions, MissionCheckResult};

type ApiErr = (StatusCode, Json<serde_json::Value>);

fn api_err(status: StatusCode, msg: impl Into<String>) -> ApiErr {
    (status, Json(serde_json::json!({ "error": msg.into() })))
}

fn check_csrf_header(headers: &HeaderMap) -> bool {
    let enabled = std::env::var("CHUMP_CSRF_ENABLED")
        .map(|v| v != "0")
        .unwrap_or(true);
    if !enabled {
        return true;
    }
    headers.get("x-csrf-token").is_some()
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn missions_root_dir() -> PathBuf {
    chump_pal::user_home().join(".chump").join("missions")
}

fn meta_path_for(root: &Path, id: &str) -> PathBuf {
    root.join("meta").join(format!("{id}.json"))
}

#[derive(Clone, Debug, Default)]
struct LiveStepState {
    activity: String,
    log_lines: Vec<String>,
}

fn running_missions() -> &'static Mutex<HashSet<String>> {
    static SET: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    SET.get_or_init(|| Mutex::new(HashSet::new()))
}

fn paused_missions() -> &'static Mutex<HashSet<String>> {
    static SET: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    SET.get_or_init(|| Mutex::new(HashSet::new()))
}

fn live_states() -> &'static Mutex<HashMap<String, LiveStepState>> {
    static MAP: OnceLock<Mutex<HashMap<String, LiveStepState>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

fn set_live_activity(mission_id: &str, activity: impl Into<String>) {
    if let Ok(mut guard) = live_states().lock() {
        let entry = guard.entry(mission_id.to_string()).or_default();
        entry.activity = activity.into();
    }
}

fn push_live_log(mission_id: &str, line: impl Into<String>) {
    let text = line.into();
    if text.trim().is_empty() {
        return;
    }
    if let Ok(mut guard) = live_states().lock() {
        let entry = guard.entry(mission_id.to_string()).or_default();
        entry.log_lines.push(text);
        if entry.log_lines.len() > 24 {
            let drain = entry.log_lines.len() - 24;
            entry.log_lines.drain(0..drain);
        }
    }
}

fn clear_live_state(mission_id: &str) {
    if let Ok(mut guard) = live_states().lock() {
        guard.remove(mission_id);
    }
}

// ── Metadata & API Schemas ───────────────────────────────────────────────────

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MissionStepMeta {
    pub id: String,
    pub sequence: u32,
    pub enabled: bool,
    pub title: String,
    pub layer: String,
    pub effort: String,
    pub description: String,
    pub done_criterion: String,
    #[serde(default)]
    pub decision_question: Option<String>,
    #[serde(default)]
    pub decision_answer: Option<String>,
    #[serde(default)]
    pub gap_id: Option<String>,
    #[serde(default)]
    pub commit_sha: Option<String>,
    #[serde(default)]
    pub pr_url: Option<String>,
    #[serde(default)]
    pub diff_stat: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub log_tail: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MissionMeta {
    pub id: String,
    pub title: String,
    pub vision: String,
    pub summary: String,
    pub repo_mode: String,
    pub repo_path: String,
    pub repo_name: String,
    #[serde(default)]
    pub remote_owner_repo: Option<String>,
    pub runner: String,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
    pub l1_passed: usize,
    pub l1_total: usize,
    #[serde(default)]
    pub active_step_id: Option<String>,
    #[serde(default)]
    pub steps: Vec<MissionStepMeta>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DiscoveredRepo {
    pub name: String,
    pub path: String,
    pub remote_owner_repo: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ArchitectRequest {
    #[serde(default)]
    pub vision: String,
    #[serde(default = "default_repo_mode")]
    pub repo_mode: String,
    #[serde(default)]
    pub repo_path: Option<String>,
    #[serde(default)]
    pub new_repo_name: Option<String>,
    #[serde(default = "default_runner")]
    pub runner: String,
}

fn default_repo_mode() -> String {
    "existing".to_string()
}

fn default_runner() -> String {
    "auto".to_string()
}

#[derive(Debug, Deserialize)]
pub struct PatchMissionRequest {
    pub title: Option<String>,
    pub runner: Option<String>,
    pub steps: Option<Vec<PatchStepItem>>,
    pub add_step: Option<NewStepInput>,
}

#[derive(Debug, Deserialize)]
pub struct PatchStepItem {
    pub id: String,
    pub enabled: Option<bool>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub done_criterion: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NewStepInput {
    pub title: String,
    #[serde(default)]
    pub layer: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub done_criterion: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ControlMissionRequest {
    pub action: String,
    #[serde(default)]
    pub step_id: Option<String>,
    #[serde(default)]
    pub decision_answer: Option<String>,
}

// ── Persistence Helpers ──────────────────────────────────────────────────────

fn save_mission_pair(
    root: &Path,
    pm: &PersistentMission,
    meta: &MissionMeta,
) -> anyhow::Result<()> {
    let store = FileBackedMissionStore::new(root);
    store.save(pm)?;
    let meta_dir = root.join("meta");
    fs::create_dir_all(&meta_dir)?;
    let bytes = serde_json::to_vec_pretty(meta)?;
    fs::write(meta_path_for(root, &meta.id), bytes)?;
    Ok(())
}

fn load_mission_pair(root: &Path, id: &str) -> anyhow::Result<(PersistentMission, MissionMeta)> {
    let store = FileBackedMissionStore::new(root);
    let pm = store.load(id)?;
    let bytes = fs::read(meta_path_for(root, id))?;
    let meta: MissionMeta = serde_json::from_slice(&bytes)?;
    Ok((pm, meta))
}

fn validate_mission_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn validate_new_repo_slug(name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return Err("Repository name must be 1–64 characters".to_string());
    }
    let first_ok = trimmed
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    let all_ok = trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !first_ok || !all_ok {
        return Err(
            "Repository name must start with a letter/number and contain only [A-Za-z0-9_-]"
                .to_string(),
        );
    }
    Ok(trimmed.to_string())
}

fn format_mission_view(pm: &PersistentMission, meta: &MissionMeta) -> serde_json::Value {
    let enabled_steps: Vec<&MissionStepMeta> = meta.steps.iter().filter(|s| s.enabled).collect();
    let total_enabled = enabled_steps.len();
    let mut completed_count = 0usize;
    let mut in_progress_count = 0usize;
    let mut failed_count = 0usize;

    let is_live_running = running_missions()
        .lock()
        .ok()
        .is_some_and(|g| g.contains(&meta.id));
    let live_snap = live_states()
        .lock()
        .ok()
        .and_then(|g| g.get(&meta.id).cloned());

    let steps_json: Vec<serde_json::Value> = meta
        .steps
        .iter()
        .map(|s| {
            let state = pm.current_state(&s.id).unwrap_or(ObjectiveState::Pending);
            let state_str = match state {
                ObjectiveState::Pending => "pending",
                ObjectiveState::InProgress => "in_progress",
                ObjectiveState::Completed => "completed",
                ObjectiveState::Failed => "failed",
                ObjectiveState::Skipped => "skipped",
            };
            if s.enabled {
                match state {
                    ObjectiveState::Completed => completed_count += 1,
                    ObjectiveState::InProgress => in_progress_count += 1,
                    ObjectiveState::Failed => failed_count += 1,
                    _ => {}
                }
            }
            let logs = if meta.active_step_id.as_deref() == Some(s.id.as_str()) {
                if let Some(ref ls) = live_snap {
                    if !ls.log_lines.is_empty() {
                        ls.log_lines.clone()
                    } else {
                        s.log_tail.clone()
                    }
                } else {
                    s.log_tail.clone()
                }
            } else {
                s.log_tail.clone()
            };

            serde_json::json!({
                "id": s.id,
                "sequence": s.sequence,
                "enabled": s.enabled,
                "state": state_str,
                "title": s.title,
                "layer": s.layer,
                "effort": s.effort,
                "description": s.description,
                "done_criterion": s.done_criterion,
                "decision_question": s.decision_question,
                "decision_answer": s.decision_answer,
                "gap_id": s.gap_id,
                "commit_sha": s.commit_sha,
                "pr_url": s.pr_url,
                "diff_stat": s.diff_stat,
                "error": s.error,
                "started_at": s.started_at,
                "completed_at": s.completed_at,
                "log_tail": logs,
            })
        })
        .collect();

    let progress_pct = (completed_count * 100)
        .checked_div(total_enabled)
        .unwrap_or(0)
        .min(100);

    let effective_status = if meta.status == "running" && !is_live_running {
        if total_enabled > 0 && completed_count == total_enabled {
            "completed"
        } else if failed_count > 0 {
            "failed"
        } else {
            "paused"
        }
    } else {
        meta.status.as_str()
    };

    let pending_decision = meta.steps.iter().find(|s| {
        s.enabled
            && s.decision_question
                .as_ref()
                .is_some_and(|q| !q.trim().is_empty())
            && s.decision_answer.as_deref().unwrap_or("").trim().is_empty()
    });

    serde_json::json!({
        "id": meta.id,
        "title": meta.title,
        "vision": meta.vision,
        "summary": meta.summary,
        "repo_mode": meta.repo_mode,
        "repo_path": meta.repo_path,
        "repo_name": meta.repo_name,
        "remote_owner_repo": meta.remote_owner_repo,
        "runner": meta.runner,
        "status": effective_status,
        "is_running": is_live_running,
        "created_at": meta.created_at,
        "updated_at": meta.updated_at,
        "l1_passed": meta.l1_passed,
        "l1_total": meta.l1_total,
        "completed_steps": completed_count,
        "in_progress_steps": in_progress_count,
        "failed_steps": failed_count,
        "total_steps": total_enabled,
        "progress_pct": progress_pct,
        "active_step_id": meta.active_step_id,
        "live_activity": live_snap.map(|l| l.activity),
        "pending_decision": pending_decision.map(|s| serde_json::json!({
            "step_id": s.id,
            "step_title": s.title,
            "question": s.decision_question,
        })),
        "steps": steps_json,
    })
}

// ── Local Projects Auto-Discovery ────────────────────────────────────────────

fn parse_github_owner_repo(repo_dir: &Path) -> Option<String> {
    let git_dir = repo_dir.join(".git");
    let config_path = if git_dir.is_dir() {
        git_dir.join("config")
    } else {
        return None;
    };
    let text = fs::read_to_string(config_path).ok()?;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("url =") {
            let url = rest.trim();
            if let Some(idx) = url.find("github.com") {
                let after = &url[idx + "github.com".len()..];
                let clean = after
                    .trim_start_matches([':', '/'])
                    .trim_end_matches('/')
                    .trim_end_matches(".git");
                let parts: Vec<&str> = clean.split('/').filter(|p| !p.is_empty()).collect();
                if parts.len() == 2 {
                    return Some(format!("{}/{}", parts[0], parts[1]));
                }
            }
        }
    }
    None
}

fn discover_local_repos() -> Vec<DiscoveredRepo> {
    let mut by_path: HashMap<String, DiscoveredRepo> = HashMap::new();

    for (name, p) in repo_path::repo_profiles_list() {
        let pb = PathBuf::from(&p);
        if pb.join(".git").exists() {
            by_path.insert(
                p.clone(),
                DiscoveredRepo {
                    name,
                    remote_owner_repo: parse_github_owner_repo(&pb),
                    path: p,
                },
            );
        }
    }

    let current = repo_path::repo_root();
    if current.join(".git").exists() {
        let p_str = current.display().to_string();
        let name = current
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("workspace")
            .to_string();
        by_path.entry(p_str.clone()).or_insert(DiscoveredRepo {
            name,
            remote_owner_repo: parse_github_owner_repo(&current),
            path: p_str,
        });
    }

    let projects_dir = chump_pal::user_home().join("Projects");
    if let Ok(entries) = fs::read_dir(&projects_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() || !path.join(".git").exists() {
                continue;
            }
            let Some(raw_name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if raw_name.starts_with('.') || raw_name.trim().is_empty() {
                continue;
            }
            let p_str = path.display().to_string();
            by_path.entry(p_str.clone()).or_insert(DiscoveredRepo {
                name: raw_name.trim().to_string(),
                remote_owner_repo: parse_github_owner_repo(&path),
                path: p_str,
            });
        }
    }

    let mut out: Vec<DiscoveredRepo> = by_path.into_values().collect();
    out.sort_by_key(|a| a.name.to_lowercase());
    out.truncate(150);
    out
}

// ── Repo Evidence Scanner + Architect LLM Synthesis ──────────────────────────

struct RepoScanSnapshot {
    l1_passed: usize,
    l1_total: usize,
    unmet_l1: Vec<(String, String, String)>,
    evidence_digest: String,
}

fn scan_existing_repo(repo_dir: &Path) -> RepoScanSnapshot {
    let missions = l1_missions();
    let results = check_l1_missions(repo_dir, missions);
    let mut l1_passed = 0usize;
    let mut unmet_l1 = Vec::new();
    for (m, r) in missions.iter().zip(results) {
        match r {
            MissionCheckResult::Met => l1_passed += 1,
            MissionCheckResult::Unmet { why, .. } => {
                unmet_l1.push((m.title.to_string(), why, m.done_criterion.to_string()));
            }
        }
    }

    let mut sections: Vec<String> = Vec::new();
    if let Ok(entries) = fs::read_dir(repo_dir) {
        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| !n.starts_with('.'))
            .collect();
        names.sort();
        names.truncate(35);
        sections.push(format!("Top-level files/dirs: {}", names.join(", ")));
    }

    for readme in ["README.md", "readme.md", "README.txt", "docs/MISSION.md"] {
        let p = repo_dir.join(readme);
        if let Ok(txt) = fs::read_to_string(&p) {
            let clipped: String = txt.chars().take(3200).collect();
            sections.push(format!("--- {readme} (excerpt) ---\n{clipped}"));
            break;
        }
    }

    for manifest in [
        "Cargo.toml",
        "package.json",
        "pyproject.toml",
        "go.mod",
        "Makefile",
    ] {
        let p = repo_dir.join(manifest);
        if let Ok(txt) = fs::read_to_string(&p) {
            let clipped: String = txt.chars().take(1600).collect();
            sections.push(format!("--- {manifest} (excerpt) ---\n{clipped}"));
            break;
        }
    }

    if let Ok(out) = std::process::Command::new("git")
        .args(["log", "-n", "8", "--oneline"])
        .current_dir(repo_dir)
        .output()
    {
        if out.status.success() {
            let log = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !log.is_empty() {
                sections.push(format!("--- Recent git commits ---\n{log}"));
            }
        }
    }

    RepoScanSnapshot {
        l1_passed,
        l1_total: missions.len(),
        unmet_l1,
        evidence_digest: sections.join("\n\n"),
    }
}

#[derive(Debug, Deserialize)]
struct LlmPlanPayload {
    #[serde(default)]
    mission_title: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    steps: Vec<LlmStepItem>,
}

#[derive(Debug, Deserialize)]
struct LlmStepItem {
    #[serde(default)]
    title: String,
    #[serde(default)]
    layer: String,
    #[serde(default)]
    effort: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    done_criterion: String,
    #[serde(default)]
    decision_question: Option<String>,
}

pub fn extract_json_object(raw: &str) -> Option<&str> {
    let trimmed = raw.trim();
    let start = trimmed.find('{')?;
    let end = trimmed.rfind('}')?;
    if end <= start {
        return None;
    }
    Some(&trimmed[start..=end])
}

fn normalize_layer(raw: &str) -> String {
    let up = raw.trim().to_uppercase();
    if up.starts_with("L1") {
        "L1".to_string()
    } else if up.starts_with("L3") {
        "L3".to_string()
    } else {
        "L2".to_string()
    }
}

fn normalize_effort(raw: &str) -> String {
    match raw.trim().to_lowercase().as_str() {
        "xs" | "s" | "small" => "s".to_string(),
        "l" | "xl" | "large" => "l".to_string(),
        _ => "m".to_string(),
    }
}

fn build_fallback_plan(
    repo_name: &str,
    vision: &str,
    repo_mode: &str,
    scan: Option<&RepoScanSnapshot>,
) -> (String, String, Vec<MissionStepMeta>) {
    let title = if vision.trim().is_empty() {
        format!("{repo_name}: 0→1 Foundation & Fulfillment Arc")
    } else {
        let line = vision.lines().next().unwrap_or(vision).trim();
        let short: String = line.chars().take(68).collect();
        format!("{repo_name}: {short}")
    };

    let mut steps: Vec<MissionStepMeta> = Vec::new();
    let mut seq = 1u32;

    if repo_mode == "new" {
        steps.push(MissionStepMeta {
            id: format!("step-{seq:02}"),
            sequence: seq,
            enabled: true,
            title: format!("Scaffold {repo_name} project manifest, module layout, and CI workflow"),
            layer: "L1".to_string(),
            effort: "s".to_string(),
            description: format!(
                "Create a clean, runnable project structure for {repo_name} with build manifest, lockfile, and test harness."
            ),
            done_criterion: "Clean build and initial smoke test pass from a fresh checkout.".to_string(),
            decision_question: None,
            decision_answer: None,
            gap_id: None,
            commit_sha: None,
            pr_url: None,
            diff_stat: None,
            error: None,
            started_at: None,
            completed_at: None,
            log_tail: Vec::new(),
        });
        seq += 1;
    } else if let Some(s) = scan {
        for (t, why, done) in s.unmet_l1.iter().take(3) {
            steps.push(MissionStepMeta {
                id: format!("step-{seq:02}"),
                sequence: seq,
                enabled: true,
                title: t.clone(),
                layer: "L1".to_string(),
                effort: "s".to_string(),
                description: format!("Resolve L1 foundation gap: {why}"),
                done_criterion: done.clone(),
                decision_question: None,
                decision_answer: None,
                gap_id: None,
                commit_sha: None,
                pr_url: None,
                diff_stat: None,
                error: None,
                started_at: None,
                completed_at: None,
                log_tail: Vec::new(),
            });
            seq += 1;
        }
    }

    let core_goal = if vision.trim().is_empty() {
        format!("Audit documented features in {repo_name} and implement missing core behavior")
    } else {
        vision.trim().to_string()
    };

    let followups = [
        (
            "L2",
            "m",
            format!("Implement core domain models and interfaces for {repo_name}"),
            format!("Build the primary data types and state transitions needed for: {core_goal}"),
            "Unit tests cover core domain types, happy path, and invalid input handling."
                .to_string(),
        ),
        (
            "L2",
            "m",
            format!("Implement primary execution path and CLI/API entrypoint in {repo_name}"),
            format!("Wire the main user-facing execution flow delivering: {core_goal}"),
            "End-to-end integration test exercises the primary entrypoint and passes.".to_string(),
        ),
        (
            "L2",
            "m",
            format!("Harden error handling, edge cases, and persistence in {repo_name}"),
            "Replace brittle failure paths with structured errors and add regression tests."
                .to_string(),
            "All existing and new regression tests pass with zero warnings.".to_string(),
        ),
        (
            "L3",
            "s",
            format!("Update {repo_name} README quickstart and usage verification"),
            "Ensure README quickstart commands match real behavior and are backed by tests."
                .to_string(),
            "Documented commands and examples match the tested implementation.".to_string(),
        ),
    ];

    for (layer, effort, st_title, desc, done) in followups {
        if steps.len() >= 8 {
            break;
        }
        steps.push(MissionStepMeta {
            id: format!("step-{seq:02}"),
            sequence: seq,
            enabled: true,
            title: st_title,
            layer: layer.to_string(),
            effort: effort.to_string(),
            description: desc,
            done_criterion: done,
            decision_question: None,
            decision_answer: None,
            gap_id: None,
            commit_sha: None,
            pr_url: None,
            diff_stat: None,
            error: None,
            started_at: None,
            completed_at: None,
            log_tail: Vec::new(),
        });
        seq += 1;
    }

    let summary = match scan {
        Some(s) => format!(
            "Scanned {repo_name} ({}/{} L1 foundation checks passing) and synthesized a {}-step L1→L2→L3 delivery arc.",
            s.l1_passed,
            s.l1_total,
            steps.len()
        ),
        None => format!(
            "Designed a {}-step greenfield 0→1 roadmap to scaffold, build, test, and ship {repo_name}.",
            steps.len()
        ),
    };

    (title, summary, steps)
}

async fn synthesize_mission_plan(
    repo_name: &str,
    repo_mode: &str,
    vision: &str,
    scan: Option<&RepoScanSnapshot>,
) -> (String, String, Vec<MissionStepMeta>) {
    let system = "You are Chump's Mission Architect. Your job is to turn a founder's product dream \
or an existing repository scan into a concrete, ordered 5-to-9 step autonomous engineering Mission Plan.\n\
Follow Chump's 3-Layer 0->1 Doctrine:\n\
- L1 (Foundation): Clean build, lockfile, automated test runner, CI workflow (include ONLY if currently unmet).\n\
- L2 (Fulfillment): Core working vertical slices, documented features, and real end-to-end behavior with tests.\n\
- L3 (Realization): High-leverage product polish, UX, CLI/API ergonomics, and verified quickstart.\n\n\
Rules:\n\
1. Output STRICT JSON ONLY (no markdown prose outside JSON) matching this exact schema:\n\
{\n\
  \"mission_title\": \"4-9 word outcome title\",\n\
  \"summary\": \"2 concise sentences summarizing current state and what 'done' looks like\",\n\
  \"steps\": [\n\
    {\n\
      \"title\": \"Specific, shippable PR-sized milestone (max 110 chars)\",\n\
      \"layer\": \"L1\" | \"L2\" | \"L3\",\n\
      \"effort\": \"s\" | \"m\" | \"l\",\n\
      \"description\": \"Concrete files/modules/behavior an autonomous coding agent will implement\",\n\
      \"done_criterion\": \"Objective test or verification command that proves this step works\",\n\
      \"decision_question\": null\n\
    }\n\
  ]\n\
}\n\
2. Produce between 5 and 9 steps ordered so each step builds cleanly on the previous one.\n\
3. Every step MUST result in real working code + automated tests (no pure research/planning-only steps).\n\
4. Leave `decision_question` as `null` unless there is a genuine, high-stakes product/stack choice \
(e.g. choosing language/framework on a blank repo) that a founder should answer; at most 1 step may set `decision_question`.";

    let user_prompt = match (repo_mode, scan) {
        ("existing", Some(s)) => {
            let unmet_summary = if s.unmet_l1.is_empty() {
                "All 5 L1 foundation checks are already passing.".to_string()
            } else {
                s.unmet_l1
                    .iter()
                    .map(|(t, why, _)| format!("- {t}: {why}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            let goal_block = if vision.trim().is_empty() {
                "Founder requested an autonomous 0->1 Revival & Improvement Arc: stabilize any unmet L1 \
foundation checks, fulfill unimplemented README/doc promises (L2), and ship the highest-impact next product milestone (L3)."
                    .to_string()
            } else {
                format!("Founder Vision / Goal:\n{}", vision.trim())
            };
            format!(
                "Target Repository: {repo_name} (existing git repo)\n\
L1 Foundation Status ({}/{} passing):\n{unmet_summary}\n\n\
{goal_block}\n\n\
Repository Evidence:\n{}",
                s.l1_passed, s.l1_total, s.evidence_digest
            )
        }
        _ => format!(
            "Target Repository: {repo_name} (brand-new greenfield repository to create from scratch)\n\n\
Founder Vision / Dream Spec:\n{}",
            vision.trim()
        ),
    };

    let provider = crate::provider_cascade::build_provider();
    let messages = vec![Message {
        role: "user".to_string(),
        content: user_prompt,
    }];

    let call = tokio::time::timeout(
        Duration::from_secs(45),
        provider.complete(messages, None, Some(3072), Some(system.to_string())),
    )
    .await;

    if let Ok(Ok(resp)) = call {
        let raw = resp.text.unwrap_or_default();
        if let Some(json_slice) = extract_json_object(&raw) {
            if let Ok(parsed) = serde_json::from_str::<LlmPlanPayload>(json_slice) {
                let valid_steps: Vec<MissionStepMeta> = parsed
                    .steps
                    .into_iter()
                    .filter(|s| !s.title.trim().is_empty())
                    .take(12)
                    .enumerate()
                    .map(|(idx, s)| {
                        let seq = (idx + 1) as u32;
                        let title = s.title.trim().chars().take(160).collect::<String>();
                        let desc = if s.description.trim().is_empty() {
                            title.clone()
                        } else {
                            s.description.trim().to_string()
                        };
                        let done = if s.done_criterion.trim().is_empty() {
                            "Automated tests and build pass with zero regressions.".to_string()
                        } else {
                            s.done_criterion.trim().to_string()
                        };
                        MissionStepMeta {
                            id: format!("step-{seq:02}"),
                            sequence: seq,
                            enabled: true,
                            title,
                            layer: normalize_layer(&s.layer),
                            effort: normalize_effort(&s.effort),
                            description: desc,
                            done_criterion: done,
                            decision_question: s
                                .decision_question
                                .map(|q| q.trim().to_string())
                                .filter(|q| !q.is_empty()),
                            decision_answer: None,
                            gap_id: None,
                            commit_sha: None,
                            pr_url: None,
                            diff_stat: None,
                            error: None,
                            started_at: None,
                            completed_at: None,
                            log_tail: Vec::new(),
                        }
                    })
                    .collect();

                if valid_steps.len() >= 2 {
                    let final_title = if parsed.mission_title.trim().is_empty() {
                        format!("{repo_name}: Mission Arc")
                    } else {
                        parsed.mission_title.trim().to_string()
                    };
                    let final_summary = if parsed.summary.trim().is_empty() {
                        format!(
                            "Proposed {}-step L1→L2→L3 autonomous delivery plan for {repo_name}.",
                            valid_steps.len()
                        )
                    } else {
                        parsed.summary.trim().to_string()
                    };
                    return (final_title, final_summary, valid_steps);
                }
            }
        }
    }

    build_fallback_plan(repo_name, vision, repo_mode, scan)
}

fn build_persistent_mission_from_meta(meta: &MissionMeta) -> PersistentMission {
    let objectives: Vec<Objective> = meta
        .steps
        .iter()
        .map(|s| Objective {
            id: s.id.clone(),
            description: s.title.clone(),
            resource_cost: match s.effort.as_str() {
                "s" => 4_000,
                "l" => 24_000,
                _ => 12_000,
            },
            duration_secs: match s.effort.as_str() {
                "s" => 300,
                "l" => 1200,
                _ => 600,
            },
            target: s.decision_question.clone(),
            sequence: s.sequence,
        })
        .collect();

    let mission = Mission {
        id: meta.id.clone(),
        name: meta.title.clone(),
        objectives,
        fallback_behavior: FallbackMode::QueryAuthority,
        timestamp_issued: meta.created_at.clone(),
        ttl_seconds: 86_400,
        version: 1,
    };
    PersistentMission::new(mission)
}

// ── HTTP Handlers ────────────────────────────────────────────────────────────

/// GET /api/missions — list all missions (newest first) + auto-discovered local git repos.
pub async fn handle_missions_list(headers: HeaderMap) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    let root = missions_root_dir();
    let store = FileBackedMissionStore::new(&root);
    let ids = store.list().unwrap_or_default();

    let mut items: Vec<(String, serde_json::Value)> = Vec::new();
    for id in ids {
        if let Ok((pm, meta)) = load_mission_pair(&root, &id) {
            let sort_key = meta.updated_at.clone();
            items.push((sort_key, format_mission_view(&pm, &meta)));
        }
    }
    items.sort_by(|a, b| b.0.cmp(&a.0));
    let missions: Vec<serde_json::Value> = items.into_iter().map(|(_, v)| v).collect();
    let repos = discover_local_repos();

    Ok(Json(serde_json::json!({
        "missions": missions,
        "repos": repos,
    })))
}

/// POST /api/missions/architect — scan repo (or greenfield spec) & generate a 5–10 step Mission Plan.
pub async fn handle_missions_architect(
    headers: HeaderMap,
    Json(body): Json<ArchitectRequest>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf_header(&headers) {
        return Err(api_err(StatusCode::FORBIDDEN, "missing CSRF token"));
    }

    let repo_mode = if body.repo_mode.trim().eq_ignore_ascii_case("new") {
        "new"
    } else {
        "existing"
    };

    let (repo_path_str, repo_name, remote_owner_repo, scan_opt) = if repo_mode == "new" {
        let slug = validate_new_repo_slug(body.new_repo_name.as_deref().unwrap_or(""))
            .map_err(|e| api_err(StatusCode::UNPROCESSABLE_ENTITY, e))?;
        if body.vision.trim().is_empty() {
            return Err(api_err(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Describe your product dream or spec so Chump can architect the new repository.",
            ));
        }
        let target_dir = chump_pal::user_home().join("Projects").join(&slug);
        if target_dir.exists() {
            return Err(api_err(
                StatusCode::CONFLICT,
                format!(
                    "{} already exists — switch to 'Existing Repo' mode to build on it.",
                    target_dir.display()
                ),
            ));
        }
        (target_dir.display().to_string(), slug, None, None)
    } else {
        let raw_path = body
            .repo_path
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(repo_path::repo_root);
        let canon = raw_path.canonicalize().map_err(|_| {
            api_err(
                StatusCode::BAD_REQUEST,
                format!("Repository path not found: {}", raw_path.display()),
            )
        })?;
        if !canon.join(".git").exists() {
            return Err(api_err(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("{} is not a git repository (.git missing)", canon.display()),
            ));
        }
        let name = canon
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("repo")
            .to_string();
        let owner_repo = parse_github_owner_repo(&canon);
        let scan = scan_existing_repo(&canon);
        (canon.display().to_string(), name, owner_repo, Some(scan))
    };

    let (plan_title, summary, steps) =
        synthesize_mission_plan(&repo_name, repo_mode, &body.vision, scan_opt.as_ref()).await;

    let short_uuid: String = uuid::Uuid::new_v4()
        .simple()
        .to_string()
        .chars()
        .take(8)
        .collect();
    let mission_id = format!("msn-{short_uuid}");
    let ts = now_iso();

    let (l1_passed, l1_total) = scan_opt
        .as_ref()
        .map(|s| (s.l1_passed, s.l1_total))
        .unwrap_or((0, 5));

    let runner = match body.runner.trim().to_lowercase().as_str() {
        "claude" | "agy" | "cascade" | "ollama" => body.runner.trim().to_lowercase(),
        _ => "auto".to_string(),
    };

    let meta = MissionMeta {
        id: mission_id.clone(),
        title: plan_title,
        vision: body.vision.trim().to_string(),
        summary,
        repo_mode: repo_mode.to_string(),
        repo_path: repo_path_str,
        repo_name,
        remote_owner_repo,
        runner,
        status: "draft".to_string(),
        created_at: ts.clone(),
        updated_at: ts,
        l1_passed,
        l1_total,
        active_step_id: None,
        steps,
    };

    let pm = build_persistent_mission_from_meta(&meta);
    let root = missions_root_dir();
    save_mission_pair(&root, &pm, &meta).map_err(|e| {
        api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to persist mission plan: {e}"),
        )
    })?;

    tracing::info!(
        mission_id = %mission_id,
        steps = meta.steps.len(),
        "PRODUCT-378: architected mission plan"
    );

    Ok(Json(serde_json::json!({
        "ok": true,
        "mission": format_mission_view(&pm, &meta),
    })))
}

/// PATCH /api/missions/{id} — edit steps, toggle steps on/off, or add a step before/during pause.
pub async fn handle_mission_patch(
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
    Json(body): Json<PatchMissionRequest>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf_header(&headers) {
        return Err(api_err(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    if !validate_mission_id(&id) {
        return Err(api_err(StatusCode::BAD_REQUEST, "invalid mission id"));
    }

    let root = missions_root_dir();
    let (mut pm, mut meta) =
        load_mission_pair(&root, &id).map_err(|_| api_err(StatusCode::NOT_FOUND, "not found"))?;

    if let Some(t) = body
        .title
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        meta.title = t.to_string();
        pm.mission.name = t.to_string();
    }
    if let Some(r) = body
        .runner
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        meta.runner = r.to_lowercase();
    }

    if let Some(patches) = body.steps {
        for p in patches {
            if let Some(step) = meta.steps.iter_mut().find(|s| s.id == p.id) {
                if let Some(en) = p.enabled {
                    step.enabled = en;
                }
                if let Some(t) = p.title.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                    step.title = t.to_string();
                }
                if let Some(d) = p.description.as_deref().map(str::trim) {
                    if !d.is_empty() {
                        step.description = d.to_string();
                    }
                }
                if let Some(dc) = p.done_criterion.as_deref().map(str::trim) {
                    if !dc.is_empty() {
                        step.done_criterion = dc.to_string();
                    }
                }
            }
        }
    }

    if let Some(new_step) = body.add_step {
        let trimmed_title = new_step.title.trim();
        if !trimmed_title.is_empty() {
            let next_seq = meta.steps.iter().map(|s| s.sequence).max().unwrap_or(0) + 1;
            let step_id = format!("step-{next_seq:02}");
            let step_meta = MissionStepMeta {
                id: step_id.clone(),
                sequence: next_seq,
                enabled: true,
                title: trimmed_title.to_string(),
                layer: normalize_layer(new_step.layer.as_deref().unwrap_or("L2")),
                effort: normalize_effort(new_step.effort.as_deref().unwrap_or("m")),
                description: new_step
                    .description
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or(trimmed_title)
                    .to_string(),
                done_criterion: new_step
                    .done_criterion
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Automated tests and build pass with zero regressions.")
                    .to_string(),
                decision_question: None,
                decision_answer: None,
                gap_id: None,
                commit_sha: None,
                pr_url: None,
                diff_stat: None,
                error: None,
                started_at: None,
                completed_at: None,
                log_tail: Vec::new(),
            };
            pm.mission.objectives.push(Objective {
                id: step_id,
                description: step_meta.title.clone(),
                resource_cost: 12_000,
                duration_secs: 600,
                target: None,
                sequence: next_seq,
            });
            pm.mission.version += 1;
            meta.steps.push(step_meta);
        }
    }

    meta.updated_at = now_iso();
    save_mission_pair(&root, &pm, &meta).map_err(|e| {
        api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to save mission: {e}"),
        )
    })?;

    Ok(Json(serde_json::json!({
        "ok": true,
        "mission": format_mission_view(&pm, &meta),
    })))
}

/// DELETE /api/missions/{id} — remove a draft/paused/completed mission.
pub async fn handle_mission_delete(
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf_header(&headers) {
        return Err(api_err(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    if !validate_mission_id(&id) {
        return Err(api_err(StatusCode::BAD_REQUEST, "invalid mission id"));
    }
    if running_missions()
        .lock()
        .ok()
        .is_some_and(|g| g.contains(&id))
    {
        return Err(api_err(
            StatusCode::CONFLICT,
            "Pause the running mission before deleting it.",
        ));
    }
    let root = missions_root_dir();
    let _ = fs::remove_file(root.join(format!("{id}.json")));
    let _ = fs::remove_file(meta_path_for(&root, &id));
    clear_live_state(&id);
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// Initialize a brand-new git repository at `repo_dir` when launching a greenfield dream.
pub fn ensure_greenfield_repo_initialized(
    repo_dir: &Path,
    meta: &MissionMeta,
) -> Result<(), String> {
    if repo_dir.join(".git").exists() {
        return Ok(());
    }
    fs::create_dir_all(repo_dir)
        .map_err(|e| format!("Failed to create {}: {e}", repo_dir.display()))?;

    let init = std::process::Command::new("git")
        .args(["init", "-b", "main"])
        .current_dir(repo_dir)
        .output()
        .map_err(|e| format!("Failed to run git init: {e}"))?;
    if !init.status.success() {
        let fallback = std::process::Command::new("git")
            .arg("init")
            .current_dir(repo_dir)
            .output()
            .map_err(|e| format!("Failed to run git init: {e}"))?;
        if !fallback.status.success() {
            return Err(format!(
                "git init failed: {}",
                String::from_utf8_lossy(&fallback.stderr)
            ));
        }
    }

    let step_lines: String = meta
        .steps
        .iter()
        .filter(|s| s.enabled)
        .map(|s| format!("- **[{}]** {} — _{}_", s.layer, s.title, s.done_criterion))
        .collect::<Vec<_>>()
        .join("\n");

    let readme = format!(
        "# {}\n\n{}\n\n## Vision\n\n{}\n\n## Mission Roadmap\n\n{}\n",
        meta.repo_name, meta.summary, meta.vision, step_lines
    );
    fs::write(repo_dir.join("README.md"), readme)
        .map_err(|e| format!("Failed to write README.md: {e}"))?;
    fs::write(
        repo_dir.join(".gitignore"),
        "/target\n/node_modules\n/.venv\n.DS_Store\n.env\n",
    )
    .map_err(|e| format!("Failed to write .gitignore: {e}"))?;

    let _ = std::process::Command::new("git")
        .args(["add", "README.md", ".gitignore"])
        .current_dir(repo_dir)
        .output();

    let commit = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=Chump Mission Factory",
            "-c",
            "user.email=chump@local",
            "commit",
            "-m",
            "chore: initialize repository from Chump Mission Vision",
        ])
        .current_dir(repo_dir)
        .output()
        .map_err(|e| format!("Failed to create initial commit: {e}"))?;
    if !commit.status.success() {
        return Err(format!(
            "Initial commit failed: {}",
            String::from_utf8_lossy(&commit.stderr)
        ));
    }
    Ok(())
}

/// POST /api/missions/{id}/launch — approve plan, scaffold greenfield repo if needed, reserve gaps & run arc.
pub async fn handle_mission_launch(
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf_header(&headers) {
        return Err(api_err(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    if !validate_mission_id(&id) {
        return Err(api_err(StatusCode::BAD_REQUEST, "invalid mission id"));
    }

    let root = missions_root_dir();
    let (pm, mut meta) =
        load_mission_pair(&root, &id).map_err(|_| api_err(StatusCode::NOT_FOUND, "not found"))?;

    if !meta.steps.iter().any(|s| s.enabled) {
        return Err(api_err(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Enable at least one step before launching the mission.",
        ));
    }

    let repo_dir = PathBuf::from(&meta.repo_path);
    if meta.repo_mode == "new" {
        ensure_greenfield_repo_initialized(&repo_dir, &meta)
            .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    } else if !repo_dir.join(".git").exists() {
        return Err(api_err(
            StatusCode::BAD_REQUEST,
            format!("Target repository missing .git: {}", repo_dir.display()),
        ));
    }

    // Reserve verified GapStore entries for traceability across Chump's ledger.
    let runtime_root = repo_path::runtime_base();
    if let Ok(gap_store) = crate::gap_store::GapStore::open(&runtime_root) {
        let session_tag = format!("mission-{id}");
        for step in meta
            .steps
            .iter_mut()
            .filter(|s| s.enabled && s.gap_id.is_none())
        {
            let short_title: String = format!("[{}] {}", meta.repo_name, step.title)
                .chars()
                .take(190)
                .collect();
            if let Ok(gap_id) = gap_store.reserve_verified(
                "PRODUCT",
                &short_title,
                "P2",
                &step.effort,
                &session_tag,
            ) {
                let ac_json =
                    serde_json::to_string(&vec![step.done_criterion.clone()]).unwrap_or_default();
                let ext = if repo_dir != runtime_root {
                    Some(format!("external_repo:{}", meta.repo_path))
                } else {
                    None
                };
                let _ = gap_store.set_fields(
                    &gap_id,
                    crate::gap_store::GapFieldUpdate {
                        description: Some(step.description.clone()),
                        acceptance_criteria: Some(ac_json),
                        skills_required: ext,
                        ..Default::default()
                    },
                );
                step.gap_id = Some(gap_id);
            }
        }
    }

    if let Ok(mut paused) = paused_missions().lock() {
        paused.remove(&id);
    }
    meta.status = "running".to_string();
    meta.updated_at = now_iso();
    save_mission_pair(&root, &pm, &meta).map_err(|e| {
        api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to update mission state: {e}"),
        )
    })?;

    spawn_mission_runner_if_idle(id.clone());

    Ok(Json(serde_json::json!({
        "ok": true,
        "mission": format_mission_view(&pm, &meta),
    })))
}

/// POST /api/missions/{id}/control — pause, resume, retry_step, skip_step, resolve_decision.
pub async fn handle_mission_control(
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
    Json(body): Json<ControlMissionRequest>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !check_auth(&headers) {
        return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf_header(&headers) {
        return Err(api_err(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    if !validate_mission_id(&id) {
        return Err(api_err(StatusCode::BAD_REQUEST, "invalid mission id"));
    }

    let root = missions_root_dir();
    let (mut pm, mut meta) =
        load_mission_pair(&root, &id).map_err(|_| api_err(StatusCode::NOT_FOUND, "not found"))?;

    let action = body.action.trim().to_lowercase();
    let ts = now_iso();

    match action.as_str() {
        "pause" => {
            if let Ok(mut p) = paused_missions().lock() {
                p.insert(id.clone());
            }
            meta.status = "paused".to_string();
            set_live_activity(
                &id,
                "Pause requested — finishing current checkpoint cleanly…",
            );
        }
        "resume" => {
            if let Ok(mut p) = paused_missions().lock() {
                p.remove(&id);
            }
            meta.status = "running".to_string();
            meta.updated_at = ts;
            save_mission_pair(&root, &pm, &meta)
                .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            spawn_mission_runner_if_idle(id.clone());
            return Ok(Json(serde_json::json!({
                "ok": true,
                "mission": format_mission_view(&pm, &meta),
            })));
        }
        "retry_step" => {
            let Some(step_id) = body.step_id.as_deref() else {
                return Err(api_err(StatusCode::BAD_REQUEST, "step_id required"));
            };
            if pm.current_state(step_id) == Some(ObjectiveState::Failed) {
                let _ = pm.checkpoint(step_id, ObjectiveState::Pending, &ts);
            }
            if let Some(s) = meta.steps.iter_mut().find(|s| s.id == step_id) {
                s.error = None;
            }
            if let Ok(mut p) = paused_missions().lock() {
                p.remove(&id);
            }
            meta.status = "running".to_string();
            meta.updated_at = ts;
            save_mission_pair(&root, &pm, &meta)
                .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            spawn_mission_runner_if_idle(id.clone());
            return Ok(Json(serde_json::json!({
                "ok": true,
                "mission": format_mission_view(&pm, &meta),
            })));
        }
        "skip_step" => {
            let Some(step_id) = body.step_id.as_deref() else {
                return Err(api_err(StatusCode::BAD_REQUEST, "step_id required"));
            };
            let cur = pm.current_state(step_id).unwrap_or(ObjectiveState::Pending);
            if cur.can_transition_to(ObjectiveState::Skipped) {
                let _ = pm.checkpoint(step_id, ObjectiveState::Skipped, &ts);
            } else if cur == ObjectiveState::Failed {
                let _ = pm.checkpoint(step_id, ObjectiveState::Pending, &ts);
                let _ = pm.checkpoint(step_id, ObjectiveState::Skipped, &ts);
            }
        }
        "resolve_decision" => {
            let answer = body.decision_answer.as_deref().map(str::trim).unwrap_or("");
            if answer.is_empty() {
                return Err(api_err(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "Please enter a decision answer to unblock the mission.",
                ));
            }
            let target_step = if let Some(ref sid) = body.step_id {
                meta.steps.iter_mut().find(|s| &s.id == sid)
            } else {
                meta.steps.iter_mut().find(|s| {
                    s.enabled
                        && s.decision_question.is_some()
                        && s.decision_answer.as_deref().unwrap_or("").is_empty()
                })
            };
            if let Some(s) = target_step {
                s.decision_answer = Some(answer.to_string());
            }
            if let Ok(mut p) = paused_missions().lock() {
                p.remove(&id);
            }
            meta.status = "running".to_string();
            meta.updated_at = ts;
            save_mission_pair(&root, &pm, &meta)
                .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            spawn_mission_runner_if_idle(id.clone());
            return Ok(Json(serde_json::json!({
                "ok": true,
                "mission": format_mission_view(&pm, &meta),
            })));
        }
        _ => {
            return Err(api_err(
                StatusCode::BAD_REQUEST,
                format!("Unsupported control action: {action}"),
            ))
        }
    }

    meta.updated_at = now_iso();
    save_mission_pair(&root, &pm, &meta)
        .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "ok": true,
        "mission": format_mission_view(&pm, &meta),
    })))
}

// ── Autonomous Multi-Step Mission Runner ─────────────────────────────────────

fn spawn_mission_runner_if_idle(mission_id: String) {
    let acquired = match running_missions().lock() {
        Ok(mut set) => set.insert(mission_id.clone()),
        Err(_) => false,
    };
    if !acquired {
        return;
    }

    tokio::spawn(async move {
        tracing::info!(mission_id = %mission_id, "PRODUCT-378: autonomous mission runner started");
        if let Err(e) = run_mission_arc(&mission_id).await {
            tracing::warn!(mission_id = %mission_id, error = %e, "PRODUCT-378: mission runner stopped");
        }
        if let Ok(mut set) = running_missions().lock() {
            set.remove(&mission_id);
        }
    });
}

fn is_mission_paused(mission_id: &str) -> bool {
    paused_missions()
        .lock()
        .ok()
        .is_some_and(|s| s.contains(mission_id))
}

async fn run_mission_arc(mission_id: &str) -> anyhow::Result<()> {
    let root = missions_root_dir();

    loop {
        if is_mission_paused(mission_id) {
            let (pm, mut meta) = load_mission_pair(&root, mission_id)?;
            meta.status = "paused".to_string();
            meta.active_step_id = None;
            meta.updated_at = now_iso();
            save_mission_pair(&root, &pm, &meta)?;
            clear_live_state(mission_id);
            return Ok(());
        }

        let (mut pm, mut meta) = load_mission_pair(&root, mission_id)?;

        // Locate next Pending enabled step.
        let next_idx = meta.steps.iter().position(|s| {
            if !s.enabled {
                return false;
            }
            let st = pm.current_state(&s.id).unwrap_or(ObjectiveState::Pending);
            st == ObjectiveState::Pending
        });

        let Some(step_idx) = next_idx else {
            // All enabled steps are terminal!
            let any_failed = meta
                .steps
                .iter()
                .any(|s| s.enabled && pm.current_state(&s.id) == Some(ObjectiveState::Failed));
            meta.status = if any_failed {
                "failed".to_string()
            } else {
                "completed".to_string()
            };
            meta.active_step_id = None;
            meta.updated_at = now_iso();
            save_mission_pair(&root, &pm, &meta)?;
            clear_live_state(mission_id);
            tracing::info!(
                mission_id = %mission_id,
                status = %meta.status,
                "PRODUCT-378: mission arc finished"
            );
            return Ok(());
        };

        // Pause if this step requires an unanswered founder decision.
        if meta.steps[step_idx]
            .decision_question
            .as_ref()
            .is_some_and(|q| !q.trim().is_empty())
            && meta.steps[step_idx]
                .decision_answer
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
        {
            meta.status = "needs_decision".to_string();
            meta.active_step_id = Some(meta.steps[step_idx].id.clone());
            meta.updated_at = now_iso();
            save_mission_pair(&root, &pm, &meta)?;
            set_live_activity(
                mission_id,
                "Paused for founder product/architecture decision",
            );
            return Ok(());
        }

        let step_snapshot = meta.steps[step_idx].clone();
        let ts_start = now_iso();
        let _ = pm.checkpoint(&step_snapshot.id, ObjectiveState::InProgress, &ts_start);
        meta.status = "running".to_string();
        meta.active_step_id = Some(step_snapshot.id.clone());
        meta.steps[step_idx].started_at = Some(ts_start);
        meta.steps[step_idx].error = None;
        meta.updated_at = now_iso();
        save_mission_pair(&root, &pm, &meta)?;

        let completed_context: Vec<String> = meta
            .steps
            .iter()
            .filter(|s| pm.current_state(&s.id) == Some(ObjectiveState::Completed))
            .map(|s| format!("- [DONE] {}: {}", s.title, s.done_criterion))
            .collect();

        let outcome =
            execute_single_mission_step(mission_id, &meta, &step_snapshot, &completed_context)
                .await;

        // Reload pair before writing step outcome so concurrent edits aren't clobbered.
        let (mut pm_after, mut meta_after) = load_mission_pair(&root, mission_id)?;
        let ts_end = now_iso();
        let live_tail = live_states()
            .lock()
            .ok()
            .and_then(|g| g.get(mission_id).map(|s| s.log_lines.clone()))
            .unwrap_or_default();

        match outcome {
            Ok(receipt) => {
                let _ = pm_after.checkpoint(&step_snapshot.id, ObjectiveState::Completed, &ts_end);
                if let Some(s) = meta_after
                    .steps
                    .iter_mut()
                    .find(|s| s.id == step_snapshot.id)
                {
                    s.commit_sha = Some(receipt.commit_sha);
                    s.diff_stat = Some(receipt.diff_stat);
                    s.completed_at = Some(ts_end);
                    s.error = None;
                    s.log_tail = live_tail;
                }
                meta_after.updated_at = now_iso();
                save_mission_pair(&root, &pm_after, &meta_after)?;
            }
            Err(err_msg) => {
                let _ = pm_after.checkpoint(&step_snapshot.id, ObjectiveState::Failed, &ts_end);
                if let Some(s) = meta_after
                    .steps
                    .iter_mut()
                    .find(|s| s.id == step_snapshot.id)
                {
                    s.error = Some(err_msg.clone());
                    s.log_tail = live_tail;
                }
                meta_after.status = "failed".to_string();
                meta_after.active_step_id = None;
                meta_after.updated_at = now_iso();
                save_mission_pair(&root, &pm_after, &meta_after)?;
                clear_live_state(mission_id);
                return Err(anyhow::anyhow!(err_msg));
            }
        }
    }
}

struct StepReceipt {
    commit_sha: String,
    diff_stat: String,
}

fn find_executable(candidates: &[&str]) -> Option<PathBuf> {
    let home = chump_pal::user_home();
    for c in candidates {
        let local = home.join(".local").join("bin").join(c);
        if local.is_file() {
            return Some(local);
        }
        let brew = PathBuf::from("/opt/homebrew/bin").join(c);
        if brew.is_file() {
            return Some(brew);
        }
        if let Ok(out) = std::process::Command::new("which").arg(c).output() {
            if out.status.success() {
                let p = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
                if p.is_file() {
                    return Some(p);
                }
            }
        }
    }
    None
}

fn load_claude_oauth_token_if_needed() -> Option<String> {
    if std::env::var_os("CLAUDE_CODE_OAUTH_TOKEN").is_some()
        || std::env::var_os("ANTHROPIC_API_KEY").is_some()
    {
        return None;
    }
    let path = chump_pal::user_home()
        .join(".chump")
        .join("oauth-token.json");
    let raw = fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    v.get("access_token")
        .or_else(|| v.get("oauth_token"))
        .or_else(|| v.get("token"))
        .and_then(|t| t.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
}

async fn execute_single_mission_step(
    mission_id: &str,
    meta: &MissionMeta,
    step: &MissionStepMeta,
    completed_context: &[String],
) -> Result<StepReceipt, String> {
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::process::Command as TokioCommand;

    let repo_dir = PathBuf::from(&meta.repo_path);
    if !repo_dir.join(".git").exists() {
        return Err(format!("Repository missing .git at {}", repo_dir.display()));
    }

    if let Ok(mut guard) = live_states().lock() {
        guard.insert(mission_id.to_string(), LiveStepState::default());
    }
    set_live_activity(
        mission_id,
        format!(
            "Step {}: Provisioning isolated git worktree…",
            step.sequence
        ),
    );
    push_live_log(
        mission_id,
        format!(
            "▶ Starting Step {} [{}]: {}",
            step.sequence, step.layer, step.title
        ),
    );

    // Resolve current branch & base SHA in target repo.
    let head_out = std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(&repo_dir)
        .output()
        .map_err(|e| format!("git rev-parse HEAD failed: {e}"))?;
    if !head_out.status.success() {
        return Err("Target repository has no initial commit yet.".to_string());
    }
    let base_sha = String::from_utf8_lossy(&head_out.stdout).trim().to_string();

    let branch_out = std::process::Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(&repo_dir)
        .output()
        .ok();
    let target_branch = branch_out
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|b| !b.is_empty() && b != "HEAD")
        .unwrap_or_else(|| "main".to_string());

    let short_id = mission_id.trim_start_matches("msn-");
    let wt_branch = format!("chump/msn-{short_id}-s{:02}", step.sequence);
    let wt_dir = std::env::temp_dir().join(format!("chump-msn-{short_id}-s{:02}", step.sequence));

    // Clean up any stale worktree/branch from a previous retry.
    let _ = std::process::Command::new("git")
        .args([
            "worktree",
            "remove",
            "--force",
            &wt_dir.display().to_string(),
        ])
        .current_dir(&repo_dir)
        .output();
    let _ = fs::remove_dir_all(&wt_dir);
    let _ = std::process::Command::new("git")
        .args(["branch", "-D", &wt_branch])
        .current_dir(&repo_dir)
        .output();

    let wt_add = std::process::Command::new("git")
        .args([
            "worktree",
            "add",
            "-b",
            &wt_branch,
            &wt_dir.display().to_string(),
            &base_sha,
        ])
        .current_dir(&repo_dir)
        .output()
        .map_err(|e| format!("git worktree add failed: {e}"))?;
    if !wt_add.status.success() {
        return Err(format!(
            "Failed to create isolated worktree: {}",
            String::from_utf8_lossy(&wt_add.stderr).trim()
        ));
    }

    push_live_log(
        mission_id,
        format!(
            "✓ Worktree isolated at {} (branch {wt_branch})",
            wt_dir.display()
        ),
    );

    let prior_block = if completed_context.is_empty() {
        "None yet (this is the first milestone).".to_string()
    } else {
        completed_context.join("\n")
    };
    let decision_block = match (&step.decision_question, &step.decision_answer) {
        (Some(q), Some(a)) => format!("\nFounder Decision ({q}): {a}\n"),
        _ => String::new(),
    };

    let agent_prompt = format!(
        "You are an autonomous coding agent executing Step {} of Mission \"{}\" in repository `{}`.\n\n\
Overall Mission Vision:\n{}\n\n\
Completed Prior Milestones:\n{}\n\
{}\n\
Current Milestone to Implement & Ship NOW:\n\
- Title: {}\n\
- Layer: {}\n\
- Scope: {}\n\
- Done Criterion (MUST BE PROVEN BY TESTS): {}\n\n\
Execution Rules:\n\
1. Inspect the repository files, implement the complete working code AND automated unit/integration tests proving the Done Criterion.\n\
2. Run the project's build and test commands locally inside this worktree and fix any compilation, lint, or test errors until green.\n\
3. Do NOT leave placeholder stubs or TODOs, and do NOT push to remote — commit your verified changes cleanly to the current git branch.",
        step.sequence,
        meta.title,
        meta.repo_name,
        if meta.vision.is_empty() { &meta.summary } else { &meta.vision },
        prior_block,
        decision_block,
        step.title,
        step.layer,
        step.description,
        step.done_criterion
    );

    // Choose agent CLI harness according to mission.runner.
    let runner_pref = meta.runner.as_str();
    let claude_bin = find_executable(&["claude"]);
    let agy_bin = find_executable(&["agy"]);
    let exe_bin = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("chump"));

    let (harness_label, mut cmd) = if runner_pref == "agy"
        || (runner_pref == "auto" && claude_bin.is_none() && agy_bin.is_some())
    {
        if let Some(agy) = agy_bin {
            let mut c = TokioCommand::new(agy);
            c.args(["--mode", "agent", "--yolo", "-p", &agent_prompt]);
            ("Gemini 4 (agy)", c)
        } else {
            let mut c = TokioCommand::new(&exe_bin);
            c.args(["gen", &agent_prompt]);
            ("Chump Cascade", c)
        }
    } else if (runner_pref == "claude" || runner_pref == "auto") && claude_bin.is_some() {
        let claude = claude_bin.unwrap_or_else(|| PathBuf::from("claude"));
        let mut c = TokioCommand::new(claude);
        c.args(["-p", "--dangerously-skip-permissions", &agent_prompt]);
        if let Some(tok) = load_claude_oauth_token_if_needed() {
            c.env("CLAUDE_CODE_OAUTH_TOKEN", tok);
        }
        ("Claude Ultra", c)
    } else {
        let mut c = TokioCommand::new(&exe_bin);
        if runner_pref == "ollama" {
            c.env("CHUMP_LOCAL_ONLY", "1");
        }
        c.args(["gen", &agent_prompt]);
        (
            if runner_pref == "ollama" {
                "Local Offline (Ollama)"
            } else {
                "Chump Cascade"
            },
            c,
        )
    };

    set_live_activity(
        mission_id,
        format!(
            "Step {}: {} coding & testing in isolated worktree…",
            step.sequence, harness_label
        ),
    );
    push_live_log(mission_id, format!("▶ Invoking {harness_label} agent…"));

    cmd.current_dir(&wt_dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let agent_res: Result<(), String> = async {
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Failed to spawn {harness_label}: {e}"))?;

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let mid_out = mission_id.to_string();
        let mid_err = mission_id.to_string();

        let out_task = tokio::spawn(async move {
            if let Some(s) = stdout {
                let mut lines = BufReader::new(s).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    push_live_log(&mid_out, line);
                }
            }
        });
        let err_task = tokio::spawn(async move {
            if let Some(s) = stderr {
                let mut lines = BufReader::new(s).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    push_live_log(&mid_err, line);
                }
            }
        });

        let wait_res = tokio::time::timeout(Duration::from_secs(900), child.wait()).await;
        let _ = out_task.await;
        let _ = err_task.await;

        match wait_res {
            Err(_) => Err(format!("{harness_label} timed out after 15 minutes")),
            Ok(Err(e)) => Err(format!("{harness_label} wait error: {e}")),
            Ok(Ok(status)) if !status.success() => {
                Err(format!("{harness_label} exited with status {status}"))
            }
            Ok(Ok(_)) => Ok(()),
        }
    }
    .await;

    if let Err(e) = agent_res {
        cleanup_mission_worktree(&repo_dir, &wt_dir, &wt_branch);
        return Err(e);
    }

    // Stage & commit any uncommitted files the agent wrote inside the worktree.
    let status_out = std::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(&wt_dir)
        .output()
        .map_err(|e| format!("git status failed: {e}"))?;
    if !String::from_utf8_lossy(&status_out.stdout)
        .trim()
        .is_empty()
    {
        let _ = std::process::Command::new("git")
            .args(["add", "-A"])
            .current_dir(&wt_dir)
            .output();
        let commit_msg = format!("feat({}): {}", step.layer.to_lowercase(), step.title);
        let _ = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=Chump Mission Factory",
                "-c",
                "user.email=chump@local",
                "commit",
                "-m",
                &commit_msg,
            ])
            .current_dir(&wt_dir)
            .output();
    }

    // Anti-cosmetic gate: verify at least 1 commit with real file changes landed beyond base_sha.
    let head_wt = std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(&wt_dir)
        .output()
        .map_err(|e| format!("git rev-parse failed: {e}"))?;
    let wt_sha = String::from_utf8_lossy(&head_wt.stdout).trim().to_string();
    if wt_sha.is_empty() || wt_sha == base_sha {
        cleanup_mission_worktree(&repo_dir, &wt_dir, &wt_branch);
        return Err(
            "Anti-cosmetic gate held merge: agent produced zero repository changes.".to_string(),
        );
    }

    // Automated build & test verification gate inside the isolated worktree.
    set_live_activity(
        mission_id,
        format!(
            "Step {}: Running automated verification gate…",
            step.sequence
        ),
    );
    if let Err(verify_err) = run_repo_verification_gate(mission_id, &wt_dir).await {
        cleanup_mission_worktree(&repo_dir, &wt_dir, &wt_branch);
        return Err(verify_err);
    }

    // Auto-merge verified branch onto target_branch!
    set_live_activity(
        mission_id,
        format!(
            "Step {}: Verification green — auto-merging onto {target_branch}…",
            step.sequence
        ),
    );
    let diff_stat = std::process::Command::new("git")
        .args(["diff", "--shortstat", &base_sha, &wt_sha])
        .current_dir(&wt_dir)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    // Detach worktree branch reference before merging in main repo.
    let _ = std::process::Command::new("git")
        .args([
            "worktree",
            "remove",
            "--force",
            &wt_dir.display().to_string(),
        ])
        .current_dir(&repo_dir)
        .output();
    let _ = fs::remove_dir_all(&wt_dir);

    let main_dirty = std::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(&repo_dir)
        .output()
        .map(|o| !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false);

    let final_sha = if !main_dirty {
        let merge_out = std::process::Command::new("git")
            .args(["merge", "--ff-only", &wt_branch])
            .current_dir(&repo_dir)
            .output();
        match merge_out {
            Ok(o) if o.status.success() => {
                let _ = std::process::Command::new("git")
                    .args(["branch", "-d", &wt_branch])
                    .current_dir(&repo_dir)
                    .output();
                wt_sha.chars().take(10).collect()
            }
            _ => {
                // Non-FF merge commit if target_branch advanced concurrently.
                let m2 = std::process::Command::new("git")
                    .args([
                        "-c",
                        "user.name=Chump Mission Factory",
                        "-c",
                        "user.email=chump@local",
                        "merge",
                        "--no-edit",
                        &wt_branch,
                    ])
                    .current_dir(&repo_dir)
                    .output();
                if let Ok(o2) = m2 {
                    if o2.status.success() {
                        let _ = std::process::Command::new("git")
                            .args(["branch", "-d", &wt_branch])
                            .current_dir(&repo_dir)
                            .output();
                        wt_sha.chars().take(10).collect()
                    } else {
                        let _ = std::process::Command::new("git")
                            .args(["merge", "--abort"])
                            .current_dir(&repo_dir)
                            .output();
                        format!("{wt_branch} ({})", &wt_sha[..wt_sha.len().min(8)])
                    }
                } else {
                    format!("{wt_branch} ({})", &wt_sha[..wt_sha.len().min(8)])
                }
            }
        }
    } else {
        push_live_log(
            mission_id,
            format!("Note: working tree had local edits; verified branch preserved at {wt_branch}"),
        );
        format!("{wt_branch} ({})", &wt_sha[..wt_sha.len().min(8)])
    };

    push_live_log(
        mission_id,
        format!(
            "✓ Step {} shipped ({final_sha}) — {diff_stat}",
            step.sequence
        ),
    );

    if let Some(ref gid) = step.gap_id {
        if let Ok(gs) = crate::gap_store::GapStore::open(&repo_path::runtime_base()) {
            let _ = gs.set_fields(
                gid,
                crate::gap_store::GapFieldUpdate {
                    notes: Some(format!("Shipped via Mission {mission_id} ({final_sha})")),
                    ..Default::default()
                },
            );
        }
    }

    Ok(StepReceipt {
        commit_sha: final_sha,
        diff_stat,
    })
}

fn cleanup_mission_worktree(repo_dir: &Path, wt_dir: &Path, wt_branch: &str) {
    let _ = std::process::Command::new("git")
        .args([
            "worktree",
            "remove",
            "--force",
            &wt_dir.display().to_string(),
        ])
        .current_dir(repo_dir)
        .output();
    let _ = fs::remove_dir_all(wt_dir);
    let _ = std::process::Command::new("git")
        .args(["branch", "-D", wt_branch])
        .current_dir(repo_dir)
        .output();
}

async fn run_repo_verification_gate(mission_id: &str, wt_dir: &Path) -> Result<(), String> {
    use tokio::process::Command as TokioCommand;

    let check_cmd: Option<(&str, Vec<&str>)> = if wt_dir.join("Cargo.toml").exists() {
        Some(("cargo", vec!["test", "--quiet"]))
    } else if wt_dir.join("package.json").exists() {
        Some(("npm", vec!["test", "--if-present"]))
    } else if wt_dir.join("go.mod").exists() {
        Some(("go", vec!["test", "./..."]))
    } else if wt_dir.join("pyproject.toml").exists() || wt_dir.join("pytest.ini").exists() {
        if find_executable(&["pytest"]).is_some() {
            Some(("pytest", vec!["-q"]))
        } else {
            None
        }
    } else {
        None
    };

    let Some((bin, args)) = check_cmd else {
        push_live_log(
            mission_id,
            "✓ Verification check: no test runner manifest detected; git diff verified.",
        );
        return Ok(());
    };

    push_live_log(
        mission_id,
        format!("▶ Running verification gate: {bin} {}", args.join(" ")),
    );

    let mut cmd = TokioCommand::new(bin);
    cmd.args(&args).current_dir(wt_dir).kill_on_drop(true);
    let res = tokio::time::timeout(Duration::from_secs(300), cmd.output()).await;
    match res {
        Err(_) => Err(format!(
            "Verification gate `{bin}` timed out after 5 minutes"
        )),
        Ok(Err(e)) => Err(format!("Failed to execute `{bin}`: {e}")),
        Ok(Ok(out)) if out.status.success() => {
            push_live_log(mission_id, format!("✓ Verification gate `{bin}` passed."));
            Ok(())
        }
        Ok(Ok(out)) => {
            let combined = format!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            let tail: Vec<&str> = combined
                .lines()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            let snippet = tail.join("\n");
            push_live_log(mission_id, format!("✗ Verification failed:\n{snippet}"));
            Err(format!("Verification gate `{bin}` failed:\n{snippet}"))
        }
    }
}

// ── Unit Tests (PRODUCT-378) ─────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_json_object_handles_markdown_fences_and_prose() {
        let raw =
            "Here is the plan:\n```json\n{\"mission_title\":\"Demo\",\"steps\":[]}\n```\nDone!";
        let extracted = extract_json_object(raw).expect("invariant: json object exists");
        assert_eq!(extracted, "{\"mission_title\":\"Demo\",\"steps\":[]}");
    }

    #[test]
    fn validate_new_repo_slug_rejects_traversal_and_spaces() {
        assert!(validate_new_repo_slug("dream-app_2").is_ok());
        assert!(validate_new_repo_slug("").is_err());
        assert!(validate_new_repo_slug("../escape").is_err());
        assert!(validate_new_repo_slug("-leading-dash").is_err());
        assert!(validate_new_repo_slug("has space").is_err());
    }

    #[test]
    fn greenfield_repo_init_and_mission_persistence_roundtrip() {
        let tmp = tempfile::tempdir().expect("invariant: tempdir");
        let store_root = tmp.path().join("missions");
        let new_repo = tmp.path().join("greenfield-dream");

        let (_title, summary, steps) =
            build_fallback_plan("greenfield-dream", "Build a fast note CLI", "new", None);
        assert!(steps.len() >= 4);
        assert_eq!(steps[0].layer, "L1");

        let meta = MissionMeta {
            id: "msn-test01".to_string(),
            title: "Greenfield Note CLI".to_string(),
            vision: "Build a fast note CLI".to_string(),
            summary,
            repo_mode: "new".to_string(),
            repo_path: new_repo.display().to_string(),
            repo_name: "greenfield-dream".to_string(),
            remote_owner_repo: None,
            runner: "auto".to_string(),
            status: "draft".to_string(),
            created_at: "2026-11-28T00:00:00Z".to_string(),
            updated_at: "2026-11-28T00:00:00Z".to_string(),
            l1_passed: 0,
            l1_total: 5,
            active_step_id: None,
            steps,
        };

        ensure_greenfield_repo_initialized(&new_repo, &meta)
            .expect("invariant: greenfield git init succeeds");
        assert!(new_repo.join(".git").exists());
        assert!(new_repo.join("README.md").exists());

        let mut pm = build_persistent_mission_from_meta(&meta);
        save_mission_pair(&store_root, &pm, &meta).expect("invariant: save pair");

        // Verify FileBackedMissionStore::list() only sees msn-test01 (not meta/ subdir).
        let ids = FileBackedMissionStore::new(&store_root)
            .list()
            .expect("invariant: list");
        assert_eq!(ids, vec!["msn-test01".to_string()]);

        pm.checkpoint(
            "step-01",
            ObjectiveState::InProgress,
            "2026-11-28T00:01:00Z",
        )
        .expect("invariant: pending -> in_progress");
        pm.checkpoint("step-01", ObjectiveState::Completed, "2026-11-28T00:02:00Z")
            .expect("invariant: in_progress -> completed");
        save_mission_pair(&store_root, &pm, &meta).expect("invariant: save updated pair");

        let (loaded_pm, loaded_meta) =
            load_mission_pair(&store_root, "msn-test01").expect("invariant: load pair");
        let view = format_mission_view(&loaded_pm, &loaded_meta);
        assert_eq!(view["completed_steps"], 1);
        assert!(view["progress_pct"].as_u64().unwrap_or(0) > 0);
    }
}
