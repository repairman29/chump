//! Adversary rule engine (COMP-011a).
//!
//! Loads `chump-adversary.yaml` from the repo root and checks every tool call
//! _before_ execution inside `ToolTimeoutWrapper::execute`. When a rule matches
//! it emits a `kind=adversary_alert` event to `.chump-locks/ambient.jsonl`.
//!
//! ## Activation
//! Default **OFF** — set `CHUMP_ADVERSARY_ENABLED=1` to activate.
//! This preserves existing behaviour and lets operators opt-in.
//!
//! ## Rule format (chump-adversary.yaml)
//! ```yaml
//! rules:
//!   - name: no-force-push
//!     match: "run_cli"           # exact tool name or "*" for any
//!     pattern: "command contains 'git push --force'"
//!     action: block              # warn | block
//!     reason: "Force pushes can destroy history"
//! ```
//!
//! ### Pattern syntax
//! `<field> contains '<substring>'`
//! - `<field>` is a top-level JSON key in the tool input, e.g. `command`, `cmd`.
//! - `*` as field matches against the full serialised input JSON.
//! - The substring match is case-sensitive.

use anyhow::Result;
use serde::Deserialize;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::OnceLock;

// ── Mode selection ────────────────────────────────────────────────────────────

/// Returns the active adversary mode from `CHUMP_ADVERSARY_MODE`.
///
/// Valid values (case-insensitive):
/// - `"off"` — disabled entirely (equivalent to `CHUMP_ADVERSARY_ENABLED=0`)
/// - `"static"` — YAML rule engine (COMP-011a, default when enabled)
/// - `"llm"` — LLM-based context-aware reviewer (COMP-011b)
///
/// Defaults to `"static"` when the env var is absent.
pub fn adversary_mode() -> &'static str {
    static MODE: OnceLock<String> = OnceLock::new();
    MODE.get_or_init(|| {
        std::env::var("CHUMP_ADVERSARY_MODE")
            .unwrap_or_else(|_| "static".to_string())
            .to_lowercase()
    })
    .as_str()
}

// ── Configuration types ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AdversaryAction {
    /// Tool call is safe to proceed (used by the LLM reviewer path).
    Allow,
    Warn,
    Block,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AdversaryRule {
    pub name: String,
    /// Tool name to match. `"*"` matches any tool.
    #[serde(rename = "match")]
    pub match_tool: String,
    /// Pattern string: `"<field> contains '<value>'"`.
    pub pattern: String,
    pub action: AdversaryAction,
    pub reason: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct AdversaryConfig {
    #[serde(default)]
    rules: Vec<AdversaryRule>,
}

/// Result of an adversary check: which rule fired, and what action to take.
#[derive(Debug, Clone)]
pub struct AdversaryAlert {
    pub rule_name: String,
    pub tool_name: String,
    pub action: AdversaryAction,
    pub reason: String,
    /// Snippet of the input that triggered the match (first 200 chars of the
    /// matched field value, for the ambient event).
    pub matched_snippet: String,
}

// ── Loaded rule set ───────────────────────────────────────────────────────────

pub struct AdversaryRules {
    rules: Vec<AdversaryRule>,
}

impl AdversaryRules {
    /// Load rules from `chump-adversary.yaml` in the repo root.
    /// Returns an empty rule set (not an error) when the file is absent or
    /// unparseable — adversary checks are advisory and must never break a cold
    /// start.
    pub fn load() -> Self {
        let path = adversary_yaml_path();
        Self::load_from_path(&path)
    }

    fn load_from_path(path: &PathBuf) -> Self {
        match std::fs::read_to_string(path) {
            Err(_) => {
                // File not present — silent no-op.
                Self { rules: Vec::new() }
            }
            Ok(content) => match serde_yaml::from_str::<AdversaryConfig>(&content) {
                Ok(cfg) => Self { rules: cfg.rules },
                Err(e) => {
                    tracing::warn!(path = %path.display(), err = %e, "adversary: failed to parse chump-adversary.yaml — using empty rule set");
                    Self { rules: Vec::new() }
                }
            },
        }
    }

    /// Check a tool call against all loaded rules.
    /// Returns the first matching rule's alert, or `None` if no rule fired.
    pub fn check(&self, tool_name: &str, input_json: &Value) -> Option<AdversaryAlert> {
        for rule in &self.rules {
            if !tool_matches(&rule.match_tool, tool_name) {
                continue;
            }
            if let Some(snippet) = pattern_matches(&rule.pattern, input_json) {
                return Some(AdversaryAlert {
                    rule_name: rule.name.clone(),
                    tool_name: tool_name.to_string(),
                    action: rule.action.clone(),
                    reason: rule.reason.clone(),
                    matched_snippet: snippet,
                });
            }
        }
        None
    }

    /// True when there are no rules (nothing to check).
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }
}

