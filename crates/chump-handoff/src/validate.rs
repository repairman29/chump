//! `Validate` trait — the post-deserialise checkpoint for output payloads.
//!
//! Distinct from "did the JSON deserialise?" (that's serde's job). This trait
//! asks "is the deserialised value *meaningful*?" — e.g. did the subagent
//! reference a file that exists, did it return at least one item in a list
//! that the parent treats as non-empty, etc.
//!
//! Contracts implement `Validate` on their `Output` so [`crate::dispatch`]
//! catches semantic violations at the same boundary as shape violations.

use std::fmt;

/// A semantic-validation error from an `Output` payload.
///
/// Cheap to construct (just a message). If validation paths grow rich
/// (e.g. multiple field errors), a follow-up gap can swap this for a
/// structured variant; the surface is intentionally narrow for v1.
#[derive(Debug, Clone)]
pub struct ValidationError {
    msg: String,
}

impl ValidationError {
    /// Construct a new validation error with a human-readable message.
    pub fn new(msg: impl Into<String>) -> Self {
        Self { msg: msg.into() }
    }

    /// Borrow the underlying message text.
    pub fn message(&self) -> &str {
        &self.msg
    }
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.msg)
    }
}

impl std::error::Error for ValidationError {}

/// Post-deserialise semantic check on an output payload.
///
/// Implementors should return `Err(ValidationError::new("…"))` when the
/// payload's *shape* is fine but its *meaning* is wrong (e.g. a
/// `unified_diff` field that doesn't start with `diff --git`).
///
/// The default impl returns `Ok(())` — opt-in to validation by overriding.
pub trait Validate {
    /// Run the semantic check. Default: nothing to check.
    fn validate(&self) -> Result<(), ValidationError> {
        Ok(())
    }
}
