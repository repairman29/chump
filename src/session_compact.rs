//! COG-019: Context-window compaction for long --chat / --web sessions.
//!
//! When the accumulated conversation history exceeds `CHUMP_COMPACT_THRESHOLD`
//! characters (default 40 000, roughly 10 k tokens), the oldest turns are
//! summarised into a single `[PRIOR CONTEXT SUMMARY]` sentinel and replaced
//! in-place so the session file stays compact.
//!
//! The last `CHUMP_COMPACT_KEEP_TURNS` user/assistant pairs (default 6) are
//! always kept verbatim so recent context is never lost.
//!
//! Controlled by:
//!   CHUMP_COMPACT_ENABLED=0   — disable entirely (default on)
//!   CHUMP_COMPACT_THRESHOLD=N — char count trigger (default 40000)
//!   CHUMP_COMPACT_KEEP_TURNS=N— pairs to keep verbatim (default 6)

use axonerai::provider::{Message, Provider};
use axonerai::session::Session;

const DEFAULT_THRESHOLD: usize = 40_000;
const DEFAULT_KEEP_TURNS: usize = 6;
const SUMMARY_MARKER: &str = "[PRIOR CONTEXT SUMMARY]";

/// Returns the total character length of all messages in the session.
fn session_char_len(session: &Session) -> usize {
    session
        .get_messages()
        .iter()
        .map(|m| m.role.len() + m.content.len())
        .sum()
}

/// Check env flags and decide whether compaction should run.
fn compaction_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_COMPACT_ENABLED").as_deref(),
        Ok("0") | Ok("false")
    )
}