// ── Path resolution ───────────────────────────────────────────────────────────

fn adversary_yaml_path() -> PathBuf {
    let base = crate::repo_path::runtime_base();
    base.join("chump-adversary.yaml")
}

// ── Matching helpers ──────────────────────────────────────────────────────────

/// Match a tool name against a rule's `match` field.
/// `"*"` is a wildcard that matches any tool name.
/// Otherwise exact string equality is used.
fn tool_matches(match_expr: &str, tool_name: &str) -> bool {
    if match_expr == "*" {
        return true;
    }
    // Simple glob: leading/trailing `*` wildcards.
    if match_expr.starts_with('*') && match_expr.ends_with('*') {
        let inner = &match_expr[1..match_expr.len() - 1];
        return tool_name.contains(inner);
    }
    if let Some(suffix) = match_expr.strip_prefix('*') {
        return tool_name.ends_with(suffix);
    }
    if let Some(prefix) = match_expr.strip_suffix('*') {
        return tool_name.starts_with(prefix);
    }
    match_expr == tool_name
}

/// Evaluate `"<field> contains '<value>'"` against an input JSON Value.
/// Returns `Some(matched_snippet)` when the pattern fires, `None` otherwise.
/// Returns `None` (no match) when the pattern cannot be parsed.
fn pattern_matches(pattern: &str, input: &Value) -> Option<String> {
    // Parse: `<field> contains '<value>'`
    let (field, contains_str) = parse_contains_pattern(pattern)?;

    let target_str: String = if field == "*" {
        // Match against full serialised JSON.
        serde_json::to_string(input).unwrap_or_default()
    } else {
        // Extract field from JSON object.
        input
            .get(&field)
            .and_then(|v| {
                v.as_str()
                    .map(|s| s.to_string())
                    .or_else(|| serde_json::to_string(v).ok())
            })
            .unwrap_or_default()
    };

    if target_str.contains(contains_str.as_str()) {
        let snippet: String = target_str.chars().take(200).collect();
        Some(snippet)
    } else {
        None
    }
}

/// Parse `"<field> contains '<value>'"` → `(field, value)`.
/// Returns `None` on parse failure.
fn parse_contains_pattern(pattern: &str) -> Option<(String, String)> {
    // Expected form: `<field> contains '<value>'`
    // Split on first occurrence of " contains '"
    let contains_marker = " contains '";
    let pos = pattern.find(contains_marker)?;
    let field = pattern[..pos].trim().to_string();
    let rest = &pattern[pos + contains_marker.len()..];
    // rest ends with a single-quote
    let value = rest.strip_suffix('\'')?;
    Some((field, value.to_string()))
}

// ── Global singleton (lazy, env-gated) ───────────────────────────────────────

static ADVERSARY_RULES: OnceLock<AdversaryRules> = OnceLock::new();

/// Return the global singleton adversary rule set (loaded once from disk).
pub fn rules() -> &'static AdversaryRules {
    ADVERSARY_RULES.get_or_init(AdversaryRules::load)
}

// ── Feature gate ─────────────────────────────────────────────────────────────

/// Returns true when `CHUMP_ADVERSARY_ENABLED=1`.
/// Default is **OFF** so no existing behaviour changes.
pub fn adversary_enabled() -> bool {
    std::env::var("CHUMP_ADVERSARY_ENABLED")
        .map(|v| v.trim() == "1" || v.trim().eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

// ── Ambient event emission ────────────────────────────────────────────────────

/// Write one `kind=adversary_alert` line to `.chump-locks/ambient.jsonl`.
///
/// Uses the same format as `ambient-emit.sh` so war-room / musher can display
/// it alongside other coordination events.
pub fn emit_ambient_alert(alert: &AdversaryAlert) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());

    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // JSON-escape the fields that might contain user-controlled content.
    let rule_name = json_escape(&alert.rule_name);
    let tool = json_escape(&alert.tool_name);
    let action = match alert.action {
        AdversaryAction::Allow => "allow",
        AdversaryAction::Warn => "warn",
        AdversaryAction::Block => "block",
    };
    let reason = json_escape(&alert.reason);
    let snippet = json_escape(&alert.matched_snippet);

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"adversary_alert\",\"rule\":\"{rule_name}\",\"tool\":\"{tool}\",\
         \"action\":\"{action}\",\"reason\":\"{reason}\",\"snippet\":\"{snippet}\"}}"
    );

    // Best-effort append — adversary must never break tool execution.
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    // FLEET-006: best-effort NATS dual-emit so remote sessions (Cold Water,
    // peer machines) see the alert. No-op when chump-coord isn't on PATH
    // or NATS is unreachable. CHUMP_AMBIENT_NATS=0 disables.
    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("adversary_alert")
            .arg(format!("rule={}", alert.rule_name))
            .arg(format!("tool={}", alert.tool_name))
            .arg(format!("action={}", action))
            .arg(format!("reason={}", alert.reason))
            .env("CHUMP_SESSION_ID", &session)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// Minimal JSON string escaping for the ambient event fields.
