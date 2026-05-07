//! INFRA-595: PR Coupling-Tax Measurement
//!
//! `chump pr-coupling-cost <PR#> [--diff-files FILE,FILE,...]`
//!
//! Reads `.github/workflows/ci.yml`, extracts the dorny/paths-filter rules,
//! and for each file in the PR diff prints which CI jobs it triggers.
//!
//! ## Output
//!
//! ```
//! PR #42 — changed files: 3
//! ┌──────────────────────────────┬──────────────────────────────────────────────┐
//! │ File                         │ Jobs triggered                               │
//! ├──────────────────────────────┼──────────────────────────────────────────────┤
//! │ src/main.rs                  │ test, fast-checks, clippy, cargo-test, e2e-* │
//! │ docs/README.md               │ test, fast-checks, clippy, cargo-test        │
//! │ .github/workflows/ci.yml     │ test, fast-checks, clippy, cargo-test, e2e-* │
//! └──────────────────────────────┴──────────────────────────────────────────────┘
//! Summary: code=2 e2e=2 tauri=1  (distinct filters hit)
//! ```

use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;

// ── Public types ─────────────────────────────────────────────────────────────

/// One row in the coupling-cost table.
#[derive(Debug, Clone)]
pub struct CouplingRow {
    pub file: String,
    pub filters_hit: Vec<String>,
    pub jobs: Vec<String>,
}

/// Full report for one PR (or a synthetic diff list).
#[derive(Debug, Clone, Default)]
pub struct CouplingReport {
    pub pr_number: Option<u64>,
    pub rows: Vec<CouplingRow>,
    /// filter_name → count of files that hit it
    pub filter_hit_counts: BTreeMap<String, usize>,
}

// ── Glob matching ─────────────────────────────────────────────────────────────

/// Minimal glob match supporting `**` and `*`.
/// Patterns are dorny/paths-filter style: `src/**`, `Cargo.toml`, `*.md`.
pub fn glob_match(pattern: &str, path: &str) -> bool {
    glob_match_segments(
        &pattern.split('/').collect::<Vec<_>>(),
        &path.split('/').collect::<Vec<_>>(),
    )
}

fn glob_match_segments(pats: &[&str], segs: &[&str]) -> bool {
    match (pats.first(), segs.first()) {
        (None, None) => true,
        (None, _) | (_, None) => {
            // pattern exhausted but path not, or vice-versa
            pats.iter().all(|p| *p == "**")
        }
        (Some(&"**"), _) => {
            // `**` can match zero or more path segments
            for skip in 0..=segs.len() {
                if glob_match_segments(&pats[1..], &segs[skip..]) {
                    return true;
                }
            }
            false
        }
        (Some(pat), Some(seg)) => {
            if single_segment_match(pat, seg) {
                glob_match_segments(&pats[1..], &segs[1..])
            } else {
                false
            }
        }
    }
}

fn single_segment_match(pattern: &str, segment: &str) -> bool {
    // Simple `*` wildcard within one path component
    let pat: Vec<char> = pattern.chars().collect();
    let seg: Vec<char> = segment.chars().collect();
    seg_match(&pat, &seg)
}

fn seg_match(pat: &[char], seg: &[char]) -> bool {
    match (pat.first(), seg.first()) {
        (None, None) => true,
        (Some(&'*'), _) => {
            // `*` matches zero or more chars in the segment
            for skip in 0..=seg.len() {
                if seg_match(&pat[1..], &seg[skip..]) {
                    return true;
                }
            }
            false
        }
        (None, _) | (_, None) => false,
        (Some(p), Some(s)) => p == s && seg_match(&pat[1..], &seg[1..]),
    }
}

// ── CI YAML parsing ───────────────────────────────────────────────────────────

/// Filter definition extracted from dorny/paths-filter.
#[derive(Debug, Clone, Default)]
pub struct PathFilter {
    pub name: String,
    pub patterns: Vec<String>,
}

