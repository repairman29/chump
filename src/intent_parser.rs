//! INFRA-798: Intent parser — natural language to structured chump ops.
//!
//! Converts operator natural-language input into a typed `IntentOp` enum,
//! which can be dispatched to chump subcommands without an LLM call.
//!
//! Also provides `format_intent_prompt()` for LLM-based intent resolution when
//! the pattern matcher returns `IntentOp::Unknown`.
//!
//! ## Single-shot mode
//!
//! `chump orchestrate <text>` (when text is provided as a positional arg, not
//! interactive) calls `parse_intent()`, prints the resolved chump command as
//! JSON, and emits `kind=intent_parse_ok|intent_parse_unknown` to ambient.jsonl.

use std::path::Path;

// ── IntentOp ──────────────────────────────────────────────────────────────────

/// A structured chump operation resolved from a natural-language intent.
#[derive(Debug, Clone, PartialEq)]
pub enum IntentOp {
    // Gap operations
    GapList {
        filter: Option<String>,
    },
    GapShow {
        id: String,
    },
    GapClaim {
        id: String,
    },
    GapShip {
        id: String,
    },
    GapReserve {
        title: String,
    },
    // Fleet operations
    FleetStatus,
    /// INFRA-1451: carries extracted --size / --domain / --priority flags.
    FleetStart {
        size: Option<u32>,
        domain: Option<String>,
        priority: Option<String>,
    },
    FleetStop,
    // Cognition / reporting
    MissionGrade,
    PillarBalance,
    WasteTally,
    // Fallback
    Unknown {
        raw: String,
    },
}

impl IntentOp {
    /// Returns the canonical chump CLI command string for this intent.
    pub fn to_chump_command(&self) -> String {
        match self {
            Self::GapList { filter: Some(f) } => format!("chump gap list --status open {f}"),
            Self::GapList { filter: None } => "chump gap list --status open".to_string(),
            Self::GapShow { id } => format!("chump gap show {id}"),
            Self::GapClaim { id } => format!("chump gap claim {id}"),
            Self::GapShip { id } => format!("chump gap ship {id}"),
            Self::GapReserve { title } => format!("chump gap reserve --title \"{title}\""),
            Self::FleetStatus => "chump fleet status".to_string(),
            Self::FleetStart {
                size,
                domain,
                priority,
            } => {
                // INFRA-1451: build chump fleet start with extracted flags.
                let mut cmd = "chump fleet start".to_string();
                if let Some(n) = size {
                    cmd.push_str(&format!(" --size {n}"));
                }
                if let Some(d) = domain {
                    cmd.push_str(&format!(" --domain {d}"));
                }
                if let Some(p) = priority {
                    cmd.push_str(&format!(" --priority {p}"));
                }
                cmd
            }
            Self::FleetStop => "chump fleet stop".to_string(),
            Self::MissionGrade => "chump mission-grade".to_string(),
            Self::PillarBalance => "chump pillar-balance".to_string(),
            Self::WasteTally => "chump waste-tally".to_string(),
            Self::Unknown { raw } => format!("# unknown intent: {raw}"),
        }
    }

    /// Kind string for ambient.jsonl.
    pub fn ambient_kind(&self) -> &'static str {
        if matches!(self, Self::Unknown { .. }) {
            "intent_parse_unknown"
        } else {
            "intent_parse_ok"
        }
    }
}

// ── Pattern-based parser ──────────────────────────────────────────────────────

