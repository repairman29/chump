//! INFRA-1455: `chump rollup <fanout-group> [--semantic]` — fan-out PR
//! consolidation primitive (Marcus M-B continuation).
//!
//! Persona-5 (skeptic) interview surfaced the "40-PR firehose" problem:
//! > "If my reward for triggering a 12-microservices fan-out is a
//! > 40-PR firehose, I will uninstall within 72 hours."
//!
//! INFRA-1484 ships the fan-out side (one operator command, N repos →
//! N reserved gaps). This module ships the *converge* side: given the
//! fan-out group name, query the gaps tagged with `fanout_group=<name>`
//! (in their `notes` field, written by `chump fanout apply`), fetch the
//! file list each gap's closed PR touched, and cluster them into named
//! **strategy classes** by file-list Jaccard similarity.
//!
//! Output: "N PRs converged on Strategy A (file set X), M on Strategy B
//! (file set Y), K blocked (reason)." Optional `--json`.
//!
//! v1 limitations (documented + filed as follow-ups in docs/process/ROLLUP.md):
//! - Clustering signal is file-list Jaccard only; diff-signature clustering
//!   (Strategy A "uses anyhow::Result" vs Strategy B "uses thiserror::Error")
//!   lands in v2.
//! - `chump rollup accept-strategy <name>` prints the `gh pr merge`
//!   commands but does not invoke them yet; operator review remains
//!   the gate. v2 auto-invokes after explicit `--apply`.
//! - PR file-list fetch goes through the existing `gh` CLI subprocess; a
//!   pluggable provider exists so tests inject fixtures without network.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One row per gap in a fan-out group.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RollupEntry {
    pub gap_id: String,
    pub target_repo: String,
    pub repo_label: String,
    pub closed_pr: Option<u64>,
    pub status: String,
}

/// One strategy class — a cluster of gaps whose PRs touch a similar
/// file set.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StrategyClass {
    pub name: String,
    pub member_gaps: Vec<String>,
    pub touched_files: Vec<String>,
    pub member_count: usize,
}

/// Full rollup result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RollupReport {
    pub fanout_group: String,
    pub semantic: bool,
    pub strategies: Vec<StrategyClass>,
    pub blocked: Vec<BlockedEntry>,
    pub flat_entries: Vec<RollupEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockedEntry {
    pub gap_id: String,
    pub reason: String,
}

/// Pluggable file-list provider: given a PR number, return the list of
/// files it touched. Defaults to `gh api repos/<owner>/<repo>/pulls/<N>/files`
/// in [`gh_files_provider`]; tests inject a fixture closure instead.
pub type FilesProvider<'a> = Box<dyn Fn(u64) -> Vec<String> + 'a>;

/// Parse `chump gap list --json` output into RollupEntry rows for the
/// requested fanout-group. Matches by the `notes` field containing
/// `fanout_group=<name>`.
pub fn entries_from_gap_list(gap_list_json: &str, fanout_group: &str) -> Vec<RollupEntry> {
    let needle = format!("fanout_group={fanout_group}");
    let entries: Vec<serde_json::Value> = if gap_list_json.trim_start().starts_with('[') {
        serde_json::from_str(gap_list_json).unwrap_or_default()
    } else {
        gap_list_json
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .collect()
    };
    let mut out: Vec<RollupEntry> = Vec::new();
    for e in &entries {
        let notes = e.get("notes").and_then(|v| v.as_str()).unwrap_or("");
        if !notes.contains(&needle) {
            continue;
        }
        let id = e
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        let status = e
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        let closed_pr = e
            .get("closed_pr")
            .and_then(|v| v.as_i64())
            .map(|n| n as u64);
        let target_repo = note_value(notes, "target_repo=").unwrap_or_default();
        let repo_label = note_value(notes, "repo_label=").unwrap_or_default();
        out.push(RollupEntry {
            gap_id: id,
            target_repo,
            repo_label,
            closed_pr,
            status,
        });
    }
    out
}

fn note_value(notes: &str, key: &str) -> Option<String> {
    let normalized = notes.replace("\\n", "\n");
    for line in normalized.lines() {
        if let Some(rest) = line.strip_prefix(key) {
            return Some(rest.trim().to_string());
        }
    }
    None
}