/// Parse `.github/workflows/ci.yml` and return the list of path filters
/// defined in the `changes` job's dorny/paths-filter step.
pub fn parse_path_filters(ci_yml: &str) -> Vec<PathFilter> {
    // Walk the YAML to find: jobs.changes.steps[].with.filters
    let doc: serde_yaml::Value = match serde_yaml::from_str(ci_yml) {
        Ok(v) => v,
        Err(_) => return vec![],
    };

    let filters_str = doc
        .get("jobs")
        .and_then(|j| j.get("changes"))
        .and_then(|c| c.get("steps"))
        .and_then(|s| s.as_sequence())
        .and_then(|steps| {
            steps.iter().find(|step| {
                step.get("id")
                    .and_then(|v| v.as_str())
                    .map(|id| id == "filter")
                    .unwrap_or(false)
            })
        })
        .and_then(|step| step.get("with"))
        .and_then(|with| with.get("filters"))
        .and_then(|f| f.as_str())
        .unwrap_or("")
        .to_string();

    if filters_str.is_empty() {
        return vec![];
    }

    // The `filters` value is itself a YAML block
    let filters_doc: serde_yaml::Value = match serde_yaml::from_str(&filters_str) {
        Ok(v) => v,
        Err(_) => return vec![],
    };

    let mapping = match filters_doc.as_mapping() {
        Some(m) => m,
        None => return vec![],
    };

    let mut result = Vec::new();
    for (k, v) in mapping {
        let name = match k.as_str() {
            Some(n) => n.to_string(),
            None => continue,
        };
        let patterns: Vec<String> = match v.as_sequence() {
            Some(seq) => seq
                .iter()
                .filter_map(|item| item.as_str().map(|s| s.trim_matches('\'').to_string()))
                .collect(),
            None => continue,
        };
        result.push(PathFilter { name, patterns });
    }
    result
}