/// Parse a natural-language operator intent into a typed `IntentOp`.
///
/// Uses keyword and token-based matching.  Returns `IntentOp::Unknown` when no
/// pattern matches — callers should then invoke `format_intent_prompt()` and send
/// to an LLM for resolution.
pub fn parse_intent(input: &str) -> IntentOp {
    let lc = input.to_lowercase();
    // Keep original-case words for gap ID extraction (IDs are uppercase).
    let orig_words: Vec<&str> = input.split_whitespace().collect();
    let lc_words: Vec<&str> = lc.split_whitespace().collect();

    // ── Gap operations ────────────────────────────────────────────────────────
    // Detect "list/show gaps" intent — broad set of phrasings.
    let is_gap_list = contains_any(&lc, &["gap list", "list gap", "show gaps", "open gap"])
        || (has_word(&lc_words, "list") && has_word(&lc_words, "gaps"))
        || (has_word(&lc_words, "list") && has_word(&lc_words, "gap"))
        || (has_word(&lc_words, "show") && has_word(&lc_words, "gaps"));
    if is_gap_list {
        let filter = extract_priority_filter(input);
        return IntentOp::GapList { filter };
    }

    if contains_any(
        &lc,
        &["gap show", "show gap", "what is gap", "tell me about gap"],
    ) {
        if let Some(id) = extract_gap_id(&orig_words) {
            return IntentOp::GapShow { id };
        }
    }

    if contains_any(&lc, &["claim gap", "pick gap", "grab gap"])
        || (has_word(&lc_words, "claim") && has_word(&lc_words, "gap"))
        || (has_word(&lc_words, "start") && has_word(&lc_words, "working"))
    {
        if let Some(id) = extract_gap_id(&orig_words) {
            return IntentOp::GapClaim { id };
        }
    }

    if contains_any(
        &lc,
        &[
            "ship gap",
            "mark done",
            "mark shipped",
            "close gap",
            "complete gap",
        ],
    ) {
        if let Some(id) = extract_gap_id(&orig_words) {
            return IntentOp::GapShip { id };
        }
    }

    if contains_any(
        &lc,
        &[
            "new gap",
            "create gap",
            "file gap",
            "reserve gap",
            "open a gap",
        ],
    ) {
        let title =
            extract_remainder_after(input, &["gap", "new", "create", "file", "reserve", "open"])
                .unwrap_or_else(|| input.to_string());
        return IntentOp::GapReserve { title };
    }

    // ── Fleet operations ──────────────────────────────────────────────────────
    // Stop/halt before status — "stop" is unambiguous.
    let has_fleet = has_word(&lc_words, "fleet");
    if has_fleet && contains_any(&lc, &["stop", "halt", "kill"]) {
        return IntentOp::FleetStop;
    }

    if has_fleet && contains_any(&lc, &["start", "spawn", "launch"]) {
        // INFRA-1451: extract optional parameters before returning.
        let size = extract_size(input);
        let domain = extract_domain(input);
        let priority = extract_fleet_priority(input);
        return IntentOp::FleetStart {
            size,
            domain,
            priority,
        };
    }

    if contains_any(
        &lc,
        &[
            "fleet status",
            "fleet health",
            "how is the fleet",
            "fleet running",
        ],
    ) || (has_word(&lc_words, "status") && has_fleet)
        || (has_word(&lc_words, "health") && has_fleet)
    {
        return IntentOp::FleetStatus;
    }

    // ── Reporting ─────────────────────────────────────────────────────────────
    if contains_any(
        &lc,
        &[
            "mission grade",
            "pillar grade",
            "grade the mission",
            "4 pillar",
            "four pillar",
        ],
    ) {
        return IntentOp::MissionGrade;
    }

    if contains_any(
        &lc,
        &[
            "pillar balance",
            "balance pillar",
            "pillar inventory",
            "rebalance",
        ],
    ) {
        return IntentOp::PillarBalance;
    }

    if contains_any(
        &lc,
        &["waste tally", "waste rate", "wasted work", "waste report"],
    ) {
        return IntentOp::WasteTally;
    }

    // ── Fallback: single-gap-ID input (e.g. "INFRA-798") ────────────────────
    if orig_words.len() == 1 {
        if let Some(id) = extract_gap_id(&orig_words) {
            return IntentOp::GapShow { id };
        }
    }

    IntentOp::Unknown {
        raw: input.to_string(),
    }
}

