//! Persistent task queue (open → in_progress → blocked → done). Same DB file as chump_memory.

use anyhow::Result;
use std::fmt::Write as _;
#[cfg(test)]
use std::path::PathBuf;

#[allow(dead_code)]
const DB_FILENAME: &str = "sessions/chump_memory.db";

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
fn open_db() -> Result<rusqlite::Connection> {
    let path = std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(DB_FILENAME);
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = rusqlite::Connection::open(&path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            repo TEXT, issue_number INTEGER, status TEXT DEFAULT 'open',
            notes TEXT, priority INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT
        );",
    )?;
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN priority INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN assignee TEXT DEFAULT 'chump'",
        [],
    );
    // Lease fields (best-effort migration; ignore if already present).
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_owner TEXT", []);
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_token TEXT", []);
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN lease_expires_at INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_group_id TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_step INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN depends_on TEXT DEFAULT '[]'",
        [],
    );
    Ok(conn)
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

fn parse_iso_secs(ts: &str) -> Option<u64> {
    let t = ts.trim();
    if t.is_empty() {
        return None;
    }
    let secs_part = t.split('.').next().unwrap_or(t).trim();
    secs_part.parse::<u64>().ok()
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct TaskRow {
    pub id: i64,
    pub title: String,
    pub repo: Option<String>,
    pub issue_number: Option<i64>,
    pub status: String,
    pub notes: Option<String>,
    pub priority: i64,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
    pub assignee: Option<String>,
    pub lease_owner: Option<String>,
    pub lease_token: Option<String>,
    pub lease_expires_at: Option<i64>,
    /// JSON array of task IDs this task depends on, e.g. `"[3, 5]"`.
    pub depends_on: Option<String>,
}

pub fn task_create(
    title: &str,
    repo: Option<&str>,
    issue_number: Option<i64>,
    priority: Option<i64>,
    assignee: Option<&str>,
    notes: Option<&str>,
) -> Result<i64> {
    task_create_with_deps(title, repo, issue_number, priority, assignee, notes, None)
}

/// Create a task with optional dependency list.
pub fn task_create_with_deps(
    title: &str,
    repo: Option<&str>,
    issue_number: Option<i64>,
    priority: Option<i64>,
    assignee: Option<&str>,
    notes: Option<&str>,
    depends_on: Option<&[i64]>,
) -> Result<i64> {
    let conn = open_db()?;
    let now = now_iso();
    let pri = priority.unwrap_or(0);
    let assignee_val = assignee
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or("chump");
    let deps_json = match depends_on {
        Some(ids) if !ids.is_empty() => serde_json::to_string(ids)?,
        _ => "[]".to_string(),
    };
    conn.execute(
        "INSERT INTO chump_tasks (title, repo, issue_number, status, priority, assignee, notes, created_at, updated_at, depends_on) VALUES (?1, ?2, ?3, 'open', ?4, ?5, ?6, ?7, ?7, ?8)",
        rusqlite::params![
            title,
            repo.unwrap_or(""),
            issue_number.unwrap_or(0),
            pri,
            assignee_val,
            notes.unwrap_or(""),
            now,
            deps_json
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

const TASK_SELECT: &str =
    "SELECT id, title, repo, issue_number, status, notes, priority, created_at, updated_at, assignee, lease_owner, lease_token, lease_expires_at, depends_on FROM chump_tasks";
const TASK_ORDER: &str = " ORDER BY priority DESC, id ASC";

fn row_from_query(r: &rusqlite::Row) -> Result<TaskRow, rusqlite::Error> {
    Ok(TaskRow {
        id: r.get(0)?,
        title: r.get(1)?,
        repo: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        issue_number: r.get::<_, Option<i64>>(3)?.filter(|&n| n != 0),
        status: r.get(4)?,
        notes: r.get(5)?,
        priority: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
        assignee: r
            .get::<_, Option<String>>(9)
            .ok()
            .flatten()
            .filter(|s| !s.is_empty()),
        lease_owner: r
            .get::<_, Option<String>>(10)
            .ok()
            .flatten()
            .filter(|s| !s.is_empty()),
        lease_token: r
            .get::<_, Option<String>>(11)
            .ok()
            .flatten()
            .filter(|s| !s.is_empty()),
        lease_expires_at: r
            .get::<_, Option<i64>>(12)
            .ok()
            .flatten()
            .filter(|&n| n > 0),
        depends_on: r
            .get::<_, Option<String>>(13)
            .ok()
            .flatten()
            .filter(|s| !s.is_empty() && s != "[]"),
    })
}

pub fn task_list(status_filter: Option<&str>) -> Result<Vec<TaskRow>> {
    let conn = open_db()?;
    let sql = match status_filter {
        Some("open") => format!("{} WHERE status = 'open'{}", TASK_SELECT, TASK_ORDER),
        Some("blocked") => format!("{} WHERE status = 'blocked'{}", TASK_SELECT, TASK_ORDER),
        Some("in_progress") => {
            format!("{} WHERE status = 'in_progress'{}", TASK_SELECT, TASK_ORDER)
        }
        Some("done") => format!("{} WHERE status = 'done'{}", TASK_SELECT, TASK_ORDER),
        Some("abandoned") => format!("{} WHERE status = 'abandoned'{}", TASK_SELECT, TASK_ORDER),
        _ => format!(
            "{} WHERE status IN ('open', 'blocked', 'in_progress'){}",
            TASK_SELECT, TASK_ORDER
        ),
    };
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], row_from_query)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Tasks assigned to a given assignee (open, blocked, or in_progress). Used for "Tasks for Jeff" in context.
pub fn task_list_for_assignee(assignee: &str) -> Result<Vec<TaskRow>> {
    let conn = open_db()?;
    let assignee = assignee.trim();
    if assignee.is_empty() {
        return Ok(Vec::new());
    }
    let sql = format!(
        "{} WHERE LOWER(COALESCE(assignee, 'chump')) = LOWER(?1) AND status IN ('open', 'blocked', 'in_progress'){}",
        TASK_SELECT, TASK_ORDER
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([assignee], row_from_query)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn task_update_status(id: i64, status: &str, notes: Option<&str>) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let n = conn.execute(
        "UPDATE chump_tasks SET status = ?1, notes = COALESCE(?2, notes), updated_at = ?3 WHERE id = ?4",
        rusqlite::params![status, notes, now, id],
    )?;
    if n > 0 {
        match status {
            "done" => crate::precision_controller::record_task_outcome_for_regime(true),
            "blocked" => crate::precision_controller::record_task_outcome_for_regime(false),
            _ => {}
        }
    }
    Ok(n > 0)
}

pub fn task_update_priority(id: i64, priority: i64) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let n = conn.execute(
        "UPDATE chump_tasks SET priority = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![priority, now, id],
    )?;
    Ok(n > 0)
}

pub fn task_complete(id: i64, notes: Option<&str>) -> Result<bool> {
    task_update_status(id, "done", notes)
}

pub fn task_update_assignee(id: i64, assignee: &str) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let assignee_val = assignee.trim();
    let n = conn.execute(
        "UPDATE chump_tasks SET assignee = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![
            if assignee_val.is_empty() {
                "chump"
            } else {
                assignee_val
            },
            now,
            id
        ],
    )?;
    Ok(n > 0)
}

pub fn task_update_notes(id: i64, notes: Option<&str>) -> Result<bool> {
    let conn = open_db()?;
    let now = now_iso();
    let n = conn.execute(
        "UPDATE chump_tasks SET notes = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![notes.unwrap_or(""), now, id],
    )?;
    Ok(n > 0)
}

// --- Task lease / claim (autonomy safety) ---

fn lease_owner_default() -> String {
    std::env::var("CHUMP_AUTONOMY_OWNER")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "chump".to_string())
}

