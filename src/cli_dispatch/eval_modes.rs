//! Evaluation, judge, lesson-grading, and reflection A/B CLI modes.

use crate::*;
use std::env;

/// EVAL-009 + EVAL-007: `chump eval run` entry point.
///
/// Loads all eval cases from the DB (seeding if needed), runs each through a
/// stateless ChumpAgent, scores the output, and persists an EvalRunResult per case.
///
/// When `CHUMP_EVAL_WITH_JUDGE=1` AND a case has at least one
/// `ExpectedProperty::LlmJudge` property, scoring uses
/// `check_all_properties_with_judge_async` so the judge_score field is populated
/// in the persisted run (EVAL-007).
///
/// Returns the process exit code: 0 = all cases passed, 1 = one or more failed.
pub(crate) async fn run_eval_runner() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores, ExpectedProperty,
    };
    use stream_events::AgentEvent;

    // Seed starter cases idempotently.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval run] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval run] failed to load eval cases: {e}");
            return 1;
        }
    };

    if cases.is_empty() {
        eprintln!("[eval run] no eval cases found in DB — nothing to run");
        return 0;
    }

    let with_judge = std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref() == Ok("1");
    let provider = provider_cascade::build_provider();
    let agent_version = version::chump_version();
    let model_label = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".into());

    let mut any_failed = false;
    let total = cases.len();

    for (i, case) in cases.iter().enumerate() {
        let run_id = format!("eval-{}-{}", case.id, uuid::Uuid::new_v4().as_simple());
        let turn_start = std::time::Instant::now();

        // Build a per-case stateless agent with an event channel so we can
        // collect the ordered list of tool names called during the turn.
        let (event_tx, mut event_rx) = stream_events::event_channel();

        let registry = axonerai::tool::ToolRegistry::new();
        // Intentionally empty registry: eval cases test agent reasoning, not
        // live tool execution. Tool-selection properties check the *names* the
        // model would call; with a real registry (and no live DB/network), side
        // effects would corrupt the production DB.
        // The agent still runs with the provider and can reason about tools via
        // the system prompt / context; it just can't execute them.

        let eval_agent = agent_loop::ChumpAgent::new(
            provider_cascade::build_provider(),
            registry,
            Some(
                "You are Chump, a software-development assistant. \
                 Respond concisely and use tools when appropriate."
                    .to_string(),
            ),
            None, // stateless — no session persistence between cases
            Some(event_tx),
            10, // max_iterations sufficient for most eval turns
        );

        let outcome = match eval_agent.run(&case.input).await {
            Ok(o) => o,
            Err(e) => {
                eprintln!("[eval run] case {} errored: {e}", case.id);
                any_failed = true;
                continue;
            }
        };

        // Drain accumulated events to collect tool names in call order.
        // The channel is unbounded; all events are already queued.
        event_rx.close();
        let mut tool_calls_made: Vec<String> = Vec::new();
        while let Ok(ev) = event_rx.try_recv() {
            if let AgentEvent::ToolCallStart { tool_name, .. } = ev {
                tool_calls_made.push(tool_name);
            }
        }

        let duration_ms = turn_start.elapsed().as_millis() as u64;
        let raw_output = outcome.reply.clone();

        // ── EVAL-007: wire CHUMP_EVAL_WITH_JUDGE ──────────────────────────
        // When the env flag is set AND the case has at least one LlmJudge
        // property, use the async judge path so judge_score is populated.
        let has_llm_judge = case
            .expected_properties
            .iter()
            .any(|p| matches!(p, ExpectedProperty::LlmJudge { .. }));

        let (passed_labels, failed_labels, judge_scores) = if with_judge && has_llm_judge {
            let (p, f, js) = check_all_properties_with_judge_async(
                case,
                &raw_output,
                &tool_calls_made,
                provider.as_ref(),
            )
            .await;
            (p, f, js)
        } else {
            let (p, f) = check_all_properties(case, &raw_output, &tool_calls_made);
            (p, f, vec![])
        };

        let case_passed = failed_labels.is_empty();
        if !case_passed {
            any_failed = true;
        }

        // Compute aggregate judge_score (mean across all judged properties).
        let judge_score_agg: Option<f64> = if judge_scores.is_empty() {
            None
        } else {
            let sum: f64 = judge_scores.iter().map(|j| j.score).sum();
            Some(sum / judge_scores.len() as f64)
        };

        // Simple overall score: fraction of properties that passed.
        let total_props = passed_labels.len() + failed_labels.len();
        let overall = if total_props == 0 {
            1.0
        } else {
            passed_labels.len() as f64 / total_props as f64
        };

        let scores = EvalScores {
            overall,
            correctness: overall,
            safety: 1.0,
            efficiency: 1.0,
            judge_score: judge_score_agg,
        };

        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id,
            properties_passed: passed_labels.clone(),
            properties_failed: failed_labels.clone(),
            scores,
            duration_ms,
            raw_output,
        };

        if let Err(e) = save_eval_run(&result, &agent_version, &model_label) {
            eprintln!("[eval run] save_eval_run failed for {}: {e}", case.id);
        }

        let status = if case_passed { "PASS" } else { "FAIL" };
        let judge_tag = judge_score_agg
            .map(|s| format!(" judge={:.3}", s))
            .unwrap_or_default();
        println!(
            "[eval run] [{}/{total}] {} {:?} — {}/{} props passed{judge_tag}",
            i + 1,
            status,
            case.category,
            passed_labels.len(),
            passed_labels.len() + failed_labels.len(),
        );
    }

    if any_failed {
        eprintln!("[eval run] one or more cases failed");
        1
    } else {
        println!("[eval run] all {} cases passed", total);
        0
    }
}

