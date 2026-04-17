//! Structured self-reflection — Sprint D2 (GEPA-inspired ASI formalization).
//!
//! GEPA (Generative Error Pattern Analysis) is a reflection pattern where an agent,
//! after completing a task, produces a *structured* record of what it was trying to do,
//! what happened, and what it would do differently next time. Unlike a freeform post-mortem,
//! the slots are typed so downstream systems (planners, trainers, eval harnesses) can
//! consume reflections programmatically.
//!
//! This is distinct from Chump's existing signals:
//!
//! - `chump_episodes` captures *what happened* (narrative + sentiment)
//! - `chump_causal_lessons` captures *what the agent learned* (one heuristic)
//! - `chump_prediction_log` captures *how surprised the agent was*
//! - Skills (`chump_skills`) capture *reusable procedures*
//!
//! Reflection records combine all four into a single typed artifact per task,
//! so improvements compound across sessions.
//!
//! ## V1 scope (this module)
//!
//! - Type definitions (`Reflection`, `ErrorPattern`, `ImprovementTarget`)
//! - DB persistence via `reflection_db`
//! - Heuristic extraction from an episode (no LLM call required)
//!
//! ## V2 (this module — COG-008)
//!
//! - LLM-assisted reflection via a live Provider (`reflect_via_provider`)
//! - Gated behind `CHUMP_REFLECTION_LLM=1` so costs are opt-in
//! - Falls back to heuristic on any parse/provider failure — a broken model
//!   must never silently produce a garbage Reflection
//!
//! ## V3 (future)
//!
//! - Integration into agent_loop: automatic reflection after N-turn episodes
//! - Injection of recent reflections into system prompt (so the agent reads its
//!   own improvement targets)
//! - Eval harness that grades whether reflections actually improve behavior
//!
//! ## Reference
//!
//! - docs/NEXT_GEN_COMPETITIVE_INTEL.md (Sprint D2 row) — adoption rationale
//! - GEPA research: structured reflection shows better transfer than freeform self-critique

use serde::{Deserialize, Serialize};

/// A single structured reflection on a task or episode.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reflection {
    pub id: Option<i64>,
    /// Link back to the source episode (if applicable).
    pub episode_id: Option<i64>,
    /// What the agent was trying to accomplish, in the agent's own words.
    pub intended_goal: String,
    /// What actually happened. Concrete, not interpretive.
    pub observed_outcome: String,
    /// Pass | PartialSuccess | Failure | Abandoned
    pub outcome_class: OutcomeClass,
    /// Categorized error pattern (if any). None when outcome_class = Pass.
    pub error_pattern: Option<ErrorPattern>,
    /// Specific improvement targets, each with a priority. Empty for clean passes.
    pub improvements: Vec<ImprovementTarget>,
    /// Free-form hypothesis for why the outcome was what it was.
    pub hypothesis: String,
    /// Surprisal EMA snapshot at reflection time (link to belief state).
    pub surprisal_at_reflect: Option<f64>,
    /// Trajectory confidence snapshot at reflection time.
    pub confidence_at_reflect: Option<f64>,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum OutcomeClass {
    Pass,
    PartialSuccess,
    Failure,
    Abandoned,
}

impl OutcomeClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::PartialSuccess => "partial",
            Self::Failure => "failure",
            Self::Abandoned => "abandoned",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "pass" => Self::Pass,
            "partial" => Self::PartialSuccess,
            "failure" => Self::Failure,
            "abandoned" => Self::Abandoned,
            _ => Self::Failure, // default on unknown
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ErrorPattern {
    /// The agent misunderstood the task (planning error).
    MisinterpretedGoal,
    /// Tool called with wrong arguments.
    ToolMisuse,
    /// Tool succeeded but output wasn't what we expected.
    UnexpectedToolOutput,
    /// Tool call timed out or circuit-broke.
    ToolFailure,
    /// Agent kept calling tools without converging (loop detection).
    NonconvergentLoop,
    /// Agent hit max iterations.
    BudgetExhausted,
    /// Agent narrated an action instead of calling the tool.
    NarratedInsteadOfActed,
    /// Agent couldn't resolve ambiguity and should have asked a clarifying question.
    UnresolvedAmbiguity,
    /// External system failed (network, DB, etc.).
    ExternalFailure,
    /// Something else — describe in the hypothesis field.
    Other,
}