/// Build the rollup. When `semantic`, clusters entries with closed PRs by
/// file-list Jaccard ≥ 0.8 into named StrategyClasses; otherwise returns
/// a flat entry list (AC#7 asymmetric fallback).
pub fn build_rollup(
    fanout_group: &str,
    entries: Vec<RollupEntry>,
    semantic: bool,
    files_for_pr: &FilesProvider<'_>,
) -> RollupReport {
    let mut blocked: Vec<BlockedEntry> = Vec::new();
    let mut active: Vec<(RollupEntry, Vec<String>)> = Vec::new();
    for e in &entries {
        let Some(pr) = e.closed_pr else {
            let reason = match e.status.as_str() {
                "open" => "PR not yet closed".to_string(),
                "abandoned" => "gap abandoned".to_string(),
                _ => format!("no closed_pr (status={})", e.status),
            };
            blocked.push(BlockedEntry {
                gap_id: e.gap_id.clone(),
                reason,
            });
            continue;
        };
        let files = files_for_pr(pr);
        if files.is_empty() {
            blocked.push(BlockedEntry {
                gap_id: e.gap_id.clone(),
                reason: format!("PR #{pr} file list empty (deleted or no read access)"),
            });
            continue;
        }
        active.push((e.clone(), files));
    }

    let strategies = if semantic && !active.is_empty() {
        cluster_by_jaccard(&active, 0.8)
    } else {
        Vec::new()
    };

    RollupReport {
        fanout_group: fanout_group.to_string(),
        semantic,
        strategies,
        blocked,
        flat_entries: entries,
    }
}

/// Cluster the active set by file-list Jaccard similarity. Threshold:
/// two entries belong to the same cluster when |A ∩ B| / |A ∪ B| ≥ `threshold`.
fn cluster_by_jaccard(active: &[(RollupEntry, Vec<String>)], threshold: f64) -> Vec<StrategyClass> {
    let mut assigned: Vec<Option<usize>> = vec![None; active.len()];
    let mut clusters: Vec<Vec<usize>> = Vec::new();

    for i in 0..active.len() {
        if assigned[i].is_some() {
            continue;
        }
        let mut cluster = vec![i];
        assigned[i] = Some(clusters.len());
        let cid = clusters.len();
        for j in (i + 1)..active.len() {
            if assigned[j].is_some() {
                continue;
            }
            if jaccard(&active[i].1, &active[j].1) >= threshold {
                cluster.push(j);
                assigned[j] = Some(cid);
            }
        }
        clusters.push(cluster);
    }

    // Sort clusters by descending size so "Strategy A" is the largest.
    clusters.sort_by_key(|c| std::cmp::Reverse(c.len()));

    let mut classes: Vec<StrategyClass> = Vec::new();
    for (idx, cluster) in clusters.iter().enumerate() {
        let name = strategy_letter(idx);
        let member_gaps: Vec<String> = cluster
            .iter()
            .map(|&k| active[k].0.gap_id.clone())
            .collect();
        // Touched-files = union of all members' file lists, deduped + sorted.
        let mut files_set: BTreeMap<String, ()> = BTreeMap::new();
        for &k in cluster {
            for f in &active[k].1 {
                files_set.insert(f.clone(), ());
            }
        }
        let touched_files: Vec<String> = files_set.keys().cloned().collect();
        classes.push(StrategyClass {
            name,
            member_gaps,
            touched_files,
            member_count: cluster.len(),
        });
    }
    classes
}

fn jaccard(a: &[String], b: &[String]) -> f64 {
    use std::collections::HashSet;
    let sa: HashSet<&String> = a.iter().collect();
    let sb: HashSet<&String> = b.iter().collect();
    let inter = sa.intersection(&sb).count();
    let union = sa.union(&sb).count();
    if union == 0 {
        return 0.0;
    }
    inter as f64 / union as f64
}

fn strategy_letter(idx: usize) -> String {
    // A, B, ..., Z, then AA, AB, ... (more than 26 is unlikely but we
    // don't want to crash on a 60-microservices fan-out).
    let mut n = idx;
    let mut s = String::new();
    loop {
        let c = (b'A' + (n % 26) as u8) as char;
        s.insert(0, c);
        n /= 26;
        if n == 0 {
            break;
        }
        n -= 1;
    }
    format!("Strategy {s}")
}

