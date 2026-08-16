//! curator_bell — INFRA-2185: per-lane post-merge curator refresh
//! ("META-125 ring-the-bell").
//!
//! `chump curator status [--role ROLE] [--json]` and
//! `chump curator refresh <role> [--pr-url U] [--commit-sha S] [--gap-ids CSV]`.
//!
//! Persistent state lives in canonical fleet state
//! (`.chump-locks/curator-memory/<role>.json`), so this is a Rust CLI per
//! the Rust-first criteria in CLAUDE.md rather than a shell script — the
//! shell side (`scripts/coord/main-merge-listener.sh` +
//! `scripts/coord/post-merge-bell.sh`) is pure glue that calls into this
//! module for every state mutation.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const STALE_THRESHOLD_SECS: i64 = 24 * 3600;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SeenMerge {
    pub pr_url: String,
    pub commit_sha: String,
    pub gap_ids_closed: Vec<String>,
    pub ts: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StalenessFinding {
    pub gap_id: String,
    pub reason: String,
    pub ts: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CuratorMemory {
    pub role: String,
    pub last_refresh: Option<String>,
    #[serde(default)]
    pub seen_merges: Vec<SeenMerge>,
    #[serde(default)]
    pub staleness_findings: Vec<StalenessFinding>,
}

fn memory_dir(repo_root: &Path) -> PathBuf {
    repo_root.join(".chump-locks/curator-memory")
}

fn memory_path(repo_root: &Path, role: &str) -> PathBuf {
    memory_dir(repo_root).join(format!("{role}.json"))
}

fn lanes_file(repo_root: &Path) -> PathBuf {
    std::env::var("CHUMP_CURATOR_LANES_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join("scripts/coord/curator-lanes.txt"))
}

/// Parse `scripts/coord/curator-lanes.txt` into `(role, globs)` pairs,
/// preserving file order. Blank lines and `#` comments are skipped.
pub fn known_roles(repo_root: &Path) -> Vec<String> {
    let path = lanes_file(repo_root);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            line.split_once(':')
                .map(|(role, _)| role.trim().to_string())
        })
        .collect()
}

pub fn load_memory(repo_root: &Path, role: &str) -> CuratorMemory {
    let path = memory_path(repo_root, role);
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| CuratorMemory {
            role: role.to_string(),
            ..Default::default()
        })
}

fn save_memory(repo_root: &Path, mem: &CuratorMemory) -> std::io::Result<()> {
    let dir = memory_dir(repo_root);
    std::fs::create_dir_all(&dir)?;
    let path = memory_path(repo_root, &mem.role);
    let json = serde_json::to_string_pretty(mem).unwrap_or_else(|_| "{}".to_string());
    std::fs::write(path, json)
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Append a structured event to ambient.jsonl (per-module helper pattern,
/// mirrors src/ci_lesson.rs::emit_ambient_event).
fn emit_ambient_event(repo_root: &Path, kind: &str, fields: &[(&str, String)]) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(now_iso()));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        if v.is_empty() {
            continue;
        }
        map.insert((*k).to_string(), serde_json::Value::String(v.clone()));
    }
    let event = serde_json::Value::Object(map).to_string();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{event}");
    }
}

pub struct RefreshArgs {
    pub role: String,
    pub pr_url: String,
    pub commit_sha: String,
    pub gap_ids: Vec<String>,
}

/// The refresh action: record the merge in the role's memory file, check
/// whether the closed gap_ids intersect any staleness marker already
/// tracked for this role, and emit `curator_refreshed` (+
/// `curator_staleness_finding` per hit).
pub fn refresh(repo_root: &Path, args: &RefreshArgs) -> CuratorMemory {
    let mut mem = load_memory(repo_root, &args.role);
    mem.role = args.role.clone();
    let ts = now_iso();

    mem.seen_merges.push(SeenMerge {
        pr_url: args.pr_url.clone(),
        commit_sha: args.commit_sha.clone(),
        gap_ids_closed: args.gap_ids.clone(),
        ts: ts.clone(),
    });

    // Staleness heuristic: if a gap this merge closed is one this curator
    // had already flagged in a prior staleness_finding (e.g. cited it in a
    // FEEDBACK broadcast before the merge landed), that finding is now
    // resolved-by-merge — surface it so the curator sees the merge closed
    // the gap it was worried about, instead of re-litigating it stale.
    let mut new_findings = Vec::new();
    for gap_id in &args.gap_ids {
        if mem.staleness_findings.iter().any(|f| &f.gap_id == gap_id) {
            let finding = StalenessFinding {
                gap_id: gap_id.clone(),
                reason: format!("gap {gap_id} closed by merge {}", args.commit_sha),
                ts: ts.clone(),
            };
            // scanner-anchor: "kind":"curator_staleness_finding"
            emit_ambient_event(
                repo_root,
                "curator_staleness_finding",
                &[
                    ("role", args.role.clone()),
                    ("gap_id", gap_id.clone()),
                    ("reason", finding.reason.clone()),
                ],
            );
            new_findings.push(finding);
        }
    }
    mem.staleness_findings.extend(new_findings);
    mem.last_refresh = Some(ts.clone());

    let _ = save_memory(repo_root, &mem);

    // scanner-anchor: "kind":"curator_refreshed"
    emit_ambient_event(
        repo_root,
        "curator_refreshed",
        &[
            ("role", args.role.clone()),
            ("pr_url", args.pr_url.clone()),
            ("commit_sha", args.commit_sha.clone()),
            ("gaps_checked", args.gap_ids.join(",")),
        ],
    );

    mem
}