fn lease_ttl_secs_default() -> u64 {
    std::env::var("CHUMP_TASK_LEASE_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|&n| (30..=86_400).contains(&n))
        .unwrap_or(900)
}

fn now_unix_secs() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Debug, Clone)]
pub struct TaskLease {
    pub task_id: i64,
    pub owner: String,
    pub token: String,
    pub expires_at_secs: u64,
}

#[cfg(test)]
#[allow(dead_code)]
impl TaskLease {
    pub fn _touch(&self) -> (&i64, &str, &str, &u64) {
        (
            &self.task_id,
            self.owner.as_str(),
            self.token.as_str(),
            &self.expires_at_secs,
        )
    }
}

/// Best-effort schema migration: adds lease columns if missing.
fn ensure_lease_schema(conn: &rusqlite::Connection) {
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_owner TEXT", []);
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_token TEXT", []);
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN lease_expires_at INTEGER DEFAULT 0",
        [],
    );
}

/// Claim a lease for a task if it is unleased or expired. Returns None if another owner holds an unexpired lease.
pub fn task_lease_claim(task_id: i64, owner: Option<&str>) -> Result<Option<TaskLease>> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let owner = owner
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(lease_owner_default);
    let token = uuid::Uuid::new_v4().to_string();
    let now = now_unix_secs();
    let ttl = lease_ttl_secs_default();
    let expires = now.saturating_add(ttl);
    let updated = conn.execute(
        "UPDATE chump_tasks
         SET lease_owner = ?1, lease_token = ?2, lease_expires_at = ?3, updated_at = ?4
         WHERE id = ?5 AND (COALESCE(lease_expires_at, 0) < ?6)",
        rusqlite::params![owner, token, expires as i64, now_iso(), task_id, now as i64],
    )?;
    if updated == 0 {
        return Ok(None);
    }
    Ok(Some(TaskLease {
        task_id,
        owner,
        token,
        expires_at_secs: expires,
    }))
}