impl ErrorPattern {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::MisinterpretedGoal => "misinterpreted_goal",
            Self::ToolMisuse => "tool_misuse",
            Self::UnexpectedToolOutput => "unexpected_tool_output",
            Self::ToolFailure => "tool_failure",
            Self::NonconvergentLoop => "nonconvergent_loop",
            Self::BudgetExhausted => "budget_exhausted",
            Self::NarratedInsteadOfActed => "narrated_instead_of_acted",
            Self::UnresolvedAmbiguity => "unresolved_ambiguity",
            Self::ExternalFailure => "external_failure",
            Self::Other => "other",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "misinterpreted_goal" => Some(Self::MisinterpretedGoal),
            "tool_misuse" => Some(Self::ToolMisuse),
            "unexpected_tool_output" => Some(Self::UnexpectedToolOutput),
            "tool_failure" => Some(Self::ToolFailure),
            "nonconvergent_loop" => Some(Self::NonconvergentLoop),
            "budget_exhausted" => Some(Self::BudgetExhausted),
            "narrated_instead_of_acted" => Some(Self::NarratedInsteadOfActed),
            "unresolved_ambiguity" => Some(Self::UnresolvedAmbiguity),
            "external_failure" => Some(Self::ExternalFailure),
            "other" => Some(Self::Other),
            _ => None,
        }
    }
}

/// A specific, actionable improvement the agent commits to applying next time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImprovementTarget {
    /// Short imperative description — "verify file exists before patch_file".
    pub directive: String,
    /// high / medium / low — how much this matters for repeat attempts.
    pub priority: Priority,
    /// Which tool or subsystem this applies to (optional).
    pub scope: Option<String>,
    /// Whether this has been converted into a skill (Phase 1.1) or lesson
    /// (chump_causal_lessons). Null means "not yet actioned".
    pub actioned_as: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Priority {
    High,
    Medium,
    Low,
}

impl Priority {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::High => "high",
            Self::Medium => "medium",
            Self::Low => "low",
        }
    }
}

/// Build a reflection heuristically from a basic outcome + signals. V1: pattern-match
/// on common failure modes. V2: replace this with an LLM-assisted variant via the
/// delegate worker.
///
/// This is the "good enough to be useful" version — it catches obvious patterns without
/// requiring a model call.
pub fn reflect_heuristic(
    intended_goal: &str,
    observed_outcome: &str,
    outcome_class: OutcomeClass,
    tool_errors: &[String],
    surprisal: Option<f64>,
    trajectory_confidence: Option<f64>,
) -> Reflection {
    let error_pattern = detect_pattern_heuristic(observed_outcome, tool_errors, outcome_class);
    let improvements = suggest_improvements(error_pattern, tool_errors);
    let hypothesis = build_hypothesis(error_pattern, tool_errors, surprisal, trajectory_confidence);

    Reflection {
        id: None,
        episode_id: None,
        intended_goal: intended_goal.to_string(),
        observed_outcome: observed_outcome.to_string(),
        outcome_class,
        error_pattern,
        improvements,
        hypothesis,
        surprisal_at_reflect: surprisal,
        confidence_at_reflect: trajectory_confidence,
        created_at: now_iso(),
    }
}

fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    secs.to_string()
}

fn detect_pattern_heuristic(
    observed: &str,
    tool_errors: &[String],
    outcome: OutcomeClass,
) -> Option<ErrorPattern> {
    if outcome == OutcomeClass::Pass {
        return None;
    }
    let lower = observed.to_lowercase();

    // Check tool errors first — they're concrete signals.
    if !tool_errors.is_empty() {
        let joined = tool_errors.join(" ").to_lowercase();
        if joined.contains("timeout") || joined.contains("timed out") {
            return Some(ErrorPattern::ToolFailure);
        }
        if joined.contains("circuit") || joined.contains("rate limit") {
            return Some(ErrorPattern::ExternalFailure);
        }
        if joined.contains("no such file")
            || joined.contains("permission denied")
            || joined.contains("invalid argument")
            || joined.contains("validation")
        {
            return Some(ErrorPattern::ToolMisuse);
        }
    }

    // Then observed outcome text heuristics.
    if lower.contains("i would")
        || lower.contains("i'll try")
        || lower.contains("let me")
        || lower.contains("i could")
    {
        // Narration without calling tools
        return Some(ErrorPattern::NarratedInsteadOfActed);
    }
    if lower.contains("not clear") || lower.contains("ambiguous") || lower.contains("unclear what")
    {
        return Some(ErrorPattern::UnresolvedAmbiguity);
    }
    if lower.contains("max iterations") || lower.contains("budget") || lower.contains("out of") {
        return Some(ErrorPattern::BudgetExhausted);
    }
    if lower.contains("looped") || lower.contains("kept calling") || lower.contains("same tool") {
        return Some(ErrorPattern::NonconvergentLoop);
    }
    Some(ErrorPattern::Other)
}

