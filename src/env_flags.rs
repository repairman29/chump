//! Trimmed string comparison for common `CHUMP_*` boolean env vars.

/// `true` when **`CHUMP_INFERENCE_BACKEND=mistralrs`** and **`CHUMP_MISTRALRS_MODEL`** is non-empty.
/// Env-only: does not check that the binary was built with `--features mistralrs-infer`.
/// Used for health/stack-status so UIs do not treat a dead HTTP `/models` probe as “no model” when chat uses in-process mistral.rs.
#[inline]
pub fn chump_inference_backend_mistralrs_env() -> bool {
    std::env::var("CHUMP_INFERENCE_BACKEND")
        .map(|v| v.eq_ignore_ascii_case("mistralrs"))
        .unwrap_or(false)
        && std::env::var("CHUMP_MISTRALRS_MODEL")
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
}

/// **Air-gap posture:** when `true`, outbound general-Internet agent tools (`web_search`, `read_url`)
/// are not registered. See `docs/HIGH_ASSURANCE_AGENT_PHASES.md` §18.
/// **`CHUMP_AIR_GAP_MODE=1`** or **`true`** (case-insensitive) enables; unset or other values ⇒ off.
#[inline]
pub fn chump_air_gap_mode() -> bool {
    std::env::var("CHUMP_AIR_GAP_MODE")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Swarm / multi-node routing. **`CHUMP_CLUSTER_MODE` unset, empty, or not exactly `1` ⇒ off (local M4 path).**
/// When `false`, orchestrator ignores `CHUMP_WORKER_API_BASE` and `CHUMP_DELEGATE` for routing;
/// see [`crate::cluster_mesh`]. When `true`, [`crate::task_executor::SwarmExecutor`] is selected
/// (today: log + same local pipeline until network fan-out exists).
#[inline]
pub fn chump_cluster_mode() -> bool {
    env_trim_eq("CHUMP_CLUSTER_MODE", "1")
}

/// When **`1`** or **`true`**, [`crate::precision_controller::recommended_max_tool_calls`] tightens
/// under high **task epistemic uncertainty** (WP-6.1 hook; see `METRICS.md` / `belief_state`).
#[inline]
pub fn chump_belief_tool_budget() -> bool {
    std::env::var("CHUMP_BELIEF_TOOL_BUDGET")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// When **`1`** or **`true`**, the web API router gets `tower_http::trace::TraceLayer` (HTTP request spans on `/api/*` only; static file fallback is separate).
/// Off by default to avoid noisy logs; enable when debugging HTTP or correlating with `RUST_LOG`.
#[inline]
pub fn chump_web_http_trace() -> bool {
    std::env::var("CHUMP_WEB_HTTP_TRACE")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// **Interactive speed:** controls context/tool scaling for web PWA / CLI chat.
///
/// Values:
/// - **`1`** / **`true`**: always slim (12 tools, minimal context).
/// - **`auto`**: dynamic — starts slim, scales to full when precision regime is
///   Explore or Conservative (high surprisal) or when the user message contains
///   action keywords. Scales back to slim when regime returns to Exploit/Balanced.
/// - **`0`** / **`false`** / unset: always full context.
///
/// When active, [`crate::context_assembly::assemble_context`] skips expensive blocks:
/// per-turn `git diff`, file-watch drain, consciousness injections, Ask-Jeff,
/// episode/schedule extras; omits ego state and brain autoload by default;
/// skips cost/epoch lines; tightens COS weekly truncation.
/// Opt-in: **`CHUMP_LIGHT_INCLUDE_STATE_DB`**, **`CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD`**.
/// Heartbeat rounds (work/research/…) are unchanged.
#[inline]
pub fn chump_light_context() -> bool {
    match std::env::var("CHUMP_LIGHT_CONTEXT") {
        Ok(v) => {
            let t = v.trim();
            if t.eq_ignore_ascii_case("auto") {
                return chump_light_context_auto();
            }
            t == "1" || t.eq_ignore_ascii_case("true")
        }
        Err(_) => false,
    }
}

/// `auto` mode: slim when precision regime is Exploit or Balanced (low surprisal,
/// predictable environment). Full context when Explore or Conservative (high surprisal,
/// the agent needs more tools to handle uncertainty).
fn chump_light_context_auto() -> bool {
    use crate::precision_controller::{current_regime, PrecisionRegime};
    let regime = current_regime();
    let slim = matches!(regime, PrecisionRegime::Exploit | PrecisionRegime::Balanced);
    tracing::debug!(regime = ?regime, slim, "auto-scale context");
    slim
}

/// Current context scaling mode for telemetry/API.
/// Returns `("always_slim", true)`, `("always_full", false)`, or `("auto", <current>)`.
pub fn context_scale_status() -> (&'static str, bool) {
    match std::env::var("CHUMP_LIGHT_CONTEXT") {
        Ok(v) => {
            let t = v.trim();
            if t.eq_ignore_ascii_case("auto") {
                ("auto", chump_light_context_auto())
            } else if t == "1" || t.eq_ignore_ascii_case("true") {
                ("always_slim", true)
            } else {
                ("always_full", false)
            }
        }
        Err(_) => ("always_full", false),
    }
}

fn heartbeat_type_empty_for_interactive() -> bool {
    std::env::var("CHUMP_HEARTBEAT_TYPE")
        .map(|s| s.trim().is_empty())
        .unwrap_or(true)
}

/// True when light context is active for an interactive (non-heartbeat) turn.
/// With `CHUMP_LIGHT_CONTEXT=auto`, this varies per-turn based on precision regime.
#[inline]
pub fn light_interactive_active() -> bool {
    chump_light_context() && heartbeat_type_empty_for_interactive()
}

/// Ego / mood lines from state DB in [`crate::context_assembly::assemble_context`] during light interactive.
/// Default **false** (smaller prompt); set **`CHUMP_LIGHT_INCLUDE_STATE_DB=1`** to keep them.
#[inline]
pub fn chump_light_include_state_db() -> bool {
    std::env::var("CHUMP_LIGHT_INCLUDE_STATE_DB")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// **`CHUMP_BRAIN_AUTOLOAD`** injection during light interactive. Default **false** (skip autoload for speed);
/// set **`CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD=1`** to keep brain file snippets in the prompt.
#[inline]
pub fn chump_light_include_brain_autoload() -> bool {
    std::env::var("CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Sliding-window cap for user/assistant messages when light interactive and **`CHUMP_MAX_CONTEXT_MESSAGES`** is unset.
#[inline]
pub fn light_chat_history_message_cap() -> usize {
    std::env::var("CHUMP_LIGHT_CHAT_HISTORY_MESSAGES")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(16)
        .clamp(4, 64)
}

/// System-2 `<plan>` / `<thinking>` mandate in the system prompt (see `discord.rs` primacy block).
///
/// Explicit **`CHUMP_THINKING_XML`**: `0` / `false` / `off` ⇒ off; `1` / `true` ⇒ on; other non-empty ⇒ on.
/// **Unset or empty**: off when [`light_interactive_active`] (faster local / PWA chat), otherwise on (heartbeat & agents).
#[inline]
pub fn thinking_xml_mandate_for_prompt() -> bool {
    match std::env::var("CHUMP_THINKING_XML") {
        Ok(v) => {
            let t = v.trim();
            if t.is_empty() {
                return !light_interactive_active();
            }
            if t == "0" || t.eq_ignore_ascii_case("false") || t.eq_ignore_ascii_case("off") {
                return false;
            }
            if t == "1" || t.eq_ignore_ascii_case("true") {
                return true;
            }
            true
        }
        Err(_) => !light_interactive_active(),
    }
}

/// `max_tokens` passed to each model completion when non-`None` (shorter decode on local MLX/vLLM).
///
/// Precedence: **`CHUMP_COMPLETION_MAX_TOKENS`** (if set and ≥ 64) wins. Else when
/// [`chump_light_context`] is on and **`CHUMP_HEARTBEAT_TYPE`** is empty, uses
/// **`CHUMP_LIGHT_COMPLETION_MAX_TOKENS`** or **1024** (clamped 256–8192). Otherwise **`None`**
/// (server default, often large).
#[inline]
pub fn agent_completion_max_tokens() -> Option<u32> {
    if let Ok(v) = std::env::var("CHUMP_COMPLETION_MAX_TOKENS") {
        if let Ok(n) = v.trim().parse::<u32>() {
            if n >= 64 {
                return Some(n.min(32768));
            }
        }
    }
    if light_interactive_active() {
        let n: u32 = std::env::var("CHUMP_LIGHT_COMPLETION_MAX_TOKENS")
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(1024);
        return Some(n.clamp(256, 8192));
    }
    None
}

/// EVAL-032: Perception layer ablation gate.
///
/// When **`CHUMP_BYPASS_PERCEPTION=1`** (or `true`), the prompt assembler skips injecting the
/// perception summary (`[Perception] Task: … | Entities: … | …`) into the system prompt.
/// All other prompt blocks (spawn lessons, task planner, COG-016 lessons, blackboard) are
/// unaffected. Use this flag to isolate the perception contribution in A/B harness sweeps.
///
/// Default: **off** (perception summary injected as normal).
#[inline]
pub fn chump_bypass_perception() -> bool {
    std::env::var("CHUMP_BYPASS_PERCEPTION")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// EVAL-043: Surprisal EMA ablation gate.
///
/// When **`CHUMP_BYPASS_SURPRISAL=1`** (or `true`), `surprise_tracker::record_prediction`
/// becomes a no-op: the EMA is not updated, Welford variance is not tracked, and no
/// blackboard events are posted. `current_surprisal_ema()` returns `0.0` (fully predictable
/// baseline). Use this flag to isolate the surprisal EMA contribution in A/B harness sweeps
/// (EVAL-043 ablation suite).
///
/// Default: **off** (surprisal EMA updated as normal).
#[inline]
pub fn chump_bypass_surprisal() -> bool {
    std::env::var("CHUMP_BYPASS_SURPRISAL")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// EVAL-043: Neuromodulation ablation gate (alias for `CHUMP_NEUROMOD_ENABLED=0`).
///
/// When **`CHUMP_BYPASS_NEUROMOD=1`** (or `true`), neuromodulator updates are skipped
/// and all modulators stay at their baseline (1.0/1.0/1.0). This is equivalent to
/// `CHUMP_NEUROMOD_ENABLED=0` but follows the consistent `CHUMP_BYPASS_*` naming
/// used by the EVAL-043 ablation suite. `CHUMP_BYPASS_NEUROMOD` takes precedence when set;
/// `CHUMP_NEUROMOD_ENABLED=0` is the legacy COG-006 gate and still works independently.
///
/// Default: **off** (neuromod updates active, subject to `CHUMP_NEUROMOD_ENABLED`).
#[inline]
pub fn chump_bypass_neuromod() -> bool {
    std::env::var("CHUMP_BYPASS_NEUROMOD")
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// `true` when `key` is set and `var.trim() == expected`.
#[inline]
pub fn env_trim_eq(key: &str, expected: &str) -> bool {
    std::env::var(key)
        .map(|v| v.trim() == expected)
        .unwrap_or(false)
}

/// Tool surface tier from **`CHUMP_TOOL_PROFILE`** (`core`, `coding`, `full`). Unset or unknown ⇒ **`core`**.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChumpToolProfile {
    Core,
    Coding,
    Full,
}

#[inline]
pub fn chump_tool_profile() -> ChumpToolProfile {
    match std::env::var("CHUMP_TOOL_PROFILE") {
        Ok(v) => {
            let t = v.trim().to_ascii_lowercase();
            match t.as_str() {
                "coding" => ChumpToolProfile::Coding,
                "full" => ChumpToolProfile::Full,
                _ => ChumpToolProfile::Core,
            }
        }
        Err(_) => ChumpToolProfile::Core,
    }
}

#[cfg(test)]
mod tests {
    use super::env_trim_eq;
    use serial_test::serial;

    #[test]
    #[serial]
    fn chump_air_gap_mode_values() {
        let key = "CHUMP_AIR_GAP_MODE";
        std::env::remove_var(key);
        assert!(!super::chump_air_gap_mode());
        std::env::set_var(key, "1");
        assert!(super::chump_air_gap_mode());
        std::env::set_var(key, "  true  ");
        assert!(super::chump_air_gap_mode());
        std::env::set_var(key, "0");
        assert!(!super::chump_air_gap_mode());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_cluster_mode_unset() {
        let key = "CHUMP_CLUSTER_MODE";
        std::env::remove_var(key);
        assert!(!super::chump_cluster_mode());
        std::env::set_var(key, "  1  ");
        assert!(super::chump_cluster_mode());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_web_http_trace_values() {
        let key = "CHUMP_WEB_HTTP_TRACE";
        std::env::remove_var(key);
        assert!(!super::chump_web_http_trace());
        std::env::set_var(key, "1");
        assert!(super::chump_web_http_trace());
        std::env::set_var(key, "true");
        assert!(super::chump_web_http_trace());
        std::env::set_var(key, "0");
        assert!(!super::chump_web_http_trace());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn env_trim_eq_unset_and_trimmed() {
        let key = "CHUMP_ENV_FLAGS_TEST_9f3a2b1c";
        std::env::remove_var(key);
        assert!(!env_trim_eq(key, "1"));
        std::env::set_var(key, "  1  ");
        assert!(env_trim_eq(key, "1"));
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_light_context_values() {
        let key = "CHUMP_LIGHT_CONTEXT";
        std::env::remove_var(key);
        assert!(!super::chump_light_context());
        std::env::set_var(key, "1");
        assert!(super::chump_light_context());
        std::env::set_var(key, "true");
        assert!(super::chump_light_context());
        std::env::set_var(key, "0");
        assert!(!super::chump_light_context());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_light_context_auto_mode() {
        let key = "CHUMP_LIGHT_CONTEXT";
        std::env::set_var(key, "auto");
        // auto mode delegates to precision regime; result depends on surprisal state
        // but must not panic and must return a bool
        let result = super::chump_light_context();
        std::hint::black_box(result); // must not panic; value depends on surprisal state
        std::env::set_var(key, "AUTO");
        let _ = super::chump_light_context(); // case insensitive, no panic
                                              // Verify auto is not treated as static true/false
        std::env::set_var(key, "0");
        assert!(!super::chump_light_context()); // explicit off still works
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn context_scale_status_modes() {
        let key = "CHUMP_LIGHT_CONTEXT";
        std::env::remove_var(key);
        let (mode, _slim) = super::context_scale_status();
        assert_eq!(mode, "always_full");

        std::env::set_var(key, "1");
        let (mode, slim) = super::context_scale_status();
        assert_eq!(mode, "always_slim");
        assert!(slim);

        std::env::set_var(key, "auto");
        let (mode, _) = super::context_scale_status();
        assert_eq!(mode, "auto");

        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn agent_completion_max_tokens_light_default() {
        let k_light = "CHUMP_LIGHT_CONTEXT";
        let k_cap = "CHUMP_COMPLETION_MAX_TOKENS";
        let k_light_cap = "CHUMP_LIGHT_COMPLETION_MAX_TOKENS";
        let k_hb = "CHUMP_HEARTBEAT_TYPE";
        for k in [k_light, k_cap, k_light_cap, k_hb] {
            std::env::remove_var(k);
        }
        assert_eq!(super::agent_completion_max_tokens(), None);

        std::env::set_var(k_light, "1");
        assert_eq!(super::agent_completion_max_tokens(), Some(1024));

        std::env::set_var(k_light_cap, "2048");
        assert_eq!(super::agent_completion_max_tokens(), Some(2048));
        std::env::remove_var(k_light_cap);

        std::env::set_var(k_hb, "work");
        assert_eq!(super::agent_completion_max_tokens(), None);
        std::env::remove_var(k_hb);

        std::env::set_var(k_cap, "4096");
        assert_eq!(super::agent_completion_max_tokens(), Some(4096));
        std::env::remove_var(k_cap);

        std::env::remove_var(k_light);
    }

    #[test]
    #[serial]
    fn thinking_xml_mandate_respects_light_interactive() {
        let k_think = "CHUMP_THINKING_XML";
        let k_light = "CHUMP_LIGHT_CONTEXT";
        let k_hb = "CHUMP_HEARTBEAT_TYPE";
        for k in [k_think, k_light, k_hb] {
            std::env::remove_var(k);
        }
        assert!(super::thinking_xml_mandate_for_prompt());

        std::env::set_var(k_light, "1");
        assert!(!super::thinking_xml_mandate_for_prompt());

        std::env::set_var(k_think, "1");
        assert!(super::thinking_xml_mandate_for_prompt());
        std::env::remove_var(k_think);

        std::env::set_var(k_hb, "work");
        assert!(super::thinking_xml_mandate_for_prompt());

        std::env::remove_var(k_hb);
        std::env::remove_var(k_light);
    }

    #[test]
    #[serial]
    fn light_chat_history_message_cap_clamped() {
        let k = "CHUMP_LIGHT_CHAT_HISTORY_MESSAGES";
        std::env::remove_var(k);
        assert_eq!(super::light_chat_history_message_cap(), 16);
        std::env::set_var(k, "3");
        assert_eq!(super::light_chat_history_message_cap(), 4);
        std::env::set_var(k, "99");
        assert_eq!(super::light_chat_history_message_cap(), 64);
        std::env::remove_var(k);
    }

    #[test]
    #[serial]
    fn chump_bypass_perception_values() {
        let key = "CHUMP_BYPASS_PERCEPTION";
        std::env::remove_var(key);
        assert!(!super::chump_bypass_perception(), "default must be off");
        std::env::set_var(key, "1");
        assert!(super::chump_bypass_perception());
        std::env::set_var(key, "true");
        assert!(super::chump_bypass_perception());
        std::env::set_var(key, "TRUE");
        assert!(super::chump_bypass_perception());
        std::env::set_var(key, "0");
        assert!(!super::chump_bypass_perception());
        std::env::set_var(key, "false");
        assert!(!super::chump_bypass_perception());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_bypass_surprisal_values() {
        let key = "CHUMP_BYPASS_SURPRISAL";
        std::env::remove_var(key);
        assert!(!super::chump_bypass_surprisal(), "default must be off");
        std::env::set_var(key, "1");
        assert!(super::chump_bypass_surprisal());
        std::env::set_var(key, "true");
        assert!(super::chump_bypass_surprisal());
        std::env::set_var(key, "TRUE");
        assert!(super::chump_bypass_surprisal());
        std::env::set_var(key, "0");
        assert!(!super::chump_bypass_surprisal());
        std::env::set_var(key, "false");
        assert!(!super::chump_bypass_surprisal());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn chump_bypass_neuromod_values() {
        let key = "CHUMP_BYPASS_NEUROMOD";
        std::env::remove_var(key);
        assert!(!super::chump_bypass_neuromod(), "default must be off");
        std::env::set_var(key, "1");
        assert!(super::chump_bypass_neuromod());
        std::env::set_var(key, "true");
        assert!(super::chump_bypass_neuromod());
        std::env::set_var(key, "0");
        assert!(!super::chump_bypass_neuromod());
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn env_flags_defaults_light_air_gap_tool_profile() {
        let k_light = "CHUMP_LIGHT_CONTEXT";
        let k_gap = "CHUMP_AIR_GAP_MODE";
        let k_profile = "CHUMP_TOOL_PROFILE";
        for k in [k_light, k_gap, k_profile] {
            std::env::remove_var(k);
        }
        assert!(!super::chump_light_context());
        assert!(!super::chump_air_gap_mode());
        assert_eq!(super::chump_tool_profile(), super::ChumpToolProfile::Core);

        std::env::set_var(k_profile, "full");
        assert_eq!(super::chump_tool_profile(), super::ChumpToolProfile::Full);
        std::env::set_var(k_profile, "coding");
        assert_eq!(super::chump_tool_profile(), super::ChumpToolProfile::Coding);
        std::env::set_var(k_profile, "unknown_value");
        assert_eq!(super::chump_tool_profile(), super::ChumpToolProfile::Core);

        std::env::remove_var(k_profile);
    }
}
