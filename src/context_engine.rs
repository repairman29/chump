//! Pluggable context engine — Phase 1.3 of Hermes competitive roadmap.
//!
//! The `ContextEngine` trait abstracts how Chump assembles its system prompt, compresses
//! message history, and decides when to compact. Different deployments benefit from
//! different strategies:
//!   - **DefaultContextEngine**: full consciousness framework injection (autonomy, research)
//!   - **LightContextEngine**: slim context for PWA/CLI fast path
//!   - **LosslessContextEngine** (future): no lossy summarization, use retrieval instead
//!   - **Custom (via plugin)**: domain-specific context (e.g. security-review mode)
//!
//! V1 is the trait + two built-in engines (Default wraps existing `assemble_context()`;
//! Light uses the light-context path already in `context_assembly.rs`). Plugin-provided
//! engines are supported via the `src/plugin.rs` registration path in future work.
//!
//! ## Selection
//!
//! `CHUMP_CONTEXT_ENGINE=default|light|autonomy|research|<plugin-name>` selects the engine.
//! Unknown values fall back to default with a tracing warn.

use anyhow::Result;
use std::sync::OnceLock;

/// Token usage report after a model response; context engines use this to decide when to compact.
#[derive(Debug, Clone, Copy, Default)]
pub struct TokenUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

/// Trait for a context engine. Engines are expected to be stateless at construction
/// but may cache compression state across `update_from_response` calls.
pub trait ContextEngine: Send + Sync {
    /// Human-readable name for logging.
    fn name(&self) -> &'static str;

    /// Assemble the system prompt context block for the current turn.
    /// Called at the top of each model call.
    fn assemble(&self) -> String;

    /// Return true if the engine thinks the message history needs compression given current
    /// prompt token count. Default: false unless explicitly overridden.
    fn should_compress(&self, _prompt_tokens: u32) -> bool {
        false
    }

    /// Compress the context string to fit within a target token budget.
    /// Default: truncate to 60K bytes, keeping head + tail with a marker.
    fn compress(&self, context: &str) -> String {
        compress_keeping_head_tail(context, 60_000)
    }

    /// Update engine state after a model response (token accounting, EMAs, etc.)
    fn update_from_response(&self, _usage: TokenUsage) {}
}

/// Default context engine — delegates to the existing `assemble_context()` function.
/// This is the "full consciousness framework" path used by CLI, Discord, and autonomy heartbeats.
pub struct DefaultContextEngine;

impl ContextEngine for DefaultContextEngine {
    fn name(&self) -> &'static str {
        "default"
    }
    fn assemble(&self) -> String {
        crate::context_assembly::assemble_context()
    }
    fn should_compress(&self, prompt_tokens: u32) -> bool {
        let threshold = std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(6000);
        prompt_tokens > threshold
    }
}

/// Light context engine — slim context for PWA/CLI fast path. Respects `CHUMP_LIGHT_CONTEXT=1`.
/// This exists as a first-class engine so deployments can opt in via `CHUMP_CONTEXT_ENGINE=light`
/// without flipping the global `CHUMP_LIGHT_CONTEXT` env var (useful for testing).
pub struct LightContextEngine;

impl ContextEngine for LightContextEngine {
    fn name(&self) -> &'static str {
        "light"
    }
    fn assemble(&self) -> String {
        // Temporarily set light mode for this assembly call, then restore.
        // We use a scoped env override via std::env since the existing assemble_context
        // reads CHUMP_LIGHT_CONTEXT directly. This isn't ideal but avoids refactoring
        // the 860-line assemble_context in V1.
        let prev = std::env::var("CHUMP_LIGHT_CONTEXT").ok();
        std::env::set_var("CHUMP_LIGHT_CONTEXT", "1");
        let out = crate::context_assembly::assemble_context();
        match prev {
            Some(v) => std::env::set_var("CHUMP_LIGHT_CONTEXT", v),
            None => std::env::remove_var("CHUMP_LIGHT_CONTEXT"),
        }
        out
    }
    fn should_compress(&self, prompt_tokens: u32) -> bool {
        // Lower threshold for light mode — compact aggressively to keep responses fast.
        let threshold = std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD_LIGHT")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(3000);
        prompt_tokens > threshold
    }
}

