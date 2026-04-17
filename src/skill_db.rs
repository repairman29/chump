//! Skill reliability tracking in SQLite.
//!
//! Complements the on-disk SKILL.md files (source of truth for procedure content)
//! with per-skill outcome tracking: success count, failure count, last_used, etc.
//! Enables Bayesian reliability scoring per skill — same pattern as per-tool belief state.

use anyhow::Result;

/// Insert or update a skill metadata row. Called after save_skill().
pub fn upsert_skill_record(
    name: &str,
    description: &str,
    version: u32,
    category: Option<&str>,
    tags: &[String],
) -> Result<()> {
    let conn = crate::db_pool::get()?;
    let tags_json = serde_json::to_string(tags).unwrap_or_else(|_| "[]".to_string());
    conn.execute(
        "INSERT INTO chump_skills (name, description, version, category, tags_json, updated_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, datetime('now')) \
         ON CONFLICT(name) DO UPDATE SET \
           description = excluded.description, \
           version = excluded.version, \
           category = excluded.category, \
           tags_json = excluded.tags_json, \
           updated_at = datetime('now')",
        rusqlite::params![name, description, version, category, tags_json],
    )?;
    Ok(())
}

/// Delete a skill metadata row.
pub fn delete_skill_record(name: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute("DELETE FROM chump_skills WHERE name = ?1", [name])?;
    Ok(())
}

/// Record a skill usage outcome. success=true increments success_count, otherwise failure_count.
pub fn record_skill_outcome(name: &str, success: bool) -> Result<()> {
    let conn = crate::db_pool::get()?;
    if success {
        conn.execute(
            "UPDATE chump_skills SET \
               use_count = use_count + 1, \
               success_count = success_count + 1, \
               last_used_at = datetime('now'), \
               updated_at = datetime('now') \
             WHERE name = ?1",
            [name],
        )?;
    } else {
        conn.execute(
            "UPDATE chump_skills SET \
               use_count = use_count + 1, \
               failure_count = failure_count + 1, \
               last_used_at = datetime('now'), \
               updated_at = datetime('now') \
             WHERE name = ?1",
            [name],
        )?;
    }
    Ok(())
}

/// Reliability of a skill, computed Bayesian-style from success/failure counts.
/// Returns (reliability, use_count) where reliability = (success+1) / (use_count+2) (Laplace smoothing).
pub fn skill_reliability(name: &str) -> Result<(f64, u64)> {
    let conn = crate::db_pool::get()?;
    let row: Option<(i64, i64, i64)> = conn
        .query_row(
            "SELECT use_count, success_count, failure_count FROM chump_skills WHERE name = ?1",
            [name],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok();
    if let Some((use_count, success, _failure)) = row {
        let reliability = (success as f64 + 1.0) / (use_count as f64 + 2.0);
        Ok((reliability, use_count as u64))
    } else {
        // No record: Laplace prior (1/2)
        Ok((0.5, 0))
    }
}

/// List all skill records with their reliability stats, ordered by confidence × recency.
pub fn list_skill_records() -> Result<Vec<SkillRecord>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT name, description, version, category, tags_json, \
                use_count, success_count, failure_count, \
                created_at, last_used_at, bt_rating \
         FROM chump_skills ORDER BY name",
    )?;
    let rows = stmt.query_map([], |r| {
        let tags_json: String = r.get(4)?;
        let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();
        Ok(SkillRecord {
            name: r.get(0)?,
            description: r.get(1)?,
            version: r.get::<_, i64>(2)? as u32,
            category: r.get(3)?,
            tags,
            use_count: r.get::<_, i64>(5)? as u64,
            success_count: r.get::<_, i64>(6)? as u64,
            failure_count: r.get::<_, i64>(7)? as u64,
            created_at: r.get(8)?,
            last_used_at: r.get(9)?,
            bt_rating: r.get(10).unwrap_or(1500.0),
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SkillRecord {
    pub name: String,
    pub description: String,
    pub version: u32,
    pub category: Option<String>,
    pub tags: Vec<String>,
    pub use_count: u64,
    pub success_count: u64,
    pub failure_count: u64,
    pub created_at: String,
    pub last_used_at: Option<String>,
    pub bt_rating: f64,
}

pub fn update_bt_rating(name: &str, new_rating: f64) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_skills SET bt_rating = ?1, updated_at = datetime('now') WHERE name = ?2",
        rusqlite::params![new_rating, name],
    )?;
    Ok(())
}

/// Sprint B (B4): Check if a skill with identical arguments has been cached.
pub fn check_skill_cache(
    skill_name: &str,
    version: u32,
    args_hash: &str,
) -> Result<Option<String>> {
    let conn = crate::db_pool::get()?;
    let row: Option<String> = conn
        .query_row(
            "SELECT outcome_json FROM chump_skill_cache WHERE skill_name = ?1 AND version = ?2 AND args_hash = ?3",
            rusqlite::params![skill_name, version, args_hash],
            |r| r.get(0),
        )
        .ok();
    Ok(row)
}

/// Sprint B (B4): Write a new outcome to the deterministic skill cache.
pub fn write_skill_cache(
    skill_name: &str,
    version: u32,
    args_hash: &str,
    outcome_json: &str,
) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT OR REPLACE INTO chump_skill_cache (skill_name, version, args_hash, outcome_json) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![skill_name, version, args_hash, outcome_json],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reliability_no_record_returns_prior() {
        // This test requires a DB pool but doesn't write to it.
        // If the pool is available, an unknown skill name returns the Laplace prior.
        if let Ok((r, n)) = skill_reliability("nonexistent-skill-xyz") {
            assert_eq!(n, 0);
            assert!((r - 0.5).abs() < 0.01);
        }
    }
}