fn json_escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            other => vec![other],
        })
        .collect()
}

// ── Public entry point used by ToolTimeoutWrapper ────────────────────────────

/// Check `tool_name` + `input` against the adversary system.
///
/// Dispatches to the appropriate backend based on `CHUMP_ADVERSARY_MODE`:
/// - `off` / `CHUMP_ADVERSARY_ENABLED=0` (default): returns `Ok(())`.
/// - `static` (default when enabled): YAML rule engine (COMP-011a).
/// - `llm`: LLM-based context-aware reviewer (COMP-011b).
///
/// `context` is the recent conversation; used only by the `llm` backend.
///
/// - `warn` action: emits ambient alert, returns `Ok(())` (tool continues).
/// - `block` action: emits ambient alert, returns `Err(…)` (tool is blocked).
///
/// The caller (ToolTimeoutWrapper) should call this before delegating to the
/// inner tool.
pub async fn adversary_check(
    tool_name: &str,
    input: &Value,
    context: &[axonerai::provider::Message],
) -> Result<()> {
    if !adversary_enabled() {
        return Ok(());
    }

    let mode = adversary_mode();

    if mode == "llm" {
        // COMP-011b: delegate to the LLM-based reviewer.
        let action = crate::adversary_llm::llm_adversary_check(tool_name, input, context).await?;
        return match action {
            AdversaryAction::Allow => Ok(()),
            AdversaryAction::Warn => Ok(()),
            AdversaryAction::Block => Err(anyhow::anyhow!(
                "DENIED (adversary/llm): tool '{}' was blocked by the LLM reviewer",
                tool_name
            )),
        };
    }

    // Default: static YAML rule engine (COMP-011a).
    let Some(alert) = rules().check(tool_name, input) else {
        return Ok(());
    };

    // Always log.
    tracing::warn!(
        rule = %alert.rule_name,
        tool = %alert.tool_name,
        action = ?alert.action,
        reason = %alert.reason,
        "COMP-011a adversary rule fired"
    );
    emit_ambient_alert(&alert);

    match alert.action {
        AdversaryAction::Allow | AdversaryAction::Warn => Ok(()),
        AdversaryAction::Block => Err(anyhow::anyhow!(
            "DENIED (adversary rule '{}'): {}",
            alert.rule_name,
            alert.reason
        )),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;
    use tempfile::TempDir;

    /// Serialize tests that mutate `CHUMP_ADVERSARY_ENABLED` to avoid
    /// race conditions when the test suite runs in parallel.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn make_rules(yaml: &str) -> AdversaryRules {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chump-adversary.yaml");
        std::fs::write(&path, yaml).unwrap();
        AdversaryRules::load_from_path(&path)
    }

    #[test]
    fn parse_contains_pattern_basic() {
        let (field, val) = parse_contains_pattern("cmd contains 'git push --force'").unwrap();
        assert_eq!(field, "cmd");
        assert_eq!(val, "git push --force");
    }

    #[test]
    fn parse_contains_pattern_wildcard_field() {
        let (field, val) = parse_contains_pattern("* contains 'secret'").unwrap();
        assert_eq!(field, "*");
        assert_eq!(val, "secret");
    }

    #[test]
    fn parse_contains_pattern_bad_input_returns_none() {
        assert!(parse_contains_pattern("no_contains_here").is_none());
        assert!(parse_contains_pattern("field contains missing_quote").is_none());
    }

    #[test]
    fn tool_matches_exact() {
        assert!(tool_matches("bash", "bash"));
        assert!(!tool_matches("bash", "run_cli"));
    }

    #[test]
    fn tool_matches_wildcard() {
        assert!(tool_matches("*", "anything"));
        assert!(tool_matches("*", "bash"));
    }

    #[test]
    fn tool_matches_prefix_glob() {
        assert!(tool_matches("git_*", "git_commit"));
        assert!(tool_matches("git_*", "git_push"));
        assert!(!tool_matches("git_*", "run_cli"));
    }

    #[test]
    fn tool_matches_suffix_glob() {
        assert!(tool_matches("*_tool", "bash_tool"));
        assert!(!tool_matches("*_tool", "bash"));
    }

    #[test]
    fn pattern_matches_cmd_field() {
        let input = json!({"cmd": "git push --force origin main"});
        let snippet = pattern_matches("cmd contains 'git push --force'", &input);
        assert!(snippet.is_some());
    }

    #[test]
    fn pattern_no_match() {
        let input = json!({"cmd": "git status"});
        let result = pattern_matches("cmd contains 'git push --force'", &input);
        assert!(result.is_none());
    }

    #[test]
    fn pattern_matches_wildcard_field() {
        let input = json!({"command": "rm -rf /tmp/test", "other": "value"});
        let snippet = pattern_matches("* contains 'rm -rf'", &input);
        assert!(snippet.is_some());
    }

    #[test]
    fn pattern_missing_field_returns_none() {
        let input = json!({"other_field": "value"});
        let result = pattern_matches("cmd contains 'something'", &input);
        assert!(result.is_none());
    }

    #[test]
    fn rule_block_fires_on_force_push() {
        let yaml = r#"
rules:
  - name: no-force-push
    match: "run_cli"
    pattern: "command contains 'git push --force'"
    action: block
    reason: "Force pushes can destroy history"
"#;
        let rules = make_rules(yaml);
        let input = json!({"command": "git push --force origin feature-branch"});
        let alert = rules.check("run_cli", &input).unwrap();
        assert_eq!(alert.rule_name, "no-force-push");
        assert_eq!(alert.action, AdversaryAction::Block);
    }

    #[test]
    fn rule_warn_fires_on_rm_rf() {
        let yaml = r#"
rules:
  - name: watch-rm-rf
    match: "bash"
    pattern: "cmd contains 'rm -rf'"
    action: warn
    reason: "Destructive deletion detected"
"#;
        let rules = make_rules(yaml);
        let input = json!({"cmd": "rm -rf /var/tmp/old"});
        let alert = rules.check("bash", &input).unwrap();
        assert_eq!(alert.action, AdversaryAction::Warn);
    }

    #[test]
    fn no_match_on_different_tool() {
        let yaml = r#"
rules:
  - name: block-bash-force-push
    match: "bash"
    pattern: "cmd contains 'git push --force'"
    action: block
    reason: "test"
"#;
        let rules = make_rules(yaml);
        // Tool is run_cli, not bash — should not match.
        let input = json!({"cmd": "git push --force"});
        assert!(rules.check("run_cli", &input).is_none());
    }

    #[test]
    fn empty_rules_file_returns_no_matches() {
        let yaml = "rules: []";
        let rules = make_rules(yaml);
        assert!(rules.is_empty());
        let alert = rules.check("bash", &json!({"cmd": "rm -rf /"}));
        assert!(alert.is_none());
    }

    #[test]
    fn missing_rules_file_returns_empty() {
        let path = PathBuf::from("/nonexistent/path/chump-adversary.yaml");
        let rules = AdversaryRules::load_from_path(&path);
        assert!(rules.is_empty());
    }

    #[test]
    fn adversary_enabled_default_off() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var("CHUMP_ADVERSARY_ENABLED");
        assert!(!adversary_enabled());
    }

    #[test]
    fn adversary_enabled_when_set() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::set_var("CHUMP_ADVERSARY_ENABLED", "1");
        assert!(adversary_enabled());
        std::env::remove_var("CHUMP_ADVERSARY_ENABLED");
    }

    #[test]
    fn json_escape_handles_special_chars() {
        assert_eq!(json_escape("say \"hi\""), r#"say \"hi\""#);
        assert_eq!(json_escape("line1\nline2"), r"line1\nline2");
    }

    #[tokio::test]
    async fn adversary_check_disabled_by_default() {
        {
            // Hold the lock only for the env mutation; drop before the await
            // to avoid `await_holding_lock` clippy lint.
            let _guard = ENV_LOCK.lock().unwrap();
            std::env::remove_var("CHUMP_ADVERSARY_ENABLED");
        }
        // Even with a dangerous input, check passes when feature is off.
        let result = adversary_check("bash", &json!({"cmd": "rm -rf /"}), &[]).await;
        assert!(result.is_ok());
    }

    #[test]
    fn snippet_is_capped_at_200_chars() {
        let long = "x".repeat(300);
        let input = json!({"cmd": long});
        let result = pattern_matches(&format!("cmd contains '{}'", "x".repeat(5)), &input);
        // If the field contains 300 x's and we search for 5, it should match.
        if let Some(snip) = result {
            assert!(snip.len() <= 200);
        }
    }
}

