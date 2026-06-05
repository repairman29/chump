//! INFRA-2116: on-disk schema for `~/.chump/external/<owner>/<repo>/`.
//!
//! This module defines the shared memory + scan-result + signal layer that:
//!
//! * **Scout** writes to `scans/onboard-scan-<ts>.json`
//! * **Context-Keeper** writes to `signals/{issues,prs,commits}.jsonl`
//! * **Context-Keeper** curates into `memory/snapshot-<date>.json`
//! * **Decompose** reads scan files to propose new gaps
//! * **Target picker** filters on `external_repo:<owner>/<repo>` tag
//!
//! ## Directory layout
//!
//! ```text
//! ~/.chump/external/<owner>/<repo>/
//! ├── clone/                        # shallow git clone (chump onboard populates)
//! ├── memory/
//! │   ├── snapshot-<iso-date>.json  # periodic health snapshot
//! │   ├── delta-<from>-to-<to>.md  # diff summary between two snapshots
//! │   └── notes.md                 # hand-maintained operator notes
//! ├── scans/
//! │   └── onboard-scan-<iso-ts>.json  # Scout output: proposed-gap list
//! └── signals/
//!     ├── issues.jsonl   # streaming-append: issue events
//!     ├── prs.jsonl      # streaming-append: PR events
//!     └── commits.jsonl  # streaming-append: commit events
//! ```
//!
//! ## Canonical tag format
//!
//! External-repo gaps use the `skills_required` tag:
//!
//! ```text
//! external_repo:<owner>/<repo>
//! ```
//!
//! Rules: lowercase, single colon, slash separator. No trailing slash.
//! Examples: `external_repo:anthropics/anthropic-sdk-rust`,
//! `external_repo:tokio-rs/tokio`.
//!
//! INFRA-2113 (picker filter) and INFRA-2112 (decompose --external-repo) rely
//! on this exact shape — do not deviate.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Tag validation
// ---------------------------------------------------------------------------

/// Validate a `skills_required` external-repo tag of the form
/// `external_repo:<owner>/<repo>` (lowercase, single colon, slash separator).
///
/// Returns `Ok(())` on a well-formed tag, `Err(reason)` otherwise.
pub fn validate_external_repo_tag(tag: &str) -> Result<(), String> {
    let rest = tag
        .strip_prefix("external_repo:")
        .ok_or_else(|| format!("tag must start with 'external_repo:'; got '{tag}'"))?;
    if rest.is_empty() {
        return Err("owner/repo portion is empty".to_string());
    }
    let parts: Vec<&str> = rest.splitn(2, '/').collect();
    if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
        return Err(format!(
            "tag must contain exactly one slash separator with non-empty owner and repo; got '{rest}'"
        ));
    }
    // Reject uppercase — canonical form is all-lowercase.
    if rest.chars().any(|c| c.is_uppercase()) {
        return Err(format!(
            "tag must be all-lowercase; got uppercase characters in '{rest}'"
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// scans/onboard-scan-<iso-ts>.json
// ---------------------------------------------------------------------------

/// Source-of-evidence pointer inside a proposed gap.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SourceOfEvidence {
    /// Relative path inside the external repo clone (e.g. `README.md`).
    pub input_path: String,
    /// Human-readable section label (e.g. `## Installation`).
    pub section: String,
    /// Short verbatim excerpt from that section.
    pub excerpt: String,
}

/// A single proposed gap emitted by Scout after scanning an external repo.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProposedGap {
    /// One-line gap title, following Chump pillar-prefix convention.
    pub title: String,
    /// Domain bucket (e.g. `INFRA`, `DOC`, `EFFECTIVE`).
    pub domain: String,
    /// Proposed priority tier.
    pub priority: Priority,
    /// Estimated effort size.
    pub effort: Effort,
    /// Scout's confidence in this proposal.
    pub confidence: Confidence,
    /// Which part of the scanned repo led Scout to propose this.
    pub source_of_evidence: SourceOfEvidence,
    /// Draft acceptance criteria (one item per string).
    pub acceptance_criteria_draft: Vec<String>,
    /// EFFECTIVE-201: Doctrine layer tag — "L1" (foundation), "L2" (fulfillment),
    /// or "L3" (realization). `None` for gaps produced before the doctrine was
    /// introduced (back-compat: existing scan JSON round-trips without this field).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    /// EFFECTIVE-201: Human-readable justification for why this gap belongs to
    /// its doctrine layer, citing the specific doctrine principle it satisfies.
    /// `None` for pre-doctrine scans (back-compat).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doctrine_justification: Option<String>,
}

/// Priority tier — mirrors Chump's own gap priority vocabulary.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Priority {
    /// Unblocking emergency — use sparingly (max 5 across fleet).
    P0,
    /// High-value, should-ship-soon.
    P1,
    /// Normal backlog.
    P2,
    /// Low-priority / nice-to-have.
    P3,
}