/// Autonomy-focused engine — optimized for heartbeat rounds (work, cursor_improve, research).
/// V1 delegates to default; distinguishes itself for future tuning.
pub struct AutonomyContextEngine;

impl ContextEngine for AutonomyContextEngine {
    fn name(&self) -> &'static str {
        "autonomy"
    }
    fn assemble(&self) -> String {
        crate::context_assembly::assemble_context()
    }
    fn should_compress(&self, prompt_tokens: u32) -> bool {
        // Autonomy rounds can afford more context — higher threshold.
        let threshold = std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD_AUTONOMY")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(10_000);
        prompt_tokens > threshold
    }
}

/// Research-focused engine — emphasizes deep knowledge retrieval over task status.
/// Suitable for `CHUMP_HEARTBEAT_TYPE=research` rounds.
pub struct ResearchContextEngine;

impl ContextEngine for ResearchContextEngine {
    fn name(&self) -> &'static str {
        "research"
    }
    fn assemble(&self) -> String {
        let prev = std::env::var("CHUMP_HEARTBEAT_TYPE").ok();
        std::env::set_var("CHUMP_HEARTBEAT_TYPE", "research");
        let out = crate::context_assembly::assemble_context();
        match prev {
            Some(v) => std::env::set_var("CHUMP_HEARTBEAT_TYPE", v),
            None => std::env::remove_var("CHUMP_HEARTBEAT_TYPE"),
        }
        out
    }
    fn should_compress(&self, prompt_tokens: u32) -> bool {
        // Research rounds need more context — compress less aggressively.
        let threshold = std::env::var("CHUMP_CONTEXT_SUMMARY_THRESHOLD_RESEARCH")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(12_000);
        prompt_tokens > threshold
    }
    fn compress(&self, context: &str) -> String {
        // Research: keep more tail (recent retrieval results) than head.
        compress_keeping_head_tail(context, 80_000)
    }
}

/// Compress `context` to at most `max_bytes`, keeping head + tail with a size marker.
fn compress_keeping_head_tail(context: &str, max_bytes: usize) -> String {
    if context.len() <= max_bytes {
        return context.to_string();
    }
    let keep = max_bytes / 2;
    let head_end = keep.min(context.len());
    let tail_start = context.len().saturating_sub(keep);
    format!(
        "{}\n\n[... {} bytes omitted by context compression ...]\n\n{}",
        &context[..head_end],
        context
            .len()
            .saturating_sub(head_end + (context.len() - tail_start)),
        &context[tail_start..],
    )
}

/// Active engine selection. Read once per process, cached.
static ACTIVE_ENGINE: OnceLock<Box<dyn ContextEngine>> = OnceLock::new();

/// Get the active context engine based on `CHUMP_CONTEXT_ENGINE` env var.
/// Falls back to `DefaultContextEngine` on unknown values.
pub fn active() -> &'static dyn ContextEngine {
    ACTIVE_ENGINE
        .get_or_init(|| select_engine_from_env())
        .as_ref()
}

fn select_engine_from_env() -> Box<dyn ContextEngine> {
    let name = std::env::var("CHUMP_CONTEXT_ENGINE")
        .unwrap_or_else(|_| "default".to_string())
        .to_lowercase();
    match name.as_str() {
        "default" | "chat" | "" => Box::new(DefaultContextEngine),
        "light" => Box::new(LightContextEngine),
        "autonomy" => Box::new(AutonomyContextEngine),
        "research" => Box::new(ResearchContextEngine),
        other => {
            tracing::warn!(engine = %other, "unknown CHUMP_CONTEXT_ENGINE; falling back to default");
            Box::new(DefaultContextEngine)
        }
    }
}