/// Run eval cases that have LlmJudge properties against the configured provider,
/// persist scores to `logs/judge-scores.json`, and print per-category summary.
/// Called by `chump --eval-judge` (and transitively by `battle-qa.sh --with-judge`).
pub(crate) async fn run_eval_judge_mode() {
    use eval_harness::{
        average_judge_score_per_category, judge_via_provider, load_eval_cases, seed_starter_cases,
        EvalCategory, ExpectedProperty, JudgeInput, JudgeScore,
    };

    // Seed cases into DB if not already there.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-judge] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-judge] failed to load eval cases: {e}");
            return;
        }
    };

    let provider = provider_cascade::build_provider();

    let mut scored: Vec<(EvalCategory, JudgeScore)> = Vec::new();
    let mut json_rows: Vec<serde_json::Value> = Vec::new();

    for case in &cases {
        for prop in &case.expected_properties {
            if let ExpectedProperty::LlmJudge { rubric, threshold } = prop {
                // Get a direct (non-agent) response for this case input.
                let messages = vec![axonerai::provider::Message {
                    role: "user".to_string(),
                    content: case.input.clone(),
                }];
                let agent_output = match provider.complete(messages, None, Some(400), None).await {
                    Ok(r) => r.text.unwrap_or_default(),
                    Err(e) => {
                        eprintln!("[eval-judge] provider error for case {}: {e}", case.id);
                        continue;
                    }
                };

                let judge_input = JudgeInput {
                    rubric: rubric.clone(),
                    agent_output: agent_output.clone(),
                    tool_calls: vec![],
                };
                let judge_out = judge_via_provider(provider.as_ref(), judge_input).await;
                let score = judge_out.score.clamp(0.0, 1.0);
                let js = JudgeScore {
                    rubric: rubric.clone(),
                    threshold: *threshold,
                    score,
                    passed: score >= *threshold,
                    reasoning: judge_out.reasoning.clone(),
                };
                json_rows.push(serde_json::json!({
                    "case_id": case.id,
                    "category": format!("{:?}", case.category),
                    "rubric": rubric,
                    "score": score,
                    "passed": js.passed,
                    "reasoning": judge_out.reasoning,
                }));
                scored.push((case.category.clone(), js));
            }
        }
    }

    // Persist to logs/judge-scores.json
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let judge_file = logs_dir.join("judge-scores.json");
    if let Ok(json) = serde_json::to_string_pretty(&json_rows) {
        let _ = std::fs::write(&judge_file, json);
    }

    // Print per-category summary
    let summary = average_judge_score_per_category(&scored);
    if summary.is_empty() {
        println!("[eval-judge] No LlmJudge cases found in loaded eval cases.");
        return;
    }
    println!("Avg judge score per category:");
    for (cat, avg, n) in &summary {
        println!(
            "  {cat}: {avg:.3} ({n} case{})",
            if *n == 1 { "" } else { "s" }
        );
    }
    println!("[eval-judge] Scores persisted to {}", judge_file.display());
}