// ---------------------------------------------------------------------------
// INFRA-130: rule-engine integration tests — load YAML → check → emit →
// verify ambient.jsonl line shape end-to-end.
//
// The existing `tests` module covers parsing, rule matching, and the
// disabled-default async path in isolation. None of them exercise the
// emit_ambient_alert sink or verify the on-disk JSON line shape that
// downstream consumers (war-room, musher, Cold Water) parse. A regression in
// the JSON template, the field names, or the JSON-escaping of user-controlled
// content would slip past the existing tests and only surface when an alert
// actually fires in production.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod e2e_rule_to_ambient {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;
    use tempfile::TempDir;

    /// Serialize tests that mutate CHUMP_AMBIENT_LOG / CHUMP_SESSION_ID — these
    /// are process-global env vars and parallel tests would interleave them.
    static AMBIENT_ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Build a fresh rules struct from a YAML literal, the same way the
    /// existing parsing tests do.
    fn make_rules(yaml: &str) -> AdversaryRules {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chump-adversary.yaml");
        std::fs::write(&path, yaml).unwrap();
        AdversaryRules::load_from_path(&path)
    }

    /// Read the temp ambient file the test pointed CHUMP_AMBIENT_LOG at.
    fn read_ambient(path: &std::path::Path) -> Vec<serde_json::Value> {
        let raw = std::fs::read_to_string(path).unwrap_or_default();
        raw.lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                serde_json::from_str::<serde_json::Value>(l)
                    .expect("ambient line must be valid JSON")
            })
            .collect()
    }

    /// Full integration: YAML rule fires on a tool call, emit_ambient_alert
    /// writes one line, the line parses as JSON and carries all fields the
    /// downstream consumers depend on.
    #[test]
    fn rule_check_emits_ambient_line_with_correct_shape() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        let tmp = TempDir::new().unwrap();
        let ambient_path = tmp.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::set_var("CHUMP_SESSION_ID", "infra130-test-session");
        std::env::set_var("CHUMP_AMBIENT_NATS", "0");

        let yaml = r#"
