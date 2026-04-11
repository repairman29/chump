//! Trimmed string comparison for common `CHUMP_*` boolean env vars.

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

    #[test]
    fn env_trim_eq_unset_and_trimmed() {
        let key = "CHUMP_ENV_FLAGS_TEST_9f3a2b1c";
        std::env::remove_var(key);
        assert!(!env_trim_eq(key, "1"));
        std::env::set_var(key, "  1  ");
        assert!(env_trim_eq(key, "1"));
        std::env::remove_var(key);
    }
}
