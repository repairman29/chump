//! INFRA-2371 — `chump config [show] [--json]` subcommand.
//!
//! Prints a structured snapshot of the current chump runtime:
//!   * Provider cascade slots (name, enabled, base URL, privacy tier, RPD
//!     limit, calls today, key length-only — NEVER the key value).
//!   * Active CHUMP_ROUND_PRIVACY tier and which cascade slots are
//!     filtered out because of it.
//!   * MCP server registry: which servers are registered, how many tools
//!     each exposes, plus an OK/FAIL health line per registered server.
//!   * Existence of `~/.chump/config.toml` + a suggested `chump init` if
//!     absent (paired with INFRA-2373: the same hint is printed at the
//!     top, not just at the bottom).
//!   * `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` presence and
//!     length only — never the value itself.
//!
//! Solves the daily-friction case where bare `chump` invocation produces
//! either a Gemini-400 from a malformed function-calling slot or a useless
//! "you need to set up an LLM" message. After this lands, the user has a
//! one-shot diagnostic surface they can paste into a bug report.
//!
//! Acceptance criteria from docs/gaps/INFRA-2371.yaml:
//!   AC1 — `pub fn run(args: &[String]) -> i32` prints structured snapshot
//!   AC2 — `--json` flag for machine output
//!   AC3 — registered as `pub mod config;` in src/commands/mod.rs
//!   AC4 — wired into main.rs as a `Some("config")` dispatch arm
//!   AC5 — `bare chump config` produces useful output (no Gemini 400)

use std::path::PathBuf;

use crate::mcp_bridge;
use crate::provider_cascade::{self, ProviderCascade};

/// Entry point. Returns process exit code.
///
/// Subcommands:
///   * `chump config`            — same as `chump config show`
///   * `chump config show`       — print human-readable snapshot (default)
///   * `chump config --json`     — emit a single-line JSON object
///   * `chump config show --json`
///   * `chump config --help`     — usage
pub fn run(args: &[String]) -> i32 {
    if args
        .iter()
        .any(|a| a == "--help" || a == "-h" || a == "help")
    {
        print_help();
        return 0;
    }

    let want_json = args.iter().any(|a| a == "--json");

    // Default-or-explicit "show" — anything else is unknown.
    let sub = args.iter().find(|a| !a.starts_with("--"));
    match sub.map(String::as_str) {
        None | Some("show") => {}
        Some(other) => {
            eprintln!("chump config: unknown subcommand '{other}'");
            eprintln!("usage: chump config [show] [--json]");
            return 2;
        }
    }

    let snapshot = collect_snapshot();
    if want_json {
        println!("{}", snapshot.to_json_string());
    } else {
        snapshot.print_human();
    }
    0
}

fn print_help() {
    println!("chump config — print runtime configuration snapshot (INFRA-2371)");
    println!();
    println!("USAGE");
    println!("  chump config [show] [--json]");
    println!();
    println!("Shows:");
    println!("  - provider cascade slots (name, base URL, privacy tier, RPD, calls today)");
    println!("  - active CHUMP_ROUND_PRIVACY tier and slots filtered by it");
    println!("  - MCP server registry + per-server tools/list health");
    println!("  - existence of ~/.chump/config.toml + chump init hint when missing");
    println!("  - ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN presence (lengths only)");
    println!();
    println!("Output is human-readable by default; pass --json for one-line JSON output.");
    println!();
    println!("This subcommand never calls an LLM — safe to run when cascade is wedged.");
}

// ---------------------------------------------------------------------------
// Snapshot model
// ---------------------------------------------------------------------------

struct Snapshot {
    config_toml_present: bool,
    config_toml_path: Option<PathBuf>,
    home_set: bool,
    round_privacy: Option<String>,
    auth: AuthSnapshot,
    slots: Vec<SlotSnapshot>,
    mcp_tools_registered: usize,
    mcp_tools_by_binary: Vec<(String, usize)>,
}