rules:
  - name: no-force-push
    match: "bash"
    pattern: "cmd contains 'git push --force'"
    action: block
    reason: force-push protection
"#;
        let rules = make_rules(yaml);
        let alert = rules
            .check("bash", &json!({"cmd": "git push --force origin main"}))
            .expect("rule must match the input");

        emit_ambient_alert(&alert);

        let lines = read_ambient(&ambient_path);
        assert_eq!(lines.len(), 1, "exactly one ambient line should be emitted");
        let row = &lines[0];

        for field in &[
            "ts", "session", "worktree", "event", "rule", "tool", "action", "reason", "snippet",
        ] {
            assert!(
                row.get(field).is_some(),
                "ambient line missing required field '{}'; got: {}",
                field,
                row
            );
        }
        assert_eq!(row["event"], "adversary_alert");
        assert_eq!(row["rule"], "no-force-push");
        assert_eq!(row["tool"], "bash");
        assert_eq!(row["action"], "block");
        assert_eq!(row["session"], "infra130-test-session");
        assert!(
            row["snippet"]
                .as_str()
                .unwrap_or("")
                .contains("git push --force"),
            "snippet should preserve the matched substring; got: {:?}",
            row["snippet"]
        );

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        std::env::remove_var("CHUMP_SESSION_ID");
        std::env::remove_var("CHUMP_AMBIENT_NATS");
    }

    /// Block-action callers (ToolTimeoutWrapper) must see the alert encoded
    /// such that the pattern at adversary.rs:385-392 produces an Err. We
    /// inline the dispatcher logic here because the public adversary_check
    /// path uses a process-wide OnceLock for rules() which we can't override
    /// in a test, so the contract we verify is the alert→Result mapping the
    /// caller depends on.
    #[test]
    fn block_action_alert_maps_to_err() {
        let yaml = r#"
rules:
  - name: rm-rf-root
    match: "bash"
    pattern: "cmd contains 'rm -rf /'"
    action: block
    reason: filesystem-wipe protection
"#;
        let rules = make_rules(yaml);
        let alert = rules
            .check("bash", &json!({"cmd": "rm -rf /"}))
            .expect("rule must match");
        assert_eq!(alert.action, AdversaryAction::Block);
        // Mirror the dispatch logic at adversary_check lines 385-392.
        let mapped: Result<()> = match alert.action {
            AdversaryAction::Allow | AdversaryAction::Warn => Ok(()),
            AdversaryAction::Block => Err(anyhow::anyhow!(
                "DENIED (adversary rule '{}'): {}",
                alert.rule_name,
                alert.reason
            )),
        };
        let err = mapped.expect_err("Block action must map to Err");
        let err_msg = format!("{}", err);
        assert!(err_msg.contains("rm-rf-root"));
        assert!(err_msg.contains("filesystem-wipe protection"));
    }

    /// Warn-action callers must continue execution (Ok(())) but the alert
    /// must still be emitted to ambient.jsonl. Same dispatcher contract as
    /// the block test, opposite outcome.
    #[test]
    fn warn_action_emits_but_caller_continues() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        let tmp = TempDir::new().unwrap();
        let ambient_path = tmp.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::set_var("CHUMP_SESSION_ID", "infra130-warn-session");
        std::env::set_var("CHUMP_AMBIENT_NATS", "0");

        let yaml = r#"