pub struct StatusRow {
    pub role: String,
    pub last_refresh: Option<String>,
    pub stale: bool,
    pub open_findings: usize,
}

fn seconds_since(iso_ts: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(iso_ts)
        .ok()
        .map(|dt| (chrono::Utc::now() - dt.with_timezone(&chrono::Utc)).num_seconds())
}

pub fn status_rows(repo_root: &Path, role_filter: Option<&str>) -> Vec<StatusRow> {
    let roles = known_roles(repo_root);
    roles
        .into_iter()
        .filter(|r| role_filter.is_none_or(|f| f == r))
        .map(|role| {
            let mem = load_memory(repo_root, &role);
            let stale = match mem.last_refresh.as_deref().and_then(seconds_since) {
                Some(secs) => secs > STALE_THRESHOLD_SECS,
                None => true,
            };
            StatusRow {
                role,
                last_refresh: mem.last_refresh,
                stale,
                open_findings: mem.staleness_findings.len(),
            }
        })
        .collect()
}

pub fn render_status_text(rows: &[StatusRow]) -> String {
    if rows.is_empty() {
        return "chump curator status: no roles found in scripts/coord/curator-lanes.txt\n"
            .to_string();
    }
    let mut out = String::new();
    out.push_str(&format!(
        "{:<18} {:<24} {:<8} {}\n",
        "ROLE", "LAST REFRESH", "STALE", "FINDINGS"
    ));
    for row in rows {
        out.push_str(&format!(
            "{:<18} {:<24} {:<8} {}\n",
            row.role,
            row.last_refresh.as_deref().unwrap_or("never"),
            if row.stale { "YES" } else { "no" },
            row.open_findings,
        ));
    }
    out
}

// INFRA-2185: ring-the-bell core-mechanism coverage — lane parsing, the
// refresh action (memory write + staleness resolution), and status rows.
#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_repo_root(lanes: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "curator-bell-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("scripts/coord")).unwrap();
        std::fs::write(dir.join("scripts/coord/curator-lanes.txt"), lanes).unwrap();
        dir
    }

    #[test]
    fn known_roles_parses_lane_file_skipping_comments_and_blanks() {
        let root = tmp_repo_root(
            "# comment\n\nhandoff: crates/chump-handoff/**\nci-audit: .github/workflows/**\n",
        );
        let roles = known_roles(&root);
        assert_eq!(roles, vec!["handoff".to_string(), "ci-audit".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn refresh_writes_memory_and_emits_no_finding_on_first_merge() {
        let root = tmp_repo_root("handoff: crates/chump-handoff/**\n");
        let mem = refresh(
            &root,
            &RefreshArgs {
                role: "handoff".to_string(),
                pr_url: "https://example.com/pull/1".to_string(),
                commit_sha: "abc123".to_string(),
                gap_ids: vec!["INFRA-2167".to_string()],
            },
        );
        assert_eq!(mem.seen_merges.len(), 1);
        assert!(mem.staleness_findings.is_empty());
        assert!(mem.last_refresh.is_some());

        let reloaded = load_memory(&root, "handoff");
        assert_eq!(reloaded.seen_merges.len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn refresh_resolves_a_prior_staleness_finding_when_the_same_gap_closes() {
        let root = tmp_repo_root("handoff: crates/chump-handoff/**\n");
        let mut mem = load_memory(&root, "handoff");
        mem.staleness_findings.push(StalenessFinding {
            gap_id: "INFRA-2167".to_string(),
            reason: "flagged before merge landed".to_string(),
            ts: "2026-01-01T00:00:00Z".to_string(),
        });
        save_memory(&root, &mem).unwrap();

        let refreshed = refresh(
            &root,
            &RefreshArgs {
                role: "handoff".to_string(),
                pr_url: "https://example.com/pull/2".to_string(),
                commit_sha: "def456".to_string(),
                gap_ids: vec!["INFRA-2167".to_string()],
            },
        );
        // The heuristic re-records the resolved finding rather than dropping it.
        assert_eq!(refreshed.staleness_findings.len(), 2);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn status_rows_marks_never_refreshed_role_as_stale() {
        let root = tmp_repo_root("handoff: crates/chump-handoff/**\n");
        let rows = status_rows(&root, None);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].role, "handoff");
        assert!(rows[0].stale);
        assert_eq!(rows[0].last_refresh, None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