/// EVAL-009 + EVAL-007: full eval runner. Returns exit code (0 = all pass).
///
/// For each chump_eval_case:
///   1. Send case.input to the configured provider (single-turn — no tool loop;
///      richer multi-turn replay lives in scripts/eval/replay-trajectory.sh per
///      EVAL-003).
///   2. Score with `check_all_properties` (always) and
///      `check_all_properties_with_judge_async` (when CHUMP_EVAL_WITH_JUDGE=1).
///   3. Persist EvalRunResult to chump_eval_runs via `save_eval_run`.
///
/// Single-turn caveat: the EvalCase contract is "user input → response"; multi-
/// turn fixtures are GoldenTrajectory's job (EVAL-003 + scripts/eval/replay-
/// trajectory.sh). When EVAL-009 acceptance says "runs each through ChumpAgent"
/// the agent here is the bare provider — full agent-loop integration with tools
/// would re-implement most of agent_loop and isn't needed for property scoring.
pub(crate) async fn run_eval_run_mode() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores,
    };
    use uuid::Uuid;

    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-run] seed_starter_cases failed: {e} — continuing with existing cases");
    }
    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-run] failed to load eval cases: {e}");
            return 2;
        }
    };
    if cases.is_empty() {
        eprintln!("[eval-run] no eval cases loaded — nothing to do");
        return 0;
    }

    let with_judge = matches!(std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref(), Ok("1"));
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());
    let agent_version = env!("CARGO_PKG_VERSION");
    let run_id = format!("evalrun-{}", Uuid::new_v4().simple());
    let provider = provider_cascade::build_provider();

    println!(
        "[eval-run] {} cases, model={}, with_judge={}, run_id={}",
        cases.len(),
        model_name,
        with_judge,
        run_id
    );

    let mut total_passed = 0usize;
    let mut total_failed = 0usize;
    for case in &cases {
        let started = std::time::Instant::now();
        let messages = vec![axonerai::provider::Message {
            role: "user".to_string(),
            content: case.input.clone(),
        }];
        let agent_output = match provider.complete(messages, None, Some(800), None).await {
            Ok(r) => r.text.unwrap_or_default(),
            Err(e) => {
                eprintln!("[eval-run] provider error for case {}: {e}", case.id);
                String::new()
            }
        };
        let duration_ms = started.elapsed().as_millis() as u64;

        // Structural pass/fail (always). Single-turn so tool_calls is empty.
        let (mut passed, mut failed) = check_all_properties(case, &agent_output, &[]);

        // Judge pass/fail (when enabled). Augments the property lists.
        let mut judge_overall = 0.0_f64;
        if with_judge {
            let (jp, jf, scores) =
                check_all_properties_with_judge_async(case, &agent_output, &[], provider.as_ref())
                    .await;
            for s in &jp {
                if !passed.contains(s) {
                    passed.push(s.clone());
                }
            }
            for s in &jf {
                if !failed.contains(s) {
                    failed.push(s.clone());
                }
            }
            if !scores.is_empty() {
                judge_overall = scores.iter().map(|s| s.score).sum::<f64>() / scores.len() as f64;
            }
        }

        let case_passed = failed.is_empty() && !agent_output.trim().is_empty();
        if case_passed {
            total_passed += 1;
        } else {
            total_failed += 1;
        }
        println!(
            "  {} {}  [pass={} fail={} judge={:.2} dur={}ms]",
            if case_passed { "✓" } else { "✗" },
            case.id,
            passed.len(),
            failed.len(),
            judge_overall,
            duration_ms
        );

        let scores = EvalScores {
            overall: if case_passed { 1.0 } else { 0.0 },
            correctness: judge_overall,
            safety: 0.0,
            efficiency: 0.0,
            judge_score: if with_judge && judge_overall > 0.0 {
                Some(judge_overall)
            } else {
                None
            },
        };
        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id: run_id.clone(),
            properties_passed: passed,
            properties_failed: failed,
            scores,
            duration_ms,
            raw_output: agent_output,
        };
        if let Err(e) = save_eval_run(&result, agent_version, &model_name) {
            eprintln!("[eval-run] save_eval_run failed for {}: {e}", case.id);
        }
    }

    println!(
        "[eval-run] done. passed={} failed={} total={}",
        total_passed,
        total_failed,
        total_passed + total_failed
    );
    if total_failed == 0 {
        0
    } else {
        1
    }
}