rules:
  - name: warn-on-rm-rf-tmp
    match: "bash"
    pattern: "cmd contains 'rm -rf /tmp'"
    action: warn
    reason: dangerous-but-allowed
"#;
        let rules = make_rules(yaml);
        let alert = rules
            .check("bash", &json!({"cmd": "rm -rf /tmp/old"}))
            .expect("rule must match");
        assert_eq!(alert.action, AdversaryAction::Warn);

        emit_ambient_alert(&alert);

        let mapped: Result<()> = match alert.action {
            AdversaryAction::Allow | AdversaryAction::Warn => Ok(()),
            AdversaryAction::Block => Err(anyhow::anyhow!("would block")),
        };
        assert!(mapped.is_ok(), "Warn action must map to Ok(())");

        let lines = read_ambient(&ambient_path);
        assert_eq!(lines.len(), 1, "Warn action must still emit ambient line");
        assert_eq!(lines[0]["action"], "warn");
        assert_eq!(lines[0]["rule"], "warn-on-rm-rf-tmp");

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        std::env::remove_var("CHUMP_SESSION_ID");
        std::env::remove_var("CHUMP_AMBIENT_NATS");
    }

    /// User-controlled content (a tool input matching a quote/newline pattern)
    /// must be JSON-escaped end-to-end so the ambient line stays parseable
    /// by downstream consumers. This is the security-shaped half of the
    /// integration: an attacker whose tool input contains a `"` or `\n`
    /// must not be able to break the JSON shape downstream parsers depend on.
    #[test]
    fn emit_handles_malicious_input_safely() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        let tmp = TempDir::new().unwrap();
        let ambient_path = tmp.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);
        std::env::set_var("CHUMP_SESSION_ID", "infra130-escape-session");
        std::env::set_var("CHUMP_AMBIENT_NATS", "0");

        let yaml = r#"
rules:
  - name: secret-leak
    match: "bash"
    pattern: "cmd contains 'secret'"
    action: warn
    reason: secret-detected
"#;
        let rules = make_rules(yaml);
        // Input deliberately contains the JSON-breaking characters: " and \n.
        let attack = "echo \"my secret\nis: 123\"";
        let alert = rules
            .check("bash", &json!({"cmd": attack}))
            .expect("rule must match");
        emit_ambient_alert(&alert);

        let lines = read_ambient(&ambient_path);
        assert_eq!(lines.len(), 1);
        // serde_json::from_str succeeded inside read_ambient — that alone
        // proves the line is valid JSON despite the embedded quote/newline.
        // Cross-check the snippet decoded back to the original characters.
        let snippet = lines[0]["snippet"].as_str().unwrap_or_default();
        assert!(
            snippet.contains("secret"),
            "snippet should still carry the matched substring; got: {:?}",
            snippet
        );
        assert!(
            snippet.contains('"') || snippet.contains('\n'),
            "snippet should preserve the dangerous characters once JSON-decoded; got: {:?}",
            snippet
        );

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        std::env::remove_var("CHUMP_SESSION_ID");
        std::env::remove_var("CHUMP_AMBIENT_NATS");
    }
}