/// Effort size estimate.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Effort {
    /// < 30 min.
    Xs,
    /// 30 min – 2 h.
    S,
    /// 2–6 h.
    M,
    /// > 6 h.
    L,
}

/// Scout's confidence in a proposed gap.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    /// Strong evidence, clear gap.
    High,
    /// Some evidence, reasonable inference.
    Med,
    /// Weak signal — might be wrong.
    Low,
}

/// Metadata about a file that was read during scanning.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct InputRead {
    /// Relative path inside the external repo clone.
    pub path: String,
    /// SHA-256 hex digest of the file contents at scan time.
    pub sha256: String,
    /// One-line summary of what the file contains.
    pub summary: String,
}

/// `scans/onboard-scan-<iso-ts>.json` — top-level record produced by Scout.
///
/// File-name convention: `onboard-scan-<YYYYMMDDTHHMMSSZ>.json`
/// where the timestamp is the ISO-8601 UTC scan start time with colons removed
/// so the filename is safe on all operating systems.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OnboardScan {
    /// ISO-8601 UTC timestamp when the scan started.
    pub scan_timestamp: DateTime<Utc>,
    /// `owner/repo` of the external repository.
    pub external_repo: String,
    /// Scout tool version string (e.g. `0.1.0`).
    pub tool_version: String,
    /// Files read during the scan, in order.
    pub inputs_read: Vec<InputRead>,
    /// Proposed gaps, ranked by confidence descending.
    pub proposed_gaps: Vec<ProposedGap>,
}

/// Return the canonical file path for a scan inside the external-repo directory.
pub fn scan_path(repo_dir: &Path, scan_timestamp: &DateTime<Utc>) -> PathBuf {
    let ts = scan_timestamp.format("%Y%m%dT%H%M%SZ");
    repo_dir
        .join("scans")
        .join(format!("onboard-scan-{ts}.json"))
}

/// Write an [`OnboardScan`] to the canonical location under `repo_dir`.
pub fn save_scan(repo_dir: &Path, scan: &OnboardScan) -> anyhow::Result<()> {
    let path = scan_path(repo_dir, &scan.scan_timestamp);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(scan)?;
    fs::write(&path, json)?;
    Ok(())
}

/// Read the most-recently-written [`OnboardScan`] from `repo_dir/scans/`.
///
/// Returns `None` if the directory is absent or contains no scan files.
pub fn read_latest_scan(repo_dir: &Path) -> anyhow::Result<Option<OnboardScan>> {
    let scans_dir = repo_dir.join("scans");
    if !scans_dir.exists() {
        return Ok(None);
    }
    let mut entries: Vec<PathBuf> = fs::read_dir(&scans_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("onboard-scan-") && n.ends_with(".json"))
                .unwrap_or(false)
        })
        .collect();
    entries.sort();
    match entries.last() {
        None => Ok(None),
        Some(path) => {
            let bytes = fs::read(path)?;
            let scan: OnboardScan = serde_json::from_slice(&bytes)?;
            Ok(Some(scan))
        }
    }
}

// ---------------------------------------------------------------------------
// memory/snapshot-<iso-date>.json
// ---------------------------------------------------------------------------