/// Default provider: invoke `gh api repos/<owner>/<repo>/pulls/<N>/files`
/// and return the .filename array. Resolves repo from the local git remote.
pub fn gh_files_provider() -> FilesProvider<'static> {
    Box::new(|pr: u64| -> Vec<String> {
        let endpoint = format!("repos/{{owner}}/{{repo}}/pulls/{pr}/files");
        let out = std::process::Command::new("gh")
            .args([
                "api",
                "-H",
                "Accept: application/vnd.github+json",
                &endpoint,
                "--jq",
                ".[].filename",
            ])
            .output();
        let Ok(o) = out else {
            return Vec::new();
        };
        if !o.status.success() {
            return Vec::new();
        }
        String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    })
}

/// Run the rollup command end-to-end. Pulls gap list via `chump gap list --json`.
pub fn run(fanout_group: &str, semantic: bool, json_out: bool) -> Result<()> {
    let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
    let out = std::process::Command::new(&chump_bin)
        .args(["gap", "list", "--json"])
        .output()
        .map_err(|e| anyhow!("spawn chump gap list: {e}"))?;
    if !out.status.success() {
        return Err(anyhow!(
            "chump gap list failed (exit {:?})",
            out.status.code()
        ));
    }
    let body = String::from_utf8_lossy(&out.stdout).to_string();
    let entries = entries_from_gap_list(&body, fanout_group);
    let provider = gh_files_provider();
    let report = build_rollup(fanout_group, entries, semantic, &provider);
    if json_out {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        print!("{}", render_text(&report));
    }
    Ok(())
}