fn compact_threshold() -> usize {
    std::env::var("CHUMP_COMPACT_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_THRESHOLD)
}

fn keep_turns() -> usize {
    std::env::var("CHUMP_COMPACT_KEEP_TURNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_KEEP_TURNS)
}

/// If the session already has a summary block, check whether the older block
/// plus new turns still exceeds the threshold so we don't re-summarise on
/// every single turn once we've already compacted once.
fn already_compacted_and_short(session: &Session, threshold: usize) -> bool {
    let has_marker = session
        .get_messages()
        .iter()
        .any(|m| m.content.starts_with(SUMMARY_MARKER));
    has_marker && session_char_len(session) < threshold
}

/// Build the summarisation prompt from a slice of messages to compress.
fn build_summary_prompt(to_compress: &[Message]) -> String {
    let mut body = String::with_capacity(to_compress.iter().map(|m| m.content.len() + 32).sum());
    for m in to_compress {
        body.push_str(&m.role);
        body.push_str(": ");
        body.push_str(&m.content);
        body.push('\n');
    }
    format!(
        "Summarise the following conversation history concisely. \
Preserve: decisions made, tools called and their outcomes, facts learned, \
the current task state, and any open questions. \
Write in third-person past tense. Be dense — every sentence must earn its place. \
Maximum 400 words.\n\n{body}"
    )
}

/// Attempt to summarise `to_compress` via the provider.
/// Returns `None` if the provider call fails (fail-open: keep original messages).
async fn summarise(to_compress: &[Message], provider: &dyn Provider) -> Option<String> {
    let prompt = build_summary_prompt(to_compress);
    let req = vec![Message {
        role: "user".to_string(),
        content: prompt,
    }];
    match provider.complete(req, None, Some(600), None).await {
        Ok(resp) => resp.text.filter(|t| !t.trim().is_empty()),
        Err(e) => {
            tracing::warn!("session_compact: summarisation failed, keeping original: {e}");
            None
        }
    }
}

/// Core compaction logic. Mutates `session` in-place.
///
/// `session_id` is threaded in from the caller because [`Session`] does not
/// expose its id field publicly; we need it to reconstruct the session after
/// replacing the message list.
///
/// Returns `true` if compaction was performed, `false` if skipped.
pub async fn maybe_compact(
    session: &mut Session,
    provider: &dyn Provider,
    session_id: &str,
) -> bool {
    if !compaction_enabled() {
        return false;
    }
    let threshold = compact_threshold();
    if session_char_len(session) < threshold {
        return false;
    }
    if already_compacted_and_short(session, threshold) {
        return false;
    }

    let messages = session.get_messages().to_vec();
    let keep = keep_turns() * 2; // each turn = 1 user + 1 assistant message

    // Need at least keep+2 messages to have something worth compressing.
    if messages.len() <= keep + 1 {
        return false;
    }

    let split_at = messages.len().saturating_sub(keep);
    let to_compress = &messages[..split_at];
    let to_keep = &messages[split_at..];

    tracing::info!(
        compress_count = to_compress.len(),
        keep_count = to_keep.len(),
        total_chars = session_char_len(session),
        threshold,
        "session_compact: threshold exceeded, compacting"
    );

    let Some(summary) = summarise(to_compress, provider).await else {
        tracing::warn!("session_compact: summarisation returned None, skipping compaction");
        return false;
    };

    let summary_message = Message {
        role: "user".to_string(),
        content: format!("{SUMMARY_MARKER}\n{summary}\n[END SUMMARY]"),
    };

    // Rebuild session: summary block + verbatim tail.
    let mut new_messages = Vec::with_capacity(1 + to_keep.len());
    new_messages.push(summary_message);
    new_messages.extend_from_slice(to_keep);

    // Replace messages in session via reconstruct.
    let new_session = rebuild_session(session_id, new_messages);
    *session = new_session;

    tracing::info!(
        new_chars = session_char_len(session),
        "session_compact: compaction complete"
    );
    true
}

/// Reconstruct a session with a new message list, preserving session_id.
fn rebuild_session(session_id: &str, new_messages: Vec<Message>) -> Session {
    let mut s = Session::new(session_id.to_string());
    for m in new_messages {
        s.add_message(m);
    }
    s
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn msgs(pairs: &[(&str, &str)]) -> Vec<Message> {
        pairs
            .iter()
            .flat_map(|(u, a)| {
                [
                    Message {
                        role: "user".to_string(),
                        content: u.to_string(),
                    },
                    Message {
                        role: "assistant".to_string(),
                        content: a.to_string(),
                    },
                ]
            })
            .collect()
    }

    #[test]
    fn char_len_counts_all_content() {
        let mut s = Session::new("t".into());
        for m in msgs(&[("hello", "world")]) {
            s.add_message(m);
        }
        // "user"(4) + "hello"(5) + "assistant"(9) + "world"(5) = 23
        assert_eq!(session_char_len(&s), 23);
    }

    #[test]
    fn below_threshold_skips_at_char_level() {
        // session_char_len < threshold → no compaction needed
        let mut s = Session::new("t".into());
        for m in msgs(&[("hi", "there")]) {
            s.add_message(m);
        }
        assert!(session_char_len(&s) < compact_threshold());
    }

    #[test]
    fn summary_prompt_contains_all_roles() {
        let to_compress = msgs(&[
            ("question one", "answer one"),
            ("question two", "answer two"),
        ]);
        let prompt = build_summary_prompt(&to_compress);
        assert!(prompt.contains("user:"));
        assert!(prompt.contains("assistant:"));
        assert!(prompt.contains("question one"));
        assert!(prompt.contains("answer two"));
    }

    #[test]
    fn summary_marker_constant_format() {
        assert!(SUMMARY_MARKER.starts_with('['));
        assert!(SUMMARY_MARKER.ends_with(']'));
    }

    #[test]
    #[serial_test::serial]
    fn keep_turns_default_is_six() {
        // Env not set in test → default 6
        std::env::remove_var("CHUMP_COMPACT_KEEP_TURNS");
        assert_eq!(keep_turns(), 6);
    }

    #[test]
    #[serial_test::serial]
    fn keep_turns_env_override() {
        std::env::set_var("CHUMP_COMPACT_KEEP_TURNS", "3");
        assert_eq!(keep_turns(), 3);
        std::env::remove_var("CHUMP_COMPACT_KEEP_TURNS");
    }

    #[test]
    #[serial_test::serial]
    fn compaction_disabled_via_env() {
        std::env::set_var("CHUMP_COMPACT_ENABLED", "0");
        assert!(!compaction_enabled());
        std::env::remove_var("CHUMP_COMPACT_ENABLED");
    }

    #[test]
    fn rebuild_session_preserves_messages() {
        let new_msgs = vec![
            Message {
                role: "user".to_string(),
                content: "[PRIOR CONTEXT SUMMARY]\nstuff\n[END SUMMARY]".to_string(),
            },
            Message {
                role: "user".to_string(),
                content: "latest question".to_string(),
            },
            Message {
                role: "assistant".to_string(),
                content: "latest answer".to_string(),
            },
        ];
        let rebuilt = rebuild_session("my-session", new_msgs.clone());
        assert_eq!(rebuilt.get_messages().len(), 3);
        assert!(rebuilt.get_messages()[0]
            .content
            .starts_with(SUMMARY_MARKER));
    }
}
