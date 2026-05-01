//! OpenAI-compatible provider that uses a configurable base URL (e.g. Ollama at http://localhost:11434/v1).
//! Supports retries with backoff, optional fallback URL (CHUMP_FALLBACK_API_BASE), and a simple circuit breaker.
//! When a [`crate::stream_events::EventSender`] is available via task-local [`STREAM_EVENT_TX`],
//! requests use `"stream": true` and emit [`crate::stream_events::AgentEvent::TextDelta`] per chunk.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool, ToolCall};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::time::sleep;

use crate::stream_events::{AgentEvent, EventSender};

tokio::task_local! {
    /// Set by [`crate::streaming_provider::StreamingProvider`] so HTTP providers can emit
    /// [`AgentEvent::TextDelta`] while streaming. Read in [`LocalOpenAIProvider::complete`].
    pub static STREAM_EVENT_TX: EventSender;
}

/// Strip Qwen3 <think>...</think> blocks from model output.
/// These appear when thinking mode leaks through despite /no_think.
pub(crate) fn strip_think_blocks(text: &str) -> String {
    if !text.contains("<think>") {
        return text.to_string();
    }
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("<think>") {
        result.push_str(&rest[..start]);
        if let Some(end) = rest[start..].find("</think>") {
            rest = &rest[start + end + 8..];
            if rest.starts_with('\n') {
                rest = &rest[1..];
            }
        } else {
            break;
        }
    }
    result.push_str(rest);
    let trimmed = result.trim().to_string();
    if trimmed.is_empty() {
        "(no response)".to_string()
    } else {
        trimmed
    }
}

/// Routes streaming `<think>` content to [`AgentEvent::ThinkingDelta`] and non-think content
/// to [`AgentEvent::TextDelta`] when `CHUMP_THINKING=1`.
///
/// Qwen3 emits `<think>...</think>` at the start of its response before any regular text.
/// Chunks can arrive mid-tag, so we buffer uncertain bytes until we can decide.
///
/// **INFRA-184 plain-prose CoT extension.** Reasoning models that don't wrap their
/// chain-of-thought in `<think>` tags (e.g. Qwen3.5-OptiQ emits `Thinking Process:\n\n1. ...`)
/// are detected at stream start by the [`PlainCotState`] sub-state-machine and routed to
/// `ThinkingDelta` until a transition marker (e.g. `\n\nFinal Answer:`) or end-of-stream.
/// Disable with `CHUMP_PLAIN_COT=0` if you need the legacy "everything is text" behavior
/// for a non-reasoning model that happens to start a reply with one of the prefix words.
pub(crate) struct ThinkStreamState {
    /// Whether `CHUMP_THINKING=1` is in effect. When false, all content → TextDelta.
    pub enabled: bool,
    inside_think: bool,
    /// Bytes accumulated while we're unsure if they're part of a `<think>` or `</think>` tag.
    buf: String,
    /// INFRA-184: plain-prose CoT detection state. Decided once at stream start.
    plain_cot: PlainCotState,
}

/// INFRA-184: state machine for plain-prose Chain-of-Thought detection.
/// Decided once per stream during the first ~64 bytes (or first newline).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PlainCotState {
    /// Initial — haven't buffered enough to classify the response prefix.
    Undecided,
    /// Prefix matched a known plain-CoT pattern; route as ThinkingDelta until
    /// a transition marker is found (or end-of-stream).
    Active,
    /// Prefix did not match (or transition already seen) — fall through to
    /// the existing `<think>`-tag routing logic.
    NotApplicable,
}

const OPEN_TAG: &str = "<think>";
const CLOSE_TAG: &str = "</think>";
const OPEN_TAG_LEN: usize = OPEN_TAG.len();
const CLOSE_TAG_LEN: usize = CLOSE_TAG.len();

/// INFRA-184: prefixes (case-insensitive, leading-whitespace tolerant) that mark
/// the start of plain-prose CoT. Conservative list — only patterns we have
/// directly observed or that are documented model behavior.
const PLAIN_COT_PREFIXES: &[&str] = &[
    "thinking process:",
    "thinking:",
    "reasoning:",
    "let me think",
    "let's think",
    "i need to think",
    "i'll think through",
    "i'll work through",
    "i should think",
    "step 1:",
    "## step 1",
    "**step 1",
    "first, ", // common CoT opener
];

/// INFRA-184: transition markers that end the plain-CoT phase. The marker
/// itself is consumed; everything before goes as ThinkingDelta, everything
/// after as TextDelta. Match is case-sensitive on the punctuation but
/// case-insensitive on the keyword via [`find_case_insensitive`].
const PLAIN_COT_TRANSITIONS: &[&str] = &[
    "\n\nfinal answer:",
    "\n\nanswer:",
    "\n\noutput:",
    "\n\nresponse:",
    "\nfinal answer:",
    "\nanswer:",
    "\n## answer",
    "\n## final",
    "\n\n## answer",
    "\n\n## final",
    "\n---\n",
];

/// Bytes to buffer at stream start before deciding plain-CoT classification.
/// Long enough to catch the longest prefix in [`PLAIN_COT_PREFIXES`] with
/// some leading whitespace; short enough that classification happens within
/// one or two streamed chunks.
const PLAIN_COT_SNIFF_LEN: usize = 64;

/// Case-insensitive substring search. Returns the byte offset of the first
/// occurrence of `needle` in `haystack`, ignoring ASCII case.
fn find_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return if needle.is_empty() { Some(0) } else { None };
    }
    let h_lower = haystack.to_ascii_lowercase();
    let n_lower = needle.to_ascii_lowercase();
    h_lower.find(&n_lower)
}

/// True when one of [`PLAIN_COT_PREFIXES`] matches at the start of `s`,
/// after skipping leading ASCII whitespace.
fn matches_plain_cot_prefix(s: &str) -> bool {
    let trimmed = s.trim_start();
    let trimmed_lower = trimmed.to_ascii_lowercase();
    PLAIN_COT_PREFIXES
        .iter()
        .any(|p| trimmed_lower.starts_with(p))
}

/// Returns true unless `CHUMP_PLAIN_COT=0` / `false` is set. Default ON whenever
/// `CHUMP_THINKING=1` enables [`ThinkStreamState`], because the user has already
/// opted into thinking-content routing — we want plain-prose CoT to come along
/// for the ride. Set `CHUMP_PLAIN_COT=0` to fall back to the pre-INFRA-184
/// "tags only" behavior.
pub(crate) fn chump_plain_cot_enabled() -> bool {
    !std::env::var("CHUMP_PLAIN_COT")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false)
}

impl ThinkStreamState {
    pub fn new(enabled: bool) -> Self {
        let plain_cot = if enabled && chump_plain_cot_enabled() {
            PlainCotState::Undecided
        } else {
            PlainCotState::NotApplicable
        };
        Self {
            enabled,
            inside_think: false,
            buf: String::new(),
            plain_cot,
        }
    }

    /// Process one streaming `delta`, sending events to `event_tx`.
    /// Returns `false` if the channel is closed.
    pub fn process(&mut self, delta: &str, event_tx: &crate::stream_events::EventSender) -> bool {
        if !self.enabled {
            // Fast path: no think routing — send everything as text.
            return event_tx
                .send(AgentEvent::TextDelta {
                    delta: delta.to_string(),
                })
                .is_ok();
        }
        self.buf.push_str(delta);

        // ── INFRA-184: plain-prose CoT pre-pass ───────────────────────────
        // Decide the plain-CoT state once we have enough bytes (or a newline,
        // because every observed prefix ends before one). If `Active`, route
        // through plain-CoT logic and return. Otherwise fall through to the
        // existing `<think>`-tag handling so we keep that contract intact.
        if self.plain_cot == PlainCotState::Undecided {
            let enough_bytes = self.buf.len() >= PLAIN_COT_SNIFF_LEN;
            let has_newline = self.buf.contains('\n');
            // If the buf already contains an opening `<think>` tag we know
            // this is the tag-routed path, not plain CoT. Decide early so
            // tag detection isn't delayed waiting for more bytes.
            let has_open_tag = self.buf.contains(OPEN_TAG);
            if enough_bytes || has_newline || has_open_tag {
                self.plain_cot = if !has_open_tag && matches_plain_cot_prefix(&self.buf) {
                    PlainCotState::Active
                } else {
                    PlainCotState::NotApplicable
                };
            } else {
                // Not enough to decide yet; keep buffering.
                return true;
            }
        }

        if self.plain_cot == PlainCotState::Active {
            // Look for any transition marker. If found, emit pre-marker as
            // ThinkingDelta and post-marker as TextDelta, then switch to
            // NotApplicable so the rest of the stream uses normal routing.
            let mut earliest: Option<(usize, usize)> = None; // (pos, marker_len)
            for marker in PLAIN_COT_TRANSITIONS {
                if let Some(pos) = find_case_insensitive(&self.buf, marker) {
                    if earliest.map(|(p, _)| pos < p).unwrap_or(true) {
                        earliest = Some((pos, marker.len()));
                    }
                }
            }
            if let Some((pos, mlen)) = earliest {
                let thinking_chunk = self.buf[..pos].to_string();
                if !thinking_chunk.is_empty()
                    && event_tx
                        .send(AgentEvent::ThinkingDelta {
                            delta: thinking_chunk,
                        })
                        .is_err()
                {
                    return false;
                }
                let after_marker = self.buf[pos + mlen..].trim_start_matches('\n').to_string();
                self.buf = after_marker;
                self.plain_cot = PlainCotState::NotApplicable;
                // fall through to existing tag routing on whatever's left
            } else {
                // No transition yet — emit the safe portion (keep last
                // (longest_marker - 1) bytes back so we don't split a marker).
                let max_marker_len = PLAIN_COT_TRANSITIONS
                    .iter()
                    .map(|m| m.len())
                    .max()
                    .unwrap_or(0);
                let safe_len = self
                    .buf
                    .len()
                    .saturating_sub(max_marker_len.saturating_sub(1));
                if safe_len > 0 {
                    let safe = self.buf[..safe_len].to_string();
                    self.buf = self.buf[safe_len..].to_string();
                    if event_tx
                        .send(AgentEvent::ThinkingDelta { delta: safe })
                        .is_err()
                    {
                        return false;
                    }
                }
                return true;
            }
        }

        // ── Existing `<think>`-tag routing ─────────────────────────────────
        loop {
            if self.inside_think {
                // Looking for </think>
                if let Some(pos) = self.buf.find(CLOSE_TAG) {
                    // Emit the thinking content before the tag.
                    let thinking_chunk = self.buf[..pos].to_string();
                    if !thinking_chunk.is_empty()
                        && event_tx
                            .send(AgentEvent::ThinkingDelta {
                                delta: thinking_chunk,
                            })
                            .is_err()
                    {
                        return false;
                    }
                    self.buf = self.buf[pos + CLOSE_TAG_LEN..].to_string();
                    // Strip leading newline that follows </think>
                    if self.buf.starts_with('\n') {
                        self.buf = self.buf[1..].to_string();
                    }
                    self.inside_think = false;
                    // Continue processing any remaining buf content.
                    continue;
                }
                // No </think> yet — check if buf might be mid-tag.
                let safe_len = self.buf.len().saturating_sub(CLOSE_TAG_LEN - 1);
                if safe_len > 0 {
                    let safe = self.buf[..safe_len].to_string();
                    self.buf = self.buf[safe_len..].to_string();
                    if event_tx
                        .send(AgentEvent::ThinkingDelta { delta: safe })
                        .is_err()
                    {
                        return false;
                    }
                }
                break;
            } else {
                // Looking for <think>
                if let Some(pos) = self.buf.find(OPEN_TAG) {
                    // Emit any text before the tag.
                    let text_chunk = self.buf[..pos].to_string();
                    if !text_chunk.is_empty()
                        && event_tx
                            .send(AgentEvent::TextDelta { delta: text_chunk })
                            .is_err()
                    {
                        return false;
                    }
                    self.buf = self.buf[pos + OPEN_TAG_LEN..].to_string();
                    self.inside_think = true;
                    continue;
                }
                // No <think> — check if buf might be mid-tag.
                let safe_len = self.buf.len().saturating_sub(OPEN_TAG_LEN - 1);
                if safe_len > 0 {
                    let safe = self.buf[..safe_len].to_string();
                    self.buf = self.buf[safe_len..].to_string();
                    if event_tx
                        .send(AgentEvent::TextDelta { delta: safe })
                        .is_err()
                    {
                        return false;
                    }
                }
                break;
            }
        }
        true
    }

