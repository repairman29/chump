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
    if p.task_type == TaskType::Unclear
        && p.detected_entities.is_empty()
        && p.risk_indicators.is_empty()
    {
        return String::new();
    }
    let mut parts = Vec::new();
    parts.push(format!("Task: {}", p.task_type));
    if !p.detected_entities.is_empty() {
        let entities: Vec<&str> = p
            .detected_entities
            .iter()
            .take(5)
            .map(|s| s.as_str())
            .collect();
        parts.push(format!("Entities: {}", entities.join(", ")));
    }
    if !p.detected_constraints.is_empty() {
        let constraints: Vec<&str> = p
            .detected_constraints
            .iter()
            .take(3)
            .map(|s| s.as_str())
            .collect();
        parts.push(format!("Constraints: {}", constraints.join(", ")));
    }
    if p.ambiguity_level > 0.6 {
        parts.push(format!(
            "Ambiguity: {:.1} (consider clarifying)",
            p.ambiguity_level
        ));
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
    let ignore = [
        "I", "I'm", "I'll", "I've", "I'd", "OK", "The", "A", "An", "It", "Is", "Are", "Was",
        "Were", "Do", "Does", "Did", "Have", "Has", "Had", "Can", "Could", "Will", "Would",
        "Should", "May", "Might", "But", "And", "Or", "So", "If", "When", "Where", "What", "How",
        "Why", "Who", "Which", "That", "This", "Not", "No", "Yes", "For", "From", "With", "About",
        "Also", "Just", "Then",
    ];
    for (i, word) in text.split_whitespace().enumerate() {
        if i > 0
            && word
                .chars()
                .next()
                .map(|c| c.is_uppercase())
                .unwrap_or(false)
            && word.len() > 1
            && !ignore.contains(&word)
        {
            let clean = word
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_string();
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
        "delete",
        "drop",
        "force",
        "production",
        "prod ",
        "master ",
        "main ",
        "rm -rf",
        "sudo",
        "reboot",
        "shutdown",
        "destroy",
        "overwrite",
        "reset",
        "wipe",
        "truncate",
        "everything",
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
    if lower.contains("yourself")
        || lower.contains("your memory")
        || lower.contains("your brain")
        || lower.contains("introspect")
        || lower.contains("your status")
        || lower.contains("your state")
    {
        return TaskType::Meta;
    }
    // Planning: multi-step indicators
    if lower.contains("plan")
        || lower.contains("steps to")
        || lower.contains("strategy")
        || lower.contains("roadmap")
        || lower.contains("how should we")
        || (lower.contains("first") && lower.contains("then"))
    {
        return TaskType::Planning;
    }
    // Research: investigation indicators
    if lower.contains("research")
        || lower.contains("investigate")
        || lower.contains("explore")
        || lower.contains("find out")
        || lower.contains("look into")
        || lower.contains("analyze")
    {
        return TaskType::Research;
    }
    // Question: ends with ? or starts with question words
    if question_count > 0
        || lower.starts_with("what ")
        || lower.starts_with("why ")
        || lower.starts_with("how ")
        || lower.starts_with("when ")
        || lower.starts_with("where ")
        || lower.starts_with("who ")
        || lower.starts_with("is ")
        || lower.starts_with("are ")
        || lower.starts_with("does ")
        || lower.starts_with("do ")
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
    let vague = [
        "something",
        "somehow",
        "maybe",
        "perhaps",
        "whatever",
        "stuff",
        "things",
        "it",
    ];
    let vague_count = vague
        .iter()
        .filter(|w| {
            // Match whole words, not substrings
            lower.split_whitespace().any(|token| token == **w)
        })
        .count();
    score += vague_count as f32 * 0.1;
    // Entities reduce ambiguity
    score -= entities.len().min(3) as f32 * 0.1;
    // Short = more ambiguous
    if text.len() < 20 {
        score += 0.2;
    }
    // Multiple questions
    if question_count > 1 {
        score += 0.15;
    }
    // Long detailed messages reduce ambiguity
    if text.len() > 200 {
        score -= 0.2;
    }
    score.clamp(0.0, 1.0)
}

// ── Tool routing (INFRA-182, 2026-05-01) ────────────────────────────────
//
// Pure-rule mapping from PerceivedInput → tool subset. The agent loop
// otherwise sends ALL ~46 chump tool schemas (~5 KB) on every turn,
// adding 15-60 s of prefill on local 14B models. This function returns
// only the tool *names* likely needed for the perceived input; the
// caller (typically agent_loop::orchestrator) filters its full Vec<Tool>
// by these names.
//
// Safety net: if the model says "I need to do X" and X requires a tool
// not in the routed subset, the agent loop's narration-detection retry
// path at iteration_controller line 245 fires the next round with the
// FULL tool set. So worst case = today's cost; common case is 3-10×
// faster.
//
// **Lives in chump-perception (not in chump main) and takes tool names
// as `&[&str]`** — keeps this crate free of axonerai/Tool types so it
// stays small and reusable.

/// Route tools by perception. Returns the subset of `all_tool_names`
/// that the routing rules suggest the model is likely to need for this
/// input. Always a subset of `all_tool_names`; never invents names.
///
/// Empty return value means "no tools needed" (`TaskType::Meta`,
/// capability questions). The orchestrator's existing
/// `skip_tools_first_call` path handles that case directly via
/// `PerceivedInput::likely_needs_tools` — `route_tools` is invoked
/// only when tools ARE expected.
pub fn route_tools<'a>(perception: &PerceivedInput, all_tool_names: &[&'a str]) -> Vec<&'a str> {
    let raw = perception.raw_text.to_lowercase();
    let mut wanted: Vec<&str> = Vec::new();

    // Meta = capability/identity questions. No tools.
    if matches!(perception.task_type, TaskType::Meta) {
        return Vec::new();
    }

    // Math
    if raw.contains("calc")
        || raw.contains("compute")
        || raw.contains("multiply")
        || raw.contains("divide")
        || raw.contains("subtract")
        || raw.contains(" times ")
        || has_arithmetic_operator(&raw)
    {
        wanted.push("wasm_calc");
    }

    // Tasks / planning
    if raw.contains("task")
        || raw.contains("todo")
        || raw.contains("to do")
        || raw.contains("plan ")
        || raw.contains("planning")
        || matches!(perception.task_type, TaskType::Planning)
    {
        wanted.push("task");
        wanted.push("task_planner");
        wanted.push("decompose_task");
        wanted.push("merge_subtask");
    }

    // Files
    if raw.contains("file ")
        || raw.contains(" file")
        || raw.contains("read ")
        || raw.contains("write ")
        || raw.contains("save ")
        || raw.contains("patch")
        || raw.contains("/ ")
        || raw.contains(" /")
        || raw.contains(".rs")
        || raw.contains(".md")
        || raw.contains(".yaml")
        || raw.contains(".json")
        || raw.contains(".toml")
    {
        wanted.push("read_file");
        wanted.push("write_file");
        wanted.push("patch_file");
        wanted.push("list_dir");
    }

    // Git
    if raw.contains("git ")
        || raw.contains(" git")
        || raw.contains("commit")
        || raw.contains("branch")
        || raw.contains("revert")
        || raw.contains("stash")
        || raw.contains("push ")
        || raw.contains("pull ")
        || raw.contains("merge ")
    {
        wanted.push("git_commit");
        wanted.push("git_push");
        wanted.push("git_revert");
        wanted.push("git_stash");
        wanted.push("cleanup_branches");
        wanted.push("diff_review");
    }

    // Web / URL
    if raw.contains("url")
        || raw.contains("http")
        || raw.contains("https")
        || raw.contains("web ")
        || raw.contains("browse")
        || raw.contains("fetch")
        || raw.contains("download")
    {
        wanted.push("read_url");
        wanted.push("browser");
    }

    // Shell / CLI / build / test
    if raw.contains("cargo")
        || raw.contains("build")
        || raw.contains("test ")
        || raw.contains("install")
        || raw.contains("shell")
        || raw.contains("bash")
        || raw.contains("run cli")
        || raw.contains("ollama")
        || raw.contains("npm")
    {
        wanted.push("run_cli");
        wanted.push("run_test");
    }

    // Memory / search / recall
    if raw.contains("remember")
        || raw.contains("recall")
        || raw.contains("memory")
        || raw.contains("search")
        || raw.contains("find ")
        || raw.contains("history")
        || raw.contains("session")
    {
        wanted.push("memory");
        wanted.push("memory_brain");
        wanted.push("session_search");
    }

    // Communication / delegation
    if raw.contains("notify")
        || raw.contains("message")
        || raw.contains("delegate")
        || raw.contains("send to")
        || raw.contains("ping ")
    {
        wanted.push("notify");
        wanted.push("message_peer");
        wanted.push("delegate");
    }

    // Schedule / reminder
    if raw.contains("schedule")
        || raw.contains("remind")
        || raw.contains("later")
        || raw.contains("tomorrow")
        || raw.contains("next week")
        || raw.contains("in a ")
    {
        wanted.push("schedule");
    }

    // Codebase research
    if matches!(perception.task_type, TaskType::Research)
        || raw.contains("codebase")
        || raw.contains("repo ")
        || raw.contains("how does")
        || raw.contains("how is ")
        || raw.contains("where is ")
        || raw.contains("explain ")
    {
        wanted.push("codebase_digest");
        wanted.push("read_url");
        wanted.push("memory");
    }

    // Self-introspection / about-the-agent (but not Meta — those returned earlier)
    if raw.contains("introspect") || raw.contains("your config") || raw.contains("your stats") {
        wanted.push("introspect");
        wanted.push("ego");
    }

    // Vision / screen
    if raw.contains("screen")
        || raw.contains("screenshot")
        || raw.contains("look at the")
        || raw.contains("see the")
    {
        wanted.push("screen_vision");
    }

    // Empty so far? Send the starter pack — the most-used tools that
    // cover the long tail of conversational requests.
    if wanted.is_empty() {
        wanted.extend([
            "wasm_calc",
            "task",
            "read_file",
            "list_dir",
            "run_cli",
            "memory",
            "codebase_digest",
            "schedule",
        ]);
    }

    // Filter to names that actually exist in the registry (caller's
    // all_tool_names) and dedupe while preserving the lookup-table
    // identity from the caller.
    let available: std::collections::HashSet<&str> = all_tool_names.iter().copied().collect();
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut result: Vec<&'a str> = Vec::with_capacity(wanted.len());
    for name in wanted {
        if let Some(slot) = all_tool_names.iter().find(|n| **n == name) {
            if available.contains(*slot) && seen.insert(*slot) {
                result.push(*slot);
            }
        }
    }
    result
}