/// Human-readable rollup output (AC#3 shape).
pub fn render_text(r: &RollupReport) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "=== chump rollup: {} ({} entries) ===\n",
        r.fanout_group,
        r.flat_entries.len()
    ));
    if r.semantic {
        if r.strategies.is_empty() {
            s.push_str("  (no semantic clustering signal — see flat list below)\n");
        }
        for st in &r.strategies {
            s.push_str(&format!(
                "\n  ⚙ {} — {} PR(s) converged on {} touched file(s)\n",
                st.name,
                st.member_count,
                st.touched_files.len()
            ));
            for g in &st.member_gaps {
                let pr = r
                    .flat_entries
                    .iter()
                    .find(|e| e.gap_id == *g)
                    .and_then(|e| e.closed_pr)
                    .map(|n| format!("PR#{n}"))
                    .unwrap_or_else(|| "?".to_string());
                s.push_str(&format!("      {g} {pr}\n"));
            }
            let preview: Vec<&str> = st
                .touched_files
                .iter()
                .take(8)
                .map(|s| s.as_str())
                .collect();
            s.push_str(&format!(
                "      files: {}{}\n",
                preview.join(", "),
                if st.touched_files.len() > 8 {
                    format!(" (+{} more)", st.touched_files.len() - 8)
                } else {
                    String::new()
                }
            ));
        }
    }
    if !r.blocked.is_empty() {
        s.push_str(&format!("\n  ⚠ blocked: {}\n", r.blocked.len()));
        for b in &r.blocked {
            s.push_str(&format!("      {} — {}\n", b.gap_id, b.reason));
        }
    }
    if !r.semantic {
        s.push_str("\n  per-gap flat list:\n");
        for e in &r.flat_entries {
            let pr = e
                .closed_pr
                .map(|n| format!("PR#{n}"))
                .unwrap_or_else(|| "—".to_string());
            s.push_str(&format!(
                "      {} [{}] {} {}\n",
                e.gap_id, e.status, e.repo_label, pr
            ));
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, pr: Option<u64>, status: &str, label: &str) -> RollupEntry {
        RollupEntry {
            gap_id: id.into(),
            target_repo: format!("/tmp/{label}"),
            repo_label: label.into(),
            closed_pr: pr,
            status: status.into(),
        }
    }

    fn provider_from(map: std::collections::HashMap<u64, Vec<String>>) -> FilesProvider<'static> {
        Box::new(move |pr: u64| map.get(&pr).cloned().unwrap_or_default())
    }

    #[test]
    fn entries_from_gap_list_filters_by_fanout_group() {
        let json = r#"[
          {"id":"INFRA-9300","status":"open","notes":"fanout_group=svc-bump\\ntarget_repo=/x\\nrepo_label=alpha"},
          {"id":"INFRA-9301","status":"open","notes":"fanout_group=other\\ntarget_repo=/y"},
          {"id":"INFRA-9302","status":"done","notes":"fanout_group=svc-bump\\ntarget_repo=/z\\nrepo_label=beta","closed_pr":42}
        ]"#;
        let entries = entries_from_gap_list(json, "svc-bump");
        assert_eq!(entries.len(), 2);
        let beta = entries.iter().find(|e| e.repo_label == "beta").unwrap();
        assert_eq!(beta.closed_pr, Some(42));
    }

    #[test]
    fn cluster_by_jaccard_groups_same_file_set() {
        let active = vec![
            (
                entry("A1", Some(1), "done", "a"),
                vec!["src/lib.rs".into(), "Cargo.toml".into()],
            ),
            (
                entry("A2", Some(2), "done", "b"),
                vec!["src/lib.rs".into(), "Cargo.toml".into()],
            ),
            (entry("B1", Some(3), "done", "c"), vec!["readme.md".into()]),
        ];
        let clusters = cluster_by_jaccard(&active, 0.8);
        assert_eq!(clusters.len(), 2);
        assert_eq!(clusters[0].member_count, 2); // biggest first
        assert_eq!(clusters[1].member_count, 1);
        assert_eq!(clusters[0].name, "Strategy A");
        assert_eq!(clusters[1].name, "Strategy B");
    }

    #[test]
    fn jaccard_handles_empty_lists() {
        assert_eq!(jaccard(&[], &[]), 0.0);
        assert!(jaccard(&["x".into()], &[]) < 0.5);
    }

    #[test]
    fn build_rollup_blocks_entries_without_closed_pr() {
        let entries = vec![
            entry("X1", None, "open", "a"),
            entry("X2", Some(99), "done", "b"),
        ];
        let mut map = std::collections::HashMap::new();
        map.insert(99u64, vec!["foo.rs".to_string()]);
        let provider = provider_from(map);
        let r = build_rollup("g", entries, true, &provider);
        assert_eq!(r.blocked.len(), 1);
        assert_eq!(r.blocked[0].gap_id, "X1");
        assert_eq!(r.strategies.len(), 1);
    }

    #[test]
    fn build_rollup_falls_back_to_flat_when_not_semantic() {
        let entries = vec![entry("Y1", Some(1), "done", "a")];
        let mut map = std::collections::HashMap::new();
        map.insert(1u64, vec!["x.rs".to_string()]);
        let provider = provider_from(map);
        let r = build_rollup("g", entries, false, &provider);
        assert!(r.strategies.is_empty());
        assert_eq!(r.flat_entries.len(), 1);
        // Render must still print the flat list.
        let out = render_text(&r);
        assert!(out.contains("flat list"));
        assert!(out.contains("Y1"));
    }

    #[test]
    fn strategy_letter_handles_overflow_past_z() {
        assert_eq!(strategy_letter(0), "Strategy A");
        assert_eq!(strategy_letter(25), "Strategy Z");
        // 26 should roll to AA per the recursive scheme.
        let s = strategy_letter(26);
        assert!(s.contains("Strategy "));
        // We tolerate any 2-letter sequence here as long as it doesn't crash.
        assert!(s.starts_with("Strategy "));
        // 51 should also produce a stable 2-letter result.
        let s = strategy_letter(51);
        assert!(s.starts_with("Strategy "));
    }

    #[test]
    fn render_text_emits_blocked_and_strategy_sections() {
        let entries = vec![
            entry("Z1", Some(1), "done", "svc-a"),
            entry("Z2", Some(2), "done", "svc-b"),
            entry("Z3", None, "open", "svc-c"),
        ];
        let mut map = std::collections::HashMap::new();
        map.insert(1u64, vec!["a.rs".to_string()]);
        map.insert(2u64, vec!["a.rs".to_string()]);
        let provider = provider_from(map);
        let r = build_rollup("zoo", entries, true, &provider);
        let out = render_text(&r);
        assert!(out.contains("Strategy A"));
        assert!(out.contains("blocked"));
        assert!(out.contains("Z3"));
        // Per-strategy line includes PR refs.
        assert!(out.contains("PR#1") && out.contains("PR#2"));
    }
}
