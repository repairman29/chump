//! Inference router — two-tier dispatch (Reflexive on-device + Neocortex cloud).
//!
//! Vendored architectural pattern from repairman29/pixel-edge-server
//! at commit bef6783f733ac8231975ff61969510f80e05788e
//! (branch claude/pixel-ai-server-setup-jGLqd),
//! original claude-gateway/server.js lines 213-269.
//!
//! See docs/arsenal/cross-pollination/CP-011-bicameral-mind.md for the
//! mapping, routing heuristics, and convergence with CP-001 (neural-farm,
//! the Reflexive backend) + CP-012 (ai-gm-service ensemble, the Neocortex
//! cascade).

use std::path::Path;

/// The two tiers a call site can be routed to. `Reflexive` is the on-device,
/// fast, cheap fallback; `Neocortex` is the cloud, deliberate, expensive path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Reflexive,
    Neocortex,
}

impl Tier {
    fn as_str(self) -> &'static str {
        match self {
            Tier::Reflexive => "reflexive",
            Tier::Neocortex => "neocortex",
        }
    }
}

/// Context describing a single routing decision. `attempt` implements the
/// escalation contract: attempt 0 tries Reflexive, attempt >= 1 escalates to
/// Neocortex (one escalation per call, per CP-011's "Escalation pollution"
/// mitigation — a second non-answer returns the gap to the pool rather than
/// escalating again).
#[derive(Debug, Clone)]
pub struct CallContext {
    pub call_site: String,
    pub attempt: u32,
}

impl CallContext {
    pub fn new(call_site: impl Into<String>) -> Self {
        Self {
            call_site: call_site.into(),
            attempt: 0,
        }
    }

    pub fn with_attempt(mut self, attempt: u32) -> Self {
        self.attempt = attempt;
        self
    }
}

/// Explicit tier override read from `CHUMP_INFERENCE_TIER`. `Auto` defers to
/// the escalation heuristic in [`route`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TierOverride {
    Reflexive,
    Neocortex,
    Auto,
}

fn tier_override() -> TierOverride {
    match std::env::var("CHUMP_INFERENCE_TIER")
        .unwrap_or_else(|_| "reflexive".to_string())
        .to_lowercase()
        .as_str()
    {
        "neocortex" => TierOverride::Neocortex,
        "auto" => TierOverride::Auto,
        // "reflexive" and anything unrecognized default to the cheap tier —
        // the router never silently escalates to Neocortex on a typo.
        _ => TierOverride::Reflexive,
    }
}

/// Decide which tier a call site should use, honoring `CHUMP_INFERENCE_TIER`
/// (`reflexive` | `neocortex` | `auto`, default `reflexive`). In `auto` mode,
/// attempt 0 goes Reflexive and any later attempt escalates to Neocortex —
/// mirroring pixel-edge-server's "caller picks the tier, gateway enforces"
/// contract, with the escalation-on-retry rule layered on top for Chump's
/// gap-decompose / subagent-dispatch call sites.
pub fn route(ctx: &CallContext) -> Tier {
    let tier = match tier_override() {
        TierOverride::Reflexive => Tier::Reflexive,
        TierOverride::Neocortex => Tier::Neocortex,
        TierOverride::Auto => {
            if ctx.attempt == 0 {
                Tier::Reflexive
            } else {
                Tier::Neocortex
            }
        }
    };
    emit_routed_event(ctx, tier);
    tier
}

/// Append `kind=inference_routed` to `ambient.jsonl` so routing decisions are
/// observable fleet-wide, mirroring the established per-module
/// `emit_ambient_event` pattern (see `src/ci_lesson.rs`).
fn emit_routed_event(ctx: &CallContext, tier: Tier) {
    let repo_root = match std::env::var("CHUMP_REPO_ROOT") {
        Ok(p) => std::path::PathBuf::from(p),
        Err(_) => match std::env::current_dir() {
            Ok(p) => p,
            Err(_) => return,
        },
    };
    let ambient_path = if let Ok(path) = std::env::var("CHUMP_AMBIENT_LOG") {
        Path::new(&path).to_path_buf()
    } else {
        let lock_dir = repo_root.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let line = serde_json::json!({
        "ts": ts,
        "kind": "inference_routed",
        "call_site": ctx.call_site,
        "attempt": ctx.attempt,
        "tier": tier.as_str(),
    });
    if let Ok(mut contents) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(contents, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // std::env is process-global; serialize tests that touch
    // CHUMP_INFERENCE_TIER so they don't race under `cargo test` threads.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_tier<T>(value: Option<&str>, f: impl FnOnce() -> T) -> T {
        let _guard = ENV_LOCK.lock().unwrap();
        match value {
            Some(v) => std::env::set_var("CHUMP_INFERENCE_TIER", v),
            None => std::env::remove_var("CHUMP_INFERENCE_TIER"),
        }
        let result = f();
        std::env::remove_var("CHUMP_INFERENCE_TIER");
        result
    }

    #[test]
    fn default_tier_is_reflexive() {
        with_tier(None, || {
            let ctx = CallContext::new("gap_decompose");
            assert_eq!(route(&ctx), Tier::Reflexive);
        });
    }

    #[test]
    fn explicit_reflexive_tier() {
        with_tier(Some("reflexive"), || {
            let ctx = CallContext::new("subagent_dispatch");
            assert_eq!(route(&ctx), Tier::Reflexive);
        });
    }

    #[test]
    fn explicit_neocortex_tier() {
        with_tier(Some("neocortex"), || {
            let ctx = CallContext::new("daily_curation");
            assert_eq!(route(&ctx), Tier::Neocortex);
        });
    }

    #[test]
    fn auto_tier_escalates_on_retry() {
        with_tier(Some("auto"), || {
            let first = CallContext::new("gap_decompose").with_attempt(0);
            assert_eq!(route(&first), Tier::Reflexive);
            let retry = CallContext::new("gap_decompose").with_attempt(1);
            assert_eq!(route(&retry), Tier::Neocortex);
        });
    }

    #[test]
    fn routing_decision_is_deterministic() {
        with_tier(Some("auto"), || {
            let ctx = CallContext::new("preflight_reasoning").with_attempt(0);
            let a = route(&ctx);
            let b = route(&ctx);
            assert_eq!(a, b);
        });
    }
}
