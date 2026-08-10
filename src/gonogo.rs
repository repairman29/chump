//! INFRA-3481: honest go/no-go gate on the CREATE/build path (evidence-before-build).
//!
//! Clones the shape of the LLM-judge rail proven in
//! `crates/chump-verify/src/pr_ac_coverage.rs::llm_judge_ac` — shell out to
//! `chump llm-complete --model <m> --max-tokens <n>`, pipe a prompt via stdin, parse
//! structured one-line output — and encodes the venture-go-no-go doctrine
//! (`~/Projects/.claude/workflows/venture-go-no-go.js`: default-bias NO-GO, demand +
//! incumbent skepticism, evidence-before-build) into the prompt instead of a generic
//! AC-coverage question.
//!
//! `run_gonogo_gate` is the entry point a caller (e.g. `chump bootstrap`) slots ahead
//! of any build mutation: LLM demand/incumbent judgement, then [`cost_axis`] against
//! the tier's USD ceiling from `budget_tracker::tier_default_cost_usd`.

use std::process::Command;

// ── Verdict ──────────────────────────────────────────────────────────────────

/// Four-way go/no-go verdict. `NoGoOnCost` is kept distinct from `NoGo` so a
/// caller can render a cost-specific reason even when the LLM's demand/incumbent
/// judgement itself was GO — the build is blocked by budget, not by the vision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Go,
    NoGo,
    NeedsNarrowing,
    NoGoOnCost,
}

impl Verdict {
    /// Whether this verdict should block the build path. `NeedsNarrowing` does
    /// NOT block — it's a signal to shrink scope, not to refuse outright; the
    /// caller may choose to surface it and proceed, or re-prompt for a
    /// narrower vision (a follow-up UX, not this gate's job).
    pub fn blocks_build(self) -> bool {
        matches!(self, Verdict::NoGo | Verdict::NoGoOnCost)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Go => "GO",
            Verdict::NoGo => "NO-GO",
            Verdict::NeedsNarrowing => "NEEDS-NARROWING",
            Verdict::NoGoOnCost => "NO-GO-ON-COST",
        }
    }
}

/// Parse ONE LLM-shaped (or `CHUMP_GONOGO_FORCE_VERDICT`-shaped) output line into
/// a `(Verdict, reason)`. Mirrors `pr_ac_coverage::parse_judge_verdicts`'
/// keyword-anywhere-on-the-line approach: format-agnostic, case-insensitive,
/// tolerant of prose around the keyword. Most-specific keyword checked first so
/// "NO-GO-ON-COST" doesn't get mis-parsed as plain "NO-GO", and "NEEDS-NARROWING"
/// doesn't fall through to the bare "GO" substring check.
pub fn parse_verdict(line: &str) -> Option<(Verdict, String)> {
    let up = line.to_uppercase();
    let (verdict, kw): (Verdict, &str) =
        if up.contains("NO-GO-ON-COST") || up.contains("NO GO ON COST") {
            (Verdict::NoGoOnCost, "COST")
        } else if up.contains("NEEDS-NARROWING")
            || up.contains("NEEDS NARROWING")
            || up.contains("NARROWING")
        {
            (Verdict::NeedsNarrowing, "NARROWING")
        } else if up.contains("NO-GO") || up.contains("NO GO") || up.contains("NOGO") {
            (Verdict::NoGo, "GO")
        } else if up.contains("GO") {
            (Verdict::Go, "GO")
        } else {
            return None;
        };
    let kw_pos = up.find(kw).unwrap_or(0);
    let reason = line[(kw_pos + kw.len()).min(line.len())..]
        .trim_start_matches([' ', '-', ':', '—', '\t'])
        .trim()
        .to_string();
    Some((verdict, reason))
}

/// Apply the cost axis to an already-judged `verdict`: if `estimate_usd` exceeds
/// `ceiling_usd`, the build is a hard NO-GO on cost grounds regardless of how
/// promising the vision looked; otherwise the input verdict passes through
/// unchanged. AC4/AC5 of the parent doctrine — cost is a gate, not a suggestion.
pub fn cost_axis(verdict: Verdict, estimate_usd: f64, ceiling_usd: f64) -> Verdict {
    if estimate_usd > ceiling_usd {
        Verdict::NoGoOnCost
    } else {
        verdict
    }
}

// ── LLM rail (cloned from llm_judge_ac's `chump llm-complete` shape) ──────────

