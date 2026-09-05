//! Unified `Get`/`Set`/`Delete` storage abstraction over SQLite, NATS-KV,
//! and git claim-branch metadata (RESILIENT-103 / EFFECTIVE-178 slice).
//!
//! Chump's lease/claim/unwind machinery persists small key-value records to
//! three different substrates depending on context: `state.db` (SQLite) for
//! the canonical claim table, NATS-KV for cross-machine coordination, and
//! git branch refs for claim-branch metadata that must travel with the
//! worktree. Each substrate previously had its own bespoke get/set/delete
//! call sites; this crate gives them one [`Storage`] trait so callers don't
//! need to know which substrate they're talking to.

use anyhow::Result;
use async_trait::async_trait;
use rusqlite::Connection;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

/// A backend-agnostic key-value store: get, set, delete.
///
/// `delete` returns whether a value was actually removed (`false` if the
/// key was already absent) so callers can distinguish "no-op" from
/// "removed" without a separate `exists` call.
#[async_trait]
pub trait Storage: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    async fn set(&self, key: &str, value: &[u8]) -> Result<()>;
    async fn delete(&self, key: &str) -> Result<bool>;
}

/// SQLite-backed [`Storage`] — mirrors the `state.db` leases/claims table
/// shape, but generalized to an arbitrary key/value table.
pub struct SqliteStorage {
    conn: Mutex<Connection>,
    table: String,
}

impl SqliteStorage {
    /// Open (or create) a SQLite-backed store at `path`, using `table` as
    /// the key-value table name. The table is created if it doesn't exist.
    pub fn open(path: &Path, table: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        Self::from_connection(conn, table)
    }

    /// In-memory SQLite store, primarily for tests.
    pub fn in_memory(table: &str) -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::from_connection(conn, table)
    }

    fn from_connection(conn: Connection, table: &str) -> Result<Self> {
        validate_table_name(table)?;
        conn.execute(
            &format!(
                "CREATE TABLE IF NOT EXISTS {table} (key TEXT PRIMARY KEY, value BLOB NOT NULL)"
            ),
            [],
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
            table: table.to_string(),
        })
    }
}

/// Table names are interpolated into SQL (SQLite doesn't support binding
/// identifiers), so restrict them to a safe charset up front.
fn validate_table_name(table: &str) -> Result<()> {
    let ok = !table.is_empty() && table.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if ok {
        Ok(())
    } else {
        Err(anyhow::anyhow!("invalid storage table name: {table:?}"))
    }
}

#[async_trait]
impl Storage for SqliteStorage {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!("SELECT value FROM {} WHERE key = ?1", self.table))?;
        let mut rows = stmt.query([key])?;
        match rows.next()? {
            Some(row) => Ok(Some(row.get(0)?)),
            None => Ok(None),
        }
    }

    async fn set(&self, key: &str, value: &[u8]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            &format!(
                "INSERT INTO {} (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                self.table
            ),
            rusqlite::params![key, value],
        )?;
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        let deleted = conn.execute(&format!("DELETE FROM {} WHERE key = ?1", self.table), [key])?;
        Ok(deleted > 0)
    }
}

/// Minimal async KV surface a NATS-KV client must provide. Kept separate
/// from `async_nats::jetstream::kv::Store` so the wrapper logic in
/// [`NatsKvStorage`] can be unit-tested with an in-memory fake instead of a
/// live NATS server.
#[async_trait]
pub trait KvClient: Send + Sync {
    async fn kv_get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    async fn kv_put(&self, key: &str, value: Vec<u8>) -> Result<()>;
    async fn kv_delete(&self, key: &str) -> Result<bool>;
}

/// NATS-KV-backed [`Storage`], generic over any [`KvClient`].
pub struct NatsKvStorage<C: KvClient> {
    client: C,
}

impl<C: KvClient> NatsKvStorage<C> {
    pub fn new(client: C) -> Self {
        Self { client }
    }
}

