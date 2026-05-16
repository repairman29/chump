//! `chump orchestrate` — Opus-driven conversational loop (INFRA-598, INFRA-796, INFRA-797).
//!
//! Reads CLAUDE.md doctrine into system prompt, uses provider_cascade::build_provider()
//! with FLEET_MODEL=opus by default, routes operator natural-language intents to chump
//! fleet/gap subcommands, emits 4-pillar mission grade after every iteration, and runs
//! a background 30-min auto-grade timer.
//!
//! ## Telemetry (INFRA-796)
//!
//! Each iteration emits a `kind=orchestrate_intent` event to ambient.jsonl with:
//!   - `intent`: the operator's natural-language input
//!   - `status`: success / failure / timeout
//!   - `tool_count`: number of TOOL lines dispatched
//!   - `est_input_tokens` / `est_output_tokens`: approximate token counts
//!   - `elapsed_ms`: wall-clock duration of the LLM call
//!
//! Tool execution failures are classified as transient (network/rate-limit) vs
//! permanent (syntax/unknown-command) via the `failure_class` field.
//!
//! ## Auto-grade timer (INFRA-797)
//!
//! A background tokio task emits `kind=mission_grade` to ambient.jsonl every 30
//! minutes, so the operator always has a recent scorecard even during long pauses.
//!
//! ## Stub mode (CI / smoke tests)
//!
//! Set `CHUMP_ORCHESTRATE_STUB=1` to skip the real LLM. Intent-to-action mapping
//! uses simple keyword matching so the smoke test can verify routing without an API key.

use anyhow::{Context, Result};
use axonerai::provider::Message;
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::time::{Duration, Instant};

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

/// Emit a structured event to ambient.jsonl for fleet observability (INFRA-796).
fn emit_ambient_event(repo_root: &Path, kind: &str, fields: &[(&str, &str)]) {
    // Respect CHUMP_AMBIENT_IN_PROMPT override (used by tests and CI).
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        Path::new(&path).to_path_buf()
    } else {
        let lock_dir = repo_root.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    let event = serde_json::Value::Object(map).to_string();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{event}");
    }
}

/// Rough token estimate: 1 token ≈ 4 characters for English text.
/// Used for cost approximation when the provider doesn't return usage.
fn estimate_tokens(text: &str) -> u64 {
    (text.len() / 4).max(1) as u64
}

/// Rough cost estimate for an orchestrate session.
/// Uses claude-opus-4 pricing as default since orchestrator runs opus.
/// Input: ~$15/1M tokens = $0.000015/token
/// Output: ~$75/1M tokens = $0.000075/token
fn estimate_cost_usd(input_tokens: u64, output_tokens: u64) -> f64 {
    (input_tokens as f64 * 0.000015) + (output_tokens as f64 * 0.000075)
}

/// Emit kind=orchestrate_session_summary at the end of every orchestrate session.
/// Session metrics bundled to avoid too-many-arguments clippy lint.
struct SessionSummaryStats {
    intents_routed: u64,
    intents_failed: u64,
    tool_calls: u64,
    cost_usd: f64,
    wall_time_s: u64,
}

/// Uses typed JSON values (ints/floats) rather than string-only ambient events.
/// INFRA-1363.
fn emit_session_summary(
    repo_root: &Path,
    session_id: &str,
    stats: SessionSummaryStats,
    exit_reason: &str,
) {
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        std::path::PathBuf::from(&path)
    } else {
        let lock_dir = repo_root.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = serde_json::json!({
        "ts": ts,
        "kind": "orchestrate_session_summary",
        "session_id": session_id,
        "intents_routed": stats.intents_routed,
        "intents_failed": stats.intents_failed,
        "tool_calls": stats.tool_calls,
        "cost_usd": (stats.cost_usd * 10000.0).round() / 10000.0,
        "wall_time_s": stats.wall_time_s,
        "exit_reason": exit_reason,
    });
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{event}");
    }
}

/// Outcome of a single LLM call attempt under timeout (INFRA-1364).
#[derive(Debug)]
enum LlmAttemptOutcome {
    /// Call completed normally; contains the reply text.
    Ok(String),
    /// Call exceeded the timeout deadline.
    TimedOut { elapsed_s: u64 },
}