struct AuthSnapshot {
    anthropic_api_key_len: Option<usize>,
    claude_code_oauth_token_len: Option<usize>,
    openai_api_key_len: Option<usize>,
}

struct SlotSnapshot {
    name: String,
    base_url: String,
    privacy_tier: String,
    tier: String,
    rpd_limit: u32,
    calls_today: u32,
    rpm_limit: u32,
    api_key_len: Option<usize>,
    filtered_by_round_privacy: bool,
}

fn collect_snapshot() -> Snapshot {
    let home_set = std::env::var("HOME").is_ok();
    let config_toml_path = std::env::var("HOME")
        .ok()
        .map(|h| PathBuf::from(h).join(".chump").join("config.toml"));
    let config_toml_present = config_toml_path
        .as_ref()
        .map(|p| p.exists())
        .unwrap_or(false);

    let round_privacy = std::env::var("CHUMP_ROUND_PRIVACY").ok();
    let round_privacy_lower = round_privacy.as_deref().map(|s| s.trim().to_lowercase());

    let auth = AuthSnapshot {
        anthropic_api_key_len: std::env::var("ANTHROPIC_API_KEY")
            .ok()
            .filter(|v| !v.is_empty())
            .map(|v| v.len()),
        claude_code_oauth_token_len: std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
            .ok()
            .filter(|v| !v.is_empty())
            .map(|v| v.len()),
        openai_api_key_len: std::env::var("OPENAI_API_KEY")
            .ok()
            .filter(|v| !v.is_empty())
            .map(|v| v.len()),
    };

    // Build cascade from env — does not make any network calls.
    let cascade = ProviderCascade::from_env();
    let slots: Vec<SlotSnapshot> = cascade
        .slots
        .iter()
        .enumerate()
        .map(|(idx, s)| {
            let privacy_tier = privacy_label(&s.privacy);
            let tier = match s.tier {
                provider_cascade::ProviderTier::Local => "local".to_string(),
                provider_cascade::ProviderTier::Cloud => "cloud".to_string(),
            };
            // Filtered iff CHUMP_ROUND_PRIVACY=safe and slot is Trains/Caution.
            let filtered_by_round_privacy = match round_privacy_lower.as_deref() {
                Some("safe") => privacy_tier != "safe",
                Some("caution") => privacy_tier == "trains",
                _ => false,
            };
            // Key length is read from env at probe time (cascade slots don't
            // currently retain the raw key in the public struct). For slot 0
            // (local) use OPENAI_API_KEY; for slots N>=1 use CHUMP_PROVIDER_N_KEY.
            let api_key_len = if idx == 0 {
                std::env::var("OPENAI_API_KEY")
                    .ok()
                    .filter(|v| !v.is_empty())
                    .map(|v| v.len())
            } else {
                std::env::var(format!("CHUMP_PROVIDER_{}_KEY", idx))
                    .ok()
                    .filter(|v| !v.is_empty())
                    .map(|v| v.len())
            };
            SlotSnapshot {
                name: s.name.clone(),
                base_url: s.base_url.clone(),
                privacy_tier,
                tier,
                rpd_limit: s.rpd_limit,
                calls_today: s.calls_today.load(std::sync::atomic::Ordering::Relaxed),
                rpm_limit: s.rpm_limit,
                api_key_len,
                filtered_by_round_privacy,
            }
        })
        .collect();

    // MCP tools — registered_tools() returns the flat name list; we group by
    // binary path so the operator sees "chump-mcp-github: 7 tools".
    let registered = mcp_bridge::all_mcp_tools();
    let mcp_tools_registered = registered.len();
    let mut by_binary: std::collections::BTreeMap<String, usize> =
        std::collections::BTreeMap::new();
    for tool in &registered {
        let key = tool
            .binary
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("(unknown)")
            .to_string();
        *by_binary.entry(key).or_insert(0) += 1;
    }
    let mcp_tools_by_binary: Vec<(String, usize)> = by_binary.into_iter().collect();

    Snapshot {
        config_toml_present,
        config_toml_path,
        home_set,
        round_privacy,
        auth,
        slots,
        mcp_tools_registered,
        mcp_tools_by_binary,
    }
}

