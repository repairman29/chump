//! OpenTelemetry GenAI semantic conventions for Chump's LLM spans.
//!
//! Sprint D1 (observability + UX): standardize attribute names across
//! `provider_cascade.rs`, `local_openai.rs`, `mistralrs_provider.rs`, and
//! `streaming_provider.rs` so any OTel-compatible collector parses them uniformly.
//!
//! Spec reference: <https://opentelemetry.io/docs/specs/semconv/gen-ai/>
//!
//! # Usage
//!
//! Rather than writing ad-hoc `tracing::info!(model = %m, ...)` spans, build a
//! `GenAiSpanFields` and emit it as structured attributes:
//!
//! ```ignore
//! use crate::genai_conv::{GenAiSpanFields, gen_ai};
//!
//! let fields = GenAiSpanFields::new("openai", "chat", "qwen2.5:14b")
//!     .with_request_max_tokens(2048)
//!     .with_request_temperature(0.2);
//!
//! let span = tracing::info_span!(
//!     "gen_ai.chat",
//!     gen_ai.system = %fields.system,
//!     gen_ai.operation.name = %fields.operation,
//!     gen_ai.request.model = %fields.request_model,
//! );
//! let _enter = span.enter();
//! // ... call the model ...
//! // Record response fields after:
//! tracing::Span::current().record(gen_ai::RESPONSE_FINISH_REASONS, "stop");
//! tracing::Span::current().record(gen_ai::USAGE_INPUT_TOKENS, usage.prompt_tokens);
//! tracing::Span::current().record(gen_ai::USAGE_OUTPUT_TOKENS, usage.completion_tokens);
//! ```
//!
//! # Why no `opentelemetry` crate dependency?
//!
//! The full `opentelemetry` Rust stack pulls in ~50 transitive crates and a new
//! async runtime layer. For V1 we just emit the attribute names correctly via
//! `tracing`; any OTel collector (including `tracing-opentelemetry` bridge if
//! someone adds it later) picks up structured `tracing` fields verbatim. This is
//! the same pattern Rig and AgentMesh use.

/// Standard OpenTelemetry GenAI attribute names. Use these as span field keys.
pub mod gen_ai {
    pub const SYSTEM: &str = "gen_ai.system";
    pub const OPERATION_NAME: &str = "gen_ai.operation.name";

    pub const REQUEST_MODEL: &str = "gen_ai.request.model";
    pub const REQUEST_MAX_TOKENS: &str = "gen_ai.request.max_tokens";
    pub const REQUEST_TEMPERATURE: &str = "gen_ai.request.temperature";
    pub const REQUEST_TOP_P: &str = "gen_ai.request.top_p";
    pub const REQUEST_PRESENCE_PENALTY: &str = "gen_ai.request.presence_penalty";
    pub const REQUEST_FREQUENCY_PENALTY: &str = "gen_ai.request.frequency_penalty";
    pub const REQUEST_STOP_SEQUENCES: &str = "gen_ai.request.stop_sequences";

    pub const RESPONSE_ID: &str = "gen_ai.response.id";
    pub const RESPONSE_MODEL: &str = "gen_ai.response.model";
    pub const RESPONSE_FINISH_REASONS: &str = "gen_ai.response.finish_reasons";

    pub const USAGE_INPUT_TOKENS: &str = "gen_ai.usage.input_tokens";
    pub const USAGE_OUTPUT_TOKENS: &str = "gen_ai.usage.output_tokens";

    /// Chump-specific extension: which provider cascade slot handled the request.
    /// Allowed per OTel spec — custom namespaces are permitted.
    pub const CHUMP_CASCADE_SLOT: &str = "chump.cascade.slot";

    /// Chump-specific extension: which precision regime was active
    /// (exploit / balanced / explore / conservative).
    pub const CHUMP_PRECISION_REGIME: &str = "chump.precision.regime";
}

/// Standard operation names per the OTel GenAI spec.
pub mod operation {
    pub const CHAT: &str = "chat";
    pub const COMPLETION: &str = "completion";
    pub const EMBEDDINGS: &str = "embeddings";
    pub const TEXT_COMPLETION: &str = "text_completion";
}

/// Standard system names. Use these in `gen_ai.system` for consistency.
pub mod system {
    pub const OPENAI: &str = "openai";
    pub const ANTHROPIC: &str = "anthropic";
    pub const OLLAMA: &str = "ollama";
    pub const VLLM: &str = "vllm";
    pub const MISTRALRS: &str = "mistralrs";
    pub const GROQ: &str = "groq";
    pub const CEREBRAS: &str = "cerebras";
    pub const MISTRAL: &str = "mistral";
    pub const OPENROUTER: &str = "openrouter";
    pub const GEMINI: &str = "gemini";
    pub const GITHUB_MODELS: &str = "github_models";
    pub const NVIDIA_NIM: &str = "nvidia_nim";
    pub const SAMBANOVA: &str = "sambanova";
}