/// Classify a tool execution failure as transient or permanent (INFRA-796).
fn classify_failure(error_msg: &str) -> &'static str {
    let lc = error_msg.to_lowercase();
    if lc.contains("timed out")
        || lc.contains("timeout")
        || lc.contains("rate limit")
        || lc.contains("too many requests")
        || lc.contains("connection refused")
        || lc.contains("connection reset")
        || lc.contains("network error")
        || lc.contains("5xx")
        || lc.contains("internal server error")
        || lc.contains("service unavailable")
    {
        "transient"
    } else {
        "permanent"
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

/// Load the last `limit` ambient.jsonl events that carry the given `session_id` field.
///
/// Events are returned in chronological order (oldest first). If `CHUMP_AMBIENT_IN_PROMPT`
/// is set, reads from that path instead of `.chump-locks/ambient.jsonl`.
fn load_session_events(
    repo_root: &Path,
    session_id: &str,
    limit: usize,
) -> Vec<serde_json::Map<String, serde_json::Value>> {
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        std::path::PathBuf::from(path)
    } else {
        repo_root.join(".chump-locks").join("ambient.jsonl")
    };
    let Ok(content) = std::fs::read_to_string(&ambient) else {
        return Vec::new();
    };
    let matching: Vec<_> = content
        .lines()
        .filter_map(|line| {
            let v: serde_json::Value = serde_json::from_str(line).ok()?;
            let map = v.into_object()?;
            let ev_session = map.get("session_id").and_then(|v| v.as_str()).unwrap_or("");
            if ev_session == session_id {
                Some(map)
            } else {
                None
            }
        })
        .collect();
    // Take the last `limit` events, preserving chronological order.
    if matching.len() <= limit {
        matching
    } else {
        matching.into_iter().rev().take(limit).rev().collect()
    }
}

/// Extension trait to convert `serde_json::Value` to `Option<serde_json::Map>`.
trait IntoObject {
    fn into_object(self) -> Option<serde_json::Map<String, serde_json::Value>>;
}
impl IntoObject for serde_json::Value {
    fn into_object(self) -> Option<serde_json::Map<String, serde_json::Value>> {
        match self {
            serde_json::Value::Object(m) => Some(m),
            _ => None,
        }
    }
}

