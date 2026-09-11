//! `GET /api/gap-pulse` (RESILIENT-1088 cockpit) — unauthenticated, count-only
//! read of the canonical gap-store state so the daily cockpit's "pickable vs
//! open" lead tile can light up from an unauthed browser.
//!
//! `GET /api/gaps` already exists but is Bearer-gated (it returns full gap
//! *contents*, which are sensitive), so the cockpit — a page fetched from an
//! unauthed browser on the tailnet — cannot read it. This route returns only
//! non-sensitive **counts** derived from one read-only pass over
//! `.chump/state.db` (the canonical gap store, `gap-store-split-brain-swamp`),
//! matching `docs/process/COCKPIT.md` §3's `/api/gap-pulse`: "open/blocked/
//! in-flight + Δcreate−close. Never a raw total."
//!
//! Honesty (COCKPIT.md §5): when `state.db` is absent or unreadable the route
//! still returns 200 with `available:false` and null counts + a `note`, so the
//! tile greys ("unknown") instead of the fetch erroring — a dark source must
//! look dark, never fake-green, and never fabricated.

use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Statuses that mean a gap is still "in play" — an open dependency in one of
/// these blocks a downstream gap from being pickable. Anything else (done,
/// closed, closed_not_a_bug, parked, …) counts as satisfied.
const ACTIVE_STATUSES: &[&str] = &["open", "blocked", "in_progress", "in-progress"];

