//! Gap-registry CI integrity gate — port of
//! `scripts/coord/check-gaps-integrity.py` (Phase 1 of INFRA-2000).
//!
//! Two layouts are validated:
//!
//! - **Per-file** (post-INFRA-188 canonical): every `*.yaml` under
//!   `docs/gaps/` parses, has a non-empty `id`, and no two files share
//!   an `id`.
//! - **Monolithic** (legacy fallback): the top-level `gaps:` list in
//!   `docs/gaps.yaml` is well-formed and has no duplicate IDs.
//!
//! The pre-commit hook catches in-branch duplicates; this CI gate
//! re-checks after the merge queue rebases — concurrent branches that
//! each filed the same ID can sneak past the pre-commit hook because
//! it only sees the locally-staged file. The merge-queue rebase
//! produces the conflict; this script makes the conflict loud.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use thiserror::Error;

/// Layout to validate.
#[derive(Debug, Clone)]
pub enum IntegritySource {
    /// `docs/gaps/` per-file layout. Pass the directory path.
    PerFile(PathBuf),
    /// Legacy monolithic `docs/gaps.yaml`. Pass the file path.
    Monolithic(PathBuf),
}

/// One integrity report.
#[derive(Debug, Clone, Default)]
pub struct IntegrityReport {
    /// Unique gap IDs seen.
    pub unique_ids: usize,
    /// Files / list-positions whose entry had no `id`.
    pub missing_ids: Vec<String>,
    /// Map of `gid -> occurrence count` for IDs that appeared >1 time.
    pub duplicates: BTreeMap<String, usize>,
    /// Files that didn't parse as YAML (per-file layout only).
    pub yaml_parse_failures: Vec<PathBuf>,
    /// Source label for the rendered output.
    pub source_label: String,
}

impl IntegrityReport {
    /// Non-zero exit when any invariant is breached.
    pub fn failing(&self) -> bool {
        !self.missing_ids.is_empty()
            || !self.duplicates.is_empty()
            || !self.yaml_parse_failures.is_empty()
    }

    /// Render the same output the Python `check_integrity` function emits.
    pub fn render(&self) -> String {
        let mut out = String::new();
        if !self.yaml_parse_failures.is_empty() {
            for p in &self.yaml_parse_failures {
                out.push_str(&format!("FAIL: {} does not parse as YAML\n", p.display()));
            }
        }
        if !self.missing_ids.is_empty() {
            out.push_str(&format!(
                "FAIL: {} gap entry(ies) have no `id:` (positions: {:?})\n",
                self.missing_ids.len(),
                self.missing_ids.iter().take(5).collect::<Vec<_>>()
            ));
        }
        if !self.duplicates.is_empty() {
            out.push_str(&format!(
                "FAIL: {} contains duplicate id(s):\n",
                self.source_label
            ));
            for (gid, n) in &self.duplicates {
                out.push_str(&format!("  - {} (appears {} times)\n", gid, n));
            }
            out.push_str(
                "\nThe pre-commit duplicate-ID guard catches in-branch duplicates but\n\
                 cannot see ids added on a sibling branch. Resolve by renaming the\n\
                 more recently filed entry to the next free ID; record the rename in\n\
                 the entry's description for audit trail.\n",
            );
        }
        if !self.failing() {
            out.push_str(&format!(
                "OK: {} parses; {} unique gap ids.\n",
                self.source_label, self.unique_ids
            ));
        }
        out
    }
}

/// Errors that prevent the check from even running (path not found,
/// permission denied, etc). Per-file YAML parse errors are captured in
/// the [`IntegrityReport`] itself, not raised here.
#[derive(Debug, Error)]
pub enum IntegrityError {
    /// I/O error reading the source layout.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    /// Monolithic source doesn't have the expected top-level `gaps:` key.
    #[error("monolithic source missing top-level `gaps:` list")]
    MalformedMonolithic,
    /// The monolithic source itself failed to parse.
    #[error("monolithic yaml parse: {0}")]
    MonolithicParse(String),
}

/// Run the integrity check.
pub fn check_gaps_integrity(source: &IntegritySource) -> Result<IntegrityReport, IntegrityError> {
    match source {
        IntegritySource::PerFile(dir) => check_per_file(dir),
        IntegritySource::Monolithic(path) => check_monolithic(path),
    }
}