#[async_trait]
impl<C: KvClient> Storage for NatsKvStorage<C> {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        self.client.kv_get(key).await
    }

    async fn set(&self, key: &str, value: &[u8]) -> Result<()> {
        self.client.kv_put(key, value.to_vec()).await
    }

    async fn delete(&self, key: &str) -> Result<bool> {
        self.client.kv_delete(key).await
    }
}

#[cfg(feature = "nats")]
mod nats_impl {
    use super::*;
    use async_nats::jetstream::kv::Store;

    #[async_trait]
    impl KvClient for Store {
        async fn kv_get(&self, key: &str) -> Result<Option<Vec<u8>>> {
            Ok(self
                .get(key)
                .await
                .map_err(|e| anyhow::anyhow!("nats kv get failed: {e}"))?
                .map(|b| b.to_vec()))
        }

        async fn kv_put(&self, key: &str, value: Vec<u8>) -> Result<()> {
            self.put(key, value.into())
                .await
                .map_err(|e| anyhow::anyhow!("nats kv put failed: {e}"))?;
            Ok(())
        }

        async fn kv_delete(&self, key: &str) -> Result<bool> {
            // `Store::delete` doesn't report whether a key existed; treat a
            // successful delete against a present key as `true` via a
            // preceding get. This costs one extra round trip but keeps the
            // `Storage::delete` contract uniform across backends.
            let existed = self.get(key).await.ok().flatten().is_some();
            self.delete(key)
                .await
                .map_err(|e| anyhow::anyhow!("nats kv delete failed: {e}"))?;
            Ok(existed)
        }
    }
}

/// Git-branch-backed [`Storage`] — persists values as blobs referenced by
/// `refs/<namespace>/<key>` in a git repository, mirroring how claim-branch
/// metadata (RESILIENT-103) travels with a worktree without touching the
/// working tree itself.
pub struct GitBranchStorage {
    repo_root: std::path::PathBuf,
    namespace: String,
}

impl GitBranchStorage {
    pub fn new(repo_root: impl Into<std::path::PathBuf>, namespace: impl Into<String>) -> Self {
        Self {
            repo_root: repo_root.into(),
            namespace: namespace.into(),
        }
    }

    fn ref_name(&self, key: &str) -> String {
        format!("refs/{}/{}", self.namespace, key)
    }

    fn run_git(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<std::process::Output> {
        use std::io::Write;
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(&self.repo_root).args(args);
        if stdin.is_some() {
            cmd.stdin(std::process::Stdio::piped());
        }
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn()?;
        if let Some(data) = stdin {
            child
                .stdin
                .take()
                .expect("stdin requested")
                .write_all(data)?;
        }
        Ok(child.wait_with_output()?)
    }
}

#[async_trait]
impl Storage for GitBranchStorage {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let ref_name = self.ref_name(key);
        let rev_parse = self.run_git(&["rev-parse", "--verify", &ref_name], None)?;
        if !rev_parse.status.success() {
            return Ok(None);
        }
        let sha = String::from_utf8_lossy(&rev_parse.stdout)
            .trim()
            .to_string();
        let cat_file = self.run_git(&["cat-file", "-p", &sha], None)?;
        if !cat_file.status.success() {
            return Err(anyhow::anyhow!(
                "git cat-file failed for {ref_name}: {}",
                String::from_utf8_lossy(&cat_file.stderr)
            ));
        }
        Ok(Some(cat_file.stdout))
    }

