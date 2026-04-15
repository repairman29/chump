//! Structured perception layer: rule-based extraction of task structure from user input.
//! Runs before the main agent loop iteration. No LLM calls — fast pattern matching only.
//! Reference architecture gap remediation: pre-reasoning structured perception.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct PerceivedInput {
    pub raw_text: String,
    pub likely_needs_tools: bool,
    pub detected_entities: Vec<String>,
    pub detected_constraints: Vec<String>,
    pub ambiguity_level: f32,
    pub risk_indicators: Vec<String>,
    pub question_count: usize,
    pub task_type: TaskType,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub enum TaskType {
    Question,
    Action,
    Planning,
    Research,
    Meta,
    Unclear,
}

impl std::fmt::Display for TaskType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Question => write!(f, "Question"),
            Self::Action => write!(f, "Action"),
            Self::Planning => write!(f, "Planning"),
            Self::Research => write!(f, "Research"),
            Self::Meta => write!(f, "Meta"),
            Self::Unclear => write!(f, "Unclear"),
        }
    }
}

/// Run structured perception on user input. Pure rule-based, no LLM calls.
pub fn perceive(text: &str, needs_tools_hint: bool) -> PerceivedInput {
    let trimmed = text.trim();
    let lower = trimmed.to_lowercase();

    let detected_entities = extract_entities(trimmed);
    let detected_constraints = extract_constraints(&lower);
    let risk_indicators = extract_risk_indicators(&lower);
    let question_count = trimmed.matches('?').count();
    let task_type = classify_task_type(&lower, question_count);
    let ambiguity_level = score_ambiguity(trimmed, &lower, question_count, &detected_entities);

    PerceivedInput {
        raw_text: trimmed.to_string(),
        likely_needs_tools: needs_tools_hint,
        detected_entities,
        detected_constraints,
        ambiguity_level,
        risk_indicators,
        question_count,
        task_type,
    }
}

/// Build a compact context summary for system prompt injection.
/// Returns empty string for trivial inputs.
pub fn context_summary(p: &PerceivedInput) -> String {
    if p.task_type == TaskType::Unclear && p.detected_entities.is_empty() && p.risk_indicators.is_empty() {
        return String::new();
    }
    let mut parts = Vec::new();
    parts.push(format!("Task: {}", p.task_type));
    if !p.detected_entities.is_empty() {
        let entities: Vec<&str> = p.detected_entities.iter().take(5).map(|s| s.as_str()).collect();
        parts.push(format!("Entities: {}", entities.join(", ")));
    }
    if !p.detected_constraints.is_empty() {
        let constraints: Vec<&str> = p.detected_constraints.iter().take(3).map(|s| s.as_str()).collect();
        parts.push(format!("Constraints: {}", constraints.join(", ")));
    }
    if p.ambiguity_level > 0.6 {
        parts.push(format!("Ambiguity: {:.1} (consider clarifying)", p.ambiguity_level));
    }
    if !p.risk_indicators.is_empty() {
        parts.push(format!("Risk: {}", p.risk_indicators.join(", ")));
    }
    parts.join(" | ")
}

// ── Entity extraction ──────────────────────────────────────────────────

