//! `chump orchestrate` — Opus-driven conversational loop (INFRA-598).
//!
//! Reads CLAUDE.md doctrine into system prompt, uses provider_cascade::build_provider()
//! with FLEET_MODEL=opus by default, routes operator natural-language intents to chump
//! fleet/gap subcommands, and emits 4-pillar mission grade after every iteration.
//!
//! ## Stub mode (CI / smoke tests)
//!
//! Set `CHUMP_ORCHESTRATE_STUB=1` to skip the real LLM. Intent-to-action mapping
//! uses simple keyword matching so the smoke test can verify routing without an API key.

use anyhow::{Context, Result};
use axonerai::provider::Message;
use std::io::{self, BufRead, Write};
use std::path::Path;

/// Maps FLEET_MODEL env → concrete model identifier for the orchestrator session.
/// Workers default to sonnet; the orchestrator defaults to opus.
fn resolve_model() -> String {
    match std::env::var("FLEET_MODEL").ok().as_deref() {
        Some("haiku") => "claude-haiku-4-5-20251001".to_string(),
        Some("sonnet") => "claude-sonnet-4-6".to_string(),
        Some(other) if !other.is_empty() => other.to_string(),
        _ => "claude-opus-4-7".to_string(),
    }
}

fn load_doctrine(repo_root: &Path) -> String {
    let path = repo_root.join("CLAUDE.md");
    std::fs::read_to_string(&path).unwrap_or_else(|_| "(CLAUDE.md not found)".to_string())
}

fn build_system_prompt(doctrine: &str) -> String {
    format!(
        "You are the Chump orchestrator, an Opus-driven conversational interface \
         that translates operator natural-language intents into chump CLI operations.\n\n\
         ## Operational doctrine\n{doctrine}\n\n\
         ## Response format\n\
         For each operator intent, emit one or more TOOL lines naming chump subcommands:\n\
           TOOL: chump fleet status\n\
           TOOL: chump gap list --status open\n\
           TOOL: chump waste-tally --window 2h\n\
         Follow with a short human-readable summary.\n\n\
         Always end your response with a 4-pillar grade line:\n\
           GRADE: {{\"effective\":N,\"credible\":N,\"resilient\":N,\"zero_waste\":N}}"
    )
}