/// Count-only pulse of the canonical gap store. Every count is `Option` so a
/// dark source renders as JSON `null` (grey tile) rather than a fabricated 0.
#[derive(Debug, Serialize, Default)]
pub struct GapPulse {
    /// True when `state.db` was found and read. False ⇒ every count is null.
    pub available: bool,
    /// Server wall-clock (ms) when this pulse was computed — the tile's age.
    pub generated_ms: i64,
    /// `status = 'open'`.
    pub open: Option<i64>,
    /// `status = 'blocked'`.
    pub blocked: Option<i64>,
    /// `status IN ('in_progress','in-progress')` — work in flight.
    pub in_flight: Option<i64>,
    /// Open gaps that are **unleased** AND have no known-unmet dependency —
    /// the real "can a worker pick one up right now" number. A recent
    /// stand-down means this is ~0 even while `open` is large.
    pub pickable: Option<i64>,
    /// Open gaps currently held by an active (unexpired) lease.
    pub leased_open: Option<i64>,
    /// Open gaps with ≥1 dependency still in an active status.
    pub deps_blocked_open: Option<i64>,
    /// Gaps created in the last 24h (`created_at` epoch-seconds ≥ cutoff).
    pub created_24h: Option<i64>,
    /// Gaps closed in the last 24h (`closed_at` epoch-seconds ≥ cutoff).
    pub closed_24h: Option<i64>,
    /// `created_24h − closed_24h` — the backlog drift the tile annotates.
    pub delta_24h: Option<i64>,
    /// Human-readable provenance / dark-source reason.
    pub note: String,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Split a `depends_on` TEXT field into gap-id tokens. Stored comma-separated
/// (`crates/chump-kpi-report` splits on ',', mcp-gaps documents "Comma-
/// separated gap IDs"); we also tolerate whitespace so a hand-edited
/// "A, B  C" parses. Empty tokens are dropped.
fn parse_deps(depends_on: &str) -> Vec<String> {
    depends_on
        .split([',', ' ', '\t', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Compute pickable/leased/deps-blocked over the open gaps given the full
/// id→status map and the set of leased gap ids. Pure so the dependency logic
/// is unit-testable without a live DB.
///
/// A dependency blocks only when it is a **known** gap still in an active
/// status; an unknown/typo dep id is treated as satisfied (we never invent a
/// blocker). Returns `(pickable, leased_open, deps_blocked_open)`.
fn classify_open(
    open_gaps: &[(String, String)], // (id, depends_on)
    status_by_id: &HashMap<String, String>,
    leased: &HashSet<String>,
) -> (i64, i64, i64) {
    let mut pickable = 0i64;
    let mut leased_open = 0i64;
    let mut deps_blocked = 0i64;
    for (id, depends_on) in open_gaps {
        let is_leased = leased.contains(id);
        if is_leased {
            leased_open += 1;
        }
        let has_unmet_dep = parse_deps(depends_on).iter().any(|dep| {
            status_by_id
                .get(dep)
                .map(|st| ACTIVE_STATUSES.contains(&st.as_str()))
                .unwrap_or(false)
        });
        if has_unmet_dep {
            deps_blocked += 1;
        }
        if !is_leased && !has_unmet_dep {
            pickable += 1;
        }
    }
    (pickable, leased_open, deps_blocked)
}

/// Build the pulse from the canonical gap store at `repo_root/.chump/state.db`
/// (same DB `dashboard::read_active_leases` reads for leases). Read-only; any
/// error degrades to `available:false` + null counts, never a 500 — a dark
/// gauge must not take the whole cockpit down.
pub fn build_pulse(repo_root: &Path) -> GapPulse {
    let generated_ms = now_ms();
    let db_path = repo_root.join(".chump").join("state.db");
    if !db_path.is_file() {
        return GapPulse {
            available: false,
            generated_ms,
            note: format!("state.db not found at {}", db_path.display()),
            ..Default::default()
        };
    }
    match compute(&db_path) {
        Ok(mut p) => {
            p.generated_ms = generated_ms;
            p
        }
        Err(e) => GapPulse {
            available: false,
            generated_ms,
            note: format!("state.db unreadable: {e}"),
            ..Default::default()
        },
    }
}

fn compute(db_path: &Path) -> anyhow::Result<GapPulse> {
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let cutoff = now_secs() - 24 * 3600;

    // One pass over gaps: id, status, depends_on, created_at, closed_at.
    let mut status_by_id: HashMap<String, String> = HashMap::new();
    let mut open_gaps: Vec<(String, String)> = Vec::new();
    let mut open = 0i64;
    let mut blocked = 0i64;
    let mut in_flight = 0i64;
    let mut created_24h = 0i64;
    let mut closed_24h = 0i64;

    {
        let mut stmt = conn.prepare(
            "SELECT id, status, depends_on, \
                    CAST(created_at AS INTEGER), \
                    CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END \
               FROM gaps",
        )?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let status: String = row.get(1)?;
            let depends_on: String = row.get::<_, Option<String>>(2)?.unwrap_or_default();
            let created_at: i64 = row.get::<_, Option<i64>>(3)?.unwrap_or(0);
            let closed_at: Option<i64> = row.get(4)?;

            match status.as_str() {
                "open" => {
                    open += 1;
                    open_gaps.push((id.clone(), depends_on));
                }
                "blocked" => blocked += 1,
                "in_progress" | "in-progress" => in_flight += 1,
                _ => {}
            }
            if created_at >= cutoff {
                created_24h += 1;
            }
            if closed_at.map(|c| c >= cutoff).unwrap_or(false) {
                closed_24h += 1;
            }
            status_by_id.insert(id, status);
        }
    }

    // Active (unexpired) leases → the set of currently-held gap ids. The
    // leases table may not exist on an ancient DB; treat that as "no leases".
    let leased = read_active_leased_ids(&conn).unwrap_or_default();

    let (pickable, leased_open, deps_blocked_open) =
        classify_open(&open_gaps, &status_by_id, &leased);

    Ok(GapPulse {
        available: true,
        generated_ms: 0, // set by caller
        open: Some(open),
        blocked: Some(blocked),
        in_flight: Some(in_flight),
        pickable: Some(pickable),
        leased_open: Some(leased_open),
        deps_blocked_open: Some(deps_blocked_open),
        created_24h: Some(created_24h),
        closed_24h: Some(closed_24h),
        delta_24h: Some(created_24h - closed_24h),
        note: "counts from .chump/state.db (canonical gap store)".into(),
    })
}

fn read_active_leased_ids(conn: &Connection) -> anyhow::Result<HashSet<String>> {
    let now = now_secs();
    let mut stmt = conn.prepare("SELECT gap_id FROM leases WHERE expires_at > ?1")?;
    let ids = stmt
        .query_map([now], |r| r.get::<_, String>(0))?
        .filter_map(|r| r.ok())
        .collect();
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn parse_deps_handles_comma_and_whitespace() {
        assert_eq!(parse_deps("A,B"), vec!["A", "B"]);
        assert_eq!(parse_deps("A, B  C"), vec!["A", "B", "C"]);
        assert_eq!(parse_deps("  "), Vec::<String>::new());
        assert_eq!(parse_deps(""), Vec::<String>::new());
    }

    #[test]
    fn classify_counts_pickable_unleased_and_dep_satisfied() {
        // INFRA-2 depends on INFRA-1 (done) → satisfied; INFRA-3 has no deps.
        let open = vec![
            ("INFRA-2".into(), "INFRA-1".into()),
            ("INFRA-3".into(), "".into()),
        ];
        let status = map(&[
            ("INFRA-1", "done"),
            ("INFRA-2", "open"),
            ("INFRA-3", "open"),
        ]);
        let leased = HashSet::new();
        let (pickable, leased_open, deps_blocked) = classify_open(&open, &status, &leased);
        assert_eq!(pickable, 2);
        assert_eq!(leased_open, 0);
        assert_eq!(deps_blocked, 0);
    }

    #[test]
    fn classify_marks_dep_blocked_when_dependency_still_active() {
        // INFRA-2 depends on INFRA-1 which is still open → INFRA-2 not pickable.
        let open = vec![
            ("INFRA-1".into(), "".into()),
            ("INFRA-2".into(), "INFRA-1".into()),
        ];
        let status = map(&[("INFRA-1", "open"), ("INFRA-2", "open")]);
        let leased = HashSet::new();
        let (pickable, _, deps_blocked) = classify_open(&open, &status, &leased);
        assert_eq!(pickable, 1); // only INFRA-1
        assert_eq!(deps_blocked, 1); // INFRA-2
    }

    #[test]
    fn classify_excludes_leased_open_from_pickable() {
        let open = vec![("INFRA-1".into(), "".into()), ("INFRA-2".into(), "".into())];
        let status = map(&[("INFRA-1", "open"), ("INFRA-2", "open")]);
        let mut leased = HashSet::new();
        leased.insert("INFRA-1".to_string());
        let (pickable, leased_open, _) = classify_open(&open, &status, &leased);
        assert_eq!(pickable, 1); // INFRA-2 only
        assert_eq!(leased_open, 1);
    }

    #[test]
    fn classify_treats_unknown_dep_as_satisfied() {
        // Dep points at a gap not in the store (typo/phantom) → never a blocker.
        let open = vec![("INFRA-2".into(), "GHOST-999".into())];
        let status = map(&[("INFRA-2", "open")]);
        let leased = HashSet::new();
        let (pickable, _, deps_blocked) = classify_open(&open, &status, &leased);
        assert_eq!(pickable, 1);
        assert_eq!(deps_blocked, 0);
    }

    #[test]
    fn build_pulse_missing_db_is_available_false_not_a_panic() {
        let p = build_pulse(Path::new("/nonexistent-repo-root-xyz"));
        assert!(!p.available);
        assert!(p.open.is_none());
        assert!(p.note.contains("state.db"));
    }
}
