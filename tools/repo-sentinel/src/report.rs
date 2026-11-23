use crate::gitignore_audit::HardenResult;
use crate::patterns::Severity;
use crate::scanner::{PortfolioReport, RepoScanReport, SeverityCounts};
impl SeverityCounts {
    pub fn total(&self) -> usize {
        self.critical + self.high + self.medium + self.low
    }
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::High => write!(f, "High"),
            Severity::Medium => write!(f, "Medium"),
            Severity::Low => write!(f, "Low"),
            Severity::Critical => write!(f, "Critical"),
        }
    }
}

pub fn render_scan_json(report: &RepoScanReport) -> String {
    serde_json::to_string_pretty(report).unwrap_or_default()
}

pub fn render_portfolio_json(report: &PortfolioReport) -> String {
    serde_json::to_string_pretty(report).unwrap_or_default()
}

pub fn render_harden_json(result: &HardenResult) -> String {
    serde_json::to_string_pretty(result).unwrap_or_default()
}

pub fn render_scan_markdown(report: &RepoScanReport) -> String {
    let mut markdown = String::new();
    markdown.push_str(&format!("# Scan Report for {}", report.repo_name));
    markdown.push_str("\n\n## Findings\n");
    for finding in &report.findings {
        markdown.push_str(&format!(
            "- **{}** at {}:{} - {}\n",
            finding.severity,
            finding.file,
            finding.line.unwrap_or(0),
            finding.summary
        ));
    }
    markdown.push_str("\n## Summary\n");
    markdown.push_str(&format!("Files scanned: {}\n", report.files_scanned));
    markdown.push_str(&format!("Total findings: {}\n", report.counts.total()));
    markdown
}

pub fn render_portfolio_markdown(report: &PortfolioReport) -> String {
    let mut markdown = String::new();
    markdown.push_str("# Portfolio Report\n\n## Repositories\n");
    for repo in &report.repos {
        markdown.push_str(&format!("- **{}** - {}\n", repo.repo_name, repo.repo_path));
    }
    markdown.push_str("\n## Summary\n");
    markdown.push_str(&format!("Total repositories: {}\n", report.repos.len()));
    markdown.push_str(&format!("Total findings: {}\n", report.totals.total()));
    markdown
}

pub fn render_scan_summary(report: &RepoScanReport) -> String {
    format!(
        "Scanned {} files in {}. Found {} findings.",
        report.files_scanned,
        report.repo_name,
        report.counts.total()
    )
}

pub fn render_portfolio_summary(report: &PortfolioReport) -> String {
    format!(
        "Scanned {} repositories ({}). Found {} findings.",
        report.repos.len(),
        report
            .repos
            .iter()
            .map(|r| r.repo_name.as_str())
            .collect::<Vec<_>>()
            .join(", "),
        report.totals.total()
    )
}