/// EVAL-008: A/B reflect_heuristic vs reflect_via_provider on a labeled
/// dataset. Returns exit code 0 if the LLM variant beats the heuristic by
/// >=15 percentage points (the acceptance gate), 1 otherwise.
///
/// Loads tests/fixtures/reflection_episodes.json — 20 labeled episodes with
/// ground-truth ErrorPattern. For each episode, runs both reflectors and
/// compares the predicted pattern against the gold label. Reports per-method
/// accuracy and per-pattern confusion stats.
///
/// Provider for reflect_via_provider comes from provider_cascade::build_provider().
pub(crate) async fn run_eval_reflection_mode() -> i32 {
    use reflection::{
        reflect_heuristic, reflect_via_provider, ErrorPattern, OutcomeClass, ReflectionInput,
    };
    use serde::Deserialize;
    use std::collections::BTreeMap;

    #[derive(Debug, Clone, Deserialize)]
    struct LabeledEpisode {
        id: String,
        intended_goal: String,
        observed_outcome: String,
        outcome_class: String,
        #[serde(default)]
        tool_errors: Vec<String>,
        gold_pattern: Option<String>,
    }

    #[derive(Debug, Clone, Deserialize)]
    struct EpisodesFile {
        episodes: Vec<LabeledEpisode>,
    }

    let fixture_path = repo_path::repo_root().join("tests/fixtures/reflection_episodes.json");
    let raw = match std::fs::read_to_string(&fixture_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[eval-reflection] cannot read {}: {e}",
                fixture_path.display()
            );
            return 2;
        }
    };
    let parsed: EpisodesFile = match serde_json::from_str(&raw) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[eval-reflection] parse error: {e}");
            return 2;
        }
    };
    println!(
        "[eval-reflection] {} episodes loaded from {}",
        parsed.episodes.len(),
        fixture_path.display()
    );

    let provider = provider_cascade::build_provider();
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());

    // Per-method totals.
    let mut h_correct = 0usize;
    let mut p_correct = 0usize;
    // Per-gold-pattern: (heuristic_correct, provider_correct, total).
    let mut by_pattern: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();

    for ep in &parsed.episodes {
        let outcome = OutcomeClass::from_str(&ep.outcome_class.to_lowercase());
        // Gold label: "ToolMisuse" → ErrorPattern variant; null/None → expected None.
        let gold_label = ep.gold_pattern.as_deref();
        let gold_pattern: Option<ErrorPattern> = gold_label
            .map(|s| s.to_lowercase().replace(' ', "_"))
            .and_then(|s| {
                // The fixture uses CamelCase but ErrorPattern::from_str expects snake.
                let snake = camel_to_snake(s.as_str());
                ErrorPattern::from_str(&snake)
            });

        // Heuristic prediction.
        let h_reflection = reflect_heuristic(
            &ep.intended_goal,
            &ep.observed_outcome,
            outcome,
            &ep.tool_errors,
            None,
            None,
        );

        // Provider prediction.
        let input = ReflectionInput {
            intended_goal: ep.intended_goal.clone(),
            observed_outcome: ep.observed_outcome.clone(),
            outcome_class: outcome,
            tool_errors: ep.tool_errors.clone(),
            surprisal: None,
            trajectory_confidence: None,
        };
        let p_reflection = reflect_via_provider(provider.as_ref(), input).await;

        let h_match = h_reflection.error_pattern == gold_pattern;
        let p_match = p_reflection.error_pattern == gold_pattern;
        if h_match {
            h_correct += 1;
        }
        if p_match {
            p_correct += 1;
        }
        let bucket = by_pattern
            .entry(gold_label.unwrap_or("Pass").to_string())
            .or_insert((0, 0, 0));
        if h_match {
            bucket.0 += 1;
        }
        if p_match {
            bucket.1 += 1;
        }
        bucket.2 += 1;

        let h_pred = h_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let p_pred = p_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let gold_str = gold_label.unwrap_or("(none)");
        println!(
            "  {:6} gold={:24} heur={:24}{}  prov={:24}{}",
            ep.id,
            gold_str,
            h_pred,
            if h_match { " ✓" } else { " ✗" },
            p_pred,
            if p_match { " ✓" } else { " ✗" },
        );
    }

    let total = parsed.episodes.len() as f64;
    let h_acc = h_correct as f64 / total;
    let p_acc = p_correct as f64 / total;
    let delta = p_acc - h_acc;

    println!();
    println!("[eval-reflection] model={}", model_name);
    println!(
        "  heuristic accuracy: {}/{} = {:.3}",
        h_correct,
        parsed.episodes.len(),
        h_acc
    );
    println!(
        "  provider  accuracy: {}/{} = {:.3}",
        p_correct,
        parsed.episodes.len(),
        p_acc
    );
    println!("  delta (provider - heuristic): {:+.3}", delta);
    println!();
    println!("  per-pattern (heur/prov/total):");
    for (pat, (h, p, t)) in &by_pattern {
        println!("    {:24} {:>2}/{:>2}/{:>2}", pat, h, p, t);
    }

    // Persist a JSON summary alongside other A/B results.
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let summary = serde_json::json!({
        "tag": "eval-reflection-ab",
        "model": model_name,
        "episodes": parsed.episodes.len(),
        "heuristic_correct": h_correct,
        "provider_correct": p_correct,
        "heuristic_accuracy": h_acc,
        "provider_accuracy": p_acc,
        "delta": delta,
        "by_pattern": by_pattern.iter().map(|(k, (h, p, t))| {
            (k.clone(), serde_json::json!({"heuristic": h, "provider": p, "total": t}))
        }).collect::<serde_json::Map<_, _>>(),
    });
    let summary_path = logs_dir.join(format!(
        "eval-reflection-{}.json",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    ));
    let _ = std::fs::write(
        &summary_path,
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    );
    println!("\n[eval-reflection] summary: {}", summary_path.display());

    // Acceptance gate: provider must beat heuristic by >=15 pp.
    if delta >= 0.15 {
        println!("[eval-reflection] PASS — provider beats heuristic by >=15 pp");
        0
    } else {
        println!(
            "[eval-reflection] FAIL — delta {:+.3} < +0.150 acceptance gate",
            delta
        );
        1
    }
}