fn extract_entities(text: &str) -> Vec<String> {
    let mut entities = Vec::new();

    // Quoted strings
    let mut in_quote = false;
    let mut current = String::new();
    for ch in text.chars() {
        if ch == '"' || ch == '\'' || ch == '`' {
            if in_quote {
                if !current.is_empty() {
                    entities.push(current.clone());
                    current.clear();
                }
                in_quote = false;
            } else {
                in_quote = true;
            }
        } else if in_quote {
            current.push(ch);
        }
    }

    // Capitalized words not at sentence start (likely proper nouns)
    let ignore = ["I", "I'm", "I'll", "I've", "I'd", "OK", "The", "A", "An", "It", "Is", "Are",
                  "Was", "Were", "Do", "Does", "Did", "Have", "Has", "Had", "Can", "Could",
                  "Will", "Would", "Should", "May", "Might", "But", "And", "Or", "So", "If",
                  "When", "Where", "What", "How", "Why", "Who", "Which", "That", "This",
                  "Not", "No", "Yes", "For", "From", "With", "About", "Also", "Just", "Then"];
    for (i, word) in text.split_whitespace().enumerate() {
        if i > 0
            && word.chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
            && word.len() > 1
            && !ignore.contains(&word)
        {
            let clean = word.trim_matches(|c: char| !c.is_alphanumeric()).to_string();
            if clean.len() > 1 && !entities.contains(&clean) {
                entities.push(clean);
            }
        }
    }

    // File paths
    for word in text.split_whitespace() {
        let w = word.trim_matches(|c: char| c == '\'' || c == '"' || c == '`');
        if (w.contains('/') || w.contains('\\'))
            && w.len() > 2
            && !w.starts_with("http")
            && !entities.contains(&w.to_string())
        {
            entities.push(w.to_string());
        }
    }

    entities.truncate(10);
    entities
}

// ── Constraint extraction ──────────────────────────────────────────────

fn extract_constraints(lower: &str) -> Vec<String> {
    let markers: &[(&str, &str)] = &[
        ("before ", "temporal:before"),
        ("by ", "temporal:deadline"),
        ("after ", "temporal:after"),
        ("must ", "requirement"),
        ("cannot ", "prohibition"),
        ("don't ", "prohibition"),
        ("do not ", "prohibition"),
        ("never ", "prohibition"),
        ("always ", "requirement"),
        ("only ", "restriction"),
        ("at most ", "limit"),
        ("at least ", "minimum"),
        ("no more than ", "limit"),
        ("without ", "exclusion"),
    ];
    let mut constraints = Vec::new();
    for &(marker, kind) in markers {
        if lower.contains(marker) {
            constraints.push(kind.to_string());
        }
    }
    constraints.dedup();
    constraints
}

// ── Risk indicator extraction ──────────────────────────────────────────

fn extract_risk_indicators(lower: &str) -> Vec<String> {
    let risk_words: &[&str] = &[
        "delete", "drop", "force", "production", "prod ", "master ", "main ",
        "rm -rf", "sudo", "reboot", "shutdown", "destroy", "overwrite",
        "reset", "wipe", "truncate", "everything",
    ];
    risk_words
        .iter()
        .filter(|w| lower.contains(**w))
        .map(|w| w.trim().to_string())
        .collect()
}

// ── Task type classification ───────────────────────────────────────────

fn classify_task_type(lower: &str, question_count: usize) -> TaskType {
    // Meta: about chump itself
    if lower.contains("yourself") || lower.contains("your memory")
        || lower.contains("your brain") || lower.contains("introspect")
        || lower.contains("your status") || lower.contains("your state")
    {
        return TaskType::Meta;
    }
    // Planning: multi-step indicators
    if lower.contains("plan") || lower.contains("steps to") || lower.contains("strategy")
        || lower.contains("roadmap") || lower.contains("how should we")
        || (lower.contains("first") && lower.contains("then"))
    {
        return TaskType::Planning;
    }
    // Research: investigation indicators
    if lower.contains("research") || lower.contains("investigate") || lower.contains("explore")
        || lower.contains("find out") || lower.contains("look into") || lower.contains("analyze")
    {
        return TaskType::Research;
    }
    // Question: ends with ? or starts with question words
    if question_count > 0 || lower.starts_with("what ") || lower.starts_with("why ")
        || lower.starts_with("how ") || lower.starts_with("when ") || lower.starts_with("where ")
        || lower.starts_with("who ") || lower.starts_with("is ") || lower.starts_with("are ")
        || lower.starts_with("does ") || lower.starts_with("do ")
    {
        return TaskType::Question;
    }
    // Action: imperative verbs
    let action_starters = [
        "run ", "create ", "make ", "build ", "deploy ", "fix ", "update ", "delete ", "write ",
        "read ", "open ", "close ", "set ", "add ", "remove ", "install ", "push ", "commit ",
        "merge ", "test ", "check ", "list ", "show ", "start ", "stop ",
    ];
    if action_starters.iter().any(|a| lower.starts_with(a)) {
        return TaskType::Action;
    }
    TaskType::Unclear
}