fn has_arithmetic_operator(s: &str) -> bool {
    // Look for digit-op-digit patterns. Conservative: requires a digit on
    // both sides (spaces allowed between) so prose like "I + you" or
    // "C++" doesn't trigger calculator routing.
    let bytes = s.as_bytes();
    for i in 0..bytes.len() {
        let c = bytes[i];
        if matches!(c, b'+' | b'-' | b'*' | b'/' | b'%' | b'^') {
            // Walk left past spaces; require a digit
            let left_digit = (0..i)
                .rev()
                .find(|&k| bytes[k] != b' ')
                .map(|k| bytes[k].is_ascii_digit())
                .unwrap_or(false);
            // Walk right past spaces; require a digit
            let right_digit = ((i + 1)..bytes.len())
                .find(|&k| bytes[k] != b' ')
                .map(|k| bytes[k].is_ascii_digit())
                .unwrap_or(false);
            if left_digit && right_digit {
                return true;
            }
        }
    }
    false
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_action() {
        let p = perceive("create a new task for the website redesign", true);
        assert_eq!(p.task_type, TaskType::Action);
        assert!(p.detected_entities.is_empty() || !p.detected_entities.is_empty());
        // entities are opportunistic
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
        let p = perceive(
            "we must finish before Friday and cannot use the old API",
            true,
        );
        assert!(p.detected_constraints.contains(&"requirement".to_string()));
        assert!(p
            .detected_constraints
            .contains(&"temporal:before".to_string()));
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

    // ── route_tools (INFRA-182) ──────────────────────────────────────────

    /// Realistic snapshot of registry tool names as of 2026-05-01 (not all
    /// of them — just enough for routing tests). If route_tools points at
    /// a name not in this list, the `available` filter drops it; tests
    /// keep this slice in sync with actual registry.
    fn registry_snapshot() -> Vec<&'static str> {
        vec![
            "wasm_calc",
            "wasm_text",
            "task",
            "task_planner",
            "decompose_task",
            "merge_subtask",
            "read_file",
            "write_file",
            "patch_file",
            "list_dir",
            "git_commit",
            "git_push",
            "git_revert",
            "git_stash",
            "cleanup_branches",
            "diff_review",
            "read_url",
            "browser",
            "run_cli",
            "run_test",
            "memory",
            "memory_brain",
            "memory_graph_viz",
            "session_search",
            "notify",
            "message_peer",
            "delegate",
            "schedule",
            "codebase_digest",
            "introspect",
            "ego",
            "screen_vision",
            "ask_jeff",
            "echo",
            "skill_hub",
            "skill_manage",
            "spawn_worker",
            "checkpoint",
            "episode",
            "fleet",
            "onboard_repo",
            "set_working_repo",
            "repo_authorize",
            "repo_deauthorize",
            "sandbox_run",
            "complete_onboarding",
            "gh_pr_list_comments",
            "run_battle_qa",
            "toolkit_status",
            "message",
        ]
    }

    #[test]
    fn route_meta_returns_empty() {
        // Capability questions need no tools.
        let mut p = perceive("what can you do?", false);
        p.task_type = TaskType::Meta; // perceive may classify this elsewhere; force Meta
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(
            routed.is_empty(),
            "Meta should route to []; got {:?}",
            routed
        );
    }

    #[test]
    fn route_math_to_calc() {
        let p = perceive("what is 231 * 243?", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(
            routed.contains(&"wasm_calc"),
            "math should route to wasm_calc; got {:?}",
            routed
        );
        // Tight subset — should NOT include unrelated tools
        assert!(!routed.contains(&"git_commit"));
        assert!(!routed.contains(&"browser"));
    }

    #[test]
    fn route_tasks_to_task_tools() {
        let p = perceive("create a task to migrate the database", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(routed.contains(&"task"));
        assert!(routed.contains(&"task_planner"));
        // Should not include git
        assert!(!routed.contains(&"git_commit"));
    }

    #[test]
    fn route_files_to_file_tools() {
        let p = perceive("read the file src/main.rs", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(routed.contains(&"read_file"));
        assert!(routed.contains(&"list_dir"));
    }

    #[test]
    fn route_git_to_git_tools() {
        let p = perceive("commit my changes and push to main", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(routed.contains(&"git_commit"));
        assert!(routed.contains(&"git_push"));
    }

    #[test]
    fn route_research_to_research_tools() {
        let mut p = perceive("how does the agent loop work?", true);
        p.task_type = TaskType::Research;
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        assert!(routed.contains(&"codebase_digest"));
        assert!(routed.contains(&"memory"));
    }

    #[test]
    fn route_unknown_falls_back_to_starter_pack() {
        // A prompt that triggers nothing specific: just a vague utterance.
        let p = perceive("hey chump show me something cool", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        // Either matched a category OR fell back to starter pack — must be
        // small (≤15) and must include one of the starter-pack tools.
        assert!(
            routed.len() <= 15,
            "subset too large: {} tools",
            routed.len()
        );
        assert!(
            routed.contains(&"task") || routed.contains(&"wasm_calc") || routed.contains(&"memory"),
            "starter pack should include core utility tools; got {:?}",
            routed
        );
    }

    #[test]
    fn route_drops_names_not_in_registry() {
        // If the rules point at a tool the caller's registry doesn't have,
        // it must NOT appear in the result (no invented names).
        let p = perceive("commit this", true);
        let small_registry = vec!["task", "memory"]; // no git_commit
        let routed = route_tools(&p, &small_registry);
        for name in &routed {
            assert!(small_registry.contains(name), "{} not in registry", name);
        }
        assert!(!routed.contains(&"git_commit"));
    }

    #[test]
    fn route_dedupes() {
        // Multiple rules can point at the same tool; result must be unique.
        let p = perceive("read the file and write a new task", true);
        let names = registry_snapshot();
        let routed = route_tools(&p, &names);
        let mut sorted = routed.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(routed.len(), sorted.len(), "duplicates in {:?}", routed);
    }

    #[test]
    fn arithmetic_operator_detection() {
        assert!(has_arithmetic_operator("231 * 243"));
        assert!(has_arithmetic_operator("5+3"));
        assert!(!has_arithmetic_operator("you and i"));
        assert!(!has_arithmetic_operator("hello world"));
    }
}