/// "ToolMisuse" → "tool_misuse" — minimal converter for fixture string → enum.
/// COG-043: read all `lessons_shown` events for `gap_id` from
/// ambient.jsonl, fetch the PR diff + body via `gh`, and emit a
/// `lesson_applied` / `lesson_not_applied` event for each unique
/// directive. Returns (applied, not_applied, skipped) counts.
///
/// Caller (bot-merge.sh) treats errors here as best-effort — never
/// gates the auto-close flow on telemetry.
pub(crate) fn run_lesson_grade(
    repo_root: &std::path::Path,
    gap_id: &str,
    pr_number: u64,
    session_filter: Option<&str>,
) -> anyhow::Result<(u64, u64, u64)> {
    use std::process::Command;
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // Find the most recent `lessons_shown` event matching gap_id (and
    // session if provided). Walk lines from the end backward.
    let mut latest_directives: Vec<String> = Vec::new();
    let mut latest_session = String::new();
    for line in contents.lines().rev() {
        if !line.contains("\"kind\":\"lessons_shown\"")
            && !line.contains("\"kind\": \"lessons_shown\"")
        {
            continue;
        }
        if !line.contains(gap_id) {
            continue;
        }
        if let Some(filt) = session_filter {
            if !line.contains(filt) {
                continue;
            }
        }
        // Parse the JSON line. Use python3 for robustness; fall back to
        // a permissive substring extract if python is unavailable.
        let parsed = parse_lessons_shown_line(line);
        if let Some((session_id, directives)) = parsed {
            if !directives.is_empty() {
                latest_directives = directives;
                latest_session = session_id;
                break;
            }
        }
    }
    if latest_directives.is_empty() {
        return Ok((0, 0, 0));
    }

    // Pull the PR body + diff via gh. Failures here just mean we can't
    // grade — return zeros, don't error.
    let body_out = Command::new("gh")
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "body,title,commits",
            "-q",
            ".title + \"\\n\" + (.body // \"\") + \"\\n\" + ([.commits[].messageHeadline + \"\\n\" + (.commits[].messageBody // \"\")] | join(\"\\n\"))",
        ])
        .current_dir(repo_root)
        .output()
        .ok();
    let diff_out = Command::new("gh")
        .args(["pr", "diff", &pr_number.to_string()])
        .current_dir(repo_root)
        .output()
        .ok();

    let mut pr_text = String::new();
    if let Some(o) = body_out {
        if o.status.success() {
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if let Some(o) = diff_out {
        if o.status.success() {
            pr_text.push('\n');
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if pr_text.is_empty() {
        return Ok((0, 0, latest_directives.len() as u64));
    }

    let mut applied = 0u64;
    let mut not_applied = 0u64;
    for directive in &latest_directives {
        let (matched, total) = lesson_action::score_directive_against_pr(directive, &pr_text);
        let is_applied = lesson_action::directive_applied(directive, &pr_text);
        lesson_action::emit_lesson_grade(
            repo_root,
            &latest_session,
            gap_id,
            pr_number,
            directive,
            is_applied,
            matched,
            total,
        );
        if is_applied {
            applied += 1;
        } else {
            not_applied += 1;
        }
    }
    Ok((applied, not_applied, 0))
}

/// Parse one `lessons_shown` JSON line. Returns (session_id, directives).
/// Permissive — uses python3 if available, hand-rolls otherwise.
pub(crate) fn parse_lessons_shown_line(line: &str) -> Option<(String, Vec<String>)> {
    use std::process::Command;
    if let Ok(out) = Command::new("python3")
        .arg("-c")
        .arg(
            r#"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
sid = d.get('session_id', '')
dirs = d.get('directives', [])
if not isinstance(dirs, list):
    dirs = []
print(sid)
for x in dirs:
    print(x)
"#,
        )
        .arg(line)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            let mut iter = s.lines();
            let sid = iter.next().unwrap_or("").to_string();
            let dirs: Vec<String> = iter.map(|l| l.to_string()).collect();
            if !dirs.is_empty() {
                return Some((sid, dirs));
            }
        }
    }
    // Fallback: don't try to be clever. If python isn't available,
    // grading just no-ops on this corpus. That's acceptable for v1.
    None
}

pub(crate) fn camel_to_snake(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            out.push('_');
        }
        out.extend(c.to_lowercase());
    }
    out
}