/// Venture go/no-go doctrine baked into the prompt (default-bias NO-GO, demand +
/// incumbent skepticism, evidence-before-build). Judge model via
/// `CHUMP_GONOGO_MODEL` (default `opus` — a build/no-build gate must be
/// trustworthy). Returns `None` if the diff/model is unavailable or the reply is
/// unparseable — the caller fails open (see [`run_gonogo_gate`]).
pub fn run_llm_gonogo(vision: &str) -> Option<(Verdict, String)> {
    if vision.trim().is_empty() {
        return None;
    }
    let prompt = format!(
        "You are a skeptical venture reviewer deciding whether to fund the BUILD of a \
         user's product vision. Default bias is NO-GO — evidence must earn a GO, not the \
         other way around. Demand skepticism: has anyone actually asked for this, or is it \
         a guess? Incumbent skepticism: does an existing product already solve this well \
         enough that building from scratch wastes effort? Evidence-before-build: prefer \
         NEEDS-NARROWING over a vague GO when the vision could be validated cheaper with a \
         smaller slice.\n\n\
         Reply with EXACTLY one line and nothing else:\n\
         GO|NO-GO|NEEDS-NARROWING - <=30-word reason\n\n\
         === VISION ===\n{vision}\n"
    );
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let model = std::env::var("CHUMP_GONOGO_MODEL").unwrap_or_else(|_| "opus".to_string());
    let mut child = Command::new(&chump_bin)
        .args(["llm-complete", "--model", &model, "--max-tokens", "80"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write;
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    let resp = String::from_utf8_lossy(&out.stdout);
    resp.lines().find_map(|l| parse_verdict(l))
}

// ── Gate ────────────────────────────────────────────────────────────────────

/// Full gate result: the LLM demand/incumbent judgement combined with the cost
/// axis, plus the numbers that produced it (for `--json` transparency).
#[derive(Debug, Clone, PartialEq)]
pub struct GateResult {
    pub verdict: Verdict,
    pub reason: String,
    pub cost_estimate_usd: f64,
    pub tier_ceiling_usd: f64,
}

/// Cheap placeholder cost estimator until a real one lands (follow-up gap):
/// scales the tier's own ceiling by vision length, clamped to [0.1, 1.0] of the
/// ceiling — a terse vision undershoots, a sprawling one approaches the ceiling.
/// Only `cost_axis` (unit-tested directly) is load-bearing for AC2; this is the
/// glue that produces a number for the `--json` surface.
fn estimate_cost_usd(vision: &str, tier: &str) -> f64 {
    let ceiling = crate::budget_tracker::tier_default_cost_usd(tier);
    let scale = (vision.trim().len() as f64 / 500.0).clamp(0.1, 1.0);
    ceiling * scale
}

/// Run the full gate for `vision`: `CHUMP_GONOGO_FORCE_VERDICT` test seam (or the
/// live LLM rail) -> `cost_axis`. `tier` selects the cost ceiling via
/// `budget_tracker::tier_default_cost_usd` (bootstrap has no effort tier of its
/// own yet, so callers pass `"m"`).
///
/// FAIL-OPEN: when the LLM call is unavailable (no network, `chump` not on
/// PATH, unparseable reply) and no force-verdict seam is set, this returns `Go`
/// so environments without live LLM access are never blocked — mirrors
/// `llm_judge_ac`'s None-on-unavailable fallback philosophy. The gate only
/// blocks the build when it actually judged (or cost genuinely exceeds ceiling).
pub fn run_gonogo_gate(vision: &str, tier: &str) -> GateResult {
    let tier_ceiling_usd = crate::budget_tracker::tier_default_cost_usd(tier);
    let cost_estimate_usd = estimate_cost_usd(vision, tier);

    let (verdict, reason) = if let Ok(forced) = std::env::var("CHUMP_GONOGO_FORCE_VERDICT") {
        match parse_verdict(&forced) {
            Some((v, r)) if !r.is_empty() => (v, r),
            Some((v, _)) => (v, "forced via CHUMP_GONOGO_FORCE_VERDICT".to_string()),
            None => (
                Verdict::Go,
                "unparseable CHUMP_GONOGO_FORCE_VERDICT — fail-open".to_string(),
            ),
        }
    } else {
        match run_llm_gonogo(vision) {
            Some((v, r)) => (v, r),
            None => (
                Verdict::Go,
                "gate unavailable (no LLM rail) — fail-open".to_string(),
            ),
        }
    };

    let final_verdict = cost_axis(verdict, cost_estimate_usd, tier_ceiling_usd);
    let reason = if final_verdict == Verdict::NoGoOnCost && verdict != Verdict::NoGoOnCost {
        format!(
            "estimated build cost ${cost_estimate_usd:.2} exceeds tier ceiling ${tier_ceiling_usd:.2}"
        )
    } else {
        reason
    };

    GateResult {
        verdict: final_verdict,
        reason,
        cost_estimate_usd,
        tier_ceiling_usd,
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

pub fn render_json(result: &GateResult) -> String {
    format!(
        "{{\"verdict\":\"{}\",\"reason\":\"{}\",\"cost_estimate_usd\":{:.2},\"tier_ceiling_usd\":{:.2}}}",
        result.verdict.as_str(),
        json_escape(&result.reason),
        result.cost_estimate_usd,
        result.tier_ceiling_usd,
    )
}

pub fn render_human(result: &GateResult) -> String {
    format!(
        "{}: {}\n  cost estimate: ${:.2} (tier ceiling ${:.2})",
        result.verdict.as_str(),
        result.reason,
        result.cost_estimate_usd,
        result.tier_ceiling_usd,
    )
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

// ── CLI dispatch: `chump gonogo <vision> [--json] [--tier xs|s|m|l]` ─────────

pub fn run(args: &[String]) -> i32 {
    // args[0] = "gonogo"
    let mut vision: Option<String> = None;
    let mut json_out = false;
    let mut tier = "m".to_string();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => {
                json_out = true;
                i += 1;
            }
            "--tier" => {
                tier = args.get(i + 1).cloned().unwrap_or_else(|| "m".to_string());
                i += 2;
            }
            "-h" | "--help" => {
                print_usage();
                return 0;
            }
            positional => {
                if vision.is_none() {
                    vision = Some(positional.to_string());
                }
                i += 1;
            }
        }
    }

    let vision = match vision {
        Some(v) if !v.trim().is_empty() => v,
        _ => {
            eprintln!("chump gonogo: missing required <vision> argument");
            print_usage();
            return 2;
        }
    };

    let result = run_gonogo_gate(&vision, &tier);
    if json_out {
        println!("{}", render_json(&result));
    } else {
        println!("{}", render_human(&result));
    }
    if result.verdict.blocks_build() {
        1
    } else {
        0
    }
}

fn print_usage() {
    println!("Usage: chump gonogo <vision> [--json] [--tier xs|s|m|l]");
    println!();
    println!("Honest go/no-go gate on a user's vision (evidence-before-build).");
    println!("Exits non-zero for NO-GO / NO-GO-ON-COST, 0 for GO / NEEDS-NARROWING.");
    println!();
    println!("Test seam: CHUMP_GONOGO_FORCE_VERDICT=GO|NO-GO|NEEDS-NARROWING|NO-GO-ON-COST");
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_verdict_maps_fixture_lines() {
        let lines = [
            (
                "1. GO - strong demand evidence, no incumbent risk",
                Verdict::Go,
            ),
            (
                "2. NO-GO - no evidence of demand, pure guess",
                Verdict::NoGo,
            ),
            ("3. GO - existing user base validates need", Verdict::Go),
            (
                "4. NEEDS-NARROWING - scope too broad, narrow to single workflow",
                Verdict::NeedsNarrowing,
            ),
            (
                "5. NO-GO - incumbent already dominates this space",
                Verdict::NoGo,
            ),
        ];
        for (line, expected) in lines {
            let (verdict, _reason) =
                parse_verdict(line).unwrap_or_else(|| panic!("failed to parse: {line}"));
            assert_eq!(verdict, expected, "line: {line}");
        }
    }

    #[test]
    fn blocks_build_matches_doctrine() {
        assert!(Verdict::NoGo.blocks_build());
        assert!(Verdict::NoGoOnCost.blocks_build());
        assert!(!Verdict::Go.blocks_build());
        assert!(!Verdict::NeedsNarrowing.blocks_build());
    }

    #[test]
    fn cost_axis_blocks_over_ceiling_passes_through_under() {
        assert_eq!(cost_axis(Verdict::Go, 8.0, 5.0), Verdict::NoGoOnCost);
        assert_eq!(cost_axis(Verdict::Go, 3.0, 5.0), Verdict::Go);
        // Passthrough preserves the INPUT verdict, not just Go.
        assert_eq!(
            cost_axis(Verdict::NeedsNarrowing, 3.0, 5.0),
            Verdict::NeedsNarrowing
        );
    }

    #[test]
    fn parse_verdict_no_go_on_cost_before_no_go() {
        let (v, _) = parse_verdict("NO-GO-ON-COST - exceeds budget").unwrap();
        assert_eq!(v, Verdict::NoGoOnCost);
    }

    #[test]
    fn parse_verdict_unparseable_returns_none() {
        assert!(parse_verdict("no keyword here at all").is_none());
    }

    #[test]
    fn render_json_has_required_keys() {
        let result = GateResult {
            verdict: Verdict::NoGo,
            reason: "no evidence".to_string(),
            cost_estimate_usd: 1.23,
            tier_ceiling_usd: 5.0,
        };
        let json = render_json(&result);
        for key in ["verdict", "reason", "cost_estimate_usd", "tier_ceiling_usd"] {
            assert!(
                json.contains(&format!("\"{key}\"")),
                "missing key {key} in {json}"
            );
        }
        assert!(json.contains("\"NO-GO\""));
    }
}