    /// Flush any buffered content at end-of-stream to the appropriate event type.
    pub fn flush(&mut self, event_tx: &crate::stream_events::EventSender) {
        if self.buf.is_empty() {
            return;
        }
        let remaining = std::mem::take(&mut self.buf);
        // INFRA-184: still in undecided state at flush time means we got a
        // very short response (< sniff threshold and no newline). Decide now.
        if self.plain_cot == PlainCotState::Undecided {
            self.plain_cot = if matches_plain_cot_prefix(&remaining) {
                PlainCotState::Active
            } else {
                PlainCotState::NotApplicable
            };
        }
        let event = if self.plain_cot == PlainCotState::Active || self.inside_think {
            AgentEvent::ThinkingDelta { delta: remaining }
        } else {
            AgentEvent::TextDelta { delta: remaining }
        };
        let _ = event_tx.send(event);
    }
}

/// Returns true if `CHUMP_THINKING=1` / `true` is set.
pub(crate) fn chump_thinking_enabled() -> bool {
    std::env::var("CHUMP_THINKING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// ACP-004: Route streaming delta text through `<think>` tag detection.
/// Emits ThinkingDelta events for content inside `<think>…</think>` blocks,
/// TextDelta events for everything else.
fn emit_delta_with_think_routing(
    delta: &str,
    in_think_block: &mut bool,
    tx: &tokio::sync::mpsc::UnboundedSender<crate::stream_events::AgentEvent>,
) {
    use crate::stream_events::AgentEvent;

    let mut rest = delta;
    loop {
        if rest.is_empty() {
            break;
        }
        if *in_think_block {
            if let Some(end) = rest.to_lowercase().find("</think>") {
                if end > 0 {
                    let _ = tx.send(AgentEvent::ThinkingDelta {
                        delta: rest[..end].to_string(),
                    });
                }
                *in_think_block = false;
                rest = &rest[end + 8..];
            } else {
                let _ = tx.send(AgentEvent::ThinkingDelta {
                    delta: rest.to_string(),
                });
                break;
            }
        } else {
            if let Some(start) = rest.to_lowercase().find("<think>") {
                if start > 0 {
                    let _ = tx.send(AgentEvent::TextDelta {
                        delta: rest[..start].to_string(),
                    });
                }
                *in_think_block = true;
                rest = &rest[start + 7..];
            } else {
                let _ = tx.send(AgentEvent::TextDelta {
                    delta: rest.to_string(),
                });
                break;
            }
        }
    }
}

/// Retry delays (ms): immediate, 1s, 2s, then 5s for vLLM restarts (connection closed).
/// Override via `CHUMP_LLM_RETRY_DELAYS_MS` (comma-separated, e.g. "0,500,2000,8000").
const RETRY_DELAYS_MS: &[u64] = &[0, 1000, 2000, 5000];

/// Heuristic char→token ratios (REL-004). BPE tokenizers split
/// punctuation-heavy code into many small tokens (`fn`, `(`, `)`, `;`, `"`
/// each ≈ 1 token), so code-like content averages closer to 3 chars/token
/// than prose's 4. JSON tool schemas are the densest at ~2.7 chars/token.
/// Target accuracy from the REL-004 acceptance criterion: ±10% on diverse
/// prompts.
const CHARS_PER_TOKEN_PROSE: f64 = 4.0;
const CHARS_PER_TOKEN_CODE: f64 = 3.0;
const CHARS_PER_TOKEN_JSON: f64 = 2.7;

/// Per-message JSON wrapper overhead in approximate tokens.
/// `{"role": "...", "content": "..."}` ≈ 6 wrapper tokens per message.
const PER_MESSAGE_WRAPPER_TOKENS: usize = 6;

/// Code-density threshold: ASCII-punctuation fraction above which a string
/// is treated as code-like rather than prose. Prose typically 0.08-0.12;
/// Rust code 0.18-0.28; JSON 0.25+.
const CODE_PUNCT_THRESHOLD: f64 = 0.15;
const JSON_PUNCT_THRESHOLD: f64 = 0.25;

/// Threshold (fraction of num_ctx) above which we emit an early warning. At
/// 80%, Ollama's typical behavior is "still works but starting to drop
/// connections under load"; at 95% it silently fails. Warning at 80% gives
/// users actionable lead time.
const NUM_CTX_WARN_FRACTION: f64 = 0.80;

/// ASCII-punctuation fraction used to classify a string as prose / code / JSON.
pub(crate) fn punct_density(s: &str) -> f64 {
    if s.is_empty() {
        return 0.0;
    }
    let mut punct: usize = 0;
    for b in s.as_bytes() {
        if matches!(
            b,
            b'{' | b'}'
                | b'('
                | b')'
                | b'['
                | b']'
                | b'<'
                | b'>'
                | b';'
                | b':'
                | b'='
                | b'/'
                | b'"'
                | b','
                | b'.'
                | b'|'
                | b'&'
                | b'\\'
        ) {
            punct += 1;
        }
    }
    punct as f64 / s.len() as f64
}

/// Estimate tokens for a single content string by classifying its punctuation
/// density and dividing by the matching chars/token ratio. Always rounds up so
/// sub-token fractions are accounted for.
pub(crate) fn estimate_tokens_for(s: &str) -> usize {
    if s.is_empty() {
        return 0;
    }
    // Non-ASCII code points (CJK, emoji, etc.) count as 1 token each — conservative.
    let non_ascii: usize = s.chars().filter(|c| !c.is_ascii()).count();
    let ascii_bytes: usize = s.len()
        - s.chars()
            .filter(|c| !c.is_ascii())
            .map(|c| c.len_utf8())
            .sum::<usize>();
    let density = punct_density(s);
    let ratio = if density >= JSON_PUNCT_THRESHOLD {
        CHARS_PER_TOKEN_JSON
    } else if density >= CODE_PUNCT_THRESHOLD {
        CHARS_PER_TOKEN_CODE
    } else {
        CHARS_PER_TOKEN_PROSE
    };
    let ascii_tokens = if ascii_bytes > 0 {
        ((ascii_bytes as f64) / ratio).ceil() as usize
    } else {
        0
    };
    ascii_tokens + non_ascii
}

/// Estimate prompt token count from the assembled OpenAI-style messages array
/// and tool schemas. Content-aware: prose uses 4 chars/token, code uses 3,
/// JSON uses 2.7. Tool schemas always use the dense ratio since they are
/// always structured JSON.
///
/// Used only for "approaching num_ctx" warnings, not precision-required paths,
/// but accurate enough to hit REL-004's ±10% acceptance on a diverse input mix
/// (prose, Rust source, tool schemas, mixed transcripts).
pub(crate) fn estimate_prompt_tokens(
    messages: &[serde_json::Value],
    tools: Option<&serde_json::Value>,
) -> usize {
    let mut total: usize = 0;
    for m in messages {
        if let Some(s) = m.get("content").and_then(|v| v.as_str()) {
            total += estimate_tokens_for(s);
        }
        if m.get("role").and_then(|v| v.as_str()).is_some() {
            total += PER_MESSAGE_WRAPPER_TOKENS;
        }
    }
    if let Some(t) = tools {
        if let Ok(s) = serde_json::to_string(t) {
            total += ((s.len() as f64) / CHARS_PER_TOKEN_JSON).ceil() as usize;
        }
    }
    total
}

/// Warn when the assembled prompt is at or above NUM_CTX_WARN_FRACTION of
/// num_ctx. Suppress with `CHUMP_NUM_CTX_WARN=0` (e.g. for benchmark runs
/// where the noise is unwanted). No-op when num_ctx is 0 (defensive).
pub(crate) fn warn_if_near_num_ctx(
    messages: &[serde_json::Value],
    tools: Option<&serde_json::Value>,
    num_ctx: u32,
) {
    if num_ctx == 0 {
        return;
    }
    if std::env::var("CHUMP_NUM_CTX_WARN")
        .map(|v| v.trim() == "0")
        .unwrap_or(false)
    {
        return;
    }
    let estimated = estimate_prompt_tokens(messages, tools);
    let threshold = ((num_ctx as f64) * NUM_CTX_WARN_FRACTION) as usize;
    if estimated >= threshold {
        let pct = (estimated as f64 / num_ctx as f64) * 100.0;
        tracing::warn!(
            estimated_tokens = estimated,
            num_ctx = num_ctx,
            pct_used = format!("{:.0}", pct),
            "ollama prompt approaching num_ctx limit; expect dropped connections or silent truncation. \
             Bump CHUMP_OLLAMA_NUM_CTX (current cap: 32768) or trim brain/memory injections."
        );
    }
}

fn retry_delays_ms() -> Vec<u64> {
    static CACHE: std::sync::OnceLock<Vec<u64>> = std::sync::OnceLock::new();
    CACHE
        .get_or_init(|| {
            std::env::var("CHUMP_LLM_RETRY_DELAYS_MS")
                .ok()
                .and_then(|v| {
                    let parsed: Result<Vec<u64>, _> =
                        v.split(',').map(|s| s.trim().parse::<u64>()).collect();
                    parsed.ok().filter(|v| !v.is_empty())
                })
                .unwrap_or_else(|| RETRY_DELAYS_MS.to_vec())
        })
        .clone()
}

const DEFAULT_CIRCUIT_FAILURE_THRESHOLD: u32 = 3;
const DEFAULT_CIRCUIT_COOLDOWN_SECS: u64 = 30;

fn circuit_failure_threshold() -> u32 {
    std::env::var("CHUMP_CIRCUIT_FAILURE_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_CIRCUIT_FAILURE_THRESHOLD)
        .max(1)
}

fn circuit_cooldown_secs() -> u64 {
    std::env::var("CHUMP_CIRCUIT_COOLDOWN_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_CIRCUIT_COOLDOWN_SECS)
}
/// Default request timeout for model API (14B can be slow; env CHUMP_MODEL_REQUEST_TIMEOUT_SECS overrides).
const DEFAULT_MODEL_REQUEST_TIMEOUT_SECS: u64 = 300;
/// TCP connect to OpenAI-compatible base (Ollama can be slow to accept while loading; env CHUMP_OPENAI_CONNECT_TIMEOUT_SECS).
const DEFAULT_OPENAI_CONNECT_TIMEOUT_SECS: u64 = 45;

struct CircuitState {
    failures: u32,
    open_until: Option<Instant>,
}

fn circuit_state() -> &'static Mutex<HashMap<String, CircuitState>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, CircuitState>>> =
        std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Record success for a base URL; clears circuit state so future requests can use it.
pub fn record_circuit_success(base: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        guard.remove(base);
    }
}

/// Record a failure for a base URL; after threshold failures the circuit opens for cooldown.
pub fn record_circuit_failure(base: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        let state = guard.entry(base.to_string()).or_insert(CircuitState {
            failures: 0,
            open_until: None,
        });
        state.failures += 1;
        if state.failures >= circuit_failure_threshold() {
            state.open_until = Some(Instant::now() + Duration::from_secs(circuit_cooldown_secs()));
        }
    }
}

/// True if the circuit is open (cooldown active) for this base URL.
pub fn is_circuit_open(base: &str) -> bool {
    if let Ok(guard) = circuit_state().lock() {
        if let Some(s) = guard.get(base) {
            if let Some(until) = s.open_until {
                if Instant::now() < until {
                    return true;
                }
            }
        }
    }
    false
}

/// Returns circuit state for the given model base URL for GET /health.
/// "closed" = healthy, "open" = cooldown after failures.
pub fn model_circuit_state(base_url: &str) -> &'static str {
    if let Ok(guard) = circuit_state().lock() {
        if let Some(s) = guard.get(base_url) {
            if let Some(until) = s.open_until {
                if std::time::Instant::now() < until {
                    return "open";
                }
            }
        }
    }
    "closed"
}

/// Exposed for provider_cascade: treat error as transient and try next slot.
pub fn is_transient_error(err: &anyhow::Error) -> bool {
    let s = err.to_string();
    // Top-level reqwest message often omits "refused"; check chain and common patterns.
    let with_chain = format!("{:?}", err);
    let combined = format!("{} {}", s, with_chain);
    combined.contains("connection")
        || combined.contains("connection closed")
        || combined.contains("SendRequest")
        || combined.contains("timed out")
        || combined.contains("Connection reset")
        || combined.contains("Connection refused")
        || combined.contains("error sending request")
        || combined.contains("tcp connect")
        || combined.contains("os error 61")
        || combined.contains("500")
        || combined.contains("502")
        || combined.contains("503")
        || combined.contains("504")
        || combined.to_lowercase().contains("model not loaded")
}

/// True if error is purely connection (refused/closed). We retry but do not trip the circuit.
fn is_connection_error_only(err: &anyhow::Error) -> bool {
    let with_chain = format!("{:?}", err);
    let s = err.to_string();
    let combined = format!("{} {}", s, with_chain);
    (combined.contains("refused")
        || combined.contains("os error 61")
        || combined.contains("connection closed")
        || combined.contains("SendRequest"))
        && !combined.contains("500")
        && !combined.contains("502")
        && !combined.contains("503")
        && !combined.contains("504")
        && !combined.contains("timed out")
}

/// After [`sliding_window_trim_messages`], session + memory snippets to prepend as a synthetic user message.
pub(crate) struct SlidingInjectCtx {
    pub skip: usize,
    pub dropped: usize,
    pub query_hint: String,
}

fn session_fts_block(query_hint: &str) -> String {
    let mut s = String::new();
    if let Some(sid) = crate::agent_session::active_session_id() {
        if let Ok(chunk) =
            crate::web_sessions_db::session_messages_fts_snippets(&sid, query_hint, 12)
        {
            if !chunk.is_empty() {
                s.push_str("### Session excerpts (FTS-ranked, verbatim)\n");
                s.push_str(&chunk);
                s.push('\n');
            }
        }
    }
    s
}

fn memory_keyword_block(query_hint: &str, limit: usize) -> String {
    let mut retrieval = String::new();
    if let Ok(rows) = crate::memory_db::keyword_search(query_hint, limit) {
        if !rows.is_empty() {
            retrieval.push_str("### Long-term memory excerpts (FTS5, verbatim)\n");
            for r in rows.iter().take(limit) {
                use std::fmt::Write as _;
                let _ = writeln!(retrieval, "---\n[{}] {}\n---", r.source, r.content);
            }
        }
    }
    retrieval
}

fn finalize_sliding_notices(
    messages: &mut Vec<Message>,
    retrieval: String,
    ctx: &SlidingInjectCtx,
) {
    if !retrieval.is_empty() {
        let notice = Message {
            role: "user".to_string(),
            content: format!(
                "[Verbatim context retrieval ({} earlier message(s) dropped from the sliding window; excerpts are exact DB text, not summaries)]\n\n{}",
                ctx.skip, retrieval
            ),
        };
        messages.insert(0, notice);
    } else if !messages.is_empty() {
        let notice = Message {
            role: "user".to_string(),
            content: format!(
                "[Earlier in this conversation: {} message(s) were trimmed to fit the context window. Below are the most recent messages.]",
                ctx.dropped
            ),
        };
        messages.insert(0, notice);
    }
}

/// Message-count cap + optional token trim; returns injection context when older turns were dropped.
pub(crate) fn sliding_window_trim_messages(
    messages: Vec<Message>,
    system_prompt: Option<&str>,
) -> (Vec<Message>, Option<SlidingInjectCtx>) {
    let cap = {
        let verbatim = crate::context_window::verbatim_turns();
        if verbatim > 0 {
            verbatim.max(2)
        } else {
            let parsed_max = std::env::var("CHUMP_MAX_CONTEXT_MESSAGES")
                .ok()
                .and_then(|v| v.parse::<usize>().ok());
            let base = parsed_max.unwrap_or(20).max(2);
            if crate::env_flags::light_interactive_active() && parsed_max.is_none() {
                crate::env_flags::light_chat_history_message_cap()
            } else {
                base
            }
        }
    };
    let mut dropped = 0usize;
    let mut messages: Vec<Message> = if messages.len() > cap {
        let start = messages.len() - cap;
        dropped = start;
        messages.into_iter().skip(start).collect()
    } else {
        messages
    };
    let threshold = crate::context_window::summary_threshold();
    let hard_cap = crate::context_window::max_tokens();
    if (threshold > 0 || hard_cap > 0) && system_prompt.is_some() {
        let sys_tokens = crate::context_window::approx_token_count(system_prompt.unwrap_or(""));
        let mut total = sys_tokens;
        let mut keep_from = 0;
        for (i, m) in messages.iter().enumerate().rev() {
            total += crate::context_window::approx_token_count(&m.content);
            if total > threshold && threshold > 0 {
                keep_from = i + 1;
                break;
            }
            if hard_cap > 0 && total > hard_cap {
                keep_from = keep_from.max(i + 1);
                break;
            }
        }
        if keep_from > 0 {
            let skip = keep_from.min(messages.len().saturating_sub(1));
            dropped += skip;
            messages = messages.into_iter().skip(skip).collect();
            let query_hint = messages
                .iter()
                .rev()
                .find(|m| m.role == "user")
                .map(|m| m.content.as_str())
                .unwrap_or("")
                .to_string();
            return (
                messages,
                Some(SlidingInjectCtx {
                    skip,
                    dropped,
                    query_hint,
                }),
            );
        }
    }
    (messages, None)
}

fn inject_sliding_window_sync(messages: &mut Vec<Message>, ctx: &SlidingInjectCtx) {
    let limit = crate::context_window::context_memory_snippet_limit();
    let mut retrieval = session_fts_block(&ctx.query_hint);
    retrieval.push_str(&memory_keyword_block(&ctx.query_hint, limit));
    finalize_sliding_notices(messages, retrieval, ctx);
}

async fn inject_sliding_window_async(messages: &mut Vec<Message>, ctx: &SlidingInjectCtx) {
    let limit = crate::context_window::context_memory_snippet_limit();
    let mut retrieval = session_fts_block(&ctx.query_hint);
    let mut memory_done = false;
    if crate::context_window::context_hybrid_memory_sliding_window() {
        let q = if ctx.query_hint.trim().is_empty() {
            None
        } else {
            Some(ctx.query_hint.as_str())
        };
        match crate::memory_tool::recall_for_context(q, limit).await {
            Ok(s) if !s.trim().is_empty() => {
                retrieval.push_str(
                    "### Long-term memory excerpts (hybrid: FTS + embeddings + graph RRF)\n",
                );
                retrieval.push_str(s.trim());
                retrieval.push('\n');
                memory_done = true;
            }
            _ => {}
        }
    }
    if !memory_done {
        retrieval.push_str(&memory_keyword_block(&ctx.query_hint, limit));
    }
    finalize_sliding_notices(messages, retrieval, ctx);
}

/// Cap/truncate chat `messages` (sync). Memory snippets use FTS5 only. Prefer
/// [`apply_sliding_window_to_messages_async`] in async providers when **`CHUMP_CONTEXT_HYBRID_MEMORY=1`**.
pub(crate) fn apply_sliding_window_to_messages(
    messages: Vec<Message>,
    system_prompt: Option<&str>,
) -> Vec<Message> {
    let (mut messages, ctx) = sliding_window_trim_messages(messages, system_prompt);
    if let Some(c) = ctx {
        inject_sliding_window_sync(&mut messages, &c);
    }
    messages
}

/// Async sliding window: when trim fires, optional hybrid long-term recall via [`crate::memory_tool::recall_for_context`].
pub(crate) async fn apply_sliding_window_to_messages_async(
    messages: Vec<Message>,
    system_prompt: Option<&str>,
) -> Vec<Message> {
    let (mut messages, ctx) = sliding_window_trim_messages(messages, system_prompt);
    if let Some(c) = ctx {
        inject_sliding_window_async(&mut messages, &c).await;
    }
    messages
}

pub struct LocalOpenAIProvider {
    base_url: String,
    fallback_base_url: Option<String>,
    api_key: String,
    model: String,
    client: reqwest::Client,
}

impl LocalOpenAIProvider {
    #[allow(dead_code)]
    pub fn new(base_url: String, api_key: String, model: String) -> Self {
        Self::with_fallback(base_url, None, api_key, model)
    }

    /// Build with optional fallback URL (e.g. from CHUMP_FALLBACK_API_BASE). If primary fails after retries, one attempt is made to the fallback.
    /// Request timeout from CHUMP_MODEL_REQUEST_TIMEOUT_SECS (default 300s for slow 14B).
    pub fn with_fallback(
        base_url: String,
        fallback_base_url: Option<String>,
        api_key: String,
        model: String,
    ) -> Self {
        let timeout_secs: u64 = std::env::var("CHUMP_MODEL_REQUEST_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_MODEL_REQUEST_TIMEOUT_SECS)
            .max(30);
        let connect_secs: u64 = std::env::var("CHUMP_OPENAI_CONNECT_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_OPENAI_CONNECT_TIMEOUT_SECS)
            .clamp(5, 120);
        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(connect_secs))
            .timeout(std::time::Duration::from_secs(timeout_secs))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            fallback_base_url: fallback_base_url.map(|u| u.trim_end_matches('/').to_string()),
            api_key,
            model,
            client,
        }
    }

    fn record_llm_http_completion(&self, base_url: &str) {
        crate::llm_backend_metrics::record_openai_http(
            &crate::llm_backend_metrics::short_openai_endpoint_label(base_url),
        );
    }
}

#[async_trait]
impl Provider for LocalOpenAIProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let messages =
            apply_sliding_window_to_messages_async(messages, system_prompt.as_deref()).await;

        let mut complete_message: Vec<Value> = Vec::new();

        if let Some(sys_prompt) = system_prompt {
            complete_message.push(json!({
                "role": "system",
                "content": sys_prompt
            }));
        }

        for m in &messages {
            // Vision passthrough (ACP-002): when content is a JSON array (multipart
            // content encoded by flatten_prompt_blocks_vision), deserialize it so the
            // provider receives `content: [{"type":"text",...},{"type":"image_url",...}]`
            // instead of a plain string. Text-only content paths are unaffected.
            let content_value: Value = if m.content.starts_with('[') {
                serde_json::from_str(&m.content).unwrap_or_else(|_| json!(m.content))
            } else {
                json!(m.content)
            };
            complete_message.push(json!({
                "role": m.role,
                "content": content_value
            }));
        }

        let mut body = json!({
            "model": self.model,
            "messages": complete_message,
        });

        if let Some(max_tokens) = max_tokens {
            body["max_tokens"] = json!(max_tokens);
        }

        // Temperature: tighter = more decisive, less rambling (CHUMP_TEMPERATURE, default 0.3).
        // Qwen3 non-thinking recommended: 0.7. We go lower for tool-use agent work.
        // Neuromod-adaptive: NA→temperature, DA→top_p.
        let base_temperature: f64 = std::env::var("CHUMP_TEMPERATURE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.3_f64)
            .clamp(0.0, 2.0);
        let temperature = crate::neuromodulation::adaptive_temperature(base_temperature);
        let top_p = crate::neuromodulation::adaptive_top_p();
        body["temperature"] = json!(temperature);
        body["top_p"] = json!(top_p);

        // COG-012: request logprobs when opted in (CHUMP_LOGPROBS_ENABLED=1).
        // Gracefully no-ops on providers that ignore the field.
        if std::env::var("CHUMP_LOGPROBS_ENABLED").as_deref() == Ok("1") {
            body["logprobs"] = json!(true);
        }

        // Ollama: set context size; 8192 balances quality and RAM (CHUMP_OLLAMA_NUM_CTX).
        // keep_alive keeps the model + KV cache in memory between requests (default "30m").
        if self.base_url.contains("11434") {
            let num_ctx: u32 = std::env::var("CHUMP_OLLAMA_NUM_CTX")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(8192)
                .clamp(1024, 32768);
            let keep_alive =
                std::env::var("CHUMP_OLLAMA_KEEP_ALIVE").unwrap_or_else(|_| "30m".to_string());
            body["options"] =
                json!({ "num_ctx": num_ctx, "temperature": temperature, "top_p": top_p });
            body["keep_alive"] = json!(keep_alive);

            // num_ctx overflow early warning: when assembled prompt approaches
            // num_ctx, Ollama silently drops connections instead of returning a
            // clear "context too large" error. Estimate the prompt size up
            // front so users see the overflow coming. Suppress with
            // CHUMP_NUM_CTX_WARN=0.
            warn_if_near_num_ctx(&complete_message, body.get("tools"), num_ctx);
        }

        if let Some(tools) = tools {
            let openai_tools: Vec<Value> = tools
                .iter()
                .map(|t| {
                    json!({
                        "type": "function",
                        "function": {
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.input_schema,
                        }
                    })
                })
                .collect();
            body["tools"] = json!(openai_tools);
            // Hint for servers that support structured tool output (e.g. vLLM with --enable-auto-tool-choice).
            body["tool_choice"] = json!("auto");
            // Structured output: force JSON when tools are present (vLLM-MLX guided generation).
            // Gate: CHUMP_FORCE_JSON_TOOLS=1 (off by default — some servers reject this).
            if std::env::var("CHUMP_FORCE_JSON_TOOLS")
                .map(|v| v == "1")
                .unwrap_or(false)
            {
                body["response_format"] = json!({"type": "json_object"});
            }
        }

        // Check for task-local event sender → use streaming when available.
        // Env override: CHUMP_STREAM_HTTP=0 disables streaming (debugging).
        let stream_tx: Option<EventSender> = STREAM_EVENT_TX.try_with(|tx| tx.clone()).ok();
        let effective_tx = stream_tx.as_ref().filter(|_| {
            std::env::var("CHUMP_STREAM_HTTP")
                .map(|v| v != "0")
                .unwrap_or(true)
        });

        let mut last_err = None;
        for delay_ms in retry_delays_ms() {
            if delay_ms > 0 {
                sleep(Duration::from_millis(delay_ms)).await;
            }
            let result = match effective_tx {
                Some(tx) => self.try_streaming_request(&self.base_url, &body, tx).await,
                None => self.try_one_request(&self.base_url, &body).await,
            };
            match result {
                Ok(r) => {
                    self.circuit_success(&self.base_url);
                    self.record_llm_http_completion(&self.base_url);
                    return Ok(r);
                }
                Err(e) => {
                    last_err = Some(anyhow!("{}", e));
                    if !is_transient_error(&e) {
                        return Err(e);
                    }
                    // Don't trip circuit for connection refused/closed — vLLM may be restarting.
                    if !is_connection_error_only(&e) {
                        self.circuit_failure(&self.base_url);
                    }
                }
            }
        }
        // One extra retry after 15s when server returns "model not loaded" (llama-server can report 200 on /v1/models before load finishes).
        if let Some(ref e) = last_err {
            if e.to_string().to_lowercase().contains("model not loaded") {
                sleep(Duration::from_secs(15)).await;
                let retry_result = match effective_tx {
                    Some(tx) => self.try_streaming_request(&self.base_url, &body, tx).await,
                    None => self.try_one_request(&self.base_url, &body).await,
                };
                if let Ok(r) = retry_result {
                    self.circuit_success(&self.base_url);
                    self.record_llm_http_completion(&self.base_url);
                    return Ok(r);
                }
            }
        }
        if let Some(ref fallback) = self.fallback_base_url {
            let fb_result = match effective_tx {
                Some(tx) => self.try_streaming_request(fallback, &body, tx).await,
                None => self.try_one_request(fallback, &body).await,
            };
            if let Ok(r) = fb_result {
                self.circuit_success(fallback);
                self.record_llm_http_completion(fallback);
                return Ok(r);
            }
            self.circuit_failure(fallback);
        }
        let err = last_err.unwrap_or_else(|| anyhow!("model temporarily unavailable"));
        let msg = err.to_string();
        let hint = if msg.contains("error sending request")
            || msg.contains("connection")
            || msg.contains("refused")
        {
            " — model HTTP unreachable (daemon down, crashed, or still starting). Ollama: brew services start ollama (or restart); probe: curl -s http://127.0.0.1:11434/api/tags. Prefer OPENAI_API_BASE=http://127.0.0.1:11434/v1 if localhost misbehaves. Backup URL: CHUMP_FALLBACK_API_BASE. vLLM: :8000/:8001."
        } else if msg.to_lowercase().contains("model not loaded") {
            " — wait for the model to finish loading (start-companion.sh now waits for /v1/chat/completions 200) or check logs/llama-server.log"
        } else {
            ""
        };
        Err(anyhow!("{}{}", err, hint))
    }
}

