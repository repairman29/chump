//! Per-tool auto-approve policy persistence (INFRA-1340, PRODUCT-109 follow-up).
//!
//! Operators set a TTL'd auto-approve policy per tool from the PWA approval UI:
//! `15min` / `1h` / `session`. The choice is persisted to `.chump/tool-policies.json`
//! keyed by `{tool_name, scope}`. Each row carries an `expires_at_unix` timestamp.
//!
//! File schema:
//! ```json
//! {
//!   "version": 1,
//!   "policies": [
//!     {
//!       "tool_name": "run_cli",
//!       "scope": "15min",
//!       "expires_at_unix": 1779498614,
//!       "created_at_unix": 1779497714,
//!       "created_by": "operator"
//!     }
//!   ]
//! }
//! ```
//!
//! Lookup is by tool_name (lowercased); the longest-living unexpired policy
//! wins when multiple rows exist for the same tool. Expired rows are pruned
//! lazily on read.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// One persisted auto-approve policy row.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PolicyEntry {
    pub tool_name: String,
    /// Operator-visible label: `"15min"`, `"1h"`, `"session"` (free-form; we also store
    /// arbitrary labels for forwards-compat with PWA versions).
    pub scope: String,
    pub expires_at_unix: u64,
    #[serde(default)]
    pub created_at_unix: u64,
    #[serde(default)]
    pub created_by: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
struct PoliciesFile {
    #[serde(default = "default_version")]
    version: u32,
    #[serde(default)]
    policies: Vec<PolicyEntry>,
}

fn default_version() -> u32 {
    1
}

/// Snapshot of the active policy that gates a tool call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivePolicy {
    pub tool_name: String,
    pub scope: String,
    pub expires_at_unix: u64,
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Resolve `.chump/tool-policies.json` honouring `CHUMP_TOOL_POLICY_FILE` override
/// (used by tests) and `CHUMP_HOME` / `CHUMP_REPO` for the base directory.
pub fn policy_file_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_TOOL_POLICY_FILE") {
        let trimmed = p.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    crate::repo_path::runtime_base()
        .join(".chump")
        .join("tool-policies.json")
}

static FILE_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn read_file() -> PoliciesFile {
    let path = policy_file_path();
    let Ok(bytes) = fs::read(&path) else {
        return PoliciesFile::default();
    };
    serde_json::from_slice::<PoliciesFile>(&bytes).unwrap_or_default()
}

fn write_file(file: &PoliciesFile) -> std::io::Result<()> {
    let path = policy_file_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(file).unwrap_or_else(|_| b"{}".to_vec());
    // Atomic write: tmp + rename.
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, &bytes)?;
    fs::rename(&tmp, &path)
}

/// Insert/replace a policy for `tool_name`+`scope`. Returns the resulting entry
/// (with normalised `expires_at_unix`).
///
/// `ttl_secs` is clamped to [60, 7*24*3600]. `scope == "session"` uses the upper
/// bound (7 days) when `ttl_secs == 0`.
pub fn upsert_policy(
    tool_name: &str,
    scope: &str,
    ttl_secs: u64,
    created_by: Option<&str>,
) -> PolicyEntry {
    let _guard = FILE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut file = read_file();
    let tool_l = tool_name.trim().to_lowercase();
    let scope_n = scope.trim().to_lowercase();
    let now = now_unix();
    let ttl = if ttl_secs == 0 {
        7 * 24 * 3600
    } else {
        ttl_secs
    };
    let ttl = ttl.clamp(60, 7 * 24 * 3600);
    let entry = PolicyEntry {
        tool_name: tool_l.clone(),
        scope: scope_n.clone(),
        expires_at_unix: now.saturating_add(ttl),
        created_at_unix: now,
        created_by: created_by.map(|s| s.to_string()),
    };
    // Replace any existing row with the same (tool, scope); drop expired.
    file.policies.retain(|p| {
        p.expires_at_unix > now
            && !(p.tool_name.eq_ignore_ascii_case(&tool_l)
                && p.scope.eq_ignore_ascii_case(&scope_n))
    });
    file.policies.push(entry.clone());
    file.version = 1;
    let _ = write_file(&file);
    entry
}

/// Remove all policies for `tool_name` (any scope). Returns the number deleted.
pub fn remove_tool(tool_name: &str) -> usize {
    let _guard = FILE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut file = read_file();
    let tool_l = tool_name.trim().to_lowercase();
    let before = file.policies.len();
    file.policies
        .retain(|p| !p.tool_name.eq_ignore_ascii_case(&tool_l));
    let removed = before - file.policies.len();
    if removed > 0 {
        let _ = write_file(&file);
    }
    removed
}

/// All active (non-expired) policies, freshest first.
pub fn list_active() -> Vec<PolicyEntry> {
    let _guard = FILE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut file = read_file();
    let now = now_unix();
    let before = file.policies.len();
    file.policies.retain(|p| p.expires_at_unix > now);
    if file.policies.len() != before {
        // Persist pruning lazily.
        let _ = write_file(&file);
    }
    file.policies
        .sort_by_key(|p| std::cmp::Reverse(p.expires_at_unix));
    file.policies
}

