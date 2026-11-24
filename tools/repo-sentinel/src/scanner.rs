use crate::gitignore_audit::audit_gitignore;
use crate::patterns::{classify_leak_filename, scan_line_for_secrets, Severity};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Finding {
    pub severity: Severity,
    pub category: String,
    pub rule_id: String,
    pub file: String,
    pub line: Option<usize>,
    pub summary: String,
    pub redacted_match: Option<String>,
    pub remediation: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SeverityCounts {
    pub critical: usize,
    pub high: usize,
    pub medium: usize,
    pub low: usize,
}

impl SeverityCounts {
    pub fn record(&mut self, s: Severity) {
        match s {
            Severity::Critical => self.critical += 1,
            Severity::High => self.high += 1,
            Severity::Medium => self.medium += 1,
            Severity::Low => self.low += 1,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoScanReport {
    pub repo_name: String,
    pub repo_path: String,
    pub is_git_repo: bool,
    pub staged_only: bool,
    pub files_scanned: usize,
    pub counts: SeverityCounts,
    pub findings: Vec<Finding>,
    pub passed_gate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortfolioRepoSummary {
    pub repo_name: String,
    pub repo_path: String,
    pub passed_gate: bool,
    pub counts: SeverityCounts,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortfolioReport {
    pub root_dir: String,
    pub repos_scanned: usize,
    pub clean_repos: usize,
    pub at_risk_repos: usize,
    pub totals: SeverityCounts,
    pub repos: Vec<PortfolioRepoSummary>,
}

pub fn scan_repo(
    path: &Path,
    staged_only: bool,
    fail_on: Severity,
) -> Result<RepoScanReport, String> {
    if !path.exists() {
        return Err(format!("Path does not exist: {}", path.display()));
    }

    let repo_name = path
        .file_name()
        .unwrap_or(path.as_os_str())
        .to_string_lossy()
        .into_owned();
    let repo_path = path.to_string_lossy().into_owned();
    let is_git_repo = path.join(".git").exists();

    let mut findings = Vec::new();
    let mut counts = SeverityCounts::default();
    let mut files_scanned = 0;

    if staged_only {
        if !is_git_repo {
            return Err("Not a git repository".to_string());
        }

        let output = Command::new("git")
            .arg("diff")
            .arg("--cached")
            .arg("--name-only")
            .current_dir(path)
            .output()
            .map_err(|e| e.to_string())?;

        let staged_files: HashSet<String> = String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(|s| s.to_string())
            .collect();

        for file in staged_files {
            if let Some((rule_id, desc)) = classify_leak_filename(&file) {
                let severity = Severity::Critical;
                findings.push(Finding {
                    severity,
                    category: "Leaked File".to_string(),
                    rule_id: rule_id.to_string(),
                    file: file.clone(),
                    line: None,
                    summary: format!("{}: {}", desc, file),
                    redacted_match: None,
                    remediation: "Remove the file from staging".to_string(),
                });
                counts.record(severity);
            }
        }

        let output = Command::new("git")
            .arg("diff")
            .arg("--cached")
            .arg("-U0")
            .current_dir(path)
            .output()
            .map_err(|e| e.to_string())?;

        let mut current_file = String::new();
        let mut current_line = 0;

        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Some(stripped) = line.strip_prefix("+++ b/") {
                current_file = stripped.to_string();
            } else if line.starts_with("@@ ") {
                if let Some(cap) = line.find('+') {
                    current_line = line[cap + 1..]
                        .split_whitespace()
                        .next()
                        .unwrap_or("0")
                        .split(',')
                        .next()
                        .unwrap_or("0")
                        .parse()
                        .unwrap_or(0);
                }
            } else if line.starts_with('+') && !line.starts_with("+++") {
                for hit in scan_line_for_secrets(&line[1..]) {
                    findings.push(Finding {
                        severity: hit.severity,
                        category: "Secret".to_string(),
                        rule_id: hit.rule_id,
                        file: current_file.clone(),
                        line: Some(current_line),
                        summary: format!("Potential secret in {}", current_file),
                        redacted_match: Some(hit.redacted),
                        remediation: "Remove the secret from the diff".to_string(),
                    });
                    counts.record(hit.severity);
                }
                current_line += 1;
            }
        }
    } else {
        let mut tracked_files = HashSet::new();
        let mut ignored_files = HashSet::new();

        if is_git_repo {
            let output = Command::new("git")
                .arg("ls-files")
                .current_dir(path)
                .output()
                .map_err(|e| e.to_string())?;

            tracked_files = String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|s| s.to_string())
                .collect();

            let output = Command::new("git")
                .arg("ls-files")
                .arg("--others")
                .arg("-i")
                .arg("--exclude-standard")
                .current_dir(path)
                .output()
                .map_err(|e| e.to_string())?;

            ignored_files = String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|s| s.to_string())
                .collect();
        }

        let mut dir_stack = vec![path.to_path_buf()];

        while let Some(dir) = dir_stack.pop() {
            let entries = fs::read_dir(&dir).map_err(|e| e.to_string())?;

            for entry in entries {
                let entry = entry.map_err(|e| e.to_string())?;
                let entry_path = entry.path();

                if entry_path.is_dir() {
                    if entry_path.ends_with(".git")
                        || entry_path.ends_with("target")
                        || entry_path.ends_with("node_modules")
                        || entry_path.ends_with(".venv")
                        || entry_path.ends_with("venv")
                        || entry_path.ends_with("dist")
                        || entry_path.ends_with(".next")
                        || entry_path.ends_with(".chump-locks")
                    {
                        continue;
                    }
                    dir_stack.push(entry_path);
                } else {
                    let rel_path = entry_path
                        .strip_prefix(path)
                        .unwrap_or(&entry_path)
                        .to_string_lossy()
                        .into_owned();

                    if ignored_files.contains(&rel_path) && !tracked_files.contains(&rel_path) {
                        continue;
                    }

                    if let Some((rule_id, desc)) = classify_leak_filename(&rel_path) {
                        let severity = if tracked_files.contains(&rel_path) {
                            Severity::Critical
                        } else {
                            Severity::High
                        };
                        findings.push(Finding {
                            severity,
                            category: "Leaked File".to_string(),
                            rule_id: rule_id.to_string(),
                            file: rel_path.clone(),
                            line: None,
                            summary: format!("{}: {}", desc, rel_path),
                            redacted_match: None,
                            remediation: "Add to .gitignore and untrack with git rm --cached"
                                .to_string(),
                        });
                        counts.record(severity);
                    }

                    let metadata = fs::metadata(&entry_path).map_err(|e| e.to_string())?;
                    if metadata.len() <= 1_048_576 {
                        if let Ok(bytes) = fs::read(&entry_path) {
                            if !bytes.contains(&0) {
                                if let Ok(content) = std::str::from_utf8(&bytes) {
                                    files_scanned += 1;
                                    for (i, line) in content.lines().enumerate() {
                                        for hit in scan_line_for_secrets(line) {
                                            findings.push(Finding {
                                                severity: hit.severity,
                                                category: "Secret".to_string(),
                                                rule_id: hit.rule_id,
                                                file: rel_path.clone(),
                                                line: Some(i + 1),
                                                summary: format!(
                                                    "Potential secret in {}",
                                                    rel_path
                                                ),
                                                redacted_match: Some(hit.redacted),
                                                remediation: "Remove the secret from the file"
                                                    .to_string(),
                                            });
                                            counts.record(hit.severity);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if is_git_repo {
            let missing = audit_gitignore(path)?;
            if !missing.is_empty() {
                findings.push(Finding {
                    severity: Severity::Medium,
                    category: "Gitignore".to_string(),
                    rule_id: "gitignore-blindspot".to_string(),
                    file: ".gitignore".to_string(),
                    line: None,
                    summary: "Gitignore is missing recommended patterns".to_string(),
                    redacted_match: None,
                    remediation: "Add missing patterns to .gitignore".to_string(),
                });
                counts.record(Severity::Medium);
            }

            let bloat_files = ["node_modules/", ".venv/", "venv/", "target/", ".dex"];
            for prefix in &bloat_files {
                if tracked_files
                    .iter()
                    .any(|f| f.starts_with(prefix) && f.ends_with(".dex"))
                {
                    findings.push(Finding {
                        severity: Severity::Medium,
                        category: "Bloat".to_string(),
                        rule_id: "tracked-bloat".to_string(),
                        file: prefix.to_string(),
                        line: None,
                        summary: format!("Bloat directory {} is tracked", prefix),
                        redacted_match: None,
                        remediation: format!("Add {} to .gitignore", prefix),
                    });
                    counts.record(Severity::Medium);
                }
            }

            let license_files = ["LICENSE", "LICENSE.md", "LICENSE-MIT", "LICENSE-APACHE"];
            let has_license = license_files.iter().any(|file| path.join(file).exists());
            if !has_license {
                findings.push(Finding {
                    severity: Severity::Low,
                    category: "License".to_string(),
                    rule_id: "missing-license".to_string(),
                    file: "".to_string(),
                    line: None,
                    summary: "No license file found".to_string(),
                    redacted_match: None,
                    remediation: "Add a license file".to_string(),
                });
                counts.record(Severity::Low);
            }
        }
    }

    findings.sort_by_key(|b| std::cmp::Reverse(b.severity));
    let passed_gate = findings.iter().all(|f| f.severity < fail_on);

    Ok(RepoScanReport {
        repo_name,
        repo_path,
        is_git_repo,
        staged_only,
        files_scanned,
        counts,
        findings,
        passed_gate,
    })
}

pub fn scan_portfolio(
    root_dir: &Path,
    max_repos: usize,
    fail_on: Severity,
) -> Result<PortfolioReport, String> {
    let mut repos = Vec::new();
    let mut totals = SeverityCounts::default();
    let mut repos_scanned = 0;
    let mut clean_repos = 0;
    let mut at_risk_repos = 0;

    let entries = fs::read_dir(root_dir).map_err(|e| e.to_string())?;

    for entry in entries {
        if repos_scanned >= max_repos {
            break;
        }

        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();

        if path.is_dir() && path.join(".git").exists() {
            let report = scan_repo(&path, false, fail_on)?;
            repos_scanned += 1;

            if report.passed_gate {
                clean_repos += 1;
            } else {
                at_risk_repos += 1;
            }

            totals.critical += report.counts.critical;
            totals.high += report.counts.high;
            totals.medium += report.counts.medium;
            totals.low += report.counts.low;

            repos.push(PortfolioRepoSummary {
                repo_name: report.repo_name,
                repo_path: report.repo_path,
                passed_gate: report.passed_gate,
                counts: report.counts,
            });
        }
    }

    Ok(PortfolioReport {
        root_dir: root_dir.to_string_lossy().into_owned(),
        repos_scanned,
        clean_repos,
        at_risk_repos,
        totals,
        repos,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn create_temp_dir() -> PathBuf {
        let mut dir = env::temp_dir();
        dir.push(format!(
            "repo_sentinel_scanner_{}_{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_leak_file() {
        let dir = create_temp_dir();
        let file_path = dir.join(".env.bak");
        fs::write(
            &file_path,
            format!("{}{}{}", "sk_", "live_", "9876543210abcdef1234"),
        )
        .unwrap();

        let report = scan_repo(&dir, false, Severity::Critical).unwrap();
        assert!(report
            .findings
            .iter()
            .any(|f| f.rule_id == "leak-backup-file"));
        assert!(report
            .findings
            .iter()
            .any(|f| f.rule_id == "stripe-live-key"));
        assert!(!report
            .findings
            .iter()
            .any(|f| f.summary.contains("9876543210abcdef")));
    }

    #[test]
    fn test_gitignored_env() {
        let dir = create_temp_dir();
        Command::new("git")
            .arg("init")
            .current_dir(&dir)
            .status()
            .unwrap();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, ".env\n").unwrap();
        let env_path = dir.join(".env");
        fs::write(
            &env_path,
            format!("{}{}{}", "sk_", "live_", "9876543210abcdef1234"),
        )
        .unwrap();

        let report = scan_repo(&dir, false, Severity::Critical).unwrap();
        assert!(!report.findings.iter().any(|f| f.file == ".env"));
    }

    #[test]
    fn test_staged_secret() {
        let dir = create_temp_dir();
        Command::new("git")
            .arg("init")
            .current_dir(&dir)
            .status()
            .unwrap();
        let file_path = dir.join("file.txt");
        fs::write(&file_path, format!("{}{}\n", "AK", "IA9876543210ABCDEF")).unwrap();
        Command::new("git")
            .arg("add")
            .arg("file.txt")
            .current_dir(&dir)
            .status()
            .unwrap();

        let report = scan_repo(&dir, true, Severity::Critical).unwrap();
        assert_eq!(report.findings.len(), 1);
        assert_eq!(report.findings[0].severity, Severity::High);
    }

    #[test]
    fn test_scan_portfolio() {
        let root_dir = create_temp_dir();
        let repo1 = root_dir.join("repo1");
        let repo2 = root_dir.join("repo2");
        fs::create_dir_all(&repo1).unwrap();
        fs::create_dir_all(&repo2).unwrap();
        Command::new("git")
            .arg("init")
            .current_dir(&repo1)
            .status()
            .unwrap();
        Command::new("git")
            .arg("init")
            .current_dir(&repo2)
            .status()
            .unwrap();

        let report = scan_portfolio(&root_dir, 2, Severity::Critical).unwrap();
        assert_eq!(report.repos_scanned, 2);
    }
}