/// `memory/snapshot-<iso-date>.json` — periodic health snapshot of the external repo.
///
/// File-name convention: `snapshot-<YYYY-MM-DD>.json` (date only, UTC).
/// When multiple snapshots exist for one date, readers take the lexicographically
/// last file (i.e. the latest write wins within a day).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RepoSnapshot {
    /// ISO-8601 UTC timestamp of when this snapshot was captured.
    pub snapshot_timestamp: DateTime<Utc>,
    /// `owner/repo` of the external repository.
    pub external_repo: String,
    /// HEAD SHA of the external repo's default branch at snapshot time.
    pub git_head_sha: String,
    /// Number of open issues at snapshot time.
    pub open_issues_count: u32,
    /// Number of open PRs at snapshot time.
    pub open_prs_count: u32,
    /// ISO-8601 timestamp of the most recent commit on the default branch.
    pub last_commit_iso: DateTime<Utc>,
    /// Number of commits in the last 30 days on the default branch.
    pub last_30d_commit_count: u32,
    /// Relative paths of "intent" files found in the repo root
    /// (e.g. `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `ROADMAP.md`).
    pub intent_files_present: Vec<String>,
}

/// Return the canonical file path for a snapshot inside the external-repo directory.
pub fn snapshot_path(repo_dir: &Path, snapshot_timestamp: &DateTime<Utc>) -> PathBuf {
    let date = snapshot_timestamp.format("%Y-%m-%d");
    repo_dir
        .join("memory")
        .join(format!("snapshot-{date}.json"))
}

/// Write a [`RepoSnapshot`] to the canonical location under `repo_dir`.
pub fn save_snapshot(repo_dir: &Path, snapshot: &RepoSnapshot) -> anyhow::Result<()> {
    let path = snapshot_path(repo_dir, &snapshot.snapshot_timestamp);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(snapshot)?;
    fs::write(&path, json)?;
    Ok(())
}

/// Read the most-recently-written [`RepoSnapshot`] from `repo_dir/memory/`.
///
/// Returns `None` if the directory is absent or contains no snapshot files.
pub fn load_snapshot(repo_dir: &Path) -> anyhow::Result<Option<RepoSnapshot>> {
    let memory_dir = repo_dir.join("memory");
    if !memory_dir.exists() {
        return Ok(None);
    }
    let mut entries: Vec<PathBuf> = fs::read_dir(&memory_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("snapshot-") && n.ends_with(".json"))
                .unwrap_or(false)
        })
        .collect();
    entries.sort();
    match entries.last() {
        None => Ok(None),
        Some(path) => {
            let bytes = fs::read(path)?;
            let snap: RepoSnapshot = serde_json::from_slice(&bytes)?;
            Ok(Some(snap))
        }
    }
}

// ---------------------------------------------------------------------------
// signals/{issues,prs,commits}.jsonl
// ---------------------------------------------------------------------------

/// A single entry from `signals/issues.jsonl`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IssueSignal {
    /// ISO-8601 UTC timestamp of the event.
    pub ts: DateTime<Utc>,
    /// GitHub issue number.
    pub number: u32,
    /// Issue lifecycle action.
    pub action: IssueAction,
    /// Issue title at event time.
    pub title: String,
}

/// Issue lifecycle action variants.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IssueAction {
    /// Issue was opened.
    Opened,
    /// Issue was closed.
    Closed,
    /// Issue was re-opened.
    Reopened,
    /// A comment was added.
    Commented,
    /// A label was added or removed.
    Labeled,
}

/// A single entry from `signals/prs.jsonl`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrSignal {
    /// ISO-8601 UTC timestamp of the event.
    pub ts: DateTime<Utc>,
    /// GitHub PR number.
    pub number: u32,
    /// PR lifecycle action.
    pub action: PrAction,
    /// PR title at event time.
    pub title: String,
    /// `owner/repo` of the fork head (same as `external_repo` for same-repo PRs).
    pub head_repo: String,
}