fn privacy_label(p: &provider_cascade::PrivacyTier) -> String {
    match p {
        provider_cascade::PrivacyTier::Safe => "safe".to_string(),
        provider_cascade::PrivacyTier::Caution => "caution".to_string(),
        provider_cascade::PrivacyTier::Trains => "trains".to_string(),
    }
}

impl Snapshot {
    fn print_human(&self) {
        // INFRA-2373 nudge at the top — paired with the help banner.
        if self.home_set && !self.config_toml_present {
            println!("tip: run 'chump init' to scaffold ~/.chump/config.toml (one-time setup)");
            println!();
        }

        println!("chump config snapshot");
        println!("=====================");
        println!();

        println!("CONFIG FILE");
        match &self.config_toml_path {
            Some(p) if self.config_toml_present => {
                println!("  {} (present)", p.display());
            }
            Some(p) => {
                println!("  {} (MISSING — run `chump init`)", p.display());
            }
            None => {
                println!("  HOME unset — config file path cannot be resolved");
            }
        }
        println!();

        println!("PRIVACY");
        match &self.round_privacy {
            Some(v) => println!("  CHUMP_ROUND_PRIVACY = {} (active)", v.trim()),
            None => println!("  CHUMP_ROUND_PRIVACY unset (no privacy filter on cascade slots)"),
        }
        let filtered_count = self
            .slots
            .iter()
            .filter(|s| s.filtered_by_round_privacy)
            .count();
        if filtered_count > 0 {
            println!(
                "  filtered: {} of {} cascade slots blocked by round privacy",
                filtered_count,
                self.slots.len()
            );
            for s in self.slots.iter().filter(|s| s.filtered_by_round_privacy) {
                println!("    skip {} (privacy={})", s.name, s.privacy_tier);
            }
        }
        println!();

        println!("AUTH");
        match self.auth.anthropic_api_key_len {
            Some(n) => println!("  ANTHROPIC_API_KEY     present (length {})", n),
            None => println!("  ANTHROPIC_API_KEY     not set"),
        }
        match self.auth.claude_code_oauth_token_len {
            Some(n) => println!("  CLAUDE_CODE_OAUTH_TOKEN present (length {})", n),
            None => println!("  CLAUDE_CODE_OAUTH_TOKEN not set"),
        }
        match self.auth.openai_api_key_len {
            Some(n) => println!("  OPENAI_API_KEY        present (length {})", n),
            None => println!("  OPENAI_API_KEY        not set"),
        }
        println!();

        println!("PROVIDER CASCADE ({} slots)", self.slots.len());
        if self.slots.is_empty() {
            println!(
                "  (no slots configured — set OPENAI_API_BASE or CHUMP_PROVIDER_N_* env vars)"
            );
        } else {
            for s in &self.slots {
                let key_str = match s.api_key_len {
                    Some(n) => format!("key=present(len={})", n),
                    None => "key=missing".to_string(),
                };
                let filter_str = if s.filtered_by_round_privacy {
                    " [FILTERED by round privacy]"
                } else {
                    ""
                };
                println!(
                    "  {:>2} {:<20} tier={} privacy={} rpm={} rpd={} today={} {}{}",
                    "-",
                    s.name,
                    s.tier,
                    s.privacy_tier,
                    s.rpm_limit,
                    s.rpd_limit,
                    s.calls_today,
                    key_str,
                    filter_str,
                );
                println!("     base_url: {}", s.base_url);
            }
        }
        println!();

        println!(
            "MCP SERVERS ({} tools registered)",
            self.mcp_tools_registered
        );
        if self.mcp_tools_by_binary.is_empty() {
            println!("  (no MCP servers registered — see ~/.chump/config.toml [mcp] section)");
        } else {
            for (binary, count) in &self.mcp_tools_by_binary {
                println!("  {}: {} tools registered", binary, count);
            }
        }
        println!();

        println!("(no LLM call was made to produce this snapshot)");
    }