/// Returns the LLM prompt to resolve an intent when pattern matching fails.
///
/// This is the "prompt template" referenced in INFRA-798.  Feed it to the
/// provider cascade (e.g. `orchestrate.rs`) and parse TOOL lines from the
/// response.
pub fn format_intent_prompt(intent: &str) -> String {
    format!(
        "You are a chump fleet operator assistant. Convert the following \
         natural-language intent into exactly one chump CLI command from the list below.\n\n\
         Allowed commands:\n\
         - chump gap list [--status open] [--priority P0|P1|P2]\n\
         - chump gap show <ID>\n\
         - chump gap claim <ID>\n\
         - chump gap ship <ID>\n\
         - chump fleet status\n\
         - chump fleet start\n\
         - chump fleet stop\n\
         - chump mission-grade\n\
         - chump pillar-balance\n\
         - chump waste-tally\n\n\
         Reply with exactly one line in this format:\n\
           TOOL: <command>\n\n\
         Intent: {intent}"
    )
}

// ── Ambient telemetry ─────────────────────────────────────────────────────────

/// Emit `intent_parse_ok` or `intent_parse_unknown` to `.chump-locks/ambient.jsonl`.
pub fn emit_intent_event(op: &IntentOp, repo_root: &Path) {
    let locks_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&locks_dir);
    let ts = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        // Format as YYYY-MM-DDTHH:MM:SSZ (reuse days_from_epoch logic inline)
        let s = secs % 60;
        let m = (secs / 60) % 60;
        let h = (secs / 3600) % 24;
        let total_days = secs / 86400;
        // Gregorian calendar approximation for display (not cryptographic)
        let year = 1970 + total_days / 365;
        let day_of_year = total_days % 365;
        let month = day_of_year / 30 + 1;
        let day = day_of_year % 30 + 1;
        format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
    };
    let kind = op.ambient_kind();
    let cmd = op.to_chump_command().replace('"', "\\\"");
    let line = format!("{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",\"command\":\"{cmd}\"}}\n");
    let path = locks_dir.join("ambient.jsonl");
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

// ── Pattern helpers ───────────────────────────────────────────────────────────

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| haystack.contains(n))
}

fn has_word(words: &[&str], word: &str) -> bool {
    words.contains(&word)
}

/// Extract gap ID like "INFRA-798", "PRODUCT-032" from a word list.
fn extract_gap_id(words: &[&str]) -> Option<String> {
    words.iter().find_map(|w| {
        // Pattern: UPPER-digits (e.g. INFRA-798, PRODUCT-032, META-045)
        let w = w.trim_matches(|c: char| !c.is_alphanumeric() && c != '-');
        let parts: Vec<&str> = w.split('-').collect();
        if parts.len() == 2
            && parts[0].chars().all(|c| c.is_ascii_uppercase())
            && !parts[0].is_empty()
            && parts[1].chars().all(|c| c.is_ascii_digit())
            && !parts[1].is_empty()
        {
            Some(w.to_uppercase())
        } else {
            None
        }
    })
}

/// INFRA-1451: Extract numeric fleet size (e.g. "size 4", "4 workers", "--size 4").
fn extract_size(input: &str) -> Option<u32> {
    let lc = input.to_lowercase();
    let words: Vec<&str> = lc.split_whitespace().collect();
    // Patterns: "size N", "--size N", "N workers", "N worker"
    for i in 0..words.len() {
        if (words[i] == "size" || words[i] == "--size") && i + 1 < words.len() {
            if let Ok(n) = words[i + 1].trim_end_matches(',').parse::<u32>() {
                return Some(n);
            }
        }
        // "N workers" / "N worker"
        if i + 1 < words.len() && (words[i + 1].starts_with("worker")) {
            if let Ok(n) = words[i].trim_end_matches(',').parse::<u32>() {
                return Some(n);
            }
        }
    }
    None
}

/// INFRA-1451: Extract domain keyword (infra, product, credible, effective, resilient, zero-waste).
fn extract_domain(input: &str) -> Option<String> {
    let lc = input.to_lowercase();
    // Order matters: check multi-word first.
    for (keyword, domain) in &[
        ("zero-waste", "ZERO-WASTE"),
        ("zero_waste", "ZERO-WASTE"),
        ("zerowaste", "ZERO-WASTE"),
        ("effective", "EFFECTIVE"),
        ("credible", "CREDIBLE"),
        ("resilient", "RESILIENT"),
        ("product", "PRODUCT"),
        ("infra", "INFRA"),
        ("meta", "META"),
        ("mission", "MISSION"),
    ] {
        if lc.contains(keyword) {
            return Some(domain.to_string());
        }
    }
    None
}