fn check_per_file(dir: &Path) -> Result<IntegrityReport, IntegrityError> {
    let mut report = IntegrityReport {
        source_label: format!("{} directory", dir.display()),
        ..Default::default()
    };
    if !dir.is_dir() {
        // Matches the Python tool's tolerance: missing dir returns empty
        // report (it's tested in CI before the dir exists).
        return Ok(report);
    }
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut entries: Vec<_> = std::fs::read_dir(dir)?
        .filter_map(|r| r.ok())
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|s| s.to_str())
                .map(|ext| ext.eq_ignore_ascii_case("yaml"))
                .unwrap_or(false)
        })
        .collect();
    entries.sort_by_key(|e| e.path());

    let mut file_count = 0usize;
    for entry in entries {
        let path = entry.path();
        file_count += 1;
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => {
                report.yaml_parse_failures.push(path.clone());
                continue;
            }
        };
        let parsed: serde_yaml::Value = match serde_yaml::from_str(&text) {
            Ok(v) => v,
            Err(_) => {
                report.yaml_parse_failures.push(path.clone());
                continue;
            }
        };
        let entries_iter: Vec<serde_yaml::Value> = match parsed {
            serde_yaml::Value::Sequence(seq) => seq,
            serde_yaml::Value::Mapping(_) => vec![parsed],
            _ => continue,
        };
        for v in entries_iter {
            if let serde_yaml::Value::Mapping(m) = &v {
                match m.get(serde_yaml::Value::String("id".to_string())) {
                    Some(serde_yaml::Value::String(id)) if !id.is_empty() => {
                        *counts.entry(id.clone()).or_insert(0) += 1;
                    }
                    _ => {
                        report.missing_ids.push(path.display().to_string());
                    }
                }
            }
        }
    }
    report.source_label = format!("{} directory ({} files)", dir.display(), file_count);
    report.unique_ids = counts.len();
    for (gid, n) in counts {
        if n > 1 {
            report.duplicates.insert(gid, n);
        }
    }
    Ok(report)
}

fn check_monolithic(path: &Path) -> Result<IntegrityReport, IntegrityError> {
    let mut report = IntegrityReport {
        source_label: path.display().to_string(),
        ..Default::default()
    };
    let text = std::fs::read_to_string(path)?;
    let parsed: serde_yaml::Value =
        serde_yaml::from_str(&text).map_err(|e| IntegrityError::MonolithicParse(e.to_string()))?;
    let gaps = match parsed {
        serde_yaml::Value::Mapping(ref m) => m
            .get(serde_yaml::Value::String("gaps".to_string()))
            .and_then(|v| v.as_sequence())
            .cloned(),
        _ => None,
    };
    let gaps = gaps.ok_or(IntegrityError::MalformedMonolithic)?;
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for (idx, v) in gaps.iter().enumerate() {
        if let serde_yaml::Value::Mapping(m) = v {
            match m.get(serde_yaml::Value::String("id".to_string())) {
                Some(serde_yaml::Value::String(id)) if !id.is_empty() => {
                    *counts.entry(id.clone()).or_insert(0) += 1;
                }
                _ => {
                    report.missing_ids.push(format!("position {}", idx));
                }
            }
        }
    }
    report.unique_ids = counts.len();
    for (gid, n) in counts {
        if n > 1 {
            report.duplicates.insert(gid, n);
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn write(path: &Path, content: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn per_file_clean_returns_unique_count() {
        let td = TempDir::new().unwrap();
        let dir = td.path().join("docs/gaps");
        write(
            &dir.join("INFRA-1.yaml"),
            "- id: INFRA-1\n  title: t\n  status: open\n",
        );
        write(
            &dir.join("INFRA-2.yaml"),
            "- id: INFRA-2\n  title: t\n  status: open\n",
        );
        let report = check_gaps_integrity(&IntegritySource::PerFile(dir)).unwrap();
        assert_eq!(report.unique_ids, 2);
        assert!(!report.failing());
    }

    #[test]
    fn per_file_duplicate_id_fails() {
        let td = TempDir::new().unwrap();
        let dir = td.path().join("docs/gaps");
        write(
            &dir.join("INFRA-1.yaml"),
            "- id: INFRA-1\n  title: t\n  status: open\n",
        );
        write(
            &dir.join("INFRA-1-DUP.yaml"),
            "- id: INFRA-1\n  title: t2\n  status: open\n",
        );
        let report = check_gaps_integrity(&IntegritySource::PerFile(dir)).unwrap();
        assert!(report.failing());
        assert_eq!(report.duplicates.get("INFRA-1"), Some(&2));
    }

    #[test]
    fn per_file_invalid_yaml_recorded() {
        let td = TempDir::new().unwrap();
        let dir = td.path().join("docs/gaps");
        write(&dir.join("BROKEN.yaml"), "id: : : not yaml\n  - dangling");
        let report = check_gaps_integrity(&IntegritySource::PerFile(dir)).unwrap();
        assert!(report.failing());
        assert_eq!(report.yaml_parse_failures.len(), 1);
    }

    #[test]
    fn monolithic_clean() {
        let td = TempDir::new().unwrap();
        let path = td.path().join("docs/gaps.yaml");
        write(
            &path,
            "gaps:\n  - id: A\n    title: t\n  - id: B\n    title: t2\n",
        );
        let report = check_gaps_integrity(&IntegritySource::Monolithic(path)).unwrap();
        assert_eq!(report.unique_ids, 2);
        assert!(!report.failing());
    }

    #[test]
    fn monolithic_missing_gaps_key_errors() {
        let td = TempDir::new().unwrap();
        let path = td.path().join("docs/gaps.yaml");
        write(&path, "not_gaps: []\n");
        let err = check_gaps_integrity(&IntegritySource::Monolithic(path)).unwrap_err();
        assert!(matches!(err, IntegrityError::MalformedMonolithic));
    }
}