/// Builder for GenAI span request fields. Construct once before the model call,
/// emit as span fields, then `record()` the response fields after.
#[derive(Debug, Clone)]
pub struct GenAiSpanFields {
    pub system: String,
    pub operation: String,
    pub request_model: String,
    pub request_max_tokens: Option<u32>,
    pub request_temperature: Option<f64>,
    pub request_top_p: Option<f64>,
}

impl GenAiSpanFields {
    pub fn new(
        system: impl Into<String>,
        operation: impl Into<String>,
        model: impl Into<String>,
    ) -> Self {
        Self {
            system: system.into(),
            operation: operation.into(),
            request_model: model.into(),
            request_max_tokens: None,
            request_temperature: None,
            request_top_p: None,
        }
    }

    pub fn with_request_max_tokens(mut self, n: u32) -> Self {
        self.request_max_tokens = Some(n);
        self
    }

    pub fn with_request_temperature(mut self, t: f64) -> Self {
        self.request_temperature = Some(t);
        self
    }

    pub fn with_request_top_p(mut self, p: f64) -> Self {
        self.request_top_p = Some(p);
        self
    }
}

/// Response-side fields to record on an active span.
#[derive(Debug, Clone, Default)]
pub struct GenAiResponseFields {
    pub response_id: Option<String>,
    pub response_model: Option<String>,
    pub response_finish_reasons: Option<String>,
    pub usage_input_tokens: Option<u64>,
    pub usage_output_tokens: Option<u64>,
}

impl GenAiResponseFields {
    /// Record all non-None fields onto the current span. Use this after a
    /// `#[tracing::instrument]` span or inside `span.in_scope(|| { ... })`.
    pub fn record_on_current_span(&self) {
        let span = tracing::Span::current();
        if let Some(ref v) = self.response_id {
            span.record(gen_ai::RESPONSE_ID, v.as_str());
        }
        if let Some(ref v) = self.response_model {
            span.record(gen_ai::RESPONSE_MODEL, v.as_str());
        }
        if let Some(ref v) = self.response_finish_reasons {
            span.record(gen_ai::RESPONSE_FINISH_REASONS, v.as_str());
        }
        if let Some(v) = self.usage_input_tokens {
            span.record(gen_ai::USAGE_INPUT_TOKENS, v);
        }
        if let Some(v) = self.usage_output_tokens {
            span.record(gen_ai::USAGE_OUTPUT_TOKENS, v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn span_fields_builder_chaining() {
        let f = GenAiSpanFields::new("ollama", "chat", "qwen2.5:14b")
            .with_request_max_tokens(2048)
            .with_request_temperature(0.2)
            .with_request_top_p(0.95);
        assert_eq!(f.system, "ollama");
        assert_eq!(f.operation, "chat");
        assert_eq!(f.request_model, "qwen2.5:14b");
        assert_eq!(f.request_max_tokens, Some(2048));
        assert!((f.request_temperature.unwrap() - 0.2).abs() < 1e-9);
        assert!((f.request_top_p.unwrap() - 0.95).abs() < 1e-9);
    }

    #[test]
    fn constants_match_otel_spec() {
        // Regression guard: if the OTel GenAI spec changes or someone edits by mistake,
        // these tests catch drift from the published convention names.
        assert_eq!(gen_ai::SYSTEM, "gen_ai.system");
        assert_eq!(gen_ai::OPERATION_NAME, "gen_ai.operation.name");
        assert_eq!(gen_ai::REQUEST_MODEL, "gen_ai.request.model");
        assert_eq!(gen_ai::RESPONSE_ID, "gen_ai.response.id");
        assert_eq!(gen_ai::USAGE_INPUT_TOKENS, "gen_ai.usage.input_tokens");
        assert_eq!(gen_ai::USAGE_OUTPUT_TOKENS, "gen_ai.usage.output_tokens");
    }

    #[test]
    fn chump_extension_namespaces_are_prefixed() {
        // Chump-specific attrs should all start with "chump." per OTel custom namespace rules.
        assert!(gen_ai::CHUMP_CASCADE_SLOT.starts_with("chump."));
        assert!(gen_ai::CHUMP_PRECISION_REGIME.starts_with("chump."));
    }

    #[test]
    fn system_names_are_lowercase_snake() {
        // OTel convention: system names are lowercase with underscores.
        for s in [
            system::OPENAI,
            system::OLLAMA,
            system::VLLM,
            system::MISTRALRS,
            system::GITHUB_MODELS,
            system::NVIDIA_NIM,
        ] {
            assert!(
                s.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "{}",
                s
            );
        }
    }

    #[test]
    fn response_fields_default_is_empty() {
        let r = GenAiResponseFields::default();
        assert!(r.response_id.is_none());
        assert!(r.usage_input_tokens.is_none());
    }
}
