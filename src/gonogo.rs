//! INFRA-3481/INFRA-5340: honest go/no-go gate on a user's vision
//! (evidence-before-build).
//!
//! `parse_verdict` is cloned from `pr_ac_coverage::parse_judge_verdicts`'s
//! keyword-anywhere-on-the-line parsing shape: robust to case and extra
//! prose from the LLM, format-agnostic ("GO -", "1. GO -", "VERDICT: GO -").
//!
//! `run_llm_gonogo` is cloned from `pr_ac_coverage::llm_judge_ac`'s shell-out
//! shape: pipe a prompt to `chump llm-complete --model <m> --max-tokens <n>`
//! via stdin, parse the structured reply. Model is `CHUMP_GONOGO_MODEL`
//! (default `opus` — this gate must be trustworthy).
//!
//! When the judge can't be reached at all (no network, no binary, unparseable
//! reply) the gate fails OPEN (defaults to `Go`) rather than blocking every
//! caller that doesn't have LLM access — see `scripts/ci/test-bootstrap-smoke.sh`
//! which exercises `chump bootstrap` with no network and must keep passing.
//! The NO-GO default-bias lives in the PROMPT (the judge itself is skeptical),
//! not in the fallback-when-unreachable path.

use std::io::Write;
use std::process::{Command, Stdio};

/// Verdict returned by the go/no-go judge for a single vision line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Go,
    NoGo,
    NeedsNarrowing,
    NoGoOnCost,
}

impl Verdict {
    /// True if this verdict should block the build path.
    pub fn blocks_build(self) -> bool {
        matches!(self, Verdict::NoGo | Verdict::NoGoOnCost)
    }

    /// Cost-axis gate: returns `NoGoOnCost` when the estimate exceeds the ceiling,
    /// otherwise returns the input verdict.
    pub fn cost_axis(self, estimate_usd: f64, ceiling_usd: f64) -> Verdict {
        if estimate_usd > ceiling_usd {
            Verdict::NoGoOnCost
        } else {
            self
        }
    }

    /// Canonical upper-case rendering, also accepted back by `parse_verdict`.
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Go => "GO",
            Verdict::NoGo => "NO-GO",
            Verdict::NeedsNarrowing => "NEEDS-NARROWING",
            Verdict::NoGoOnCost => "NO-GO-ON-COST",
        }
    }
}

/// Parse a single LLM-shaped go/no-go output line into a [`Verdict`].
/// `NO-GO` is checked before `GO` since "NO-GO" contains "GO" as a substring
/// (same ordering trick as `parse_judge_verdicts`'s `UNMET`-before-`MET`).
/// Returns `None` if the line contains none of the recognized keywords.
pub(crate) fn parse_verdict(line: &str) -> Option<Verdict> {
    let up = line.to_uppercase();
    if up.contains("NO-GO") || up.contains("NO GO") || up.contains("NOGO") {
        Some(Verdict::NoGo)
    } else if up.contains("NEEDS-NARROWING") || up.contains("NEEDS NARROWING") {
        Some(Verdict::NeedsNarrowing)
    } else if up.contains("GO") {
        Some(Verdict::Go)
    } else {
        None
    }
}

/// Test/operator seam: `CHUMP_GONOGO_FORCE_VERDICT=GO|NO-GO|NEEDS-NARROWING|NO-GO-ON-COST`
/// bypasses the real LLM call entirely. Used by `scripts/ci/test-gonogo.sh` to assert
/// exit codes deterministically (no network / no LLM credentials in CI).
pub(crate) fn force_verdict_from_env() -> Option<Verdict> {
    let raw = std::env::var("CHUMP_GONOGO_FORCE_VERDICT").ok()?;
    let up = raw.to_uppercase();
    match up.as_str() {
        "GO" => Some(Verdict::Go),
        "NO-GO" | "NOGO" => Some(Verdict::NoGo),
        "NEEDS-NARROWING" | "NEEDS NARROWING" => Some(Verdict::NeedsNarrowing),
        "NO-GO-ON-COST" | "NOGO-ON-COST" => Some(Verdict::NoGoOnCost),
        _ => None,
    }
}