/// Renew an existing lease. Returns false if the lease token does not match or is expired.
pub fn task_lease_renew(task_id: i64, token: &str) -> Result<bool> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let now = now_unix_secs();
    let ttl = lease_ttl_secs_default();
    let expires = now.saturating_add(ttl);
    let n = conn.execute(
        "UPDATE chump_tasks
         SET lease_expires_at = ?1, updated_at = ?2
         WHERE id = ?3 AND lease_token = ?4 AND COALESCE(lease_expires_at, 0) >= ?5",
        rusqlite::params![expires as i64, now_iso(), task_id, token, now as i64],
    )?;
    Ok(n > 0)
}

/// Release a lease token (best-effort). Returns true if a row was updated.
pub fn task_lease_release(task_id: i64, token: &str) -> Result<bool> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let n = conn.execute(
        "UPDATE chump_tasks
         SET lease_owner = NULL, lease_token = NULL, lease_expires_at = 0, updated_at = ?1
         WHERE id = ?2 AND lease_token = ?3",
        rusqlite::params![now_iso(), task_id, token],
    )?;
    Ok(n > 0)
}

/// List active leases (unexpired).
pub fn task_leases_list() -> Result<Vec<TaskLease>> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let now = now_unix_secs() as i64;
    let mut stmt = conn.prepare(
        "SELECT id, lease_owner, lease_token, lease_expires_at
         FROM chump_tasks
         WHERE COALESCE(lease_expires_at, 0) >= ?1 AND COALESCE(lease_token, '') != ''",
    )?;
    let rows = stmt
        .query_map([now], |r| {
            Ok(TaskLease {
                task_id: r.get::<_, i64>(0)?,
                owner: r
                    .get::<_, Option<String>>(1)?
                    .unwrap_or_else(|| "chump".to_string()),
                token: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                expires_at_secs: r.get::<_, Option<i64>>(3)?.unwrap_or(0).max(0) as u64,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Reap expired leases (clear lease_* fields). Returns number of tasks updated.
pub fn task_reap_expired_leases() -> Result<u32> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let now = now_unix_secs() as i64;
    let n = conn.execute(
        "UPDATE chump_tasks
         SET lease_owner = NULL, lease_token = NULL, lease_expires_at = 0, updated_at = ?1
         WHERE COALESCE(lease_expires_at, 0) > 0 AND COALESCE(lease_expires_at, 0) < ?2",
        rusqlite::params![now_iso(), now],
    )?;
    Ok(n as u32)
}

/// Requeue stuck in_progress tasks back to open when they have no active lease and have been unchanged for `stuck_secs`.
/// Returns number of tasks updated.
pub fn task_requeue_stuck_in_progress(stuck_secs: u64) -> Result<u32> {
    let conn = open_db()?;
    ensure_lease_schema(&conn);
    let now = now_unix_secs();
    let cutoff = now.saturating_sub(stuck_secs.max(60)) as i64;

    // Select candidates first so we can append a deterministic note.
    let mut stmt = conn.prepare(
        "SELECT id, notes, updated_at
         FROM chump_tasks
         WHERE status = 'in_progress'
           AND (COALESCE(lease_expires_at, 0) = 0 OR COALESCE(lease_expires_at, 0) < ?1)",
    )?;
    let candidates: Vec<(i64, String, String)> = stmt
        .query_map([now as i64], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut updated: u32 = 0;
    for (id, notes, updated_at) in candidates {
        let updated_secs = parse_iso_secs(&updated_at).unwrap_or(now);
        if updated_secs as i64 >= cutoff {
            continue;
        }
        let stamp = now_iso();
        let mut new_notes = notes;
        let line = format!(
            "\n- [{}] requeued: task was in_progress without active lease for >{}s\n",
            stamp,
            stuck_secs.max(60)
        );
        if new_notes.trim().is_empty() {
            new_notes = format!("## Progress{}", line);
        } else {
            new_notes.push_str(&line);
        }
        let n = conn.execute(
            "UPDATE chump_tasks
             SET status = 'open', notes = ?1, updated_at = ?2
             WHERE id = ?3",
            rusqlite::params![new_notes, stamp, id],
        )?;
        if n > 0 {
            updated += 1;
        }
    }
    Ok(updated)
}

/// Set task status to abandoned (soft delete for API).
pub fn task_abandon(id: i64, notes: Option<&str>) -> Result<bool> {
    task_update_status(id, "abandoned", notes)
}

// --- Task dependency DAG ---

/// Best-effort schema migration: adds depends_on column if missing.
fn ensure_depends_on_schema(conn: &rusqlite::Connection) {
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN depends_on TEXT DEFAULT '[]'",
        [],
    );
}

/// Parse `depends_on` JSON text to a Vec of task IDs.
fn parse_depends_on(raw: Option<&str>) -> Vec<i64> {
    let Some(s) = raw else { return vec![] };
    let s = s.trim();
    if s.is_empty() || s == "[]" {
        return vec![];
    }
    serde_json::from_str::<Vec<i64>>(s).unwrap_or_default()
}

/// List open tasks whose dependencies are all satisfied (done/abandoned).
/// A task with no dependencies is always unblocked.
pub fn task_list_unblocked() -> Result<Vec<TaskRow>> {
    let conn = open_db()?;
    ensure_depends_on_schema(&conn);
    // SQLite json_each requires the JSON1 extension (bundled by default in rusqlite).
    // Note: outer table aliased as `outer_t` so json_each references the correct `depends_on`.
    let sql = format!(
        "SELECT outer_t.id, outer_t.title, outer_t.repo, outer_t.issue_number, outer_t.status, \
         outer_t.notes, outer_t.priority, outer_t.created_at, outer_t.updated_at, outer_t.assignee, \
         outer_t.lease_owner, outer_t.lease_token, outer_t.lease_expires_at, outer_t.depends_on \
         FROM chump_tasks AS outer_t \
         WHERE outer_t.status = 'open' \
         AND (COALESCE(outer_t.depends_on, '[]') = '[]' \
              OR NOT EXISTS ( \
                  SELECT 1 FROM json_each(outer_t.depends_on) AS dep \
                  JOIN chump_tasks AS t ON t.id = dep.value \
                  WHERE t.status NOT IN ('done', 'abandoned') \
              )){}",
        TASK_ORDER
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], row_from_query)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Add a dependency: task `task_id` now depends on `depends_on_id`.
pub fn task_add_dependency(task_id: i64, depends_on_id: i64) -> Result<()> {
    if task_id == depends_on_id {
        return Err(anyhow::anyhow!("task cannot depend on itself"));
    }
    let conn = open_db()?;
    ensure_depends_on_schema(&conn);
    let raw: String = conn
        .query_row(
            "SELECT COALESCE(depends_on, '[]') FROM chump_tasks WHERE id = ?1",
            [task_id],
            |r| r.get(0),
        )
        .map_err(|_| anyhow::anyhow!("task {} not found", task_id))?;
    let mut deps = parse_depends_on(Some(&raw));
    if deps.contains(&depends_on_id) {
        return Ok(()); // already present
    }
    // Cycle check: ensure depends_on_id does not transitively depend on task_id
    if has_transitive_dep(&conn, depends_on_id, task_id, &mut vec![])? {
        return Err(anyhow::anyhow!(
            "circular dependency: {} already depends on {} (transitively)",
            depends_on_id,
            task_id
        ));
    }
    deps.push(depends_on_id);
    let json = serde_json::to_string(&deps)?;
    conn.execute(
        "UPDATE chump_tasks SET depends_on = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![json, now_iso(), task_id],
    )?;
    Ok(())
}

/// Remove a dependency from task `task_id`.
pub fn task_remove_dependency(task_id: i64, depends_on_id: i64) -> Result<bool> {
    let conn = open_db()?;
    ensure_depends_on_schema(&conn);
    let raw: String = conn
        .query_row(
            "SELECT COALESCE(depends_on, '[]') FROM chump_tasks WHERE id = ?1",
            [task_id],
            |r| r.get(0),
        )
        .map_err(|_| anyhow::anyhow!("task {} not found", task_id))?;
    let mut deps = parse_depends_on(Some(&raw));
    let before = deps.len();
    deps.retain(|&id| id != depends_on_id);
    if deps.len() == before {
        return Ok(false); // wasn't present
    }
    let json = serde_json::to_string(&deps)?;
    conn.execute(
        "UPDATE chump_tasks SET depends_on = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![json, now_iso(), task_id],
    )?;
    Ok(true)
}

/// DFS check: does `start_id` transitively depend on `target_id`?
fn has_transitive_dep(
    conn: &rusqlite::Connection,
    start_id: i64,
    target_id: i64,
    visited: &mut Vec<i64>,
) -> Result<bool> {
    if visited.contains(&start_id) {
        return Ok(false);
    }
    visited.push(start_id);
    let raw: String = conn
        .query_row(
            "SELECT COALESCE(depends_on, '[]') FROM chump_tasks WHERE id = ?1",
            [start_id],
            |r| r.get(0),
        )
        .unwrap_or_else(|_| "[]".to_string());
    let deps = parse_depends_on(Some(&raw));
    for dep in deps {
        if dep == target_id {
            return Ok(true);
        }
        if has_transitive_dep(conn, dep, target_id, visited)? {
            return Ok(true);
        }
    }
    Ok(false)
}

pub fn task_available() -> bool {
    #[cfg(not(test))]
    {
        crate::db_pool::get().is_ok()
    }
    #[cfg(test)]
    {
        open_db().is_ok()
    }
}

// --- TaskPlanner (Vector 2): multi-step plans in `chump_tasks` ---

/// Insert one objective per row sharing `planner_group_id`. First step is `in_progress`, rest `open`.
pub fn planner_submit_objectives(objectives: &[String], assignee: Option<&str>) -> Result<String> {
    let objectives: Vec<&str> = objectives
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if objectives.is_empty() {
        return Err(anyhow::anyhow!(
            "objectives must contain at least one non-empty string"
        ));
    }
    let conn = open_db()?;
    let group = uuid::Uuid::new_v4().to_string();
    let now = now_iso();
    let assignee_val = assignee
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or("chump");
    for (step, title) in objectives.iter().enumerate() {
        let status = if step == 0 { "in_progress" } else { "open" };
        let pri = (1000_i64).saturating_sub(step as i64);
        conn.execute(
            "INSERT INTO chump_tasks (title, repo, issue_number, status, priority, assignee, notes, created_at, updated_at, planner_group_id, planner_step)
             VALUES (?1, '', 0, ?2, ?3, ?4, '', ?5, ?5, ?6, ?7)",
            rusqlite::params![
                title,
                status,
                pri,
                assignee_val,
                now,
                &group,
                step as i64
            ],
        )?;
    }
    Ok(group)
}

/// Markdown block for system prompt: next plan step + predecessor outcome (if any).
pub fn planner_active_prompt_block() -> Result<Option<String>> {
    let conn = open_db()?;
    let group: Option<String> = match conn.query_row(
        "SELECT planner_group_id FROM chump_tasks
         WHERE planner_group_id IS NOT NULL
           AND TRIM(planner_group_id) != ''
           AND status IN ('open','in_progress','blocked')
         GROUP BY planner_group_id
         ORDER BY MAX(id) DESC
         LIMIT 1",
        [],
        |r| r.get::<_, String>(0),
    ) {
        Ok(g) => Some(g),
        Err(rusqlite::Error::QueryReturnedNoRows) => None,
        Err(e) => return Err(e.into()),
    };
    let Some(group) = group else {
        return Ok(None);
    };

    let next_open: Option<(i64, i64, String, String)> = match conn.query_row(
        "SELECT id, planner_step, title, COALESCE(notes, '') FROM chump_tasks
             WHERE planner_group_id = ?1 AND status = 'open'
             ORDER BY planner_step ASC, id ASC LIMIT 1",
        [&group],
        |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        },
    ) {
        Ok(t) => Some(t),
        Err(rusqlite::Error::QueryReturnedNoRows) => None,
        Err(e) => return Err(e.into()),
    };

    let (next_id, next_step, next_title, _next_notes) = if let Some(t) = next_open {
        t
    } else {
        match conn.query_row(
            "SELECT id, planner_step, title, COALESCE(notes, '') FROM chump_tasks
                 WHERE planner_group_id = ?1 AND status = 'in_progress'
                 ORDER BY planner_step ASC, id ASC LIMIT 1",
            [&group],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            },
        ) {
            Ok(t) => t,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    };

    let pred: Option<(String, String)> = match conn.query_row(
        "SELECT title, COALESCE(notes, '') FROM chump_tasks
             WHERE planner_group_id = ?1 AND status = 'done' AND planner_step < ?2
             ORDER BY planner_step DESC LIMIT 1",
        rusqlite::params![&group, next_step],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
    ) {
        Ok(t) => Some(t),
        Err(rusqlite::Error::QueryReturnedNoRows) => None,
        Err(e) => return Err(e.into()),
    };

    let mut block = String::from("## TaskPlanner (SQLite-backed plan)\n");
    let _ = writeln!(block, "Plan group: `{}`", group);
    let _ = writeln!(
        block,
        "Focus task id: {} (step index {})\n",
        next_id, next_step
    );
    let _ = writeln!(block, "**Next step:** {}", next_title.trim());
    if let Some((ptitle, pnotes)) = pred {
        let tail = pnotes.trim();
        if !ptitle.is_empty() || !tail.is_empty() {
            let _ = writeln!(block);
            let _ = writeln!(block, "**Previous step outcome:** {}", ptitle.trim());
            if !tail.is_empty() {
                let snippet = if tail.len() > 1200 {
                    format!("{}…", &tail[..1200])
                } else {
                    tail.to_string()
                };
                let _ = writeln!(block, "{}", snippet);
            }
        }
    }
    block.push_str("\nAdvance the plan with the `task` tool (update status / notes) when a step is done or blocked.\n");
    Ok(Some(block))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn task_create_and_list_roundtrip() {
        let dir = std::env::temp_dir().join("chump_task_db_test");
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let id = task_create(
            "Fix login bug",
            Some("owner/repo"),
            Some(47),
            None,
            None,
            None,
        )
        .unwrap();
        assert!(id > 0);
        let open_list = task_list(Some("open")).unwrap();
        assert_eq!(open_list.len(), 1);
        assert_eq!(open_list[0].title, "Fix login bug");
        assert_eq!(open_list[0].repo.as_deref(), Some("owner/repo"));
        assert_eq!(open_list[0].issue_number, Some(47));
        assert_eq!(open_list[0].status, "open");

        task_update_status(id, "in_progress", Some("Working on it")).unwrap();
        let in_progress = task_list(Some("in_progress")).unwrap();
        assert_eq!(in_progress.len(), 1);
        assert_eq!(in_progress[0].notes.as_deref(), Some("Working on it"));

        task_complete(id, Some("Done")).unwrap();
        let done_list = task_list(Some("done")).unwrap();
        assert_eq!(done_list.len(), 1);

        let id2 = task_create("Wontfix idea", None, None, None, None, None).unwrap();
        task_update_status(id2, "abandoned", Some("Out of scope")).unwrap();
        let abandoned_list = task_list(Some("abandoned")).unwrap();
        assert_eq!(abandoned_list.len(), 1);
        assert_eq!(abandoned_list[0].title, "Wontfix idea");

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }

    #[test]
    #[serial]
    fn planner_submit_and_prompt_block() {
        let dir = std::env::temp_dir().join(format!(
            "chump_planner_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let gid = planner_submit_objectives(
            &[
                "Step A".to_string(),
                "Step B".to_string(),
                "Step C".to_string(),
            ],
            None,
        )
        .unwrap();
        assert!(!gid.is_empty());

        let block = planner_active_prompt_block().unwrap();
        assert!(block.is_some());
        let b = block.unwrap();
        assert!(b.contains("Step B") || b.contains("Step A"));

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }

    #[test]
    #[serial]
    fn task_dag_unblocked_and_cycle_detection() {
        let dir =
            std::env::temp_dir().join(format!("chump_dag_test_{}", uuid::Uuid::new_v4().simple()));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        // Create three tasks: A, B, C
        let a = task_create("Task A", None, None, None, None, None).unwrap();
        let b = task_create("Task B", None, None, None, None, None).unwrap();
        let c = task_create("Task C", None, None, None, None, None).unwrap();

        // All three should be unblocked initially
        let unblocked = task_list_unblocked().unwrap();
        assert!(unblocked.iter().any(|t| t.id == a));
        assert!(unblocked.iter().any(|t| t.id == b));
        assert!(unblocked.iter().any(|t| t.id == c));

        // B depends on A → B should be blocked
        task_add_dependency(b, a).unwrap();
        let unblocked = task_list_unblocked().unwrap();
        assert!(unblocked.iter().any(|t| t.id == a), "A should be unblocked");
        assert!(
            !unblocked.iter().any(|t| t.id == b),
            "B should be blocked by A"
        );
        assert!(unblocked.iter().any(|t| t.id == c), "C should be unblocked");

        // C depends on B → C also blocked (transitive chain)
        task_add_dependency(c, b).unwrap();
        let unblocked = task_list_unblocked().unwrap();
        assert!(
            !unblocked.iter().any(|t| t.id == c),
            "C blocked by B (which is blocked by A)"
        );

        // Cycle detection: A depends on C would create A→C→B→A
        let err = task_add_dependency(a, c);
        assert!(err.is_err(), "should reject circular dependency");
        assert!(
            err.unwrap_err().to_string().contains("circular"),
            "error should mention circular"
        );

        // Self-dependency rejected
        let err = task_add_dependency(a, a);
        assert!(err.is_err(), "should reject self-dependency");

        // Complete A → B becomes unblocked, C still blocked by B
        task_complete(a, None).unwrap();
        let unblocked = task_list_unblocked().unwrap();
        assert!(
            unblocked.iter().any(|t| t.id == b),
            "B unblocked after A done"
        );
        assert!(!unblocked.iter().any(|t| t.id == c), "C still blocked by B");

        // Complete B → C becomes unblocked
        task_complete(b, None).unwrap();
        let unblocked = task_list_unblocked().unwrap();
        assert!(
            unblocked.iter().any(|t| t.id == c),
            "C unblocked after B done"
        );

        // Remove dependency test
        let d = task_create("Task D", None, None, None, None, None).unwrap();
        let e = task_create("Task E", None, None, None, None, None).unwrap();
        task_add_dependency(e, d).unwrap();
        assert!(!task_list_unblocked().unwrap().iter().any(|t| t.id == e));
        let removed = task_remove_dependency(e, d).unwrap();
        assert!(removed, "should return true when dependency existed");
        assert!(task_list_unblocked().unwrap().iter().any(|t| t.id == e));
        let removed_again = task_remove_dependency(e, d).unwrap();
        assert!(
            !removed_again,
            "should return false when dependency already gone"
        );

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }

    #[test]
    #[serial]
    fn task_create_with_deps_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "chump_deps_create_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let a = task_create("Dep target", None, None, None, None, None).unwrap();
        let b =
            task_create_with_deps("Has deps", None, None, None, None, None, Some(&[a])).unwrap();
        let tasks = task_list(Some("open")).unwrap();
        let b_row = tasks.iter().find(|t| t.id == b).unwrap();
        let deps = parse_depends_on(b_row.depends_on.as_deref());
        assert_eq!(deps, vec![a]);

        // b should be blocked
        let unblocked = task_list_unblocked().unwrap();
        assert!(!unblocked.iter().any(|t| t.id == b));

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }

    #[test]
    #[serial]
    fn task_lease_second_owner_cannot_claim_until_released() {
        let dir = std::env::temp_dir().join(format!(
            "chump_task_lease_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let notes = "## Acceptance\n- done\n\n## Verify\n- [ ] Command(s): true\n";
        let id = task_create(
            "Lease test",
            None,
            None,
            Some(1),
            Some("chump"),
            Some(notes),
        )
        .unwrap();

        let a = task_lease_claim(id, Some("worker-a"))
            .unwrap()
            .expect("first claim");
        assert_eq!(a.owner, "worker-a");

        let blocked = task_lease_claim(id, Some("worker-b")).unwrap();
        assert!(
            blocked.is_none(),
            "second owner must not steal an active lease"
        );

        assert!(task_lease_release(id, &a.token).unwrap());

        let b = task_lease_claim(id, Some("worker-b"))
            .unwrap()
            .expect("claim after release");
        assert_eq!(b.owner, "worker-b");
        let _ = task_lease_release(id, &b.token);

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let db_file = dir.join(DB_FILENAME);
        let _ = std::fs::remove_file(db_file);
    }
}
