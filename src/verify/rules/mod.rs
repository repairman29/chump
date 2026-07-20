//! CREDIBLE-155 — rule trait + registry for `chump verify`.
//!
//! Each rule evaluates PARSED diff semantics (never raw patch grep where a
//! value comparison is possible), carries the incident receipt that justifies
//! its existence, and returns machine-readable remediation. The engine (not
//! the rule) applies Verify-Bypass trailers and emits the audit event.

pub mod docs_delta;
pub mod no_new_bypass_env_vars;
pub mod test_lag;

use super::VerifyContext;

/// Outcome of a single rule evaluation, before bypass application.
pub enum Evaluation {
    /// Rule applied and is satisfied.
    Pass(String),
    /// Rule has nothing to say about this diff.
    NotApplicable(String),
    /// Rule applied and is violated.
    Fail { detail: String, remediation: String },
}

pub trait Rule {
    /// Stable kebab-case id — this is what `Verify-Bypass:` trailers name.
    fn id(&self) -> &'static str;
    /// The incident(s) that made this rule exist. Kept verbatim so the *why*
    /// survives the port from the shell gates.
    fn incident_receipt(&self) -> &'static str;
    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation;
}

/// All registered rules, in report order.
pub fn registry() -> Vec<Box<dyn Rule>> {
    vec![
        Box::new(docs_delta::DocsDelta),
        Box::new(test_lag::TestLag),
        Box::new(no_new_bypass_env_vars::NoNewBypassEnvVars),
    ]
}
