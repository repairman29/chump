//! PRODUCT-014: lightweight intent classifier for inbound Discord messages.
//!
//! Recognizes three top-level user intents — `summarize`, `search`, `remind` —
//! using simple keyword/prefix matching. The classifier runs *before* the
//! LLM-based handler and only emits a structured ambient.jsonl event so the
//! PWA / observability surfaces can show "what users are asking Discord for"
//! without parsing free-form prompts. The LLM still drives the actual reply.

use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscordIntent {
    Summarize,
    Search,
    Remind,
}

impl DiscordIntent {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Summarize => "summarize",
            Self::Search => "search",
            Self::Remind => "remind",
        }
    }
}

/// Classify a Discord message into one of the three known intents, if any.
///
/// Strategy: case-insensitive keyword search anchored at word boundaries.
/// Slash-style prefixes (`/summarize`, `/search`, `/remind`) match too, as
/// do natural-language openers like "remind me to ...", "search for ...",
/// "summarize this ...".
pub fn classify(content: &str) -> Option<DiscordIntent> {
    let lower = content.trim().to_lowercase();
    if lower.is_empty() {
        return None;
    }

    // Slash-prefix forms
    if lower.starts_with("/summarize") || lower.starts_with("/tldr") {
        return Some(DiscordIntent::Summarize);
    }
    if lower.starts_with("/search") || lower.starts_with("/find") {
        return Some(DiscordIntent::Search);
    }
    if lower.starts_with("/remind") {
        return Some(DiscordIntent::Remind);
    }

    // Natural-language openers (cheap word-boundary check)
    let starts_with_word = |w: &str| lower == w || lower.starts_with(&format!("{} ", w));
    if starts_with_word("summarize") || starts_with_word("tldr") || lower.starts_with("tl;dr") {
        return Some(DiscordIntent::Summarize);
    }
    if starts_with_word("search") || lower.starts_with("look up ") || lower.starts_with("find me ")
    {
        return Some(DiscordIntent::Search);
    }
    if lower.starts_with("remind me ") || starts_with_word("remind") {
        return Some(DiscordIntent::Remind);
    }

    None
}

/// Append a `kind=discord_intent` event to ambient.jsonl via the
/// scripts/dev/ambient-emit.sh helper. Best-effort: failures are swallowed so a
/// missing/unwritable ambient log never breaks Discord message handling.
pub fn emit_ambient(intent: DiscordIntent, channel_id: u64, user_name: &str) {
    let script = ambient_emit_script_path();
    if !script.exists() {
        return;
    }
    let _ = Command::new(&script)
        .arg("discord_intent")
        .arg(format!("intent={}", intent.as_str()))
        .arg(format!("channel={}", channel_id))
        .arg(format!("user={}", user_name))
        .status();
}

fn ambient_emit_script_path() -> PathBuf {
    // Resolve from git repo root if possible, fall back to cwd.
    let root = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout).ok()
            } else {
                None
            }
        })
        .map(|s| PathBuf::from(s.trim()))
        .unwrap_or_else(|| PathBuf::from("."));
    root.join("scripts/dev/ambient-emit.sh")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slash_forms_recognized() {
        assert_eq!(classify("/summarize"), Some(DiscordIntent::Summarize));
        assert_eq!(
            classify("/tldr this thread"),
            Some(DiscordIntent::Summarize)
        );
        assert_eq!(classify("/search rust async"), Some(DiscordIntent::Search));
        assert_eq!(classify("/find docs"), Some(DiscordIntent::Search));
        assert_eq!(classify("/remind me at 5pm"), Some(DiscordIntent::Remind));
    }

    #[test]
    fn natural_language_openers() {
        assert_eq!(
            classify("summarize the last 20 messages"),
            Some(DiscordIntent::Summarize)
        );
        assert_eq!(
            classify("TLDR what happened today"),
            Some(DiscordIntent::Summarize)
        );
        assert_eq!(
            classify("tl;dr the meeting"),
            Some(DiscordIntent::Summarize)
        );
        assert_eq!(
            classify("search the docs for Tauri"),
            Some(DiscordIntent::Search)
        );
        assert_eq!(
            classify("look up the cargo docs"),
            Some(DiscordIntent::Search)
        );
        assert_eq!(
            classify("remind me to ship at 5"),
            Some(DiscordIntent::Remind)
        );
    }

    #[test]
    fn case_insensitive() {
        assert_eq!(classify("SUMMARIZE this"), Some(DiscordIntent::Summarize));
        assert_eq!(classify("Remind me to eat"), Some(DiscordIntent::Remind));
    }

    #[test]
    fn unrecognized_returns_none() {
        assert_eq!(classify("hello there"), None);
        assert_eq!(classify(""), None);
        assert_eq!(classify("   "), None);
        assert_eq!(classify("can you do something"), None);
        // "summary" alone is not a slash command and doesn't open with the
        // verb — a bare word inside a sentence shouldn't trigger.
        assert_eq!(classify("give me a summary"), None);
    }

    #[test]
    fn intent_str_roundtrip() {
        assert_eq!(DiscordIntent::Summarize.as_str(), "summarize");
        assert_eq!(DiscordIntent::Search.as_str(), "search");
        assert_eq!(DiscordIntent::Remind.as_str(), "remind");
    }
}