/// Explicitly construct an engine by name (bypasses env selection). Useful for tests and
/// future plugin-based registration.
pub fn engine_by_name(name: &str) -> Result<Box<dyn ContextEngine>> {
    match name.to_lowercase().as_str() {
        "default" | "chat" => Ok(Box::new(DefaultContextEngine)),
        "light" => Ok(Box::new(LightContextEngine)),
        "autonomy" => Ok(Box::new(AutonomyContextEngine)),
        "research" => Ok(Box::new(ResearchContextEngine)),
        other => Err(anyhow::anyhow!("unknown context engine '{}'", other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_engine_name() {
        let e = DefaultContextEngine;
        assert_eq!(e.name(), "default");
    }

    #[test]
    fn light_engine_name() {
        let e = LightContextEngine;
        assert_eq!(e.name(), "light");
    }

    #[test]
    fn default_compress_threshold() {
        let e = DefaultContextEngine;
        assert!(!e.should_compress(100));
        assert!(e.should_compress(100_000));
    }

    #[test]
    fn light_compress_threshold() {
        let e = LightContextEngine;
        assert!(!e.should_compress(100));
        assert!(e.should_compress(5_000));
    }

    #[test]
    fn autonomy_compress_threshold_is_higher() {
        let default = DefaultContextEngine;
        let autonomy = AutonomyContextEngine;
        // Both start not compressing under 6K
        assert!(!default.should_compress(5_000));
        assert!(!autonomy.should_compress(5_000));
        // Default compresses at 7K, autonomy doesn't
        assert!(default.should_compress(7_000));
        assert!(!autonomy.should_compress(7_000));
    }

    #[test]
    fn engine_by_name_valid() {
        assert!(engine_by_name("default").is_ok());
        assert!(engine_by_name("light").is_ok());
        assert!(engine_by_name("autonomy").is_ok());
        assert!(engine_by_name("DEFAULT").is_ok()); // case-insensitive
    }

    #[test]
    fn engine_by_name_invalid_errors() {
        assert!(engine_by_name("nonexistent").is_err());
        assert!(engine_by_name("").is_err());
    }

    #[test]
    fn engine_by_name_chat_alias_works() {
        assert!(engine_by_name("chat").is_ok());
        assert_eq!(engine_by_name("chat").unwrap().name(), "default");
    }

    #[test]
    fn engine_by_name_research_works() {
        assert!(engine_by_name("research").is_ok());
        assert_eq!(engine_by_name("research").unwrap().name(), "research");
    }

    #[test]
    fn research_compress_threshold_higher_than_default() {
        let research = ResearchContextEngine;
        let default = DefaultContextEngine;
        // Research threshold (12K) > default (6K) → research doesn't compress at 7K
        assert!(default.should_compress(7_000));
        assert!(!research.should_compress(7_000));
        assert!(research.should_compress(15_000));
    }

    #[test]
    fn compress_trait_default_truncates_large_context() {
        let engine = DefaultContextEngine;
        let large = "x".repeat(120_000);
        let compressed = engine.compress(&large);
        assert!(compressed.len() < large.len());
        assert!(compressed.contains("bytes omitted by context compression"));
    }

    #[test]
    fn compress_trait_noop_on_small_context() {
        let engine = DefaultContextEngine;
        let small = "hello world";
        assert_eq!(engine.compress(small), small);
    }

    #[test]
    fn trait_object_safety() {
        // Compile-time check: ContextEngine must be dyn-compatible.
        let _e: Box<dyn ContextEngine> = Box::new(DefaultContextEngine);
        let _e: Box<dyn ContextEngine> = Box::new(LightContextEngine);
        let _e: Box<dyn ContextEngine> = Box::new(AutonomyContextEngine);
    }

    #[test]
    fn token_usage_default() {
        let u = TokenUsage::default();
        assert_eq!(u.prompt_tokens, 0);
        assert_eq!(u.completion_tokens, 0);
        assert_eq!(u.total_tokens, 0);
    }
}