/// INFRA-1451: Extract fleet priority flags (p0, p1, p0/p1, highest).
fn extract_fleet_priority(input: &str) -> Option<String> {
    let lc = input.to_lowercase();
    // "p0/p1" or "p0,p1" → P0,P1
    if lc.contains("p0/p1") || lc.contains("p0,p1") || lc.contains("p0 p1") {
        return Some("P0,P1".to_string());
    }
    // "highest" → P0
    if lc.contains("highest") || lc.contains("urgent") || lc.contains("critical") {
        return Some("P0".to_string());
    }
    // Standalone p0 or p1
    if contains_any(&lc, &[" p0 ", " p0,", " p0/", "on p0", "(p0"]) || lc.ends_with(" p0") {
        return Some("P0".to_string());
    }
    if contains_any(&lc, &[" p1 ", " p1,", " p1/", "on p1", "(p1"]) || lc.ends_with(" p1") {
        return Some("P1".to_string());
    }
    None
}

/// Extract a priority filter like "--priority P1" from the input.
fn extract_priority_filter(input: &str) -> Option<String> {
    let lc = input.to_lowercase();
    for priority in &["p0", "p1", "p2"] {
        if lc.contains(priority) {
            return Some(format!("--priority {}", priority.to_uppercase()));
        }
    }
    None
}

/// Extract remainder of input after any of the given skip-words.
fn extract_remainder_after(input: &str, skip_words: &[&str]) -> Option<String> {
    let words: Vec<&str> = input.split_whitespace().collect();
    let mut i = 0;
    while i < words.len() {
        if skip_words
            .iter()
            .any(|sw| words[i].eq_ignore_ascii_case(sw))
        {
            i += 1;
            continue;
        }
        let remainder = words[i..].join(" ");
        if !remainder.is_empty() {
            return Some(remainder);
        }
        break;
    }
    None
}

// ── LLM fallback support (INFRA-1452) ────────────────────────────────────────

/// Returns `true` if any LLM provider is configured in the environment.
///
/// Checked in order: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
/// `CHUMP_OPENAI_API_KEY`, `OLLAMA_HOST`, `CHUMP_CASCADE_ENABLED=1`.
pub fn llm_provider_configured() -> bool {
    let has_key = |var: &str| !std::env::var(var).unwrap_or_default().trim().is_empty();
    has_key("ANTHROPIC_API_KEY")
        || has_key("OPENAI_API_KEY")
        || has_key("CHUMP_OPENAI_API_KEY")
        || has_key("OLLAMA_HOST")
        || std::env::var("CHUMP_CASCADE_ENABLED")
            .map(|v| v.trim() == "1")
            .unwrap_or(false)
}

/// Extract the `TOOL: <command>` line from an LLM response.
///
/// Returns `Some(command)` on first matching TOOL line, else `None`.
pub fn parse_llm_response(response: &str) -> Option<String> {
    for line in response.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("TOOL:") {
            let cmd = rest.trim().to_string();
            if !cmd.is_empty() {
                return Some(cmd);
            }
        }
    }
    None
}

/// Emit `kind=intent_parse_llm` to `.chump-locks/ambient.jsonl`.
pub fn emit_intent_llm_event(raw: &str, command: &str, provider: &str, repo_root: &Path) {
    let locks_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&locks_dir);
    let ts = iso8601_now();
    let raw_esc = raw.replace('"', "\\\"");
    let cmd_esc = command.replace('"', "\\\"");
    let prov_esc = provider.replace('"', "\\\"");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_parse_llm\",\
         \"raw\":\"{raw_esc}\",\"command\":\"{cmd_esc}\",\"provider\":\"{prov_esc}\"}}\n"
    );
    let path = locks_dir.join("ambient.jsonl");
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// Budget status for LLM-fallback intent calls.
#[derive(Debug)]
pub enum BudgetStatus {
    /// Enough budget remains; `per_call` is the estimated cost to charge.
    Ok { per_call: f64 },
    /// Daily cap exceeded; re-run with `--confirm-budget` to override.
    Exceeded { spend: f64, cap: f64 },
}

