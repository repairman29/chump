//! Heartbeat interrupt policy (W2.2): optionally restrict the `notify` tool so DMs fire only for
//! high-signal interrupts during autonomous heartbeat rounds. System paths (e.g. git auth DM)
//! bypass this filter via `chump_log::set_pending_notify_unfiltered`.

/// When `restrict` (or `1` / `true` / `heartbeat`), user `notify` calls are filtered during heartbeat rounds.
pub fn heartbeat_restrict_enabled() -> bool {
    std::env::var("CHUMP_INTERRUPT_NOTIFY_POLICY")
        .map(|v| {
            matches!(
                v.to_lowercase().as_str(),
                "restrict" | "1" | "true" | "yes" | "heartbeat"
            )
        })
        .unwrap_or(false)
}

fn in_heartbeat_round() -> bool {
    std::env::var("CHUMP_HEARTBEAT_TYPE")
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

/// True if the user `notify` tool may queue a DM in the current process context.
pub fn allow_user_notify(message: &str) -> bool {
    if !heartbeat_restrict_enabled() || !in_heartbeat_round() {
        return true;
    }
    let m = message.to_lowercase();
    let needles: &[&str] = &[
        "[interrupt:",
        "[interrupt]",
        "approval timed out",
        "approval timeout",
        "ship blocked",
        "playbook blocked",
        "circuit open",
        "circuit breaker",
        "circuit is open",
        "[human]",
    ];
    if needles.iter().any(|n| m.contains(n)) {
        return true;
    }
    if let Ok(extra) = std::env::var("CHUMP_NOTIFY_INTERRUPT_EXTRA") {
        for part in extra.split(',') {
            let p = part.trim().to_lowercase();
            if !p.is_empty() && m.contains(&p) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_user_notify_respects_env() {
        std::env::remove_var("CHUMP_INTERRUPT_NOTIFY_POLICY");
        std::env::remove_var("CHUMP_HEARTBEAT_TYPE");
        assert!(allow_user_notify("anything"));

        std::env::set_var("CHUMP_INTERRUPT_NOTIFY_POLICY", "restrict");
        std::env::set_var("CHUMP_HEARTBEAT_TYPE", "work");
        assert!(!allow_user_notify("hello jeff"));
        assert!(allow_user_notify(
            "Blocked: [interrupt:ship_blocked] cannot push"
        ));
        assert!(allow_user_notify("Tool approval timeout — need human"));
        assert!(allow_user_notify("Please review [human]"));

        std::env::set_var("CHUMP_NOTIFY_INTERRUPT_EXTRA", "MAGIC_TOKEN_XYZ");
        assert!(allow_user_notify("prefix MAGIC_TOKEN_XYZ suffix"));

        std::env::remove_var("CHUMP_INTERRUPT_NOTIFY_POLICY");
        std::env::remove_var("CHUMP_HEARTBEAT_TYPE");
        std::env::remove_var("CHUMP_NOTIFY_INTERRUPT_EXTRA");
    }
}