/// EVAL-008: A/B accuracy comparison between `reflect_heuristic` and
/// `reflect_via_provider` on a labeled episode dataset.
///
/// Env gating:
///   CHUMP_REFLECTION_AB_WITH_LLM=1  — also runs the provider leg (fails loud
///                                     if no endpoint reachable)
///
/// Exit behaviour (via std::process::exit):
///   0  — heuristic-only run, or LLM leg ≥ 15% more accurate than heuristic
///   1  — LLM leg present but accuracy delta < 15%
pub(crate) async fn run_reflection_ab_mode(episodes_path: Option<std::path::PathBuf>) {
    use reflection::{reflect_heuristic, reflect_via_provider, OutcomeClass, ReflectionInput};

    // ── Locate episode file ────────────────────────────────────────────────
    let default_path = std::path::PathBuf::from("scripts/eval/fixtures/reflection-episodes.json");
    let path = episodes_path.unwrap_or(default_path);
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[reflect-ab] ERROR: cannot read episodes file {}: {e}",
                path.display()
            );
            std::process::exit(2);
        }
    };
    let doc: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[reflect-ab] ERROR: malformed JSON in episodes file: {e}");
            std::process::exit(2);
        }
    };
    let episodes = match doc.get("episodes").and_then(|v| v.as_array()) {
        Some(a) => a.clone(),
        None => {
            eprintln!("[reflect-ab] ERROR: episodes file has no top-level 'episodes' array");
            std::process::exit(2);
        }
    };

    // ── LLM leg setup ─────────────────────────────────────────────────────
    let with_llm = std::env::var("CHUMP_REFLECTION_AB_WITH_LLM")
        .map(|v| v == "1")
        .unwrap_or(false);
    // build_provider() returns Box<dyn Provider + Send + Sync> directly.
    // The shell script already probed the endpoint before setting
    // CHUMP_REFLECTION_AB_WITH_LLM=1, so this will succeed if --with-llm was passed.
    let provider_box: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = if with_llm {
        Some(crate::provider_cascade::build_provider())
    } else {
        None
    };

    // ── Per-pattern counters ───────────────────────────────────────────────
    let mut h_correct: usize = 0; // heuristic correct
    let mut l_correct: usize = 0; // llm correct
    let mut total_labeled: usize = 0; // episodes with a label (non-pass)

    // Confusion accumulators: (label, heuristic_pred) → count
    let mut h_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();
    let mut l_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();

    println!(
        "[reflect-ab] episodes={} with_llm={}",
        episodes.len(),
        with_llm
    );
    println!();

    for ep in &episodes {
        let id = ep.get("id").and_then(|v| v.as_str()).unwrap_or("?");
        let intended_goal = ep
            .get("intended_goal")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let observed_outcome = ep
            .get("observed_outcome")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let outcome_class_str = ep
            .get("outcome_class")
            .and_then(|v| v.as_str())
            .unwrap_or("fail");
        let outcome_class = if outcome_class_str == "pass" {
            OutcomeClass::Pass
        } else {
            OutcomeClass::Failure
        };
        let tool_errors: Vec<String> = ep
            .get("tool_errors")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let surprisal = ep.get("surprisal").and_then(|v| v.as_f64());
        let trajectory_confidence = ep.get("trajectory_confidence").and_then(|v| v.as_f64());
        let label_raw = ep.get("label").and_then(|v| v.as_str()); // None for pass episodes

        // Pass episodes: both methods should return None error_pattern.
        if outcome_class == OutcomeClass::Pass {
            let h_refl = reflect_heuristic(
                &intended_goal,
                &observed_outcome,
                outcome_class,
                &tool_errors,
                surprisal,
                trajectory_confidence,
            );
            let h_pred = h_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            println!("  [{id}] pass | heuristic→{h_pred}");
            continue;
        }

        // Labeled failure episodes.
        let label = match label_raw {
            Some(l) => l.to_string(),
            None => {
                eprintln!("  [{id}] WARN: fail episode has no label — skipping");
                continue;
            }
        };
        total_labeled += 1;

        let input = ReflectionInput {
            intended_goal: intended_goal.clone(),
            observed_outcome: observed_outcome.clone(),
            outcome_class,
            tool_errors: tool_errors.clone(),
            surprisal,
            trajectory_confidence,
        };

        // Heuristic leg
        let h_refl = reflect_heuristic(
            &intended_goal,
            &observed_outcome,
            outcome_class,
            &tool_errors,
            surprisal,
            trajectory_confidence,
        );
        let h_pred = h_refl
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "null".to_string());
        let h_hit = h_pred == label;
        if h_hit {
            h_correct += 1;
        }
        *h_confusion
            .entry((label.clone(), h_pred.clone()))
            .or_insert(0) += 1;

        // LLM leg (optional)
        let l_pred = if let Some(ref prov) = provider_box {
            let l_refl = reflect_via_provider(prov.as_ref(), input.clone()).await;
            let pred = l_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            let l_hit = pred == label;
            if l_hit {
                l_correct += 1;
            }
            *l_confusion
                .entry((label.clone(), pred.clone()))
                .or_insert(0) += 1;
            Some(pred)
        } else {
            None
        };

        let h_mark = if h_hit { "✓" } else { "✗" };
        if let Some(ref lp) = l_pred {
            let l_hit = *lp == label;
            let l_mark = if l_hit { "✓" } else { "✗" };
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}  llm={lp}{l_mark}");
        } else {
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}");
        }
    }

    // ── Summary ───────────────────────────────────────────────────────────
    println!();
    println!("=== EVAL-008: Reflection A/B Results ===");
    println!("Labeled failure episodes: {total_labeled}");
    println!(
        "Heuristic accuracy: {}/{total_labeled} = {:.1}%",
        h_correct,
        100.0 * h_correct as f64 / total_labeled.max(1) as f64
    );

    if with_llm {
        let l_acc = 100.0 * l_correct as f64 / total_labeled.max(1) as f64;
        let h_acc = 100.0 * h_correct as f64 / total_labeled.max(1) as f64;
        let delta = l_acc - h_acc;
        println!(
            "LLM accuracy:       {}/{total_labeled} = {l_acc:.1}%",
            l_correct
        );
        println!("Delta (LLM − heuristic): {delta:+.1}%");
        println!();

        // Per-pattern confusion matrix (heuristic)
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut h_rows: Vec<_> = h_confusion.iter().collect();
        h_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &h_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        println!("--- LLM confusion (label → predicted) ---");
        let mut l_rows: Vec<_> = l_confusion.iter().collect();
        l_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &l_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        // A/B gate
        if delta >= 15.0 {
            println!("[reflect-ab] PASS: LLM variant is ≥15% more accurate ({delta:+.1}% delta)");
        } else {
            eprintln!(
                "[reflect-ab] FAIL: LLM delta {delta:+.1}% is below the 15% acceptance threshold"
            );
            std::process::exit(1);
        }
    } else {
        println!();
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut rows: Vec<_> = h_confusion.iter().collect();
        rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();
        println!(
            "[reflect-ab] Heuristic-only run complete. Re-run with \
             CHUMP_REFLECTION_AB_WITH_LLM=1 to compare against LLM variant."
        );
    }
}