/// PR lifecycle action variants.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PrAction {
    /// PR was opened.
    Opened,
    /// PR was merged.
    Merged,
    /// PR was closed without merging.
    Closed,
    /// A review was submitted.
    Reviewed,
}

/// A single entry from `signals/commits.jsonl`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CommitSignal {
    /// ISO-8601 UTC timestamp of the push event.
    pub ts: DateTime<Utc>,
    /// Full SHA of the commit.
    pub sha: String,
    /// Author display name or `login`.
    pub author: String,
    /// First line of the commit message.
    pub summary: String,
}

/// Which signal stream to append to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalKind {
    /// `signals/issues.jsonl`
    Issues,
    /// `signals/prs.jsonl`
    Prs,
    /// `signals/commits.jsonl`
    Commits,
}

impl SignalKind {
    fn filename(self) -> &'static str {
        match self {
            SignalKind::Issues => "issues.jsonl",
            SignalKind::Prs => "prs.jsonl",
            SignalKind::Commits => "commits.jsonl",
        }
    }
}

/// Append a single signal event to the appropriate `.jsonl` file under
/// `repo_dir/signals/`.
///
/// Each call appends exactly one JSON line followed by `\n`. The file is
/// created (including parent directories) if it does not yet exist.
pub fn append_signal<S: Serialize>(
    repo_dir: &Path,
    kind: SignalKind,
    signal: &S,
) -> anyhow::Result<()> {
    let signals_dir = repo_dir.join("signals");
    fs::create_dir_all(&signals_dir)?;
    let path = signals_dir.join(kind.filename());
    let line = serde_json::to_string(signal)?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{line}")?;
    Ok(())
}

/// Read all signal entries of type `S` from the given `.jsonl` stream.
///
/// Lines that fail to deserialize are silently skipped (tolerant of partially-
/// written lines from a previous crash). Callers that need strict parsing
/// should use [`read_signals_strict`] instead.
pub fn read_signals<S: for<'de> Deserialize<'de>>(
    repo_dir: &Path,
    kind: SignalKind,
) -> anyhow::Result<Vec<S>> {
    let path = repo_dir.join("signals").join(kind.filename());
    if !path.exists() {
        return Ok(vec![]);
    }
    let file = fs::File::open(&path)?;
    let reader = BufReader::new(file);
    let records = reader
        .lines()
        .map_while(Result::ok)
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<S>(&l).ok())
        .collect();
    Ok(records)
}