impl LocalOpenAIProvider {
    fn circuit_success(&self, base: &str) {
        record_circuit_success(base);
    }

    fn circuit_failure(&self, base: &str) {
        record_circuit_failure(base);
    }

    fn circuit_open(&self, base: &str) -> bool {
        is_circuit_open(base)
    }

    /// Streaming variant: sends `"stream": true`, reads SSE chunks, emits [`AgentEvent::TextDelta`].
    /// Returns the assembled [`CompletionResponse`] identical in shape to [`try_one_request`].
    async fn try_streaming_request(
        &self,
        base_url: &str,
        body: &Value,
        event_tx: &EventSender,
    ) -> Result<CompletionResponse> {
        if self.circuit_open(base_url) {
            return Err(anyhow!(
                "model temporarily unavailable (circuit open for {}s)",
                circuit_cooldown_secs()
            ));
        }
        let url = format!("{}/chat/completions", base_url);
        let is_local = base_url.contains("127.0.0.1") || base_url.contains("localhost");
        let skip_auth = is_local
            && (self.api_key.is_empty()
                || self.api_key == "not-needed"
                || self.api_key == "token-abc123");

        // Clone body and set stream: true
        let mut stream_body = body.clone();
        stream_body["stream"] = json!(true);
        // Request usage in final chunk (OpenAI extension, supported by vLLM/Ollama)
        stream_body["stream_options"] = json!({"include_usage": true});

        let mut req = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(&stream_body);
        if !skip_auth {
            req = req.header("Authorization", format!("Bearer {}", self.api_key));
        }
        let log_timing = std::env::var("CHUMP_LOG_TIMING")
            .map(|v| v == "1" || v == "true")
            .unwrap_or(false);
        let api_start = Instant::now();
        let response = req.send().await?;
        let status = response.status();
        if !status.is_success() {
            let error_text = response.text().await?;
            if log_timing {
                eprintln!(
                    "[timing] stream_request_ms={} status={}",
                    api_start.elapsed().as_millis(),
                    status
                );
                let _ = std::io::stderr().flush();
            }
            return Err(anyhow!("Local API error {}: {}", status, error_text));
        }

        // Read SSE byte stream
        let mut byte_stream = response.bytes_stream();
        let mut text_accum = String::new();
        let mut tool_calls: Vec<ToolCallAccum> = Vec::new();
        let mut finish_reason: Option<String> = None;
        let mut last_usage: Option<UsageInfo> = None;
        let mut line_buf = String::new();
        let mut streamed_any_text = false;
        let mut think_state = ThinkStreamState::new(chump_thinking_enabled());

        while let Some(chunk_result) = byte_stream.next().await {
            let bytes = chunk_result?;
            let chunk_str = String::from_utf8_lossy(&bytes);

            // SSE lines may span chunk boundaries; buffer and split on newlines
            line_buf.push_str(&chunk_str);
            while let Some(newline_pos) = line_buf.find('\n') {
                let line = line_buf[..newline_pos].trim().to_string();
                line_buf = line_buf[newline_pos + 1..].to_string();

                if line.is_empty() || line.starts_with(':') {
                    continue; // SSE comment or blank separator
                }
                let data = if let Some(d) = line.strip_prefix("data: ") {
                    d.trim()
                } else {
                    continue;
                };
                if data == "[DONE]" {
                    continue;
                }

                let parsed: StreamChunk = match serde_json::from_str(data) {
                    Ok(c) => c,
                    Err(_) => continue, // skip malformed chunks
                };

                if let Some(u) = parsed.usage {
                    last_usage = Some(u);
                }

                if let Some(choice) = parsed.choices.first() {
                    // Text content
                    if let Some(ref content) = choice.delta.content {
                        if !content.is_empty() {
                            text_accum.push_str(content);
                            streamed_any_text = true;
                            think_state.process(content, event_tx);
                        }
                    }

                    // Tool call deltas
                    if let Some(ref tc_deltas) = choice.delta.tool_calls {
                        for tc in tc_deltas {
                            // Grow tool_calls vec as needed
                            while tool_calls.len() <= tc.index {
                                tool_calls.push(ToolCallAccum::default());
                            }
                            let accum = &mut tool_calls[tc.index];
                            if let Some(ref id) = tc.id {
                                accum.id = id.clone();
                            }
                            if let Some(ref f) = tc.function {
                                if let Some(ref name) = f.name {
                                    accum.name = name.clone();
                                }
                                if let Some(ref args) = f.arguments {
                                    accum.arguments.push_str(args);
                                }
                            }
                        }
                    }

                    if choice.finish_reason.is_some() {
                        finish_reason = choice.finish_reason.clone();
                    }
                }
            }
        }

        // Flush any buffered think-state bytes (covers truncated-tag-at-end-of-stream edge case).
        think_state.flush(event_tx);

        // Record usage
        if let Some(ref u) = last_usage {
            let inp = u.prompt_tokens.unwrap_or(0) as u64;
            let out = u.completion_tokens.unwrap_or(0) as u64;
            crate::cost_tracker::record_completion(1, inp, out);
        }
        if log_timing {
            let ms = api_start.elapsed().as_millis();
            match &last_usage {
                Some(u) => {
                    eprintln!(
                        "[timing] stream_request_ms={} status={} prompt_tokens={} completion_tokens={} streamed_text={}",
                        ms, status,
                        u.prompt_tokens.map(|n| n.to_string()).unwrap_or_else(|| "-".to_string()),
                        u.completion_tokens.map(|n| n.to_string()).unwrap_or_else(|| "-".to_string()),
                        streamed_any_text,
                    );
                }
                None => {
                    eprintln!(
                        "[timing] stream_request_ms={} status={} streamed_text={}",
                        ms, status, streamed_any_text
                    );
                }
            }
            let _ = std::io::stderr().flush();
        }

        // Assemble CompletionResponse
        let text = if text_accum.is_empty() {
            None
        } else {
            Some(strip_think_blocks(&text_accum))
        };

        let parsed_tool_calls: Vec<ToolCall> = tool_calls
            .into_iter()
            .filter(|tc| !tc.name.is_empty())
            .map(|tc| {
                let input = match serde_json::from_str(&tc.arguments) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!(
                            "chump: malformed streamed tool JSON for {}: {} — args: [REDACTED]",
                            tc.name, e
                        );
                        json!({})
                    }
                };
                ToolCall {
                    id: tc.id,
                    name: tc.name,
                    input,
                }
            })
            .collect();

        let finish = finish_reason.as_deref().unwrap_or("stop");
        let stop_reason = match finish {
            "tool_calls" => StopReason::ToolUse,
            "stop" => StopReason::EndTurn,
            "length" => StopReason::MaxTokens,
            "content_filter" => StopReason::ContentFilter,
            _ => StopReason::EndTurn,
        };

        Ok(CompletionResponse {
            text,
            tool_calls: parsed_tool_calls,
            stop_reason,
        })
    }

    async fn try_one_request(&self, base_url: &str, body: &Value) -> Result<CompletionResponse> {
        if self.circuit_open(base_url) {
            return Err(anyhow!(
                "model temporarily unavailable (circuit open for {}s)",
                circuit_cooldown_secs()
            ));
        }
        let url = format!("{}/chat/completions", base_url);
        let is_local = base_url.contains("127.0.0.1") || base_url.contains("localhost");
        let skip_auth = is_local
            && (self.api_key.is_empty()
                || self.api_key == "not-needed"
                || self.api_key == "token-abc123");
        let mut req = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(body);
        if !skip_auth {
            req = req.header("Authorization", format!("Bearer {}", self.api_key));
        }
        let log_timing = std::env::var("CHUMP_LOG_TIMING")
            .map(|v| v == "1" || v == "true")
            .unwrap_or(false);
        let api_start = Instant::now();
        let response = req.send().await?;
        let status = response.status();
        if !status.is_success() {
            let error_text = response.text().await?;
            if log_timing {
                eprintln!(
                    "[timing] api_request_ms={} status={}",
                    api_start.elapsed().as_millis(),
                    status
                );
                let _ = std::io::stderr().flush(); // so timing appears in companion.log when stderr is redirected
            }
            let mut msg = format!("Local API error {}: {}", status, error_text);
            if status.as_u16() == 401 || error_text.to_lowercase().contains("models permission") {
                msg.push_str(" Check API key scope; run scripts/ci/check-providers.sh.");
                if error_text.contains("invalid_api_key")
                    || error_text.contains("Incorrect API key")
                {
                    msg.push_str(
                        " For local Ollama, set OPENAI_API_BASE=http://127.0.0.1:11434/v1 and OPENAI_API_KEY=ollama (or leave the key unset).",
                    );
                }
            }
            return Err(anyhow!("{}", msg));
        }
        let response_bytes = response.bytes().await?;
        // COG-012: extract logprobs from raw JSON before typed deserialization (no Serialize needed).
        if std::env::var("CHUMP_LOGPROBS_ENABLED").as_deref() == Ok("1") {
            if let Ok(raw_json) = serde_json::from_slice::<serde_json::Value>(&response_bytes) {
                if let Some((min_lp, avg_lp)) =
                    crate::asi_telemetry::extract_logprobs_from_response(&raw_json)
                {
                    crate::asi_telemetry::record_logprobs(min_lp, avg_lp);
                }
            }
        }
        let api_response: LocalOpenAIResponse = serde_json::from_slice(&response_bytes)
            .map_err(|e| anyhow!("failed to parse API response JSON: {}", e))?;
        if let Some(ref u) = api_response.usage {
            let inp = u.prompt_tokens.unwrap_or(0) as u64;
            let out = u.completion_tokens.unwrap_or(0) as u64;
            crate::cost_tracker::record_completion(1, inp, out);
        }
        if log_timing {
            let ms = api_start.elapsed().as_millis();
            match &api_response.usage {
                Some(u) => {
                    eprintln!(
                        "[timing] api_request_ms={} status={} prompt_tokens={} completion_tokens={}",
                        ms,
                        status,
                        u.prompt_tokens.map(|n| n.to_string()).unwrap_or_else(|| "-".to_string()),
                        u.completion_tokens.map(|n| n.to_string()).unwrap_or_else(|| "-".to_string())
                    );
                }
                None => {
                    eprintln!("[timing] api_request_ms={} status={}", ms, status);
                }
            }
            let _ = std::io::stderr().flush(); // so timing appears in companion.log when stderr is redirected
        }
        let choice = api_response
            .choices
            .first()
            .ok_or_else(|| anyhow!("No choices in response"))?;

        let text = choice
            .message
            .content
            .clone()
            .map(|t| strip_think_blocks(&t));
        let tool_calls = if let Some(calls) = &choice.message.tool_calls {
            calls
                .iter()
                .map(|tc| {
                    let input = match serde_json::from_str(&tc.function.arguments) {
                        Ok(v) => v,
                        Err(e) => {
                            eprintln!(
                                "chump: malformed tool JSON for {}: {} — args: [REDACTED]",
                                tc.function.name, e
                            );
                            json!({})
                        }
                    };
                    ToolCall {
                        id: tc.id.clone(),
                        name: tc.function.name.clone(),
                        input,
                    }
                })
                .collect()
        } else {
            vec![]
        };

        let finish = choice.finish_reason.as_deref().unwrap_or("stop");
        let stop_reason = match finish {
            "tool_calls" => StopReason::ToolUse,
            "stop" => StopReason::EndTurn,
            "length" => StopReason::MaxTokens,
            "content_filter" => StopReason::ContentFilter,
            _ => StopReason::EndTurn,
        };

        Ok(CompletionResponse {
            text,
            tool_calls,
            stop_reason,
        })
    }
}