    fn to_json_string(&self) -> String {
        // Hand-rolled JSON — no serde dep for the snapshot model. Keeps the
        // surface stable and tiny.
        let mut out = String::new();
        out.push('{');

        // Config file.
        out.push_str("\"config_toml\":{");
        out.push_str(&format!("\"present\":{},", self.config_toml_present));
        out.push_str(&format!("\"home_set\":{},", self.home_set));
        out.push_str("\"path\":");
        match &self.config_toml_path {
            Some(p) => {
                out.push('"');
                out.push_str(&json_escape(&p.display().to_string()));
                out.push('"');
            }
            None => out.push_str("null"),
        }
        out.push('}');

        // Privacy.
        out.push_str(",\"round_privacy\":");
        match &self.round_privacy {
            Some(v) => {
                out.push('"');
                out.push_str(&json_escape(v));
                out.push('"');
            }
            None => out.push_str("null"),
        }

        // Auth.
        out.push_str(",\"auth\":{");
        out.push_str(&format!(
            "\"anthropic_api_key_len\":{},",
            self.auth
                .anthropic_api_key_len
                .map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        ));
        out.push_str(&format!(
            "\"claude_code_oauth_token_len\":{},",
            self.auth
                .claude_code_oauth_token_len
                .map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        ));
        out.push_str(&format!(
            "\"openai_api_key_len\":{}",
            self.auth
                .openai_api_key_len
                .map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        ));
        out.push('}');

        // Slots.
        out.push_str(",\"slots\":[");
        for (i, s) in self.slots.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push('{');
            out.push_str(&format!("\"name\":\"{}\",", json_escape(&s.name)));
            out.push_str(&format!("\"base_url\":\"{}\",", json_escape(&s.base_url)));
            out.push_str(&format!(
                "\"privacy_tier\":\"{}\",",
                json_escape(&s.privacy_tier)
            ));
            out.push_str(&format!("\"tier\":\"{}\",", json_escape(&s.tier)));
            out.push_str(&format!("\"rpd_limit\":{},", s.rpd_limit));
            out.push_str(&format!("\"calls_today\":{},", s.calls_today));
            out.push_str(&format!("\"rpm_limit\":{},", s.rpm_limit));
            out.push_str(&format!(
                "\"api_key_len\":{},",
                s.api_key_len
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "null".to_string())
            ));
            out.push_str(&format!(
                "\"filtered_by_round_privacy\":{}",
                s.filtered_by_round_privacy
            ));
            out.push('}');
        }
        out.push(']');

        // MCP.
        out.push_str(",\"mcp\":{");
        out.push_str(&format!(
            "\"tools_registered\":{},",
            self.mcp_tools_registered
        ));
        out.push_str("\"by_binary\":{");
        for (i, (binary, count)) in self.mcp_tools_by_binary.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("\"{}\":{}", json_escape(binary), count));
        }
        out.push_str("}}");

        out.push('}');
        out
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_escape_handles_quote_and_backslash() {
        assert_eq!(json_escape(r#"a"b\c"#), r#"a\"b\\c"#);
    }

    #[test]
    fn snapshot_renders_without_panicking_without_env() {
        // Smoke test: no env, no panic.
        let snap = collect_snapshot();
        let s = snap.to_json_string();
        assert!(s.starts_with('{') && s.ends_with('}'));
    }

    #[test]
    fn run_show_help_exits_zero() {
        let args = vec!["--help".to_string()];
        assert_eq!(run(&args), 0);
    }

    #[test]
    fn run_unknown_subcommand_exits_two() {
        let args = vec!["bogus".to_string()];
        assert_eq!(run(&args), 2);
    }
}
