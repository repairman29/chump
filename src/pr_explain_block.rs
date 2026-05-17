//! INFRA-1416: `chump pr explain-block <PR>`
//!
//! EFFECTIVE pillar — replaces 6× manual `gh pr view --json statusCheckRollup`
//! digging during cascade-fix sessions. Returns ONE coherent explanation per PR:
//!
//!   - For each failing check: name + failure class + locality (local vs fleet-wide)
//!   - Names the next mechanical action: "rebase", "wait for INFRA-NNN sibling-fix",
//!     "fix locally: <hint>"
//!   - If failure is fleet-wide (≥3 PRs failing same check): "fleet-wide block,
//!     file P0 fix or wait"
//!
//! Testability:
//!   - `CHUMP_GH` env var overrides the `gh` binary path (mock-injection).
//!   - `CHUMP_PR_EXPLAIN_FIXTURE` env var: if set to a path, reads
//!     `pr_view.json` / `pr_list.json` / `sibling_claims.json` from that dir
//!     instead of shelling out — used by `scripts/ci/test-pr-explain-block.sh`.

use std::path::Path;
use std::process::Command;

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

fn run_gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args(args)
        .output()
        .map_err(|e| format!("gh not found: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "gh {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Read a file from CHUMP_PR_EXPLAIN_FIXTURE dir (if set), else return None.
fn fixture(name: &str) -> Option<String> {
    let dir = std::env::var("CHUMP_PR_EXPLAIN_FIXTURE").ok()?;
    let p = Path::new(&dir).join(name);
    std::fs::read_to_string(p).ok()
}

#[derive(Debug, Clone)]
pub struct ExplainOptions {
    pub pr_arg: String, // "1234" or "https://github.com/.../pull/1234"
    pub json: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Locality {
    Local,
    FleetWide {
        sibling_prs: Vec<u64>,
    },
}

#[derive(Debug, Clone)]
pub struct CheckExplanation {
    pub name: String,
    pub conclusion: String, // "FAILURE", "TIMED_OUT", "CANCELLED", etc
    pub failure_class: String,
    pub locality: Locality,
    pub mechanical_action: String,
}

#[derive(Debug, Clone)]
pub struct Explanation {
    pub pr_number: u64,
    pub title: String,
    pub branch: String,
    pub failing_checks: Vec<CheckExplanation>,
    pub pending_checks: Vec<String>,
    pub overall_action: String,
}

/// Parse PR number from either "1234" or a GH URL.
fn parse_pr_arg(s: &str) -> Result<u64, String> {
    let trimmed = s.trim_start_matches('#').trim();
    if let Ok(n) = trimmed.parse::<u64>() {
        return Ok(n);
    }
    if let Some(idx) = trimmed.rfind("/pull/") {
        let tail = &trimmed[idx + "/pull/".len()..];
        let num = tail.split(|c: char| !c.is_ascii_digit()).next().unwrap_or("");
        return num
            .parse::<u64>()
            .map_err(|_| format!("could not parse PR number from URL: {s}"));
    }
    Err(format!("could not parse PR ID: {s} (expected number or URL)"))
}

/// Classify a failing check by name into a coarse class. Heuristic.
fn classify_failure(name: &str) -> &'static str {
    let n = name.to_lowercase();
    if n.contains("fmt") {
        "cargo_fmt_drift"
    } else if n.contains("clippy") || n.contains("lint") {
        "clippy_lint"
    } else if n.contains("audit") {
        "audit_check"
    } else if n.contains("acp") {
        "acp_smoke"
    } else if n.contains("tauri") || n.contains("playwright") || n.contains("e2e") {
        "browser_e2e"
    } else if n.contains("test") {
        "unit_or_integration_test"
    } else if n.contains("build") || n.contains("compile") {
        "build"
    } else {
        "other"
    }
}

/// Suggest a mechanical action given the failure class + locality.
fn mechanical_action(class: &str, locality: &Locality, sibling_gap: Option<&str>) -> String {
    match (class, locality) {
        ("cargo_fmt_drift", _) => {
            "fix locally: cargo fmt && git commit --amend --no-edit && git push --force-with-lease".to_string()
        }
        ("clippy_lint", _) => {
            "fix locally: cargo clippy --all-targets -- -D warnings (see job log for file:line)".to_string()
        }
        (_, Locality::FleetWide { sibling_prs }) if sibling_prs.len() >= 2 => {
            format!(
                "fleet-wide block ({} PRs failing same check) — file a P0 fix or wait for sibling rescue",
                sibling_prs.len() + 1
            )
        }
        (_, _) if sibling_gap.is_some() => {
            format!(
                "wait for {} sibling-fix (in flight) — rebase against main after it merges",
                sibling_gap.unwrap()
            )
        }
        ("browser_e2e", _) | ("acp_smoke", _) => {
            "likely flake — gh run rerun --failed --repo <repo> <run-id>".to_string()
        }
        ("audit_check", _) => {
            "rebase against main (INFRA-1600 audit-ci.yml fix may already be merged)".to_string()
        }
        (_, _) => "inspect job log: gh run view --job <id> --log-failed".to_string(),
    }
}

/// Load sibling claim gap IDs from .chump-locks/*.json. Returns a Vec of gap-ids.
fn load_sibling_claims() -> Vec<String> {
    let mut out = vec![];
    let lock_dir = Path::new(".chump-locks");
    let Ok(rd) = std::fs::read_dir(lock_dir) else {
        return out;
    };
    for ent in rd.flatten() {
        let p = ent.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        // Hand-rolled extraction: look for "gap_id":"INFRA-N" or "gap":"INFRA-N"
        for key in ["\"gap_id\":\"", "\"gap\":\""] {
            if let Some(idx) = text.find(key) {
                let rest = &text[idx + key.len()..];
                if let Some(end) = rest.find('"') {
                    let g = rest[..end].to_string();
                    if !g.is_empty() && !out.contains(&g) {
                        out.push(g);
                    }
                }
            }
        }
    }
    out
}

/// Extract failing-check names per other open PR (number + check-name list).
fn count_fleet_wide_failures(check_name: &str, exclude_pr: u64) -> Result<Vec<u64>, String> {
    let raw = if let Some(fx) = fixture("pr_list.json") {
        fx
    } else {
        run_gh(&[
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "number,statusCheckRollup",
            "--limit",
            "50",
        ])?
    };
    let mut siblings = vec![];
    // Hand-rolled JSON walk: split by "number":N → look ahead for check_name + FAILURE
    for prblock in raw.split("\"number\":") {
        let Some(num_end) = prblock.find(|c: char| !c.is_ascii_digit()) else {
            continue;
        };
        let num_str = &prblock[..num_end];
        let Ok(num) = num_str.parse::<u64>() else {
            continue;
        };
        if num == exclude_pr {
            continue;
        }
        // Find the check_name in this PR's block + verify FAILURE conclusion is near
        let needle = format!("\"name\":\"{check_name}\"");
        let alt_needle = format!("\"context\":\"{check_name}\"");
        if let Some(idx) = prblock.find(&needle).or_else(|| prblock.find(&alt_needle)) {
            let window = &prblock[idx..(idx + 400).min(prblock.len())];
            if window.contains("\"conclusion\":\"FAILURE\"") {
                siblings.push(num);
            }
        }
    }
    Ok(siblings)
}

pub fn run_explain(opts: &ExplainOptions) -> Result<Explanation, String> {
    let pr_num = parse_pr_arg(&opts.pr_arg)?;

    let pr_view = if let Some(fx) = fixture("pr_view.json") {
        fx
    } else {
        run_gh(&[
            "pr",
            "view",
            &pr_num.to_string(),
            "--json",
            "number,title,headRefName,statusCheckRollup",
        ])?
    };

    // Title
    let title = extract_string(&pr_view, "title").unwrap_or_default();
    let branch = extract_string(&pr_view, "headRefName").unwrap_or_default();

    // Walk statusCheckRollup — find each entry's name + conclusion + status
    let rollup_start = pr_view
        .find("\"statusCheckRollup\":")
        .ok_or("statusCheckRollup missing")?;
    let rollup = &pr_view[rollup_start..];

    let mut failing = vec![];
    let mut pending = vec![];

    // Each check is delimited by { ... } inside the rollup array; split heuristically.
    for chunk in rollup.split('{').skip(1) {
        let name = extract_string(chunk, "name")
            .or_else(|| extract_string(chunk, "context"))
            .unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        let conc = extract_string(chunk, "conclusion")
            .unwrap_or_default()
            .to_uppercase();
        let stat = extract_string(chunk, "status").unwrap_or_default().to_uppercase();
        if conc == "FAILURE" || conc == "TIMED_OUT" || conc == "CANCELLED" {
            failing.push((name, conc));
        } else if matches!(stat.as_str(), "IN_PROGRESS" | "QUEUED" | "PENDING") {
            pending.push(name);
        }
    }

    // Load sibling claims once
    let sib_claims = load_sibling_claims();

    let mut failing_checks = vec![];
    for (name, conclusion) in failing {
        let class = classify_failure(&name).to_string();
        let fleet_siblings = count_fleet_wide_failures(&name, pr_num).unwrap_or_default();
        let locality = if fleet_siblings.is_empty() {
            Locality::Local
        } else {
            Locality::FleetWide {
                sibling_prs: fleet_siblings.clone(),
            }
        };
        // Look for a sibling gap that matches this failure class (heuristic — first claim).
        let sibling_gap = sib_claims
            .first()
            .filter(|_| class != "cargo_fmt_drift" && class != "clippy_lint")
            .map(|s| s.as_str());

        let action = mechanical_action(&class, &locality, sibling_gap);
        failing_checks.push(CheckExplanation {
            name,
            conclusion,
            failure_class: class,
            locality,
            mechanical_action: action,
        });
    }

    // Overall action: dominant theme
    let overall_action = if failing_checks.is_empty() {
        if pending.is_empty() {
            "READY: no failures, no pending — ship via bot-merge.sh --gap <id> --auto-merge"
                .to_string()
        } else {
            format!(
                "WAITING: {} checks still running — re-run explain-block in 2-4 min",
                pending.len()
            )
        }
    } else if failing_checks
        .iter()
        .any(|c| matches!(c.locality, Locality::FleetWide { .. }))
    {
        "FLEET-WIDE: at least one failure also blocking other PRs — file P0 fix or wait for sibling rescue"
            .to_string()
    } else if failing_checks.len() == 1 {
        format!("LOCAL: {}", failing_checks[0].mechanical_action)
    } else {
        format!(
            "LOCAL: {} failures — see per-check actions below",
            failing_checks.len()
        )
    };

    Ok(Explanation {
        pr_number: pr_num,
        title,
        branch,
        failing_checks,
        pending_checks: pending,
        overall_action,
    })
}

/// Extract `"key":"value"` from a JSON-ish string.
fn extract_string(s: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\":\"");
    let idx = s.find(&needle)?;
    let rest = &s[idx + needle.len()..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

pub fn render_text(e: &Explanation) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "PR #{}  {}\n  branch: {}\n",
        e.pr_number, e.title, e.branch
    ));
    out.push_str(&format!("\n  OVERALL: {}\n", e.overall_action));
    if !e.failing_checks.is_empty() {
        out.push_str("\n  FAILING CHECKS:\n");
        for c in &e.failing_checks {
            let loc = match &c.locality {
                Locality::Local => "local-only".to_string(),
                Locality::FleetWide { sibling_prs } => {
                    format!("fleet-wide ({} sibling PRs)", sibling_prs.len())
                }
            };
            out.push_str(&format!(
                "    [{}] {} ({}) — {}\n      → {}\n",
                c.failure_class, c.name, c.conclusion, loc, c.mechanical_action
            ));
        }
    }
    if !e.pending_checks.is_empty() {
        out.push_str(&format!("\n  PENDING: {} checks\n", e.pending_checks.len()));
    }
    out
}

pub fn render_json(e: &Explanation) -> String {
    let escape = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut checks_json = String::new();
    for (i, c) in e.failing_checks.iter().enumerate() {
        if i > 0 {
            checks_json.push(',');
        }
        let loc_json = match &c.locality {
            Locality::Local => "{\"kind\":\"local\"}".to_string(),
            Locality::FleetWide { sibling_prs } => {
                let prs: Vec<String> = sibling_prs.iter().map(|p| p.to_string()).collect();
                format!(
                    "{{\"kind\":\"fleet_wide\",\"sibling_prs\":[{}]}}",
                    prs.join(",")
                )
            }
        };
        checks_json.push_str(&format!(
            "{{\"name\":\"{}\",\"conclusion\":\"{}\",\"failure_class\":\"{}\",\"locality\":{},\"mechanical_action\":\"{}\"}}",
            escape(&c.name),
            escape(&c.conclusion),
            escape(&c.failure_class),
            loc_json,
            escape(&c.mechanical_action)
        ));
    }
    let pending_json: Vec<String> = e
        .pending_checks
        .iter()
        .map(|p| format!("\"{}\"", escape(p)))
        .collect();
    format!(
        "{{\"pr_number\":{},\"title\":\"{}\",\"branch\":\"{}\",\"overall_action\":\"{}\",\"failing_checks\":[{}],\"pending_checks\":[{}]}}\n",
        e.pr_number,
        escape(&e.title),
        escape(&e.branch),
        escape(&e.overall_action),
        checks_json,
        pending_json.join(",")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pr_arg_handles_plain_number() {
        assert_eq!(parse_pr_arg("1234").unwrap(), 1234);
        assert_eq!(parse_pr_arg("#1234").unwrap(), 1234);
    }

    #[test]
    fn parse_pr_arg_handles_url() {
        assert_eq!(
            parse_pr_arg("https://github.com/foo/bar/pull/1234").unwrap(),
            1234
        );
        assert_eq!(
            parse_pr_arg("https://github.com/foo/bar/pull/1234/files").unwrap(),
            1234
        );
    }

    #[test]
    fn parse_pr_arg_rejects_garbage() {
        assert!(parse_pr_arg("not-a-pr").is_err());
    }

    #[test]
    fn classify_failure_recognizes_common_classes() {
        assert_eq!(classify_failure("rustfmt"), "cargo_fmt_drift");
        assert_eq!(classify_failure("cargo clippy"), "clippy_lint");
        assert_eq!(classify_failure("audit-required"), "audit_check");
        assert_eq!(
            classify_failure("ACP protocol smoke test (Zed / JetBrains compatible)"),
            "acp_smoke"
        );
        assert_eq!(classify_failure("tauri-cowork-e2e"), "browser_e2e");
        assert_eq!(classify_failure("unknown-blob"), "other");
    }

    #[test]
    fn mechanical_action_branches_on_locality() {
        let fleet = Locality::FleetWide {
            sibling_prs: vec![1, 2, 3],
        };
        let action = mechanical_action("audit_check", &fleet, None);
        assert!(action.contains("fleet-wide"));

        let local = Locality::Local;
        let action = mechanical_action("cargo_fmt_drift", &local, None);
        assert!(action.contains("cargo fmt"));
    }

    #[test]
    fn extract_string_pulls_first_match() {
        let s = r#"{"name":"foo","name":"bar"}"#;
        assert_eq!(extract_string(s, "name"), Some("foo".to_string()));
    }
}