/// Check whether the per-intent LLM budget allows one more call.
///
/// Env vars:
///   `CHUMP_INTENT_LLM_BUDGET_USD`       — per-call cost (default `$0.01`)
///   `CHUMP_INTENT_LLM_DAILY_BUDGET_USD` — daily cap    (default `$0.10`)
///   `CHUMP_INTENT_LLM_CONFIRM_BUDGET=1` — override exhausted budget
pub fn intent_llm_budget_check(repo_root: &Path) -> BudgetStatus {
    let confirm = std::env::var("CHUMP_INTENT_LLM_CONFIRM_BUDGET")
        .map(|v| v.trim() == "1")
        .unwrap_or(false);
    let daily_cap: f64 = std::env::var("CHUMP_INTENT_LLM_DAILY_BUDGET_USD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.10);
    let per_call: f64 = std::env::var("CHUMP_INTENT_LLM_BUDGET_USD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.01);

    let spend = read_today_intent_spend(repo_root);
    if spend >= daily_cap && !confirm {
        BudgetStatus::Exceeded {
            spend,
            cap: daily_cap,
        }
    } else {
        BudgetStatus::Ok { per_call }
    }
}

/// Record `per_call` dollars against today's intent LLM budget.
///
/// Stored in `<repo>/.chump/intent_llm_spend.txt` as `YYYY-MM-DD <usd>` lines.
pub fn record_intent_llm_spend(repo_root: &Path, per_call: f64) {
    let path = repo_root.join(".chump").join("intent_llm_spend.txt");
    let today = today_date();
    let existing = read_today_intent_spend(repo_root);
    let new_spend = existing + per_call;

    // Re-write file: keep all non-today lines, append updated today line.
    let prior = std::fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<String> = prior
        .lines()
        .filter(|l| !l.starts_with(today.as_str()))
        .map(String::from)
        .collect();
    lines.push(format!("{today} {new_spend:.6}"));
    let content = lines.join("\n") + "\n";
    let _ = std::fs::create_dir_all(path.parent().unwrap_or(repo_root));
    let _ = std::fs::write(&path, content);
}

fn read_today_intent_spend(repo_root: &Path) -> f64 {
    let path = repo_root.join(".chump").join("intent_llm_spend.txt");
    let today = today_date();
    let Ok(content) = std::fs::read_to_string(&path) else {
        return 0.0;
    };
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix(today.as_str()) {
            return rest.trim().parse().unwrap_or(0.0);
        }
    }
    0.0
}

fn today_date() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let total_days = secs / 86400;
    let year = 1970 + total_days / 365;
    let day_of_year = total_days % 365;
    let month = day_of_year / 30 + 1;
    let day = day_of_year % 30 + 1;
    format!("{year:04}-{month:02}-{day:02}")
}