fn suggest_improvements(
    pattern: Option<ErrorPattern>,
    _tool_errors: &[String],
) -> Vec<ImprovementTarget> {
    let Some(p) = pattern else { return Vec::new() };
    match p {
        ErrorPattern::ToolMisuse => vec![ImprovementTarget {
            directive: "validate tool input schema + preconditions (file exists, permissions) before invocation".to_string(),
            priority: Priority::High,
            scope: Some("tool_middleware".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::ToolFailure => vec![ImprovementTarget {
            directive: "add retry with exponential backoff, or switch to alternate tool on failure".to_string(),
            priority: Priority::Medium,
            scope: Some("tool_middleware".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::NarratedInsteadOfActed => vec![ImprovementTarget {
            directive: "convert narration to an immediate tool call; agent_loop should retry with stronger 'act don't narrate' guard".to_string(),
            priority: Priority::High,
            scope: Some("agent_loop".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::UnresolvedAmbiguity => vec![ImprovementTarget {
            directive: "ask a clarifying question before acting when perception ambiguity > 0.7".to_string(),
            priority: Priority::High,
            scope: Some("perception".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::NonconvergentLoop => vec![ImprovementTarget {
            directive: "detect repeated-tool-with-same-args and break out to escalation path".to_string(),
            priority: Priority::High,
            scope: Some("agent_loop".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::BudgetExhausted => vec![ImprovementTarget {
            directive: "plan step decomposition up-front; raise budget or split task".to_string(),
            priority: Priority::Medium,
            scope: Some("task_planner".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::MisinterpretedGoal => vec![ImprovementTarget {
            directive: "re-read the user prompt; confirm understanding before substantial tool use".to_string(),
            priority: Priority::High,
            scope: Some("perception".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::UnexpectedToolOutput => vec![ImprovementTarget {
            directive: "add post-execution verification for this tool class".to_string(),
            priority: Priority::Medium,
            scope: Some("tool_middleware".to_string()),
            actioned_as: None,
        }],
        ErrorPattern::ExternalFailure => vec![ImprovementTarget {
            directive: "external failure — probably retry later; not actionable within task".to_string(),
            priority: Priority::Low,
            scope: None,
            actioned_as: None,
        }],
        ErrorPattern::Other => Vec::new(),
    }
}

fn build_hypothesis(
    pattern: Option<ErrorPattern>,
    tool_errors: &[String],
    surprisal: Option<f64>,
    confidence: Option<f64>,
) -> String {
    let mut parts = Vec::new();
    if let Some(p) = pattern {
        parts.push(format!("Error pattern: {}", p.as_str()));
    }
    if !tool_errors.is_empty() {
        parts.push(format!("Tool errors: {}", tool_errors.join("; ")));
    }
    if let Some(s) = surprisal {
        parts.push(format!("Surprisal at reflect: {:.3}", s));
    }
    if let Some(c) = confidence {
        parts.push(format!("Trajectory confidence: {:.3}", c));
    }
    if parts.is_empty() {
        "no signals available for hypothesis".to_string()
    } else {
        parts.join(" | ")
    }
}

// ── COG-008: async LLM reflection adapter ───────────────────────────────
//
// `reflect_heuristic` above ships the "good enough" pattern-matching version.
// COG-008 adds the async variant that runs a live Provider — mirroring the
// EVAL-004 (`judge_via_provider`) and MEM-004 (`summarize_via_provider`)
// pattern: sync path stays closure-injectable, async path takes a Provider
// directly. Gated behind `CHUMP_REFLECTION_LLM=1` so provider cost is opt-in.
//
// On any failure (provider error, empty response, unparseable JSON) the
// adapter falls back to `reflect_heuristic` — a broken model MUST NOT silently
// ship a garbage Reflection into the DB.

/// Input context handed to the reflection LLM. Separate struct so tests can pin
/// prompt wording against snapshot drift without rebuilding the whole call.
#[derive(Debug, Clone)]
pub struct ReflectionInput {
    pub intended_goal: String,
    pub observed_outcome: String,
    pub outcome_class: OutcomeClass,
    pub tool_errors: Vec<String>,
    pub surprisal: Option<f64>,
    pub trajectory_confidence: Option<f64>,
}

/// True when `CHUMP_REFLECTION_LLM=1`. Keep the check here (not a lazy_static)
/// so tests can flip the env var mid-run.
pub fn reflection_llm_enabled() -> bool {
    std::env::var("CHUMP_REFLECTION_LLM")
        .map(|v| v == "1")
        .unwrap_or(false)
}

/// Build the prompt shown to the reflection model. Free fn so tests can pin
/// exact wording. Asks for a JSON object that maps 1:1 to the fields of
/// `Reflection` that the LLM is allowed to fill in.
pub fn build_reflect_prompt(input: &ReflectionInput) -> String {
    let mut prompt = String::with_capacity(
        800 + input.intended_goal.len()
            + input.observed_outcome.len()
            + input.tool_errors.iter().map(|e| e.len() + 4).sum::<usize>(),
    );
    prompt.push_str(
        "You are analyzing an agent's recent task attempt to produce a STRUCTURED reflection.\n\
         Respond with EXACTLY one JSON object, no prose outside the JSON:\n\
         {\n  \
           \"error_pattern\": \"<one of: misinterpreted_goal, tool_misuse, unexpected_tool_output, \
         tool_failure, nonconvergent_loop, budget_exhausted, narrated_instead_of_acted, \
         unresolved_ambiguity, external_failure, other>\" or null,\n  \
           \"improvements\": [{\"directive\": \"<short imperative>\", \"priority\": \"high|medium|low\", \
         \"scope\": \"<subsystem or null>\"}],\n  \
           \"hypothesis\": \"<one sentence explaining why the outcome was what it was>\"\n\
         }\n\
         Rules:\n\
         - error_pattern MUST be null when outcome_class == pass; otherwise pick the best match.\n\
         - improvements is empty for clean passes; each directive is an actionable imperative.\n\
         - Keep hypothesis factual; do NOT invent tool errors that aren't listed.\n\n",
    );
    prompt.push_str("## Intended goal\n");
    prompt.push_str(input.intended_goal.trim());
    prompt.push_str("\n\n## Observed outcome\n");
    prompt.push_str(input.observed_outcome.trim());
    prompt.push_str("\n\n## Outcome class\n");
    prompt.push_str(input.outcome_class.as_str());
    prompt.push('\n');
    if !input.tool_errors.is_empty() {
        prompt.push_str("\n## Tool errors (in order)\n");
        for (i, err) in input.tool_errors.iter().enumerate() {
            prompt.push_str(&format!("{}. {}\n", i + 1, err));
        }
    }
    if let Some(s) = input.surprisal {
        prompt.push_str(&format!("\n## Surprisal EMA at reflection\n{:.3}\n", s));
    }
    if let Some(c) = input.trajectory_confidence {
        prompt.push_str(&format!("\n## Trajectory confidence\n{:.3}\n", c));
    }
    prompt.push_str("\nRespond with the JSON only.");
    prompt
}

/// Parse the raw model text into the three LLM-produced fields. Tolerant to
/// extra prose: extracts the first `{...}` block, parses it, and validates.
/// Returns `None` on any failure — caller should fall back to heuristic.
fn parse_reflection_response(
    text: &str,
) -> Option<(Option<ErrorPattern>, Vec<ImprovementTarget>, String)> {
    // Extract the first JSON object. Tolerant to code fences / stray text.
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end <= start {
        return None;
    }
    let blob = &text[start..=end];
    let val: serde_json::Value = serde_json::from_str(blob).ok()?;

    let error_pattern = match val.get("error_pattern") {
        Some(serde_json::Value::String(s)) => ErrorPattern::from_str(s),
        // explicit null or missing → None
        _ => None,
    };

    let improvements = match val.get("improvements") {
        Some(serde_json::Value::Array(arr)) => arr
            .iter()
            .filter_map(|item| {
                let directive = item.get("directive")?.as_str()?.trim().to_string();
                if directive.is_empty() {
                    return None;
                }
                let priority = match item.get("priority").and_then(|p| p.as_str()) {
                    Some("high") => Priority::High,
                    Some("medium") => Priority::Medium,
                    Some("low") => Priority::Low,
                    // default unknown → medium (don't drop the whole item)
                    _ => Priority::Medium,
                };
                let scope = item
                    .get("scope")
                    .and_then(|s| s.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());
                Some(ImprovementTarget {
                    directive,
                    priority,
                    scope,
                    actioned_as: None,
                })
            })
            .collect(),
        _ => Vec::new(),
    };

    let hypothesis = val
        .get("hypothesis")
        .and_then(|h| h.as_str())
        .map(|s| s.trim().to_string())
        .unwrap_or_default();

    // Require at least one of the three to be meaningful — otherwise the model
    // gave us nothing and we should fall back to heuristic.
    if error_pattern.is_none() && improvements.is_empty() && hypothesis.is_empty() {
        return None;
    }
    Some((error_pattern, improvements, hypothesis))
}

/// Build a Reflection via a live Provider. Takes a full `ReflectionInput` so
/// callers can build it once and share with the heuristic fallback.
///
/// Fallback contract: on ANY failure (provider error, empty response,
/// unparseable JSON, or a response that gave zero useful signal) this returns
/// the heuristic reflection with the same inputs — never a partially-formed
/// Reflection.
pub async fn reflect_via_provider(
    provider: &dyn axonerai::provider::Provider,
    input: ReflectionInput,
) -> Reflection {
    let prompt = build_reflect_prompt(&input);
    let messages = vec![axonerai::provider::Message {
        role: "user".to_string(),
        content: prompt,
    }];

    let parsed = match provider.complete(messages, None, Some(400), None).await {
        Ok(resp) => {
            let text = resp.text.unwrap_or_default();
            parse_reflection_response(&text)
        }
        Err(e) => {
            tracing::warn!(error = %e, "reflection provider error; falling back to heuristic");
            None
        }
    };

    match parsed {
        Some((error_pattern, improvements, hypothesis)) => Reflection {
            id: None,
            episode_id: None,
            intended_goal: input.intended_goal,
            observed_outcome: input.observed_outcome,
            outcome_class: input.outcome_class,
            error_pattern,
            improvements,
            hypothesis,
            surprisal_at_reflect: input.surprisal,
            confidence_at_reflect: input.trajectory_confidence,
            created_at: now_iso(),
        },
        None => reflect_heuristic(
            &input.intended_goal,
            &input.observed_outcome,
            input.outcome_class,
            &input.tool_errors,
            input.surprisal,
            input.trajectory_confidence,
        ),
    }
}

/// Entry point most callers should use: if `CHUMP_REFLECTION_LLM=1` is set and
/// a provider is available, run [`reflect_via_provider`]; otherwise return the
/// heuristic. This keeps call sites uniform and lets the env flag flip cleanly.
pub async fn reflect_or_fallback(
    provider: Option<&dyn axonerai::provider::Provider>,
    input: ReflectionInput,
) -> Reflection {
    if reflection_llm_enabled() {
        if let Some(p) = provider {
            return reflect_via_provider(p, input).await;
        }
    }
    reflect_heuristic(
        &input.intended_goal,
        &input.observed_outcome,
        input.outcome_class,
        &input.tool_errors,
        input.surprisal,
        input.trajectory_confidence,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pass_outcome_produces_no_error_pattern() {
        let r = reflect_heuristic(
            "run tests",
            "all tests passed",
            OutcomeClass::Pass,
            &[],
            Some(0.05),
            Some(0.9),
        );
        assert_eq!(r.outcome_class, OutcomeClass::Pass);
        assert!(r.error_pattern.is_none());
        assert!(r.improvements.is_empty());
    }

    #[test]
    fn detects_tool_misuse_from_errors() {
        let r = reflect_heuristic(
            "edit file",
            "write failed",
            OutcomeClass::Failure,
            &["No such file or directory: foo.txt".into()],
            None,
            None,
        );
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        assert!(!r.improvements.is_empty());
        assert_eq!(r.improvements[0].priority, Priority::High);
    }

    #[test]
    fn detects_narration_from_text() {
        let r = reflect_heuristic(
            "update the README",
            "I would edit the file to add the note about Ollama",
            OutcomeClass::Failure,
            &[],
            None,
            None,
        );
        assert_eq!(r.error_pattern, Some(ErrorPattern::NarratedInsteadOfActed));
    }

    #[test]
    fn detects_ambiguity() {
        let r = reflect_heuristic(
            "clean things up",
            "not clear what the user meant by clean",
            OutcomeClass::Abandoned,
            &[],
            Some(0.8),
            Some(0.3),
        );
        assert_eq!(r.error_pattern, Some(ErrorPattern::UnresolvedAmbiguity));
    }

    #[test]
    fn detects_timeout_from_tool_errors() {
        let r = reflect_heuristic(
            "run long operation",
            "failed",
            OutcomeClass::Failure,
            &["tool timed out after 30s".into()],
            None,
            None,
        );
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolFailure));
    }

    #[test]
    fn detects_budget_exhausted() {
        let r = reflect_heuristic(
            "complex task",
            "hit max iterations",
            OutcomeClass::Abandoned,
            &[],
            None,
            None,
        );
        assert_eq!(r.error_pattern, Some(ErrorPattern::BudgetExhausted));
    }

    #[test]
    fn outcome_class_roundtrip() {
        for c in [
            OutcomeClass::Pass,
            OutcomeClass::PartialSuccess,
            OutcomeClass::Failure,
            OutcomeClass::Abandoned,
        ] {
            let s = c.as_str();
            assert_eq!(OutcomeClass::from_str(s), c);
        }
    }

    #[test]
    fn error_pattern_roundtrip() {
        for p in [
            ErrorPattern::MisinterpretedGoal,
            ErrorPattern::ToolMisuse,
            ErrorPattern::UnexpectedToolOutput,
            ErrorPattern::ToolFailure,
            ErrorPattern::NonconvergentLoop,
            ErrorPattern::BudgetExhausted,
            ErrorPattern::NarratedInsteadOfActed,
            ErrorPattern::UnresolvedAmbiguity,
            ErrorPattern::ExternalFailure,
            ErrorPattern::Other,
        ] {
            assert_eq!(ErrorPattern::from_str(p.as_str()), Some(p));
        }
    }

    #[test]
    fn hypothesis_builds_from_signals() {
        let h = build_hypothesis(
            Some(ErrorPattern::ToolMisuse),
            &["validation failed".into()],
            Some(0.7),
            Some(0.2),
        );
        assert!(h.contains("tool_misuse"));
        assert!(h.contains("validation failed"));
        assert!(h.contains("Surprisal"));
        assert!(h.contains("Trajectory"));
    }

    #[test]
    fn serialization_roundtrip() {
        let r = reflect_heuristic(
            "test",
            "worked",
            OutcomeClass::Pass,
            &[],
            Some(0.1),
            Some(0.9),
        );
        let json = serde_json::to_string(&r).unwrap();
        let r2: Reflection = serde_json::from_str(&json).unwrap();
        assert_eq!(r2.outcome_class, r.outcome_class);
        assert_eq!(r2.intended_goal, r.intended_goal);
    }

    // ── COG-008: async adapter tests ──────────────────────────────────
    //
    // Mirrors the pattern from eval_harness.rs (EVAL-004) and memory_db.rs
    // (MEM-004): a single StubProvider with a canned response, exercised
    // across happy-path, malformed-JSON, provider-error, and env-gate
    // branches.

    struct StubProvider {
        response_text: String,
        should_fail: bool,
    }

    impl StubProvider {
        fn ok(text: &str) -> Self {
            Self {
                response_text: text.to_string(),
                should_fail: false,
            }
        }
        fn err() -> Self {
            Self {
                response_text: String::new(),
                should_fail: true,
            }
        }
    }

    #[async_trait::async_trait]
    impl axonerai::provider::Provider for StubProvider {
        async fn complete(
            &self,
            _messages: Vec<axonerai::provider::Message>,
            _tools: Option<Vec<axonerai::provider::Tool>>,
            _max_tokens: Option<u32>,
            _system_prompt: Option<String>,
        ) -> anyhow::Result<axonerai::provider::CompletionResponse> {
            if self.should_fail {
                return Err(anyhow::anyhow!("stub provider error"));
            }
            Ok(axonerai::provider::CompletionResponse {
                text: Some(self.response_text.clone()),
                tool_calls: vec![],
                stop_reason: axonerai::provider::StopReason::EndTurn,
            })
        }
    }

    fn failure_input() -> ReflectionInput {
        ReflectionInput {
            intended_goal: "edit the config file".into(),
            observed_outcome: "write failed on missing path".into(),
            outcome_class: OutcomeClass::Failure,
            tool_errors: vec!["No such file or directory: config.toml".into()],
            surprisal: Some(0.6),
            trajectory_confidence: Some(0.3),
        }
    }

    #[test]
    fn build_reflect_prompt_contains_rubric_and_context() {
        let p = build_reflect_prompt(&failure_input());
        // The prompt must ask for exactly one JSON object.
        assert!(
            p.contains("EXACTLY one JSON object"),
            "prompt must pin response format"
        );
        // Must list all valid error_pattern strings so a small model has the
        // full vocabulary in context.
        assert!(p.contains("tool_misuse"));
        assert!(p.contains("narrated_instead_of_acted"));
        // Must echo the inputs — otherwise the model is flying blind.
        assert!(p.contains("edit the config file"));
        assert!(p.contains("write failed"));
        assert!(p.contains("failure"));
        assert!(p.contains("config.toml"));
        assert!(p.contains("0.600"), "surprisal must be rendered");
    }

    #[test]
    fn build_reflect_prompt_omits_optional_sections_when_empty() {
        let mut input = failure_input();
        input.tool_errors.clear();
        input.surprisal = None;
        input.trajectory_confidence = None;
        let p = build_reflect_prompt(&input);
        assert!(!p.contains("Tool errors"));
        assert!(!p.contains("Surprisal EMA"));
        assert!(!p.contains("Trajectory confidence"));
    }

    #[test]
    fn parse_reflection_response_happy_path() {
        let raw = r#"{
          "error_pattern": "tool_misuse",
          "improvements": [
            {"directive": "check path exists before writing", "priority": "high", "scope": "tool_middleware"}
          ],
          "hypothesis": "agent skipped a precondition check"
        }"#;
        let (pat, imps, hyp) = parse_reflection_response(raw).expect("must parse");
        assert_eq!(pat, Some(ErrorPattern::ToolMisuse));
        assert_eq!(imps.len(), 1);
        assert_eq!(imps[0].priority, Priority::High);
        assert_eq!(imps[0].scope.as_deref(), Some("tool_middleware"));
        assert!(hyp.contains("precondition"));
    }

    #[test]
    fn parse_reflection_response_extracts_json_from_prose() {
        // Models often wrap JSON in commentary. The parser should recover.
        let raw = "Sure, here's the analysis:\n\
                   {\"error_pattern\": \"budget_exhausted\", \"improvements\": [], \
                    \"hypothesis\": \"agent hit iteration cap\"}\n\
                   Hope this helps.";
        let (pat, imps, hyp) = parse_reflection_response(raw).expect("must parse");
        assert_eq!(pat, Some(ErrorPattern::BudgetExhausted));
        assert!(imps.is_empty());
        assert!(hyp.contains("iteration cap"));
    }

    #[test]
    fn parse_reflection_response_rejects_empty_result() {
        // If every field is empty/missing, parser returns None so caller falls
        // back to heuristic. This prevents a no-signal JSON from being treated
        // as a valid reflection.
        let raw = r#"{"error_pattern": null, "improvements": [], "hypothesis": ""}"#;
        assert!(parse_reflection_response(raw).is_none());
    }

    #[test]
    fn parse_reflection_response_unknown_priority_defaults_medium() {
        let raw = r#"{"error_pattern": null, "improvements": [
          {"directive": "do thing", "priority": "urgent", "scope": null}
        ], "hypothesis": "ok"}"#;
        let (_, imps, _) = parse_reflection_response(raw).expect("must parse");
        assert_eq!(imps[0].priority, Priority::Medium);
        assert!(imps[0].scope.is_none());
    }

    #[test]
    fn parse_reflection_response_malformed_returns_none() {
        assert!(parse_reflection_response("not json at all").is_none());
        assert!(parse_reflection_response("{broken: yaml}").is_none());
        assert!(parse_reflection_response("").is_none());
    }

    #[tokio::test]
    async fn reflect_via_provider_parses_structured_json() {
        let stub = StubProvider::ok(
            r#"{"error_pattern": "tool_misuse", "improvements": [
                {"directive": "validate path first", "priority": "high", "scope": "tool_middleware"}
              ], "hypothesis": "precondition check missing"}"#,
        );
        let r = reflect_via_provider(&stub, failure_input()).await;
        assert_eq!(r.outcome_class, OutcomeClass::Failure);
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        assert_eq!(r.improvements.len(), 1);
        assert_eq!(r.improvements[0].priority, Priority::High);
        assert!(r.hypothesis.contains("precondition"));
        // Original input fields preserved:
        assert_eq!(r.intended_goal, "edit the config file");
        assert_eq!(r.surprisal_at_reflect, Some(0.6));
    }

    #[tokio::test]
    async fn reflect_via_provider_falls_back_on_provider_error() {
        let stub = StubProvider::err();
        let r = reflect_via_provider(&stub, failure_input()).await;
        // Heuristic fallback kicks in — tool_errors contain "No such file"
        // which heuristic classifies as ToolMisuse.
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        assert!(!r.improvements.is_empty());
    }

    #[tokio::test]
    async fn reflect_via_provider_falls_back_on_unparseable_response() {
        let stub = StubProvider::ok("I don't know, this is hard to evaluate.");
        let r = reflect_via_provider(&stub, failure_input()).await;
        // Again, fallback to heuristic — a broken model MUST NOT produce a
        // Reflection with no error_pattern / empty improvements for a failure.
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        assert!(
            !r.improvements.is_empty(),
            "heuristic fallback must populate improvements"
        );
    }

    #[tokio::test]
    async fn reflect_via_provider_falls_back_on_empty_json() {
        let stub =
            StubProvider::ok(r#"{"error_pattern": null, "improvements": [], "hypothesis": ""}"#);
        let r = reflect_via_provider(&stub, failure_input()).await;
        // No-signal JSON → fallback → heuristic picks up ToolMisuse from errors.
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn reflect_or_fallback_uses_heuristic_when_env_unset() {
        std::env::remove_var("CHUMP_REFLECTION_LLM");
        // Even with a "good" stub present, env-off means heuristic path.
        let stub = StubProvider::ok(
            r#"{"error_pattern": "other", "improvements": [], "hypothesis": "from llm"}"#,
        );
        let r = reflect_or_fallback(Some(&stub), failure_input()).await;
        // Heuristic path on ToolMisuse input → ToolMisuse, NOT "other" from stub.
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        assert!(
            !r.hypothesis.contains("from llm"),
            "env-off must NOT have called provider"
        );
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn reflect_or_fallback_calls_provider_when_env_set() {
        std::env::set_var("CHUMP_REFLECTION_LLM", "1");
        let stub = StubProvider::ok(
            r#"{"error_pattern": "nonconvergent_loop", "improvements": [
                {"directive": "break out of repeated-tool loop", "priority": "high", "scope": "agent_loop"}
              ], "hypothesis": "kept calling same tool"}"#,
        );
        let r = reflect_or_fallback(Some(&stub), failure_input()).await;
        assert_eq!(r.error_pattern, Some(ErrorPattern::NonconvergentLoop));
        assert!(r.hypothesis.contains("same tool"));
        std::env::remove_var("CHUMP_REFLECTION_LLM");
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn reflect_or_fallback_heuristic_when_no_provider() {
        std::env::set_var("CHUMP_REFLECTION_LLM", "1");
        // env set but no provider → still heuristic, no panic.
        let r = reflect_or_fallback(None, failure_input()).await;
        assert_eq!(r.error_pattern, Some(ErrorPattern::ToolMisuse));
        std::env::remove_var("CHUMP_REFLECTION_LLM");
    }

    #[test]
    #[serial_test::serial]
    fn reflection_llm_enabled_respects_env() {
        std::env::remove_var("CHUMP_REFLECTION_LLM");
        assert!(!reflection_llm_enabled());
        std::env::set_var("CHUMP_REFLECTION_LLM", "0");
        assert!(!reflection_llm_enabled(), "only '1' enables");
        std::env::set_var("CHUMP_REFLECTION_LLM", "1");
        assert!(reflection_llm_enabled());
        std::env::remove_var("CHUMP_REFLECTION_LLM");
    }
}
