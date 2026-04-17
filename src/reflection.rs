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
//! ## V2 (future)
//!
//! - LLM-assisted reflection via the delegate worker (richer analysis)
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
}