/// `chump orchestrate --resume <session-id>` — recover from a crashed/timed-out session.
///
/// Reads the last 200 ambient events for the given session_id:
/// - If exit_reason=clean (session completed normally), refuses with an error message.
/// - If exit_reason is missing (no summary event) or crash/timeout/user_quit,
///   re-poses the last unanswered intent and drops into the normal interactive loop.
/// - Refuses if the session has already been resumed CHUMP_ORCHESTRATE_MAX_RESUMES times.
///
/// Emits kind=orchestrate_session_resumed on successful recovery.
pub async fn resume(repo_root: &Path, session_id: &str) -> Result<()> {
    let events = load_session_events(repo_root, session_id, 200);

    // --- AC-2: refuse if the session was clean-exited -------------------------
    // Look for orchestrate_session_summary (INFRA-1363) with exit_reason=clean,
    // or fall back to orchestrate_session_end with status=ok (current codebase).
    let exit_reason = events
        .iter()
        .rfind(|e| e.get("kind").and_then(|v| v.as_str()) == Some("orchestrate_session_summary"))
        .and_then(|e| e.get("exit_reason"))
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| {
            // Pre-INFRA-1363 fallback: infer clean from orchestrate_session_end + status=ok.
            let clean = events.iter().any(|e| {
                e.get("kind").and_then(|v| v.as_str()) == Some("orchestrate_session_end")
                    && e.get("status").and_then(|v| v.as_str()) == Some("ok")
                    && e.get("intent").and_then(|v| v.as_str()) == Some("exit")
            });
            if clean {
                "clean"
            } else {
                ""
            }
        });

    if exit_reason == "clean" {
        eprintln!(
            "session {} already completed — start a fresh session",
            session_id
        );
        std::process::exit(1);
    }

    // --- AC-5: check resume attempt limit ------------------------------------
    let prior_resumes = events
        .iter()
        .filter(|e| e.get("kind").and_then(|v| v.as_str()) == Some("orchestrate_session_resumed"))
        .count();

    let max_resumes: usize = std::env::var("CHUMP_ORCHESTRATE_MAX_RESUMES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);

    if prior_resumes >= max_resumes {
        eprintln!(
            "session {} has been resumed {} time(s) — limit is {}; \
             refusing to avoid infinite resume loop",
            session_id, prior_resumes, max_resumes
        );
        std::process::exit(1);
    }

    // --- AC-3: find the last unanswered intent --------------------------------
    let last_intent = events
        .iter()
        .rfind(|e| e.get("kind").and_then(|v| v.as_str()) == Some("orchestrate_intent"))
        .and_then(|e| e.get("intent"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // --- AC-4: emit orchestrate_session_resumed ------------------------------
    let events_replayed = events.len().to_string();
    let resume_attempts = (prior_resumes + 1).to_string();
    tracing::info!(
        kind = "orchestrate_session_resumed",
        session_id = session_id,
        events_replayed = events.len(),
        resume_attempts = prior_resumes + 1,
        "session resumed"
    );
    emit_ambient_event(
        repo_root,
        "orchestrate_session_resumed",
        &[
            ("session_id", session_id),
            ("events_replayed", &events_replayed),
            ("resume_attempts", &resume_attempts),
            (
                "prior_exit_reason",
                if exit_reason.is_empty() {
                    "unknown"
                } else {
                    exit_reason
                },
            ),
        ],
    );

    // --- AC-3: re-pose last intent to operator --------------------------------
    println!(
        "[orchestrate --resume] Session {} recovered ({} events replayed, attempt {}/{})",
        session_id, events_replayed, resume_attempts, max_resumes
    );
    if !last_intent.is_empty() {
        println!(
            "[orchestrate --resume] Last intent: '{}' — completed routing, \
             awaiting confirmation when session crashed",
            last_intent
        );
    }
    println!("[orchestrate --resume] Resuming interactive loop. Type intent or 'exit'.");
    println!();

    // Drop into the normal interactive session.
    run(repo_root).await
}

pub async fn run(repo_root: &Path) -> Result<()> {
    let stub_mode = std::env::var("CHUMP_ORCHESTRATE_STUB").as_deref() == Ok("1");

    // LLM timeout config (INFRA-1364). Default 60s; scale down in tests via env.
    let llm_timeout_s: u64 = std::env::var("CHUMP_ORCHESTRATE_LLM_TIMEOUT_S")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60);
    let llm_timeout = Duration::from_secs(llm_timeout_s);

    // Stub timeout simulation: set CHUMP_ORCHESTRATE_STUB_SLEEP_S=N to make the
    // first LLM call per intent sleep N seconds (triggers timeout when N > llm_timeout_s).
    let stub_sleep_s: u64 = std::env::var("CHUMP_ORCHESTRATE_STUB_SLEEP_S")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    // Session identity (INFRA-1363 / INFRA-1364): use env if provided, else synthesize.
    let session_id = std::env::var("CHUMP_ORCHESTRATE_SESSION_ID").unwrap_or_else(|_| {
        format!(
            "orchestrate-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        )
    });

    // Session-level counters (INFRA-1363).
    let session_start = Instant::now();
    let mut intents_routed: u64 = 0;
    let mut intents_failed: u64 = 0;
    let mut total_tool_calls: u64 = 0;
    let mut total_est_input_tokens: u64 = 0;
    let mut total_est_output_tokens: u64 = 0;
    // exit_reason is set before every break/return; default covers unexpected
    // returns from the async block.
    let mut exit_reason = "crash";

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

    // Spawn background auto-grade timer (INFRA-797): emit mission grade every 30 min.
    let bg_root = repo_root.to_path_buf();
    let _bg_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(1800));
        loop {
            interval.tick().await;
            emit_grade(&bg_root);
        }
    });

    println!("[orchestrate] ready (model={model}, stub={stub_mode}). Type intent or 'exit'.");

    // Initial grade on startup (AC-d).
    emit_grade(repo_root);
    println!();

    let mut conversation: Vec<Message> = Vec::new();
    let stdin = io::stdin();
    let stdout = io::stdout();

    let loop_result: Result<()> = async {
        loop {
            {
                let mut out = stdout.lock();
                write!(out, "orchestrate> ")?;
                out.flush()?;
            }

            let mut line = String::new();
            let n = stdin.lock().read_line(&mut line).context("stdin read")?;
            if n == 0 {
                // EOF — operator closed stdin (Ctrl-D) or pipe ended.
                exit_reason = "user_quit";
                break;
            }
            let intent = line.trim().to_string();
            if intent.is_empty() {
                continue;
            }
            if matches!(intent.as_str(), "exit" | "quit") {
                emit_ambient_event(
                    repo_root,
                    "orchestrate_session_end",
                    &[("intent", "exit"), ("status", "ok")],
                );
                println!("[orchestrate] bye.");
                exit_reason = "clean";
                break;
            }

            let iter_start = Instant::now();
            let mut tool_count: usize = 0;
            let mut had_failure = false;
            let mut failure_classes: Vec<&str> = Vec::new();

            // ── LLM call with timeout + single retry (INFRA-1364) ─────────────────
            // Push user intent before attempt loop so retry reuses the same context.
            if !stub_mode {
                conversation.push(Message {
                    role: "user".into(),
                    content: intent.clone(),
                });
            }

            let mut timeout_abort = false;
            let reply = 'attempts: {
                for attempt in 1u32..=2 {
                    let call_start = Instant::now();

                    // Build the outcome for this attempt (stub vs real).
                    let outcome: Result<LlmAttemptOutcome> = if stub_mode {
                        // Stub path: simulate hang on attempt 1 if CHUMP_ORCHESTRATE_STUB_SLEEP_S is set.
                        if stub_sleep_s > 0 && attempt == 1 {
                            match tokio::time::timeout(
                                llm_timeout,
                                tokio::time::sleep(Duration::from_secs(stub_sleep_s)),
                            )
                            .await
                            {
                                Err(_) => Ok(LlmAttemptOutcome::TimedOut {
                                    elapsed_s: call_start.elapsed().as_secs(),
                                }),
                                Ok(_) => Ok(LlmAttemptOutcome::Ok(stub_response(&intent))),
                            }
                        } else {
                            Ok(LlmAttemptOutcome::Ok(stub_response(&intent)))
                        }
                    } else {
                        // Real provider path.
                        match tokio::time::timeout(
                            llm_timeout,
                            provider.as_ref().unwrap().complete(
                                conversation.clone(),
                                None,
                                Some(2048),
                                Some(system.clone()),
                            ),
                        )
                        .await
                        {
                            Err(_) => Ok(LlmAttemptOutcome::TimedOut {
                                elapsed_s: call_start.elapsed().as_secs(),
                            }),
                            Ok(Err(e)) => Err(e.context("orchestrator LLM call")),
                            Ok(Ok(resp)) => Ok(LlmAttemptOutcome::Ok(resp.text.unwrap_or_default())),
                        }
                    };

                    match outcome? {
                        LlmAttemptOutcome::Ok(text) => {
                            if !stub_mode {
                                conversation.push(Message {
                                    role: "assistant".into(),
                                    content: text.clone(),
                                });
                            }
                            break 'attempts text;
                        }
                        LlmAttemptOutcome::TimedOut { elapsed_s } => {
                            tracing::warn!(
                                kind = "orchestrate_llm_timeout",
                                session_id = %session_id,
                                attempt_number = attempt,
                                elapsed_s = elapsed_s,
                                "LLM call timed out (INFRA-1364)"
                            );
                            emit_ambient_event(
                                repo_root,
                                "orchestrate_llm_timeout",
                                &[
                                    ("session_id", &session_id),
                                    ("attempt_number", &attempt.to_string()),
                                    ("call_kind", "intent_parse"),
                                    ("elapsed_s", &elapsed_s.to_string()),
                                ],
                            );
                            eprintln!(
                                "[orchestrate] LLM call timed out (attempt {attempt}/2, elapsed={elapsed_s}s)"
                            );
                            if attempt == 2 {
                                // Double timeout → abort session (exit_reason="timeout" for INFRA-1363).
                                eprintln!("[orchestrate] 2 consecutive timeouts — aborting session.");
                                emit_ambient_event(
                                    repo_root,
                                    "orchestrate_session_end",
                                    &[("intent", &intent), ("status", "timeout")],
                                );
                                timeout_abort = true;
                                exit_reason = "timeout";
                                break 'attempts String::from(
                                    "(session aborted: LLM unresponsive after 2 attempts)",
                                );
                            }
                            // Retry after 2× backoff (scales with timeout_s for fast CI tests).
                            let backoff_s = 2 * llm_timeout_s;
                            eprintln!("[orchestrate] retrying after {backoff_s}s backoff...");
                            tokio::time::sleep(Duration::from_secs(backoff_s)).await;
                        }
                    }
                }
                // Unreachable: loop always breaks via 'attempts label above.
                String::new()
            };

            if timeout_abort {
                break;
            }
            // ── End LLM call with timeout + retry ─────────────────────────────────

            let llm_elapsed_ms = iter_start.elapsed().as_millis() as u64;

            println!("{reply}");
            println!();

            // Execute TOOL: lines dispatched by the LLM (AC-c).
            let tool_start = Instant::now();
            for cmd in parse_tool_calls(&reply) {
                tool_count += 1;
                let result = run_tool(&cmd, repo_root);
                if !result.is_empty() {
                    println!("  [{}]\n  {}\n", cmd, result);
                }
                // Classify tool execution failures (INFRA-796).
                if result.contains("error") || result.contains("Error") || result.contains("failed") {
                    had_failure = true;
                    failure_classes.push(classify_failure(&result));
                }
            }
            let tool_elapsed_ms = tool_start.elapsed().as_millis() as u64;

            // Update session counters (INFRA-1363).
            intents_routed += 1;
            if had_failure {
                intents_failed += 1;
            }
            total_tool_calls += tool_count as u64;
            let est_in = estimate_tokens(&format!("{system}\n{intent}"));
            let est_out = estimate_tokens(&reply);
            total_est_input_tokens += est_in;
            total_est_output_tokens += est_out;

            // Emit per-intent telemetry event (INFRA-796).
            let total_elapsed = llm_elapsed_ms + tool_elapsed_ms;
            let failure_class = if had_failure {
                if failure_classes.contains(&"transient") {
                    "transient"
                } else {
                    "permanent"
                }
            } else {
                "none"
            };
            emit_ambient_event(
                repo_root,
                "orchestrate_intent",
                &[
                    ("intent", &intent),
                    ("status", if had_failure { "failure" } else { "success" }),
                    ("tool_count", &tool_count.to_string()),
                    ("est_input_tokens", &est_in.to_string()),
                    ("est_output_tokens", &est_out.to_string()),
                    ("elapsed_ms", &total_elapsed.to_string()),
                    ("failure_class", failure_class),
                ],
            );

            // Emit 4-pillar grade after every iter (AC-d).
            emit_grade(repo_root);
            println!();

            // If a non-stubbed session hits an intent with no errors, update exit_reason
            // so a future clean break is not shadowed.
            if !had_failure {
                exit_reason = "clean";
            }
        }
        Ok(())
    }
    .await;

    // Emit session summary regardless of how the loop ended (INFRA-1363).
    if loop_result.is_err() {
        exit_reason = "crash";
    }
    let wall_time_s = session_start.elapsed().as_secs();
    let cost_usd = estimate_cost_usd(total_est_input_tokens, total_est_output_tokens);
    emit_session_summary(
        repo_root,
        &session_id,
        SessionSummaryStats {
            intents_routed,
            intents_failed,
            tool_calls: total_tool_calls,
            cost_usd,
            wall_time_s,
        },
        exit_reason,
    );

    loop_result
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