/// Return the longest-living active policy for `tool_name`, if any.
pub fn active_policy(tool_name: &str) -> Option<ActivePolicy> {
    let tool_l = tool_name.trim().to_lowercase();
    let now = now_unix();
    list_active()
        .into_iter()
        .filter(|p| p.tool_name == tool_l && p.expires_at_unix > now)
        .max_by_key(|p| p.expires_at_unix)
        .map(|p| ActivePolicy {
            tool_name: p.tool_name,
            scope: p.scope,
            expires_at_unix: p.expires_at_unix,
        })
}

/// Summary for `/api/stack-status`: `{tool_name: scope}` for fast PWA rendering.
pub fn active_summary() -> HashMap<String, String> {
    let mut out: HashMap<String, String> = HashMap::new();
    for p in list_active() {
        out.entry(p.tool_name.clone()).or_insert(p.scope.clone());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_env() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        std::env::set_var(
            "CHUMP_TOOL_POLICY_FILE",
            dir.path().join("tool-policies.json"),
        );
        dir
    }

    #[test]
    #[serial_test::serial]
    fn upsert_then_active_policy() {
        let _d = isolated_env();
        let _ = upsert_policy("run_cli", "15min", 900, Some("test"));
        let ap = active_policy("RUN_CLI").expect("active");
        assert_eq!(ap.tool_name, "run_cli");
        assert_eq!(ap.scope, "15min");
        assert!(ap.expires_at_unix > now_unix());
    }

    #[test]
    #[serial_test::serial]
    fn upsert_replaces_same_scope_extends_expiry() {
        let _d = isolated_env();
        let a = upsert_policy("write_file", "15min", 60, None);
        let b = upsert_policy("write_file", "15min", 3600, None);
        assert!(b.expires_at_unix >= a.expires_at_unix);
        let listed = list_active();
        // Only one row per (tool, scope) pair.
        let n = listed
            .iter()
            .filter(|p| p.tool_name == "write_file" && p.scope == "15min")
            .count();
        assert_eq!(n, 1, "duplicate (tool, scope) row");
    }

    #[test]
    #[serial_test::serial]
    fn remove_tool_clears_all_scopes() {
        let _d = isolated_env();
        upsert_policy("bash", "15min", 900, None);
        upsert_policy("bash", "1h", 3600, None);
        let removed = remove_tool("bash");
        assert_eq!(removed, 2);
        assert!(active_policy("bash").is_none());
    }

    #[test]
    #[serial_test::serial]
    fn expired_policy_returns_none() {
        let _d = isolated_env();
        // Write directly to bypass clamp, then re-read.
        let path = policy_file_path();
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).unwrap();
        }
        let stale = PoliciesFile {
            version: 1,
            policies: vec![PolicyEntry {
                tool_name: "run_cli".into(),
                scope: "15min".into(),
                expires_at_unix: 1, // ancient
                created_at_unix: 1,
                created_by: None,
            }],
        };
        fs::write(&path, serde_json::to_vec(&stale).unwrap()).unwrap();
        assert!(active_policy("run_cli").is_none());
    }

    #[test]
    #[serial_test::serial]
    fn ttl_clamped_lower_bound() {
        let _d = isolated_env();
        let e = upsert_policy("calc", "burst", 1, None);
        // 60s minimum.
        assert!(e.expires_at_unix >= now_unix() + 60 - 1);
        assert!(e.expires_at_unix <= now_unix() + 60 + 5);
    }

    // AC6 integration: configure auto-approve for bash for 15 min → assert
    // fires without UI interaction; after policy expiry → assert manual
    // approval required again.
    //
    // The approval gate in task_executor.rs consults
    // policy_store::active_policy() at the moment of tool dispatch — that's
    // the exact predicate we exercise here.
    #[test]
    #[serial_test::serial]
    fn ac6_15min_policy_fires_then_expires() {
        let _d = isolated_env();

        // (a) configure auto-approve for bash for 15 min.
        let e = upsert_policy("bash", "15min", 900, Some("ac6"));
        let active = active_policy("bash").expect("active immediately after upsert");
        assert_eq!(active.scope, "15min");
        assert!(e.expires_at_unix > now_unix());

        // (b) clock-inject expiry: rewrite the row with expires_at_unix in the past.
        let path = policy_file_path();
        let mut file = read_file();
        for p in file.policies.iter_mut() {
            if p.tool_name == "bash" {
                p.expires_at_unix = now_unix().saturating_sub(1);
            }
        }
        fs::write(&path, serde_json::to_vec(&file).unwrap()).unwrap();

        // After clock-injected expiry, no active policy → caller must wait.
        assert!(
            active_policy("bash").is_none(),
            "expired policy must not match"
        );
    }
}