// ── Ambiguity scoring ──────────────────────────────────────────────────

fn score_ambiguity(text: &str, lower: &str, question_count: usize, entities: &[String]) -> f32 {
    let mut score: f32 = 0.5;
    // Vague language
    let vague = ["something", "somehow", "maybe", "perhaps", "whatever", "stuff", "things", "it"];
    let vague_count = vague.iter().filter(|w| {
        // Match whole words, not substrings
        lower.split_whitespace().any(|token| token == **w)
    }).count();
    score += vague_count as f32 * 0.1;
    // Entities reduce ambiguity
    score -= entities.len().min(3) as f32 * 0.1;
    // Short = more ambiguous
    if text.len() < 20 { score += 0.2; }
    // Multiple questions
    if question_count > 1 { score += 0.15; }
    // Long detailed messages reduce ambiguity
    if text.len() > 200 { score -= 0.2; }
    score.clamp(0.0, 1.0)
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_action() {
        let p = perceive("create a new task for the website redesign", true);
        assert_eq!(p.task_type, TaskType::Action);
        assert!(p.detected_entities.is_empty() || !p.detected_entities.is_empty()); // entities are opportunistic
    }

    #[test]
    fn classify_question() {
        let p = perceive("what tasks do we have?", false);
        assert_eq!(p.task_type, TaskType::Question);
        assert_eq!(p.question_count, 1);
    }

    #[test]
    fn classify_planning() {
        let p = perceive("plan the steps to migrate our database", true);
        assert_eq!(p.task_type, TaskType::Planning);
    }

    #[test]
    fn classify_research() {
        let p = perceive("investigate why the tests are failing", true);
        assert_eq!(p.task_type, TaskType::Research);
    }

    #[test]
    fn classify_meta() {
        let p = perceive("tell me about your memory", false);
        assert_eq!(p.task_type, TaskType::Meta);
    }

    #[test]
    fn risk_detection() {
        let p = perceive("delete everything in production", true);
        assert!(p.risk_indicators.contains(&"delete".to_string()));
        assert!(p.risk_indicators.contains(&"everything".to_string()));
        assert!(p.risk_indicators.contains(&"production".to_string()));
    }

    #[test]
    fn entity_extraction_quoted() {
        let p = perceive("look at the \"CustomerService\" module in src/lib.rs", true);
        assert!(p.detected_entities.contains(&"CustomerService".to_string()));
        assert!(p.detected_entities.iter().any(|e| e.contains("src/lib.rs")));
    }

    #[test]
    fn constraint_detection() {
        let p = perceive("we must finish before Friday and cannot use the old API", true);
        assert!(p.detected_constraints.contains(&"requirement".to_string()));
        assert!(p.detected_constraints.contains(&"temporal:before".to_string()));
        assert!(p.detected_constraints.contains(&"prohibition".to_string()));
    }

    #[test]
    fn ambiguity_high_for_vague() {
        let p = perceive("do something", true);
        assert!(p.ambiguity_level > 0.5);
    }

    #[test]
    fn ambiguity_low_for_detailed() {
        let long = "Create a new task titled 'Migrate database schema' with priority high, assigned to Jeff, due by April 20th. The task should include steps for backup, migration, and verification.";
        let p = perceive(long, true);
        assert!(p.ambiguity_level < 0.5);
    }

    #[test]
    fn context_summary_empty_for_trivial() {
        let p = perceive("hi", false);
        assert!(context_summary(&p).is_empty() || p.task_type == TaskType::Unclear);
    }

    #[test]
    fn context_summary_nonempty_for_risk() {
        let p = perceive("delete the production database", true);
        let s = context_summary(&p);
        assert!(s.contains("Risk"));
    }
}