    async fn set(&self, key: &str, value: &[u8]) -> Result<()> {
        let hash_object = self.run_git(&["hash-object", "-w", "--stdin"], Some(value))?;
        if !hash_object.status.success() {
            return Err(anyhow::anyhow!(
                "git hash-object failed: {}",
                String::from_utf8_lossy(&hash_object.stderr)
            ));
        }
        let sha = String::from_utf8_lossy(&hash_object.stdout)
            .trim()
            .to_string();
        let ref_name = self.ref_name(key);
        let update_ref = self.run_git(&["update-ref", &ref_name, &sha], None)?;
        if !update_ref.status.success() {
            return Err(anyhow::anyhow!(
                "git update-ref failed for {ref_name}: {}",
                String::from_utf8_lossy(&update_ref.stderr)
            ));
        }
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<bool> {
        let ref_name = self.ref_name(key);
        let rev_parse = self.run_git(&["rev-parse", "--verify", &ref_name], None)?;
        if !rev_parse.status.success() {
            return Ok(false);
        }
        let update_ref = self.run_git(&["update-ref", "-d", &ref_name], None)?;
        if !update_ref.status.success() {
            return Err(anyhow::anyhow!(
                "git update-ref -d failed for {ref_name}: {}",
                String::from_utf8_lossy(&update_ref.stderr)
            ));
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex as StdMutex;

    #[tokio::test]
    async fn sqlite_roundtrip() {
        let store = SqliteStorage::in_memory("kv_test").unwrap();
        assert_eq!(store.get("a").await.unwrap(), None);

        store.set("a", b"hello").await.unwrap();
        assert_eq!(store.get("a").await.unwrap(), Some(b"hello".to_vec()));

        store.set("a", b"world").await.unwrap();
        assert_eq!(store.get("a").await.unwrap(), Some(b"world".to_vec()));

        assert!(store.delete("a").await.unwrap());
        assert_eq!(store.get("a").await.unwrap(), None);
        assert!(!store.delete("a").await.unwrap());
    }

    #[tokio::test]
    async fn sqlite_rejects_bad_table_name() {
        assert!(SqliteStorage::in_memory("bad; drop table").is_err());
    }

    struct InMemoryKvClient {
        map: StdMutex<HashMap<String, Vec<u8>>>,
    }

    impl InMemoryKvClient {
        fn new() -> Self {
            Self {
                map: StdMutex::new(HashMap::new()),
            }
        }
    }

    #[async_trait]
    impl KvClient for InMemoryKvClient {
        async fn kv_get(&self, key: &str) -> Result<Option<Vec<u8>>> {
            Ok(self.map.lock().unwrap().get(key).cloned())
        }

        async fn kv_put(&self, key: &str, value: Vec<u8>) -> Result<()> {
            self.map.lock().unwrap().insert(key.to_string(), value);
            Ok(())
        }

        async fn kv_delete(&self, key: &str) -> Result<bool> {
            Ok(self.map.lock().unwrap().remove(key).is_some())
        }
    }

    #[tokio::test]
    async fn nats_kv_roundtrip() {
        let store = NatsKvStorage::new(InMemoryKvClient::new());
        assert_eq!(store.get("a").await.unwrap(), None);

        store.set("a", b"hello").await.unwrap();
        assert_eq!(store.get("a").await.unwrap(), Some(b"hello".to_vec()));

        store.set("a", b"world").await.unwrap();
        assert_eq!(store.get("a").await.unwrap(), Some(b"world".to_vec()));

        assert!(store.delete("a").await.unwrap());
        assert_eq!(store.get("a").await.unwrap(), None);
        assert!(!store.delete("a").await.unwrap());
    }

    fn init_repo(dir: &Path) {
        let status = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["init", "--quiet"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[tokio::test]
    async fn git_branch_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        init_repo(dir.path());
        let store = GitBranchStorage::new(dir.path(), "chump-storage-test");

        assert_eq!(store.get("lease-1").await.unwrap(), None);

        store.set("lease-1", b"claimed-by=session-a").await.unwrap();
        assert_eq!(
            store.get("lease-1").await.unwrap(),
            Some(b"claimed-by=session-a".to_vec())
        );

        store.set("lease-1", b"claimed-by=session-b").await.unwrap();
        assert_eq!(
            store.get("lease-1").await.unwrap(),
            Some(b"claimed-by=session-b".to_vec())
        );

        assert!(store.delete("lease-1").await.unwrap());
        assert_eq!(store.get("lease-1").await.unwrap(), None);
        assert!(!store.delete("lease-1").await.unwrap());
    }

    #[tokio::test]
    async fn git_branch_missing_repo_errors_on_set() {
        let dir = tempfile::tempdir().unwrap();
        // Not a git repo: `set` should surface an error rather than panic.
        let store = GitBranchStorage::new(dir.path(), "chump-storage-test");
        assert!(store.set("k", b"v").await.is_err());
    }
}
