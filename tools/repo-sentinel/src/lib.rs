pub mod gitignore_audit;
pub mod patterns;
pub mod report;
pub mod scanner;

pub use crate::gitignore_audit::{harden_repo, HardenResult};
pub use crate::patterns::{classify_leak_filename, scan_line_for_secrets, Severity};
pub use crate::report::{
    render_harden_json, render_harden_summary, render_portfolio_json, render_portfolio_markdown,
    render_portfolio_summary, render_scan_json, render_scan_markdown, render_scan_summary,
};
pub use crate::scanner::{
    scan_portfolio, scan_repo, Finding, PortfolioRepoSummary, PortfolioReport, RepoScanReport,
    SeverityCounts,
};