/// Run the LLM go/no-go judge on a vision string via `chump llm-complete`
/// (same rail as `pr_ac_coverage::llm_judge_ac`). Returns `(verdict, reason)`,
/// or `None` if the CLI/model is unavailable or the reply is unparseable.
pub(crate) fn run_llm_gonogo(vision: &str) -> Option<(Verdict, String)> {
    let prompt = format!(
        "You are a skeptical venture go/no-go judge deciding whether to spend real \
         engineering effort building a user's product vision. Default bias: NO-GO unless \
         there is clear evidence of real demand and no dominant incumbent already serving \
         it. Prefer NEEDS-NARROWING over a hopeful GO when the vision is vague or overbroad. \
         Evidence before build.\n\n\
         Reply with EXACTLY one line and nothing else:\n\
         VERDICT: GO|NO-GO|NEEDS-NARROWING - <=30-word plain-language reason\n\n\
         === VISION ===\n{vision}\n"
    );
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let model = std::env::var("CHUMP_GONOGO_MODEL").unwrap_or_else(|_| "opus".to_string());
    let mut child = Command::new(&chump_bin)
        .args(["llm-complete", "--model", &model, "--max-tokens", "80"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut si) = child.stdin.take() {
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    let resp = String::from_utf8_lossy(&out.stdout);
    let line = resp.lines().find(|l| parse_verdict(l).is_some())?;
    let verdict = parse_verdict(line)?;
    let up = line.to_uppercase();
    let kw = if up.contains("NO-GO") || up.contains("NOGO") {
        "NO-GO"
    } else if up.contains("NEEDS-NARROWING") {
        "NEEDS-NARROWING"
    } else {
        "GO"
    };
    let kw_pos = up.find(kw).unwrap_or(0);
    let reason = line[(kw_pos + kw.len()).min(line.len())..]
        .trim_start_matches([' ', '-', ':', '—', '\t'])
        .trim()
        .to_string();
    Some((verdict, reason))
}

/// Resolve a verdict + reason for `vision`: the force-verdict test seam wins,
/// then the real LLM judge, then a fail-open `Go` with an explanatory reason
/// when the judge can't be reached at all.
pub(crate) fn resolve_verdict(vision: &str) -> (Verdict, String) {
    force_verdict_from_env()
        .map(|v| (v, "forced via CHUMP_GONOGO_FORCE_VERDICT".to_string()))
        .or_else(|| run_llm_gonogo(vision))
        .unwrap_or((
            Verdict::Go,
            "go/no-go judge unreachable (no LLM credentials/network) — failing open".to_string(),
        ))
}

/// AC4 gate consumed by `commands::bootstrap::run_bootstrap`. Returns
/// `Err(reason)` when the vision resolves to a build-blocking verdict,
/// `Ok(())` otherwise. Callers check `CHUMP_GONOGO_SKIP` themselves before
/// calling this (so the bypass short-circuits before any judge call).
pub fn gate(vision: &str) -> Result<(), String> {
    let (verdict, reason) = resolve_verdict(vision);
    if verdict.blocks_build() {
        Err(reason)
    } else {
        Ok(())
    }
}

/// Render the go/no-go result as a single-line JSON object.
pub(crate) fn render_json(
    verdict: Verdict,
    reason: &str,
    cost_estimate_usd: f64,
    tier_ceiling_usd: f64,
) -> String {
    let reason_escaped = reason.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        r#"{{"verdict":"{}","reason":"{}","cost_estimate_usd":{:.4},"tier_ceiling_usd":{:.4}}}"#,
        verdict.as_str(),
        reason_escaped,
        cost_estimate_usd,
        tier_ceiling_usd
    )
}

/// Render the go/no-go result as plain-language human output.
pub(crate) fn render_human(
    verdict: Verdict,
    reason: &str,
    cost_estimate_usd: f64,
    tier_ceiling_usd: f64,
) -> String {
    format!(
        "verdict: {}\nreason: {}\ncost_estimate_usd: {:.2}\ntier_ceiling_usd: {:.2}",
        verdict.as_str(),
        reason,
        cost_estimate_usd,
        tier_ceiling_usd
    )
}

fn print_usage() {
    println!("Usage: chump gonogo \"<vision>\" [--json] [--cost-estimate-usd <N>]");
    println!();
    println!("Honest go/no-go gate on a user's vision (evidence-before-build).");
    println!("Exits non-zero for NO-GO / NO-GO-ON-COST, 0 for GO / NEEDS-NARROWING.");
    println!();
    println!("Env:");
    println!("  CHUMP_GONOGO_FORCE_VERDICT   GO|NO-GO|NEEDS-NARROWING|NO-GO-ON-COST (test seam)");
    println!("  CHUMP_GONOGO_MODEL           LLM model for the judge (default: opus)");
}

/// `chump gonogo "<vision>" [--json] [--cost-estimate-usd <N>]` (AC3).
pub fn run(args: &[String]) -> i32 {
    let mut vision: Option<String> = None;
    let mut json_out = false;
    let mut cost_estimate_usd: f64 = std::env::var("CHUMP_GONOGO_COST_ESTIMATE_USD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1.0);

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => json_out = true,
            "--help" | "-h" => {
                print_usage();
                return 0;
            }
            "--cost-estimate-usd" => {
                i += 1;
                if let Some(v) = args.get(i).and_then(|s| s.parse::<f64>().ok()) {
                    cost_estimate_usd = v;
                }
            }
            other if vision.is_none() => vision = Some(other.to_string()),
            _ => {}
        }
        i += 1;
    }

    let vision = match vision {
        Some(v) => v,
        None => {
            eprintln!("chump gonogo: missing <vision> argument");
            print_usage();
            return 2;
        }
    };

    let tier_ceiling_usd = crate::budget_tracker::tier_default_cost_usd("m");
    let (verdict, reason) = resolve_verdict(&vision);
    let verdict = verdict.cost_axis(cost_estimate_usd, tier_ceiling_usd);

    if json_out {
        println!(
            "{}",
            render_json(verdict, &reason, cost_estimate_usd, tier_ceiling_usd)
        );
    } else {
        println!(
            "{}",
            render_human(verdict, &reason, cost_estimate_usd, tier_ceiling_usd)
        );
    }

    if verdict.blocks_build() {
        1
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_verdict_fixture() {
        let fixture = [
            (
                "VERDICT: GO - clear demand signal, no incumbent risk",
                Some(Verdict::Go),
            ),
            ("1. GO - evidence supports build", Some(Verdict::Go)),
            (
                "VERDICT: NO-GO - no evidence of demand",
                Some(Verdict::NoGo),
            ),
            (
                "2. NO-GO - incumbent already dominates this niche",
                Some(Verdict::NoGo),
            ),
            (
                "VERDICT: NEEDS-NARROWING - vision too broad, narrow the ICP first",
                Some(Verdict::NeedsNarrowing),
            ),
        ];
        for (line, expected) in fixture {
            assert_eq!(parse_verdict(line), expected, "line={line:?}");
        }
    }

    #[test]
    fn test_parse_verdict_unrecognized() {
        assert_eq!(parse_verdict("no keyword here"), None);
    }

    #[test]
    fn test_cost_axis() {
        // AC2: estimate exceeds ceiling -> NoGoOnCost regardless of input verdict.
        assert_eq!(Verdict::Go.cost_axis(8.0, 5.0), Verdict::NoGoOnCost);
        // AC2: estimate within ceiling -> input verdict passes through unchanged.
        assert_eq!(Verdict::Go.cost_axis(3.0, 5.0), Verdict::Go);
    }

    #[test]
    fn test_force_verdict_from_env() {
        // Isolated via a lock-free env var that this test owns exclusively.
        std::env::set_var("CHUMP_GONOGO_FORCE_VERDICT", "no-go-on-cost");
        assert_eq!(force_verdict_from_env(), Some(Verdict::NoGoOnCost));
        std::env::remove_var("CHUMP_GONOGO_FORCE_VERDICT");
        assert_eq!(force_verdict_from_env(), None);
    }

    #[test]
    fn test_blocks_build() {
        assert!(Verdict::NoGo.blocks_build());
        assert!(Verdict::NoGoOnCost.blocks_build());
        assert!(!Verdict::Go.blocks_build());
        assert!(!Verdict::NeedsNarrowing.blocks_build());
    }
}