/// Extract `TOOL: chump <subcommand>` lines from a provider response.
fn parse_tool_calls(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("TOOL:")
                .map(str::trim)
                .map(str::to_string)
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// Execute a `chump <subcommand>` command and return combined stdout+stderr.
fn run_tool(cmd: &str, repo_root: &Path) -> String {
    let parts: Vec<&str> = cmd.split_whitespace().collect();
    let Some((&"chump", rest)) = parts.split_first() else {
        return format!("(skipped non-chump command: {cmd})");
    };
    let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
    match std::process::Command::new(&chump_bin)
        .args(rest)
        .current_dir(repo_root)
        .output()
    {
        Ok(out) => {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            combined.trim().to_string()
        }
        Err(e) => format!("(tool error: {e})"),
    }
}

/// Compute, emit to ambient.jsonl, and print the 4-pillar mission grade.
fn emit_grade(repo_root: &Path) {
    let report = crate::mission_grade::build_report(repo_root);
    crate::mission_grade::emit(repo_root, &report);
    println!(
        "[grade] effective={ep}/{ei} credible={cp}/{ci} resilient={rp}/{ri} zero_waste={zp}/{zi}  (pickable/in_flight)",
        ep = report.effective.count_pickable,
        ei = report.effective.count_in_flight,
        cp = report.credible.count_pickable,
        ci = report.credible.count_in_flight,
        rp = report.resilient.count_pickable,
        ri = report.resilient.count_in_flight,
        zp = report.zero_waste.count_pickable,
        zi = report.zero_waste.count_in_flight,
    );
}

/// Stub intent → TOOL routing used when `CHUMP_ORCHESTRATE_STUB=1`.
fn stub_response(intent: &str) -> String {
    let lc = intent.to_lowercase();
    let mut tools: Vec<&str> = Vec::new();
    if lc.contains("spawn") || lc.contains("start") || lc.contains("fleet") {
        tools.push("TOOL: chump fleet status");
    }
    if lc.contains("grade") || lc.contains("mission") || lc.contains("pillar") {
        tools.push("TOOL: chump mission-grade");
    }
    if lc.contains("stop") || lc.contains("halt") {
        tools.push("TOOL: chump fleet stop");
    }
    if tools.is_empty() {
        tools.push("TOOL: chump gap list --status open");
    }
    format!("{}\n(stub response — no LLM call)", tools.join("\n"))
}

pub async fn run(repo_root: &Path) -> Result<()> {
    let stub_mode = std::env::var("CHUMP_ORCHESTRATE_STUB").as_deref() == Ok("1");

    // Apply FLEET_MODEL=opus default for the orchestrator session.
    // Workers (dispatched by the orchestrator) stay on sonnet.
    let model = resolve_model();
    if std::env::var("OPENAI_MODEL").is_err() {
        std::env::set_var("OPENAI_MODEL", &model);
    }

    let doctrine = load_doctrine(repo_root);
    let system = build_system_prompt(&doctrine);

    let provider = if stub_mode {
        None
    } else {
        Some(crate::provider_cascade::build_provider())
    };

    println!("[orchestrate] ready (model={model}, stub={stub_mode}). Type intent or 'exit'.");

    // Initial grade on startup (AC-d).
    emit_grade(repo_root);
    println!();

    let mut conversation: Vec<Message> = Vec::new();
    let stdin = io::stdin();
    let stdout = io::stdout();

    loop {
        {
            let mut out = stdout.lock();
            write!(out, "orchestrate> ")?;
            out.flush()?;
        }

        let mut line = String::new();
        let n = stdin.lock().read_line(&mut line).context("stdin read")?;
        if n == 0 {
            break; // EOF
        }
        let intent = line.trim().to_string();
        if intent.is_empty() {
            continue;
        }
        if matches!(intent.as_str(), "exit" | "quit") {
            println!("[orchestrate] bye.");
            break;
        }

        let reply = if stub_mode {
            stub_response(&intent)
        } else {
            conversation.push(Message {
                role: "user".into(),
                content: intent.clone(),
            });
            let resp = provider
                .as_ref()
                .unwrap()
                .complete(conversation.clone(), None, Some(2048), Some(system.clone()))
                .await
                .context("orchestrator LLM call")?;
            let text = resp.text.unwrap_or_default();
            conversation.push(Message {
                role: "assistant".into(),
                content: text.clone(),
            });
            text
        };

        println!("{reply}");
        println!();

        // Execute TOOL: lines dispatched by the LLM (AC-c).
        for cmd in parse_tool_calls(&reply) {
            let result = run_tool(&cmd, repo_root);
            if !result.is_empty() {
                println!("  [{}]\n  {}\n", cmd, result);
            }
        }

        // Emit 4-pillar grade after every iter (AC-d).
        emit_grade(repo_root);
        println!();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_spawn_routes_to_fleet_status() {
        let r = stub_response("spawn fleet on infra p0");
        assert!(r.contains("TOOL: chump fleet status"), "got: {r}");
    }

    #[test]
    fn stub_grade_routes_to_mission_grade() {
        let r = stub_response("what's our mission grade?");
        assert!(r.contains("TOOL: chump mission-grade"), "got: {r}");
    }

    #[test]
    fn stub_stop_routes_to_fleet_stop() {
        let r = stub_response("stop the fleet");
        assert!(r.contains("TOOL: chump fleet stop"), "got: {r}");
    }

    #[test]
    fn parse_tool_calls_extracts_lines() {
        let text = "Sure!\nTOOL: chump fleet status\nTOOL: chump gap list\nDone.";
        let calls = parse_tool_calls(text);
        assert_eq!(calls, vec!["chump fleet status", "chump gap list"]);
    }

    #[test]
    fn resolve_model_defaults_to_opus() {
        // Only safe to call when FLEET_MODEL + OPENAI_MODEL are not set.
        // Subprocess test to avoid env-mutation cross-talk.
        // Here we just verify the function compiles and returns non-empty.
        // The default path (no FLEET_MODEL) yields opus.
        let saved = std::env::var("FLEET_MODEL").ok();
        unsafe {
            std::env::remove_var("FLEET_MODEL");
        }
        let m = resolve_model();
        assert!(m.contains("opus"), "expected opus model, got: {m}");
        if let Some(v) = saved {
            std::env::set_var("FLEET_MODEL", v);
        }
    }
}