fn iso8601_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let total_days = secs / 86400;
    let year = 1970 + total_days / 365;
    let day_of_year = total_days % 365;
    let month = day_of_year / 30 + 1;
    let day = day_of_year % 30 + 1;
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gap_list_no_filter() {
        let op = parse_intent("show me the open gaps");
        assert_eq!(op, IntentOp::GapList { filter: None });
    }

    #[test]
    fn gap_list_with_p1_filter() {
        let op = parse_intent("list open P1 gaps");
        assert_eq!(
            op,
            IntentOp::GapList {
                filter: Some("--priority P1".to_string())
            }
        );
    }

    #[test]
    fn gap_show_by_id() {
        let op = parse_intent("gap show INFRA-798");
        assert_eq!(
            op,
            IntentOp::GapShow {
                id: "INFRA-798".to_string()
            }
        );
    }

    #[test]
    fn single_gap_id_resolves_to_show() {
        let op = parse_intent("INFRA-798");
        assert_eq!(
            op,
            IntentOp::GapShow {
                id: "INFRA-798".to_string()
            }
        );
    }

    #[test]
    fn fleet_status_multiple_phrasings() {
        assert_eq!(parse_intent("fleet status"), IntentOp::FleetStatus);
        assert_eq!(
            parse_intent("how is the fleet doing"),
            IntentOp::FleetStatus
        );
        assert_eq!(parse_intent("fleet health check"), IntentOp::FleetStatus);
    }

    #[test]
    fn fleet_stop() {
        assert_eq!(parse_intent("stop the fleet now"), IntentOp::FleetStop);
        assert_eq!(parse_intent("halt fleet"), IntentOp::FleetStop);
    }

    // ── INFRA-1451: FleetStart parameter extraction ───────────────────────────

    #[test]
    fn fleet_start_no_params() {
        let op = parse_intent("start the fleet");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: None,
                domain: None,
                priority: None
            }
        );
    }

    #[test]
    fn fleet_start_with_size() {
        let op = parse_intent("spawn the fleet size 4");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: Some(4),
                domain: None,
                priority: None
            }
        );
    }

    #[test]
    fn fleet_start_workers_phrasing() {
        let op = parse_intent("launch 3 workers fleet");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: Some(3),
                domain: None,
                priority: None
            }
        );
    }

    #[test]
    fn fleet_start_domain_infra() {
        let op = parse_intent("spawn the fleet on infra");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: None,
                domain: Some("INFRA".to_string()),
                priority: None
            }
        );
    }

    #[test]
    fn fleet_start_full_demo_phrase() {
        // The exact phrase from the June-6 demo criterion #4.
        let op = parse_intent("spawn the fleet on infra p0/p1, size 4");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: Some(4),
                domain: Some("INFRA".to_string()),
                priority: Some("P0,P1".to_string()),
            }
        );
    }

    #[test]
    fn fleet_start_to_chump_command_full() {
        let op = IntentOp::FleetStart {
            size: Some(4),
            domain: Some("INFRA".to_string()),
            priority: Some("P0,P1".to_string()),
        };
        assert_eq!(
            op.to_chump_command(),
            "chump fleet start --size 4 --domain INFRA --priority P0,P1"
        );
    }

    #[test]
    fn fleet_start_priority_p1_only() {
        let op = parse_intent("start fleet on infra p1");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: None,
                domain: Some("INFRA".to_string()),
                priority: Some("P1".to_string()),
            }
        );
    }

    #[test]
    fn fleet_start_effective_domain() {
        let op = parse_intent("spawn fleet effective gaps size 2");
        assert_eq!(
            op,
            IntentOp::FleetStart {
                size: Some(2),
                domain: Some("EFFECTIVE".to_string()),
                priority: None,
            }
        );
    }

    #[test]
    fn mission_grade() {
        assert_eq!(
            parse_intent("what is our mission grade?"),
            IntentOp::MissionGrade
        );
        assert_eq!(parse_intent("4 pillar report"), IntentOp::MissionGrade);
    }

    #[test]
    fn unknown_returns_unknown() {
        let op = parse_intent("deploy the kubernetes cluster");
        assert!(matches!(op, IntentOp::Unknown { .. }));
    }

    #[test]
    fn gap_claim_extracts_id() {
        let op = parse_intent("claim gap PRODUCT-056 and start working on it");
        assert_eq!(
            op,
            IntentOp::GapClaim {
                id: "PRODUCT-056".to_string()
            }
        );
    }

    #[test]
    fn to_chump_command_round_trips() {
        let op = IntentOp::GapList {
            filter: Some("--priority P0".to_string()),
        };
        assert_eq!(
            op.to_chump_command(),
            "chump gap list --status open --priority P0"
        );
    }

    #[test]
    fn waste_tally() {
        assert_eq!(
            parse_intent("show me the waste tally"),
            IntentOp::WasteTally
        );
        assert_eq!(parse_intent("what's our waste rate?"), IntentOp::WasteTally);
    }

    #[test]
    fn format_intent_prompt_contains_tool_lines() {
        let prompt = format_intent_prompt("show me open gaps");
        assert!(prompt.contains("TOOL:"));
        assert!(prompt.contains("chump gap list"));
        assert!(prompt.contains("show me open gaps"));
    }
}