pub fn render_harden_summary(result: &HardenResult) -> String {
    format!(
        "Harden result for {}: Applied: {}, Hook installed: {}, Missing patterns: {}",
        result.repo_path,
        result.applied,
        result.hook_installed,
        result.missing_patterns.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::patterns::Severity;
    use crate::scanner::{Finding, PortfolioRepoSummary, SeverityCounts};

    #[test]
    fn test_render_scan_json() {
        let report = RepoScanReport {
            repo_name: String::from("test_repo"),
            repo_path: String::from("/path/to/test_repo"),
            is_git_repo: true,
            staged_only: false,
            files_scanned: 10,
            counts: SeverityCounts::default(),
            findings: vec![Finding {
                severity: Severity::High,
                category: String::from("test_category"),
                rule_id: String::from("test_rule"),
                file: String::from("test_file.rs"),
                line: Some(10),
                summary: String::from("test_summary"),
                redacted_match: Some(String::from("sk_liv****...7890")),
                remediation: String::from("test_remediation"),
            }],
            passed_gate: true,
        };
        let json = render_scan_json(&report);
        assert!(json.contains("test_repo"));
    }

    #[test]
    fn test_render_portfolio_json() {
        let report = PortfolioReport {
            root_dir: String::from("/path/to/root"),
            repos_scanned: 1,
            clean_repos: 0,
            at_risk_repos: 1,
            totals: SeverityCounts::default(),
            repos: vec![PortfolioRepoSummary {
                repo_name: String::from("test_repo"),
                repo_path: String::from("/path/to/test_repo"),
                counts: SeverityCounts::default(),
                passed_gate: true,
            }],
        };
        let json = render_portfolio_json(&report);
        assert!(json.contains("test_repo"));
    }

    #[test]
    fn test_render_harden_json() {
        let result = HardenResult {
            repo_path: String::from("/path/to/test_repo"),
            missing_patterns: vec![String::from("*.bak")],
            applied: true,
            hook_installed: false,
        };
        let json = render_harden_json(&result);
        assert!(json.contains("*.bak"));
    }

    #[test]
    fn test_render_scan_markdown() {
        let report = RepoScanReport {
            repo_name: String::from("test_repo"),
            repo_path: String::from("/path/to/test_repo"),
            is_git_repo: true,
            staged_only: false,
            files_scanned: 10,
            counts: SeverityCounts::default(),
            findings: vec![Finding {
                severity: Severity::High,
                category: String::from("test_category"),
                rule_id: String::from("test_rule"),
                file: String::from("test_file.rs"),
                line: Some(10),
                summary: String::from("test_summary"),
                redacted_match: Some(String::from("sk_liv****...7890")),
                remediation: String::from("test_remediation"),
            }],
            passed_gate: true,
        };
        let markdown = render_scan_markdown(&report);
        assert!(markdown.contains("test_repo"));
    }

    #[test]
    fn test_render_portfolio_markdown() {
        let report = PortfolioReport {
            root_dir: String::from("/path/to/root"),
            repos_scanned: 1,
            clean_repos: 0,
            at_risk_repos: 1,
            totals: SeverityCounts::default(),
            repos: vec![PortfolioRepoSummary {
                repo_name: String::from("test_repo"),
                repo_path: String::from("/path/to/test_repo"),
                counts: SeverityCounts::default(),
                passed_gate: true,
            }],
        };
        let markdown = render_portfolio_markdown(&report);
        assert!(markdown.contains("test_repo"));
    }

    #[test]
    fn test_render_scan_summary() {
        let report = RepoScanReport {
            repo_name: String::from("test_repo"),
            repo_path: String::from("/path/to/test_repo"),
            is_git_repo: true,
            staged_only: false,
            files_scanned: 10,
            counts: SeverityCounts::default(),
            findings: vec![Finding {
                severity: Severity::High,
                category: String::from("test_category"),
                rule_id: String::from("test_rule"),
                file: String::from("test_file.rs"),
                line: Some(10),
                summary: String::from("test_summary"),
                redacted_match: Some(String::from("sk_liv****...7890")),
                remediation: String::from("test_remediation"),
            }],
            passed_gate: true,
        };
        let summary = render_scan_summary(&report);
        assert!(summary.contains("test_repo"));
    }

    #[test]
    fn test_render_portfolio_summary() {
        let report = PortfolioReport {
            root_dir: String::from("/path/to/root"),
            repos_scanned: 1,
            clean_repos: 0,
            at_risk_repos: 1,
            totals: SeverityCounts::default(),
            repos: vec![PortfolioRepoSummary {
                repo_name: String::from("test_repo"),
                repo_path: String::from("/path/to/test_repo"),
                counts: SeverityCounts::default(),
                passed_gate: true,
            }],
        };
        let summary = render_portfolio_summary(&report);
        assert!(summary.contains("test_repo"));
    }

    #[test]
    fn test_render_harden_summary() {
        let result = HardenResult {
            repo_path: String::from("/path/to/test_repo"),
            missing_patterns: vec![String::from("*.bak")],
            applied: true,
            hook_installed: false,
        };
        let summary = render_harden_summary(&result);
        assert!(summary.contains("*.bak"));
    }
}