/// Same as [`read_signals`] but returns an error on any malformed line.
pub fn read_signals_strict<S: for<'de> Deserialize<'de>>(
    repo_dir: &Path,
    kind: SignalKind,
) -> anyhow::Result<Vec<S>> {
    let path = repo_dir.join("signals").join(kind.filename());
    if !path.exists() {
        return Ok(vec![]);
    }
    let file = fs::File::open(&path)?;
    let reader = BufReader::new(file);
    let mut records = Vec::new();
    for line in reader.lines() {
        let l = line?;
        if l.trim().is_empty() {
            continue;
        }
        let record: S = serde_json::from_str(&l)?;
        records.push(record);
    }
    Ok(records)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use tempfile::TempDir;

    fn fixed_ts() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 28, 12, 0, 0).unwrap()
    }

    fn sample_snapshot(_repo_dir: &Path) -> RepoSnapshot {
        RepoSnapshot {
            snapshot_timestamp: fixed_ts(),
            external_repo: "anthropics/anthropic-sdk-rust".to_string(),
            git_head_sha: "abc123def456abc123def456abc123def456abc1".to_string(),
            open_issues_count: 7,
            open_prs_count: 2,
            last_commit_iso: fixed_ts(),
            last_30d_commit_count: 15,
            intent_files_present: vec!["AGENTS.md".to_string(), "CONTRIBUTING.md".to_string()],
        }
    }

    fn sample_scan(_repo_dir: &Path) -> OnboardScan {
        OnboardScan {
            scan_timestamp: fixed_ts(),
            external_repo: "anthropics/anthropic-sdk-rust".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![InputRead {
                path: "README.md".to_string(),
                sha256: "deadbeef".to_string(),
                summary: "Main project overview".to_string(),
            }],
            proposed_gaps: vec![ProposedGap {
                title: "EFFECTIVE: add streaming support to SDK".to_string(),
                domain: "EFFECTIVE".to_string(),
                priority: Priority::P1,
                effort: Effort::M,
                confidence: Confidence::High,
                source_of_evidence: SourceOfEvidence {
                    input_path: "README.md".to_string(),
                    section: "## Roadmap".to_string(),
                    excerpt: "streaming SSE support planned".to_string(),
                },
                acceptance_criteria_draft: vec![
                    "SSE stream iterator returns typed chunks".to_string(),
                    "README updated with streaming example".to_string(),
                ],
                layer: None,
                doctrine_justification: None,
            }],
        }
    }

    // Test (a): round-trip snapshot save/load
    #[test]
    fn snapshot_round_trip() {
        let dir = TempDir::new().unwrap();
        let repo_dir = dir.path();
        let snap = sample_snapshot(repo_dir);
        save_snapshot(repo_dir, &snap).unwrap();
        let loaded = load_snapshot(repo_dir)
            .unwrap()
            .expect("snapshot not found");
        assert_eq!(snap, loaded);
    }

    // Test (b): round-trip scan save/load
    #[test]
    fn scan_round_trip() {
        let dir = TempDir::new().unwrap();
        let repo_dir = dir.path();
        let scan = sample_scan(repo_dir);
        save_scan(repo_dir, &scan).unwrap();
        let loaded = read_latest_scan(repo_dir).unwrap().expect("scan not found");
        assert_eq!(scan, loaded);
    }

    // Test (c): signal append produces well-formed JSONL, one entry per line
    #[test]
    fn signal_append_well_formed_jsonl() {
        let dir = TempDir::new().unwrap();
        let repo_dir = dir.path();
        let s1 = IssueSignal {
            ts: fixed_ts(),
            number: 42,
            action: IssueAction::Opened,
            title: "Fix the thing".to_string(),
        };
        let s2 = IssueSignal {
            ts: fixed_ts(),
            number: 43,
            action: IssueAction::Closed,
            title: "Also fix that".to_string(),
        };
        append_signal(repo_dir, SignalKind::Issues, &s1).unwrap();
        append_signal(repo_dir, SignalKind::Issues, &s2).unwrap();

        // Read raw file and verify: 2 non-empty lines, each valid JSON, no blank separators
        let path = repo_dir.join("signals").join("issues.jsonl");
        let content = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(
            lines.len(),
            2,
            "expected exactly 2 lines, got {}",
            lines.len()
        );
        for line in &lines {
            assert!(!line.trim().is_empty(), "blank line found");
            let _: serde_json::Value = serde_json::from_str(line).expect("not valid JSON");
        }

        // Round-trip via read_signals
        let records: Vec<IssueSignal> = read_signals(repo_dir, SignalKind::Issues).unwrap();
        assert_eq!(records, vec![s1, s2]);
    }

    // Test (d): reject malformed tags
    #[test]
    fn tag_validation_rejects_malformed() {
        // Missing _repo suffix
        assert!(
            validate_external_repo_tag("external:foo/bar").is_err(),
            "should reject 'external:foo/bar' (missing _repo)"
        );
        // Missing slash (no repo part)
        assert!(
            validate_external_repo_tag("external_repo:foo").is_err(),
            "should reject 'external_repo:foo' (missing slash)"
        );
        // Uppercase characters
        assert!(
            validate_external_repo_tag("external_repo:Owner/repo").is_err(),
            "should reject uppercase owner"
        );
        // Empty repo part
        assert!(
            validate_external_repo_tag("external_repo:foo/").is_err(),
            "should reject empty repo"
        );
        // Valid tags pass
        assert!(validate_external_repo_tag("external_repo:anthropics/anthropic-sdk-rust").is_ok());
        assert!(validate_external_repo_tag("external_repo:tokio-rs/tokio").is_ok());
    }
}