#[derive(Debug, Deserialize)]
struct LocalOpenAIResponse {
    choices: Vec<LocalChoice>,
    #[serde(default)]
    usage: Option<UsageInfo>,
}

#[derive(Debug, Deserialize)]
struct UsageInfo {
    prompt_tokens: Option<u32>,
    completion_tokens: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct LocalChoice {
    message: LocalResponseMessage,
    finish_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LocalResponseMessage {
    content: Option<String>,
    tool_calls: Option<Vec<LocalToolCall>>,
}

#[derive(Debug, Deserialize)]
struct LocalToolCall {
    id: String,
    function: LocalFunctionCall,
}

#[derive(Debug, Deserialize)]
struct LocalFunctionCall {
    name: String,
    arguments: String,
}

// --- Streaming SSE chunk types (OpenAI-compatible) ---

#[derive(Debug, Deserialize)]
struct StreamChunk {
    choices: Vec<StreamChoice>,
    #[serde(default)]
    usage: Option<UsageInfo>,
}

#[derive(Debug, Deserialize)]
struct StreamChoice {
    delta: StreamDelta,
    finish_reason: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct StreamDelta {
    content: Option<String>,
    tool_calls: Option<Vec<StreamToolCallDelta>>,
}

#[derive(Debug, Deserialize)]
struct StreamToolCallDelta {
    index: usize,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    function: Option<StreamFunctionDelta>,
}

#[derive(Debug, Default, Deserialize)]
struct StreamFunctionDelta {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    arguments: Option<String>,
}

/// Accumulated state for a single tool call across streaming chunks.
#[derive(Debug, Default)]
struct ToolCallAccum {
    id: String,
    name: String,
    arguments: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use axonerai::provider::Message;
    use serial_test::serial;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Clears sliding-window env vars on drop so `#[serial]` tests do not leak.
    struct SlidingEnvGuard;
    impl SlidingEnvGuard {
        fn new() -> Self {
            for k in [
                "CHUMP_CONTEXT_VERBATIM_TURNS",
                "CHUMP_CONTEXT_SUMMARY_THRESHOLD",
                "CHUMP_CONTEXT_MAX_TOKENS",
                "CHUMP_CONTEXT_HYBRID_MEMORY",
                "CHUMP_MAX_CONTEXT_MESSAGES",
            ] {
                std::env::remove_var(k);
            }
            Self
        }
    }
    impl Drop for SlidingEnvGuard {
        fn drop(&mut self) {
            for k in [
                "CHUMP_CONTEXT_VERBATIM_TURNS",
                "CHUMP_CONTEXT_SUMMARY_THRESHOLD",
                "CHUMP_CONTEXT_MAX_TOKENS",
                "CHUMP_CONTEXT_HYBRID_MEMORY",
                "CHUMP_MAX_CONTEXT_MESSAGES",
            ] {
                std::env::remove_var(k);
            }
        }
    }

    #[tokio::test]
    async fn complete_parses_valid_response_and_tool_calls() {
        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": "Sure, I'll run that.",
                    "tool_calls": [{
                        "id": "call_1",
                        "function": {
                            "name": "run_cli",
                            "arguments": "{\"command\": \"ls -la\"}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let provider = LocalOpenAIProvider::new(
            mock.uri().to_string(),
            "not-needed".to_string(),
            "test".to_string(),
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: "List files".to_string(),
        }];
        let out = provider.complete(messages, None, None, None).await.unwrap();
        assert_eq!(out.text.as_deref(), Some("Sure, I'll run that."));
        assert_eq!(out.tool_calls.len(), 1);
        assert_eq!(out.tool_calls[0].id, "call_1");
        assert_eq!(out.tool_calls[0].name, "run_cli");
        assert_eq!(
            out.tool_calls[0]
                .input
                .get("command")
                .and_then(|c| c.as_str()),
            Some("ls -la")
        );
    }

    #[tokio::test]
    async fn complete_malformed_tool_args_maps_to_empty_object() {
        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": null,
                    "tool_calls": [{
                        "id": "call_2",
                        "function": {
                            "name": "run_cli",
                            "arguments": "not valid json at all"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let provider = LocalOpenAIProvider::new(
            mock.uri().to_string(),
            "not-needed".to_string(),
            "test".to_string(),
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: "run something".to_string(),
        }];
        let out = provider.complete(messages, None, None, None).await.unwrap();
        assert_eq!(out.tool_calls.len(), 1);
        assert_eq!(out.tool_calls[0].name, "run_cli");
        assert!(out.tool_calls[0].input.is_object());
        assert!(out.tool_calls[0].input.as_object().unwrap().is_empty());
    }

    /// Task 1.3: deterministic trim — newest user turn survives; injection ctx carries its query hint.
    #[test]
    #[serial]
    fn sliding_window_trim_drops_oldest_when_over_hard_cap() {
        let _g = SlidingEnvGuard::new();
        std::env::set_var("CHUMP_CONTEXT_MAX_TOKENS", "150");
        std::env::set_var("CHUMP_MAX_CONTEXT_MESSAGES", "50");
        let sys = "s".repeat(80);
        let messages: Vec<_> = (0..4)
            .map(|i| Message {
                role: "user".to_string(),
                content: format!("turn_{i}_{}", "w".repeat(300)),
            })
            .collect();
        let (out, ctx) = sliding_window_trim_messages(messages, Some(&sys));
        let c = ctx.expect("expected token trim");
        assert_eq!(out.len(), 1);
        assert!(
            out[0].content.contains("turn_3"),
            "newest user content preserved"
        );
        assert!(
            c.query_hint.contains("turn_3"),
            "query hint from latest user"
        );
    }

    /// Task 1.3: trimmed path inserts a synthetic user notice (verbatim or fallback).
    #[tokio::test]
    #[serial]
    async fn sliding_window_async_inserts_notice_when_trimmed() {
        let _g = SlidingEnvGuard::new();
        std::env::set_var("CHUMP_CONTEXT_MAX_TOKENS", "150");
        std::env::set_var("CHUMP_MAX_CONTEXT_MESSAGES", "50");
        let sys = "s".repeat(80);
        let messages: Vec<_> = (0..4)
            .map(|i| Message {
                role: "user".to_string(),
                content: format!("tail_{i}_{}", "w".repeat(300)),
            })
            .collect();
        let out = apply_sliding_window_to_messages_async(messages, Some(&sys)).await;
        assert!(!out.is_empty());
        assert!(
            out[0].content.contains("Verbatim context retrieval")
                || out[0].content.contains("Earlier in this conversation"),
            "first message should be trim notice, got: {:?}",
            &out[0].content[..out[0].content.len().min(120)]
        );
        assert!(
            out.iter().any(|m| m.content.contains("tail_3")),
            "latest user turn still in window"
        );
    }

    // ── ThinkStreamState tests ────────────────────────────────────────

    fn collect_events(state: &mut ThinkStreamState, chunks: &[&str]) -> Vec<AgentEvent> {
        let (tx, mut rx) = crate::stream_events::event_channel();
        for chunk in chunks {
            state.process(chunk, &tx);
        }
        state.flush(&tx);
        drop(tx);
        let mut out = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            out.push(ev);
        }
        out
    }

    #[test]
    fn think_state_disabled_sends_all_as_text_delta() {
        let mut s = ThinkStreamState::new(false);
        let evs = collect_events(&mut s, &["<think>plan</think>answer"]);
        assert!(evs
            .iter()
            .all(|e| matches!(e, AgentEvent::TextDelta { .. })));
        let text: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::TextDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(text, "<think>plan</think>answer");
    }

    #[test]
    fn think_state_routes_think_block_to_thinking_delta() {
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(&mut s, &["<think>reasoning here</think>\nanswer text"]);
        let thinking: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::ThinkingDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        let text: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::TextDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(thinking, "reasoning here");
        assert_eq!(text, "answer text");
    }

    #[test]
    fn think_state_handles_tag_split_across_chunks() {
        let mut s = ThinkStreamState::new(true);
        // "<think>" split as "<thi" + "nk>" + "plan" + "</th" + "ink>"
        let evs = collect_events(&mut s, &["<thi", "nk>", "plan", "</th", "ink>"]);
        let thinking: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::ThinkingDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        let text: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::TextDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(thinking, "plan");
        assert!(text.is_empty());
    }

    #[test]
    fn think_state_text_before_and_after_think_block() {
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(&mut s, &["prefix<think>middle</think>suffix"]);
        let thinking: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::ThinkingDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        let text: String = evs
            .iter()
            .filter_map(|e| {
                if let AgentEvent::TextDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(thinking, "middle");
        assert!(text.contains("prefix"));
        assert!(text.contains("suffix"));
    }

    #[test]
    fn think_state_no_think_tag_all_text() {
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(&mut s, &["just regular text here"]);
        assert!(evs
            .iter()
            .all(|e| matches!(e, AgentEvent::TextDelta { .. })));
    }

    // ── INFRA-184: plain-prose CoT detection tests ────────────────────

    fn collect_thinking(evs: &[AgentEvent]) -> String {
        evs.iter()
            .filter_map(|e| {
                if let AgentEvent::ThinkingDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect()
    }

    fn collect_text(evs: &[AgentEvent]) -> String {
        evs.iter()
            .filter_map(|e| {
                if let AgentEvent::TextDelta { delta } = e {
                    Some(delta.as_str())
                } else {
                    None
                }
            })
            .collect()
    }

    #[test]
    fn plain_cot_thinking_process_prefix_routes_to_thinking_delta() {
        // The exact pattern observed from Qwen3.5-9B-OptiQ-4bit on
        // "Say pong, nothing else." (PRODUCT-024 / INFRA-183 measurement).
        let mut s = ThinkStreamState::new(true);
        let cot = "Thinking Process:\n\n1.  **Analyze the Request:**\n    *   Input: \"Say pong\".\n    *   Output the word \"pong\".\n\n";
        let answer = "pong";
        let evs = collect_events(&mut s, &[cot, &format!("\n\nFinal Answer:\n{}", answer)]);
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(
            thinking.contains("Thinking Process:"),
            "thinking should contain CoT prefix, got: {:?}",
            thinking
        );
        assert!(
            thinking.contains("Analyze the Request"),
            "thinking should contain CoT body"
        );
        // The CoT prose itself can mention the word the model will output
        // (here: 'Output the word "pong"'), so we don't assert thinking
        // *excludes* "pong". What matters is the final answer is in text.
        assert!(
            text.contains("pong"),
            "text should contain the final answer, got: {:?}",
            text
        );
        assert!(
            !text.contains("Analyze the Request"),
            "text should NOT contain CoT body; text={:?}",
            text
        );
    }

    #[test]
    fn plain_cot_no_transition_routes_entire_response_as_thinking() {
        // Reasoning model that doesn't use a transition marker — the
        // chunk processor should still route everything as ThinkingDelta
        // rather than dumping the whole CoT into the chat bubble as
        // visible text.
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &["Thinking Process:\n\n1. Consider the input.\n2. Decide.\n"],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.contains("Thinking Process:"));
        assert!(text.is_empty(), "no transition seen → no text expected");
    }

    #[test]
    fn plain_cot_handles_chunked_prefix_across_deltas() {
        // The "Thinking Process:" prefix arrives split across multiple
        // streaming deltas — detection should still fire once enough
        // bytes have accumulated.
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &[
                "Thinki",
                "ng Pro",
                "cess:\n\n",
                "Step 1.\n\nFinal Answer:\nresult",
            ],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.contains("Step 1."));
        assert_eq!(text.trim(), "result");
    }

    #[test]
    fn plain_cot_inactive_when_response_is_normal_chat() {
        // A normal chat reply that doesn't start with a CoT prefix should
        // be routed as TextDelta unchanged (the existing tag-routing path).
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &["The capital of France is Paris. It has been since the early Middle Ages."],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.is_empty(), "no CoT prefix → no thinking");
        assert!(text.contains("Paris"));
    }

    #[test]
    fn plain_cot_does_not_misfire_when_think_tag_present() {
        // If the model uses `<think>` tags, the existing tag-routing path
        // wins — plain-CoT detection must defer.
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &["<think>Thinking Process: this is fake</think>real answer"],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.contains("Thinking Process:"));
        assert!(text.contains("real answer"));
    }

    #[test]
    fn plain_cot_short_response_below_sniff_threshold() {
        // Very short response that ends before we have enough bytes to
        // sniff the prefix — flush() decides at the end.
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(&mut s, &["Reasoning: yes"]);
        let thinking = collect_thinking(&evs);
        // "Reasoning:" matches, so the whole thing is thinking.
        assert!(thinking.contains("yes"));
    }

    #[test]
    fn plain_cot_prefix_is_case_insensitive() {
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &["THINKING PROCESS:\n\nstep one\n\nFinal Answer:\nok"],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.contains("step one"));
        assert_eq!(text.trim(), "ok");
    }

    #[test]
    fn plain_cot_disabled_via_env_falls_back_to_tag_only() {
        // Simulate CHUMP_PLAIN_COT=0 by manually constructing the state
        // with NotApplicable from the start. This is the same shape
        // ThinkStreamState::new produces when chump_plain_cot_enabled()
        // returns false.
        let mut s = ThinkStreamState {
            enabled: true,
            inside_think: false,
            buf: String::new(),
            plain_cot: PlainCotState::NotApplicable,
        };
        let evs = collect_events(
            &mut s,
            &["Thinking Process:\n\nbody\n\nFinal Answer:\ndone"],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        // With plain-CoT off, the prefix is just text — no thinking events.
        assert!(thinking.is_empty(), "plain-CoT off → no thinking");
        assert!(text.contains("Thinking Process"));
        assert!(text.contains("done"));
    }

    #[test]
    fn plain_cot_transition_with_chunked_marker() {
        // Transition marker arrives split across deltas.
        let mut s = ThinkStreamState::new(true);
        let evs = collect_events(
            &mut s,
            &[
                "Thinking Process:\n\nfigure it out\n",
                "\nFinal ",
                "Answer:\n",
                "the result",
            ],
        );
        let thinking = collect_thinking(&evs);
        let text = collect_text(&evs);
        assert!(thinking.contains("figure it out"));
        assert!(text.contains("the result"));
    }

    // ── num_ctx warning tests ─────────────────────────────────────────

    #[test]
    fn estimate_prompt_tokens_empty_messages() {
        let msgs: Vec<serde_json::Value> = vec![];
        assert_eq!(estimate_prompt_tokens(&msgs, None), 0);
    }

    #[test]
    fn estimate_prompt_tokens_counts_content_chars() {
        // "hello" + per-message overhead. Real chat-format token count ≈ 5-6.
        let msgs = vec![serde_json::json!({"role": "user", "content": "hello"})];
        let tokens = estimate_prompt_tokens(&msgs, None);
        assert!((7..=9).contains(&tokens), "unexpected estimate: {}", tokens);
    }

    #[test]
    fn estimate_prompt_tokens_includes_tool_schema_bytes() {
        let msgs = vec![serde_json::json!({"role": "user", "content": "hi"})];
        let tools = serde_json::json!([
            {"type": "function", "function": {"name": "read_file", "description": "Read a file from disk with a long enough description to measurably shift the token estimate.", "parameters": {}}}
        ]);
        let with_tools = estimate_prompt_tokens(&msgs, Some(&tools));
        let without = estimate_prompt_tokens(&msgs, None);
        assert!(
            with_tools > without,
            "tools JSON should increase estimated tokens: with={}, without={}",
            with_tools,
            without
        );
    }

    #[test]
    fn estimate_tokens_code_denser_than_prose() {
        // Code has high code-symbol density → fewer chars per token than prose.
        // For equal byte lengths, code should yield more estimated tokens.
        let prose = "The quick brown fox jumps over the lazy dog and keeps on running.";
        let code = "fn foo(x: i32) -> i32 { if x > 0 { x * 2 } else { -x } }";
        let prose_toks = estimate_tokens_for(prose);
        let code_toks = estimate_tokens_for(code);
        assert!(
            code_toks >= prose_toks,
            "code ({} toks) should use >= tokens than prose ({} toks) for similar length",
            code_toks,
            prose_toks
        );
    }

    #[test]
    fn estimate_tokens_non_ascii_counted_individually() {
        // Each non-ASCII byte → 1 token (conservative: CJK chars are 2+ bytes).
        let cjk = "你好世界"; // 4 CJK chars, 12 UTF-8 bytes
        let toks = estimate_tokens_for(cjk);
        // 12 non-ASCII bytes → 12 tokens (CJK often 1 char = 1 token, but bytes overcount here; any reasonable range)
        assert!(toks >= 4, "CJK estimate too low: {}", toks);
    }

    /// The warning only fires above 80% of num_ctx. Below threshold = silent.
    /// (We can't capture tracing output easily without a subscriber fixture,
    /// so these tests pin the pure estimate_prompt_tokens path and verify the
    /// helper itself doesn't panic when called.)
    #[test]
    fn warn_if_near_num_ctx_no_panic_on_zero() {
        warn_if_near_num_ctx(&[], None, 0);
    }

    #[test]
    fn warn_if_near_num_ctx_no_panic_under_threshold() {
        let msgs = vec![serde_json::json!({"role": "user", "content": "hi"})];
        warn_if_near_num_ctx(&msgs, None, 8192);
    }

    #[test]
    fn warn_if_near_num_ctx_no_panic_over_threshold() {
        // Build a message large enough to exceed 80% of a 1024 num_ctx
        // (that's ~819 tokens ≈ 3276 chars).
        let big = "x".repeat(5000);
        let msgs = vec![serde_json::json!({"role": "user", "content": big})];
        warn_if_near_num_ctx(&msgs, None, 1024);
    }

    /// CHUMP_NUM_CTX_WARN=0 suppresses the warning path entirely.
    #[test]
    #[serial]
    fn warn_if_near_num_ctx_suppressed_by_env() {
        std::env::set_var("CHUMP_NUM_CTX_WARN", "0");
        let big = "x".repeat(5000);
        let msgs = vec![serde_json::json!({"role": "user", "content": big})];
        warn_if_near_num_ctx(&msgs, None, 1024);
        std::env::remove_var("CHUMP_NUM_CTX_WARN");
    }

    // ── REL-004: content-aware token estimation ───────────────────────
    //
    // Acceptance: ±10% of actual token count on diverse prompts (code,
    // prose, tool schemas). "Actual" numbers below are approximate
    // Qwen3/GPT-style BPE tokenizer counts — these are conservative tests
    // that guard the bucket classification, not exact-match assertions.

    fn assert_token_estimate_within(s: &str, expected: usize, tolerance: f64) {
        let got = estimate_tokens_for(s);
        let err = ((got as f64) - (expected as f64)).abs() / (expected as f64);
        assert!(
            err <= tolerance,
            "estimate for {:?} = {}, expected ~{}, err={:.2} > tolerance={:.2}",
            if s.len() < 60 { s } else { &s[..60] },
            got,
            expected,
            err,
            tolerance
        );
    }

    #[test]
    fn punct_density_classifies_prose_as_low() {
        let prose = "The quick brown fox jumps over the lazy dog.";
        assert!(punct_density(prose) < CODE_PUNCT_THRESHOLD);
    }

    #[test]
    fn punct_density_classifies_rust_as_code() {
        let code = "fn main() { let x: Vec<u8> = vec![1, 2, 3]; println!(\"{:?}\", x); }";
        let d = punct_density(code);
        assert!(
            d >= CODE_PUNCT_THRESHOLD,
            "rust code density {} should be >= {}",
            d,
            CODE_PUNCT_THRESHOLD
        );
    }

    #[test]
    fn punct_density_classifies_json_as_dense() {
        let json = r#"{"name": "read_file", "args": {"path": "src/main.rs", "start": 1}}"#;
        assert!(punct_density(json) >= JSON_PUNCT_THRESHOLD);
    }

    #[test]
    fn estimate_prose_within_tolerance() {
        assert_token_estimate_within("The quick brown fox jumps over the lazy dog.", 10, 0.15);
    }

    #[test]
    fn estimate_rust_code_within_tolerance() {
        let code = "fn main() { let x: Vec<u8> = vec![1, 2, 3]; println!(\"{:?}\", x); }";
        assert_token_estimate_within(code, 24, 0.15);
    }

    #[test]
    fn estimate_json_within_tolerance() {
        let json = r#"{"name": "read_file", "args": {"path": "src/main.rs"}}"#;
        assert_token_estimate_within(json, 20, 0.15);
    }

    #[test]
    fn estimate_empty_string_is_zero() {
        assert_eq!(estimate_tokens_for(""), 0);
    }

    #[test]
    fn estimate_single_char_is_one() {
        assert_eq!(estimate_tokens_for("x"), 1);
    }

    #[test]
    fn estimate_code_higher_than_old_heuristic() {
        // Regression guard: code should now report MORE tokens than the
        // old `chars / 4` heuristic would have. This is the key safety
        // improvement — num_ctx warnings fire earlier on code content.
        let code = "fn x() { vec![1,2,3] }"; // 22 chars of pure code
        let old_heuristic = (22_f64 / 4.0).ceil() as usize;
        let new_estimate = estimate_tokens_for(code);
        assert!(
            new_estimate > old_heuristic,
            "code should exceed old chars/4; old={}, new={}",
            old_heuristic,
            new_estimate
        );
    }

    #[test]
    fn estimate_mixed_content_uses_per_message_classification() {
        // Prose and code in separate messages — each classified independently.
        let msgs = vec![
            serde_json::json!({"role": "user", "content": "Please update the following function:"}),
            serde_json::json!({
                "role": "assistant",
                "content": "fn foo() -> Vec<u8> { vec![1, 2, 3] }"
            }),
        ];
        let total = estimate_prompt_tokens(&msgs, None);
        assert!(
            (25..=60).contains(&total),
            "mixed content total out of range: {}",
            total
        );
    }

    // ACP-004: emit_delta_with_think_routing tests.

    fn collect_events_from_delta(
        delta: &str,
        in_think: &mut bool,
    ) -> Vec<crate::stream_events::AgentEvent> {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        emit_delta_with_think_routing(delta, in_think, &tx);
        drop(tx);
        let mut events = Vec::new();
        while let Ok(e) = rx.try_recv() {
            events.push(e);
        }
        events
    }

    #[test]
    fn routing_plain_text_emits_text_delta() {
        let mut in_think = false;
        let events = collect_events_from_delta("hello world", &mut in_think);
        assert_eq!(events.len(), 1);
        match &events[0] {
            crate::stream_events::AgentEvent::TextDelta { delta } => {
                assert_eq!(delta, "hello world")
            }
            other => panic!("expected TextDelta, got {:?}", other),
        }
        assert!(!in_think);
    }

    #[test]
    fn routing_complete_think_block_in_one_delta() {
        let mut in_think = false;
        let events = collect_events_from_delta("<think>step 1</think>answer", &mut in_think);
        assert_eq!(events.len(), 2, "events: {:?}", events);
        match &events[0] {
            crate::stream_events::AgentEvent::ThinkingDelta { delta } => {
                assert_eq!(delta, "step 1")
            }
            other => panic!("expected ThinkingDelta, got {:?}", other),
        }
        match &events[1] {
            crate::stream_events::AgentEvent::TextDelta { delta } => {
                assert_eq!(delta, "answer")
            }
            other => panic!("expected TextDelta, got {:?}", other),
        }
        assert!(!in_think);
    }

    #[test]
    fn routing_think_block_split_across_deltas() {
        let mut in_think = false;
        let e1 = collect_events_from_delta("<think>reasoning", &mut in_think);
        assert!(in_think);
        match &e1[0] {
            crate::stream_events::AgentEvent::ThinkingDelta { delta } => {
                assert_eq!(delta, "reasoning")
            }
            other => panic!("expected ThinkingDelta, got {:?}", other),
        }
        let e2 = collect_events_from_delta(" continues</think>final", &mut in_think);
        assert!(!in_think);
        match &e2[0] {
            crate::stream_events::AgentEvent::ThinkingDelta { delta } => {
                assert!(delta.contains("continues"))
            }
            other => panic!("expected ThinkingDelta, got {:?}", other),
        }
        match &e2[1] {
            crate::stream_events::AgentEvent::TextDelta { delta } => {
                assert_eq!(delta, "final")
            }
            other => panic!("expected TextDelta, got {:?}", other),
        }
    }

    #[test]
    fn routing_text_before_and_after_think_block() {
        let mut in_think = false;
        let events = collect_events_from_delta("prefix<think>thought</think>suffix", &mut in_think);
        assert_eq!(events.len(), 3);
        match &events[0] {
            crate::stream_events::AgentEvent::TextDelta { delta } => assert_eq!(delta, "prefix"),
            o => panic!("{:?}", o),
        }
        match &events[1] {
            crate::stream_events::AgentEvent::ThinkingDelta { delta } => {
                assert_eq!(delta, "thought")
            }
            o => panic!("{:?}", o),
        }
        match &events[2] {
            crate::stream_events::AgentEvent::TextDelta { delta } => assert_eq!(delta, "suffix"),
            o => panic!("{:?}", o),
        }
    }
}
