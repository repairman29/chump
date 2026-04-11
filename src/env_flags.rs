//! Trimmed string comparison for common `CHUMP_*` boolean env vars.

/// Swarm / multi-node routing. **`CHUMP_CLUSTER_MODE` unset, empty, or not exactly `1` ⇒ off (local M4 path).**
/// When `false`, orchestrator ignores `CHUMP_WORKER_API_BASE` and `CHUMP_DELEGATE` for routing;
/// see [`crate::cluster_mesh`]. When `true`, [`crate::task_executor::SwarmExecutor`] is selected
/// (today: log + same local pipeline until network fan-out exists).
#[inline]
pub fn chump_cluster_mode() -> bool {
    env_trim_eq("CHUMP_CLUSTER_MODE", "1")
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
    fn env_trim_eq_unset_and_trimmed() {
        let key = "CHUMP_ENV_FLAGS_TEST_9f3a2b1c";
        std::env::remove_var(key);
        assert!(!env_trim_eq(key, "1"));
        std::env::set_var(key, "  1  ");
        assert!(env_trim_eq(key, "1"));
        std::env::remove_var(key);
    }
}