/// Parse job names from ci.yml and map filter_name → jobs gated by that filter.
/// A job is gated by a filter when its `if:` condition references
/// `needs.changes.outputs.<filter> == 'true'`.
pub fn parse_filter_to_jobs(ci_yml: &str) -> BTreeMap<String, Vec<String>> {
    let doc: serde_yaml::Value = match serde_yaml::from_str(ci_yml) {
        Ok(v) => v,
        Err(_) => return BTreeMap::new(),
    };

    let jobs = match doc.get("jobs").and_then(|j| j.as_mapping()) {
        Some(m) => m,
        None => return BTreeMap::new(),
    };

    let mut filter_jobs: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for (job_key, job_val) in jobs {
        let job_name = match job_key.as_str() {
            Some(n) => n,
            None => continue,
        };
        // Skip the changes job itself
        if job_name == "changes" {
            continue;
        }
        let if_cond = match job_val.get("if").and_then(|v| v.as_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        // Extract filter names referenced in this condition
        for filter_name in extract_filter_refs(&if_cond) {
            filter_jobs
                .entry(filter_name)
                .or_default()
                .push(job_name.to_string());
        }
    }
    filter_jobs
}

/// Extract `<filter>` from strings like `needs.changes.outputs.<filter> == 'true'`.
fn extract_filter_refs(cond: &str) -> Vec<String> {
    let prefix = "needs.changes.outputs.";
    let mut refs = Vec::new();
    let mut rest = cond;
    while let Some(pos) = rest.find(prefix) {
        rest = &rest[pos + prefix.len()..];
        // Read until whitespace or `'` or `=`
        let end = rest
            .find(|c: char| c.is_whitespace() || c == '\'' || c == '=')
            .unwrap_or(rest.len());
        refs.push(rest[..end].to_string());
    }
    refs
}

// ── PR diff fetching ──────────────────────────────────────────────────────────

/// Fetch changed file paths for a PR via `gh pr diff --name-only`.
/// Returns an empty vec on error (error printed to stderr).
pub fn fetch_pr_files(pr_number: u64) -> Vec<String> {
    let out = Command::new("gh")
        .args(["pr", "diff", &pr_number.to_string(), "--name-only"])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
        Ok(o) => {
            eprintln!(
                "chump pr-coupling-cost: gh pr diff failed: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            vec![]
        }
        Err(e) => {
            eprintln!("chump pr-coupling-cost: gh not found: {e}");
            vec![]
        }
    }
}

// ── Report builder ────────────────────────────────────────────────────────────

/// Build the coupling-cost report.
///
/// `diff_files`: list of file paths changed in the PR.
/// `ci_yml`:     contents of `.github/workflows/ci.yml`.
pub fn build_report(pr_number: Option<u64>, diff_files: &[String], ci_yml: &str) -> CouplingReport {
    let filters = parse_path_filters(ci_yml);
    let filter_to_jobs = parse_filter_to_jobs(ci_yml);

    let mut filter_hit_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut rows = Vec::new();

    for file in diff_files {
        let mut filters_hit: BTreeSet<String> = BTreeSet::new();
        for f in &filters {
            if f.patterns.iter().any(|pat| glob_match(pat, file)) {
                filters_hit.insert(f.name.clone());
            }
        }

        // Collect jobs from all matched filters, deduplicated + sorted
        let mut job_set: BTreeSet<String> = BTreeSet::new();
        for fname in &filters_hit {
            if let Some(jobs) = filter_to_jobs.get(fname) {
                for j in jobs {
                    job_set.insert(j.clone());
                }
            }
            *filter_hit_counts.entry(fname.clone()).or_insert(0) += 1;
        }

        rows.push(CouplingRow {
            file: file.clone(),
            filters_hit: filters_hit.into_iter().collect(),
            jobs: job_set.into_iter().collect(),
        });
    }

    CouplingReport {
        pr_number,
        rows,
        filter_hit_counts,
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

impl CouplingReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();

        let header = match self.pr_number {
            Some(n) => format!("PR #{} — changed files: {}\n", n, self.rows.len()),
            None => format!("changed files: {}\n", self.rows.len()),
        };
        out.push_str(&header);
        out.push('\n');

        if self.rows.is_empty() {
            out.push_str("(no changed files)\n");
            return out;
        }

        // Column widths
        let file_w = self
            .rows
            .iter()
            .map(|r| r.file.len())
            .max()
            .unwrap_or(4)
            .max(4);
        let jobs_w = self
            .rows
            .iter()
            .map(|r| r.jobs.join(", ").len())
            .max()
            .unwrap_or(14)
            .max(14);

        let divider = format!("+-{}-+-{}-+\n", "-".repeat(file_w), "-".repeat(jobs_w));
        let header_row = format!(
            "| {:<file_w$} | {:<jobs_w$} |\n",
            "File",
            "Jobs triggered",
            file_w = file_w,
            jobs_w = jobs_w
        );

        out.push_str(&divider);
        out.push_str(&header_row);
        out.push_str(&divider);

        for row in &self.rows {
            let jobs_str = if row.jobs.is_empty() {
                "(none — not matched by any filter)".to_string()
            } else {
                row.jobs.join(", ")
            };
            out.push_str(&format!(
                "| {:<file_w$} | {:<jobs_w$} |\n",
                row.file,
                jobs_str,
                file_w = file_w,
                jobs_w = jobs_w
            ));
        }
        out.push_str(&divider);

        // Summary line
        if !self.filter_hit_counts.is_empty() {
            out.push('\n');
            out.push_str("Summary: ");
            let parts: Vec<String> = self
                .filter_hit_counts
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect();
            out.push_str(&parts.join("  "));
            out.push_str("  (distinct filters hit per file)\n");
        }

        out
    }

    pub fn render_json(&self) -> String {
        let rows: Vec<serde_json::Value> = self
            .rows
            .iter()
            .map(|r| {
                serde_json::json!({
                    "file": r.file,
                    "filters_hit": r.filters_hit,
                    "jobs_triggered": r.jobs,
                })
            })
            .collect();
        serde_json::json!({
            "pr": self.pr_number,
            "rows": rows,
            "filter_hit_counts": self.filter_hit_counts,
        })
        .to_string()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_src_double_star() {
        assert!(glob_match("src/**", "src/main.rs"));
        assert!(glob_match("src/**", "src/foo/bar/baz.rs"));
        assert!(!glob_match("src/**", "scripts/foo.sh"));
    }

    #[test]
    fn glob_exact_file() {
        assert!(glob_match("Cargo.toml", "Cargo.toml"));
        assert!(!glob_match("Cargo.toml", "Cargo.lock"));
    }

    #[test]
    fn glob_star_extension() {
        assert!(glob_match("*.toml", "Cargo.toml"));
        assert!(!glob_match("*.toml", "src/main.rs"));
    }

    #[test]
    fn glob_docs_double_star() {
        assert!(glob_match("docs/**", "docs/README.md"));
        assert!(glob_match("docs/**", "docs/process/CLAUDE_GOTCHAS.md"));
        assert!(!glob_match("docs/**", "src/main.rs"));
    }

    #[test]
    fn parse_filters_minimal_yaml() {
        let yaml = r#"
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - 'src/**'
              - 'Cargo.toml'
            docs:
              - 'docs/**'
"#;
        let filters = parse_path_filters(yaml);
        assert_eq!(filters.len(), 2);
        let code = filters.iter().find(|f| f.name == "code").unwrap();
        assert!(code.patterns.contains(&"src/**".to_string()));
        let docs = filters.iter().find(|f| f.name == "docs").unwrap();
        assert!(docs.patterns.contains(&"docs/**".to_string()));
    }

    #[test]
    fn build_report_code_only() {
        let yaml = minimal_ci_yaml();
        let files = vec!["src/main.rs".to_string()];
        let report = build_report(Some(42), &files, &yaml);
        assert_eq!(report.rows.len(), 1);
        assert!(report.rows[0].filters_hit.contains(&"code".to_string()));
        assert!(!report.rows[0].jobs.is_empty());
    }

    #[test]
    fn build_report_docs_only_no_e2e() {
        let yaml = minimal_ci_yaml();
        let files = vec!["docs/README.md".to_string()];
        let report = build_report(None, &files, &yaml);
        assert_eq!(report.rows.len(), 1);
        // docs/** is in code filter, not in e2e
        let jobs = &report.rows[0].jobs;
        let e2e_jobs: Vec<_> = jobs.iter().filter(|j| j.starts_with("e2e")).collect();
        assert!(e2e_jobs.is_empty(), "docs-only should not trigger e2e jobs");
    }

    #[test]
    fn build_report_workflow_triggers_all() {
        let yaml = minimal_ci_yaml();
        let files = vec![".github/workflows/ci.yml".to_string()];
        let report = build_report(None, &files, &yaml);
        assert_eq!(report.rows.len(), 1);
        // .github/workflows/** matches code; ci.yml also matches e2e and tauri
        let filters = &report.rows[0].filters_hit;
        assert!(filters.contains(&"code".to_string()));
        assert!(filters.contains(&"e2e".to_string()));
        assert!(filters.contains(&"tauri".to_string()));
    }

    fn minimal_ci_yaml() -> String {
        r#"
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.filter.outputs.code }}
      e2e: ${{ steps.filter.outputs.e2e }}
      tauri: ${{ steps.filter.outputs.tauri }}
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            code:
              - 'src/**'
              - 'docs/**'
              - '.github/workflows/**'
            e2e:
              - 'src/**'
              - '.github/workflows/ci.yml'
            tauri:
              - 'src/**'
              - 'desktop/**'
              - '.github/workflows/ci.yml'
  test:
    needs: changes
    if: needs.changes.outputs.code == 'true' || github.event_name == 'push'
    runs-on: ubuntu-latest
    steps: []
  e2e-pwa:
    needs: changes
    if: needs.changes.outputs.e2e == 'true' || github.event_name == 'push'
    runs-on: ubuntu-latest
    steps: []
  tauri-cowork-e2e:
    needs: changes
    if: needs.changes.outputs.tauri == 'true' || github.event_name == 'push'
    runs-on: ubuntu-latest
    steps: []
"#
        .to_string()
    }
}
