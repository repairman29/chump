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

/// `true` when `key` is set and `var.trim() == expected`.
#[inline]
pub fn env_trim_eq(key: &str, expected: &str) -> bool {
    std::env::var(key)
        .map(|v| v.trim() == expected)
        .unwrap_or(false)
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
}
