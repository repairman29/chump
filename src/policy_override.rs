//! Time-boxed relaxations of **CHUMP_TOOLS_ASK** per web session (universal power P3.3).
//! Default off: set **`CHUMP_POLICY_OVERRIDE_API=1`** and use **`POST /api/policy-override`** or the
//! optional **`policy_override`** field on **`POST /api/chat`**. Each tool run skipped via override
//! logs **`tool_approval_audit`** with result **`policy_override_session`**.

use std::collections::HashSet;
use std::future::Future;
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

type SessionMap = std::collections::HashMap<String, ActiveOverride>;

static SESSION_OVERRIDES: LazyLock<Mutex<SessionMap>> =
    LazyLock::new(|| Mutex::new(SessionMap::new()));

#[derive(Clone)]
struct ActiveOverride {
    until_unix: u64,
    relax: HashSet<String>,
}

fn map_lock() -> std::sync::MutexGuard<'static, SessionMap> {
    SESSION_OVERRIDES.lock().expect("policy override map lock")
}

pub fn policy_override_api_enabled() -> bool {
    std::env::var("CHUMP_POLICY_OVERRIDE_API")
        .map(|s| {
            let t = s.trim();
            t == "1" || t.eq_ignore_ascii_case("true") || t.eq_ignore_ascii_case("yes")
        })
        .unwrap_or(false)
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_tools(s: &str) -> HashSet<String> {
    s.split(',')
        .map(|x| x.trim().to_lowercase())
        .filter(|x| !x.is_empty())
        .collect()
}

/// Clamp TTL: min 60s, max 7 days.
pub fn clamp_ttl_secs(ttl: u64) -> u64 {
    ttl.clamp(60, 604_800)
}

/// Register relax tools for a web session until `now + ttl_secs` (clamped).
pub fn register_session_relax(session_id: &str, relax_tools_csv: &str, ttl_secs: u64) {
    let sid = session_id.trim();
    if sid.is_empty() {
        return;
    }
    let relax = parse_tools(relax_tools_csv);
    if relax.is_empty() {
        return;
    }
    let ttl = clamp_ttl_secs(ttl_secs);
    let until = now_unix().saturating_add(ttl);
    let mut m = map_lock();
    m.insert(
        sid.to_string(),
        ActiveOverride {
            until_unix: until,
            relax,
        },
    );
}

/// Snapshot relax set for this session if still valid; prunes expired rows.
pub fn snapshot_relax_for_session(session_id: &str) -> Option<HashSet<String>> {
    let sid = session_id.trim();
    if sid.is_empty() {
        return None;
    }
    let now = now_unix();
    let mut m = map_lock();
    if let Some(entry) = m.get(sid) {
        if entry.until_unix <= now {
            m.remove(sid);
            return None;
        }
        return Some(entry.relax.clone());
    }
    None
}

tokio::task_local! {
    /// Tools (lowercase names) temporarily not requiring approval for this web chat turn.
    static RELAX_TOOLS: Option<HashSet<String>>;
}

/// Run a future with optional per-turn relax set (from [`snapshot_relax_for_session`]).
pub async fn relax_scope<Fut, R>(relax: Option<HashSet<String>>, fut: Fut) -> R
where
    Fut: Future<Output = R>,
{
    RELAX_TOOLS.scope(relax, fut).await
}

/// True when the current task has a relax entry that includes `tool_name`.
/// Returns false when called outside a `relax_scope` (e.g. CLI mode).
pub fn session_relax_active_for_tool(tool_name: &str) -> bool {
    let key = tool_name.trim().to_lowercase();
    RELAX_TOOLS
        .try_with(|opt| opt.as_ref().is_some_and(|set| set.contains(&key)))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_ttl_bounds() {
        assert_eq!(clamp_ttl_secs(0), 60);
        assert_eq!(clamp_ttl_secs(30), 60);
        assert_eq!(clamp_ttl_secs(120), 120);
        assert_eq!(clamp_ttl_secs(999_999_999), 604_800);
    }

    #[test]
    fn register_and_snapshot() {
        let sid = "test-policy-override-session";
        register_session_relax(sid, "run_cli, write_file ", 120);
        let snap = snapshot_relax_for_session(sid).expect("active");
        assert!(snap.contains("run_cli"));
        assert!(snap.contains("write_file"));
        let mut m = map_lock();
        m.remove(sid);
    }
}
