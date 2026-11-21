//! RESILIENT-1736: lease identity + orphan detection.
//!
//! Worker session IDs look like `fleet-<fleet>-agent<N>@<host>-<pid>-<epoch>`
//! (see `scripts/dispatch/worker.sh`). The trailing `-<pid>-<epoch>` is
//! volatile — a restarted tick gets a fresh pid + timestamp — while the
//! leading `fleet-<fleet>-agent<N>@<host>` segment is the stable identity of
//! the worker *slot*. Before this module, lease ownership was compared by
//! exact session-id string equality, so a restarted tick's lease (same
//! slot, new pid) looked indistinguishable from a lease held by a totally
//! unrelated, possibly-dead session: both failed the equality check and sat
//! "live-claimed" until the 16h TTL expired (incident 2026-10-28, 5 orphan
//! rows starved both cuphead workers for ~12h).

/// Split a session id into its stable identity prefix and the pid embedded
/// in it, e.g. `"fleet-ops-agent1@host-3232363-1793185476"` ->
/// `("fleet-ops-agent1@host", 3232363)`. Returns `None` if the session id
/// doesn't match the `<identity>-<pid>-<epoch>` shape (older/foreign session
/// ids are left alone rather than guessed at).
pub fn parse_identity(session_id: &str) -> Option<(&str, u32)> {
    let (rest, epoch) = session_id.rsplit_once('-')?;
    if epoch.is_empty() || !epoch.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let (identity, pid_str) = rest.rsplit_once('-')?;
    if identity.is_empty() {
        return None;
    }
    let pid: u32 = pid_str.parse().ok()?;
    Some((identity, pid))
}

/// Two session ids name the same worker slot (same fleet+agent+host),
/// irrespective of which tick (pid/epoch) wrote them.
pub fn same_identity(a: &str, b: &str) -> bool {
    match (parse_identity(a), parse_identity(b)) {
        (Some((ia, _)), Some((ib, _))) => ia == ib,
        _ => false,
    }
}

/// Check whether a process id is alive on *this* host. `kill(pid, 0)` sends
/// no signal, it only probes existence/permission.
pub fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // SAFETY: kill(pid, 0) is a pure existence probe, no signal delivered.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// A lease session id is orphaned when it parses as a worker session id AND
/// its embedded pid is not alive on this host. Session ids we can't parse
/// (manual claims, older formats, non-worker tooling) are never treated as
/// orphaned here — absence of a signal is not "dead".
pub fn is_orphaned(session_id: &str) -> bool {
    match parse_identity(session_id) {
        Some((_, pid)) => !pid_is_alive(pid),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_identity_and_pid() {
        let (identity, pid) =
            parse_identity("fleet-ops-agent1@cuphead-3232363-1793185476").expect("should parse");
        assert_eq!(identity, "fleet-ops-agent1@cuphead");
        assert_eq!(pid, 3232363);
    }

    #[test]
    fn rejects_malformed_session_id() {
        assert!(parse_identity("not-a-worker-session").is_none());
        assert!(parse_identity("").is_none());
        assert!(parse_identity("agent1-abc-123").is_none());
    }

    #[test]
    fn same_identity_ignores_pid_and_epoch() {
        assert!(same_identity(
            "fleet-ops-agent1@cuphead-111-222",
            "fleet-ops-agent1@cuphead-333-444"
        ));
        assert!(!same_identity(
            "fleet-ops-agent1@cuphead-111-222",
            "fleet-ops-agent2@cuphead-111-222"
        ));
    }

    #[test]
    fn own_pid_is_alive() {
        let my_pid = std::process::id();
        assert!(pid_is_alive(my_pid));
    }

    #[test]
    fn pid_zero_is_never_alive() {
        assert!(!pid_is_alive(0));
    }

    #[test]
    fn improbable_pid_is_dead() {
        // Linux PIDs top out well under this; a session id carrying it is
        // from a process that cannot currently exist on this host.
        assert!(!pid_is_alive(u32::MAX - 1));
    }

    #[test]
    fn is_orphaned_true_for_dead_pid_session() {
        assert!(is_orphaned("fleet-ops-agent1@cuphead-999999999-1793185476"));
    }

    #[test]
    fn is_orphaned_false_for_live_pid_session() {
        let my_pid = std::process::id();
        let sess = format!("fleet-ops-agent1@cuphead-{my_pid}-1793185476");
        assert!(!is_orphaned(&sess));
    }

    #[test]
    fn is_orphaned_false_for_unparseable_session() {
        assert!(!is_orphaned("manual-interactive-session"));
    }
}
