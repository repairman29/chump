//! `GET /api/gaps/next` + `POST /api/gap/claim` — the API-first pick+claim
//! keystone (INFRA-3966).
//!
//! Where the worker's per-cycle "get my next gap + claim it" currently runs
//! over **local** SQLite + `.chump-locks/` flock lease files (via
//! `scripts/dispatch/_pick_and_claim_gap.py`), these two endpoints expose the
//! SAME pick+claim over HTTP so a client can run it against the canonical store
//! on owned iron WITHOUT holding a writable local replica. This is **additive**
//! — worker.sh and the Python picker are untouched; repointing them is a
//! follow-up.
//!
//! ## Ranking parity with `_pick_and_claim_gap.py`
//!
//! The pick order mirrors the canonical picker's sort tuple
//! `(prio_rank, mission_rank, wedge_rank, effort_rank, age, id)`:
//!   - `prio_rank` (P0=0 < P1=1 < P2=2 < P3=3) is the AUTHORITATIVE primary key
//!     — no heuristic ever promotes a lower-priority gap above a higher one.
//!   - `mission_rank` (0 for active-mission-linked, else 1) is a within-band
//!     tiebreak.
//!   - `wedge_rank = -(affinity_score + rebalance_boost)` folds the INFRA-314
//!     skill-affinity and FLEET-046 ship-history rebalance heuristics into a
//!     within-band tiebreak only.
//!   - then `effort_rank`, then `created_at` (age), then `id`.
//!
//! Filters ported verbatim: status=open, non-SUPERSEDED, non-manufactured-
//! pillar-starved-junk, `priority_filter`/`effort_filter`, the META-044
//! meta-domain effort gate, `depends_on` blocking, and INFRA-314 skill
//! hard-filtering. In-progress exclusion covers BOTH active DB leases
//! (`GapStore::active_leases`) AND open `chump/<gap-id>-…` branches on origin.
//!
//! ### Known, bounded divergences (documented, not silent)
//!   - The INFRA-720 ambient-4h under-represented-pillar boost (an ADDITIONAL
//!     within-band `+2` layered on the FLEET-046 ship-history rebalance) is not
//!     ported here — it only ever reorders WITHIN a priority band, never across
//!     bands, so which priorities get served is identical.
//!   - `required_model` tier gating is not applied: this endpoint has no worker
//!     model-tier input, so it treats every worker as capable (`any`).
//!   - The multi-worker stagger offset is dropped: `/api/gaps/next` returns the
//!     single best pickable gap; collision safety lives in the atomic
//!     `/api/gap/claim` (409 on race), not in a pick-time offset.

use std::collections::HashSet;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use chump_gap_store::{GapRow, GapStore};
use serde::{Deserialize, Serialize};

const PILLAR_TAGS: &[&str] = &[
    "EFFECTIVE",
    "CREDIBLE",
    "RESILIENT",
    "ZERO-WASTE",
    "MISSION",
];
const DEFAULT_ACTIVE_MISSION: &str = "MISSION-010";
const DEFAULT_CLAIM_TTL_SECS: i64 = 4 * 3600;
const REBALANCE_WINDOW: i64 = 20;
const REBALANCE_DOMAIN_THRESHOLD: u32 = 70;

// ── query params / response shapes ──────────────────────────────────────────

/// Query params for `GET /api/gaps/next`.
#[derive(Debug, Deserialize)]
pub struct NextQuery {
    /// Worker id (used for skill-affinity context; required by contract).
    #[serde(default)]
    pub worker: Option<String>,
    /// Comma-separated priority allow-list (e.g. `P0,P1`). Empty = all.
    #[serde(default)]
    pub priority_filter: Option<String>,
    /// Comma-separated effort allow-list (e.g. `xs,s,m`). Empty = all.
    #[serde(default)]
    pub effort_filter: Option<String>,
    /// Comma-separated worker skills for INFRA-314 affinity + hard-filter.
    #[serde(default)]
    pub skills: Option<String>,
}

/// The single best pickable gap, returned by `GET /api/gaps/next`.
#[derive(Debug, Serialize)]
pub struct PickedGap {
    pub id: String,
    pub domain: String,
    pub title: String,
    pub priority: String,
    pub effort: String,
    /// Acceptance criteria (raw JSON-or-text blob as stored).
    pub acceptance_criteria: String,
}

impl From<GapRow> for PickedGap {
    fn from(g: GapRow) -> Self {
        PickedGap {
            id: g.id,
            domain: g.domain,
            title: g.title,
            priority: g.priority,
            effort: g.effort,
            acceptance_criteria: g.acceptance_criteria,
        }
    }
}

/// Body for `POST /api/gap/claim`.
#[derive(Debug, Deserialize)]
pub struct ClaimRequest {
    pub gap_id: String,
    pub worker: String,
    /// Lease TTL in seconds (default 4h, matching the Python picker).
    #[serde(default)]
    pub ttl: Option<i64>,
}

/// The lease record returned by a successful `POST /api/gap/claim`.
#[derive(Debug, Serialize)]
pub struct ClaimRecord {
    pub gap_id: String,
    /// The claiming worker == the lease `session_id`.
    pub worker: String,
    pub worktree: String,
    pub expires_at: i64,
    pub ttl_secs: i64,
    pub status: String,
}

/// Why a claim failed, so the route can map to the right HTTP status.
#[derive(Debug)]
pub enum ClaimError {
    /// Someone else holds a live lease, or the gap is already done — 409.
    Conflict(String),
    /// The gap id does not exist — 404.
    NotFound(String),
    /// Anything else (store open failure, IO) — 500.
    Internal(String),
}

// ── small helpers ───────────────────────────────────────────────────────────

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Split a comma-separated query value into trimmed, non-empty tokens.
pub fn csv(v: Option<&str>) -> Vec<String> {
    v.unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Extract the pillar tag from a gap title (`EFFECTIVE: foo` → `EFFECTIVE`).
fn extract_pillar(title: &str) -> Option<&'static str> {
    let upper = title.trim_start().to_uppercase();
    for tag in PILLAR_TAGS {
        if upper.starts_with(&format!("{tag}:")) {
            return Some(tag);
        }
    }
    None
}

/// RESILIENT-272: self-referential "pillar starved" junk gaps are banned and
/// must never be picked. Mirrors the picker's `_MANUFACTURED_PILLAR_STARVED_RE`
/// without pulling in a regex dep.
fn is_manufactured_pillar_starved_junk(title: &str) -> bool {
    let t = title.trim_start().to_lowercase();
    const PREFIXES: &[&str] = &[
        "mission-effective:",
        "mission-credible:",
        "mission-resilient:",
        "mission-zero-waste:",
    ];
    PREFIXES.iter().any(|p| t.starts_with(p)) && t.contains("pillar starved")
}

/// MISSION-011: resolve the active mission outcome id.
/// Order: `CHUMP_ACTIVE_MISSION` env (present even if empty) → `~/.chump/
/// ACTIVE_MISSION` file → hard default `MISSION-010`.
fn load_active_mission() -> String {
    if let Ok(v) = std::env::var("CHUMP_ACTIVE_MISSION") {
        return v.trim().to_string();
    }
    if let Some(home) = std::env::var_os("HOME") {
        let path = Path::new(&home).join(".chump").join("ACTIVE_MISSION");
        if let Ok(contents) = std::fs::read_to_string(&path) {
            let v = contents.trim();
            if !v.is_empty() {
                return v.to_string();
            }
        }
    }
    DEFAULT_ACTIVE_MISSION.to_string()
}

/// MISSION-011: is `g` linked to the active mission?
fn is_mission_linked(g: &GapRow, active_mission: &str) -> bool {
    if active_mission.is_empty() {
        return false;
    }
    if g.outcome_id.as_deref().unwrap_or("").trim() == active_mission {
        return true;
    }
    if g.domain.to_uppercase() == "MISSION" {
        return true;
    }
    if g.id.trim() == active_mission {
        return true;
    }
    let needle = active_mission.to_uppercase();
    g.title.to_uppercase().contains(&needle)
        || g.notes.to_uppercase().contains(&needle)
        || g.description.to_uppercase().contains(&needle)
}

/// FLEET-046: from recent ship history, derive `(monopoly_domain,
/// starved_pillars)`. A domain that is ≥ `threshold`% of recent ships is a
/// monopoly (gaps from OTHER domains get boosted); pillars absent from recent
/// ship titles are starved (gaps tagged with them get boosted).
fn compute_rebalance_boosts(
    ship_history: &[(String, String)],
    threshold: u32,
) -> (String, HashSet<&'static str>) {
    if ship_history.is_empty() {
        return (String::new(), HashSet::new());
    }
    let mut domain_counts: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    let mut seen_pillars: HashSet<&'static str> = HashSet::new();
    for (domain, title) in ship_history {
        let d = domain.to_uppercase();
        if !d.is_empty() {
            *domain_counts.entry(d).or_insert(0) += 1;
        }
        if let Some(p) = extract_pillar(title) {
            seen_pillars.insert(p);
        }
    }
    let total = ship_history.len();
    let mut monopoly_domain = String::new();
    for (domain, count) in &domain_counts {
        let pct = (count * 100) / total;
        if pct as u32 >= threshold {
            monopoly_domain = domain.clone();
            break;
        }
    }
    let starved: HashSet<&'static str> = PILLAR_TAGS
        .iter()
        .copied()
        .filter(|p| !seen_pillars.contains(p))
        .collect();
    (monopoly_domain, starved)
}

/// Parse a `skills_required` / `depends_on` blob the way the Python picker
/// does: `json.loads` and take the resulting list. A non-JSON string (e.g. a
/// bare CSV) or any parse error yields `None`, exactly mirroring the picker's
/// `except JSONDecodeError` fall-throughs.
fn parse_json_list(raw: &str) -> Option<Vec<String>> {
    let t = raw.trim();
    if t.is_empty() {
        return Some(Vec::new());
    }
    match serde_json::from_str::<serde_json::Value>(t) {
        Ok(serde_json::Value::Array(a)) => Some(
            a.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect(),
        ),
        Ok(serde_json::Value::Null) => Some(Vec::new()),
        _ => None,
    }
}

/// RESILIENT-332 (anti-spin, Layer B): gap ids with an open `chump/<id>-…`
/// branch on origin must never be offered. Best-effort: a git/network failure
/// returns an empty set (leases still exclude in-flight pre-push work).
fn in_progress_from_branches(repo_root: &Path) -> HashSet<String> {
    let mut set = HashSet::new();
    let out = Command::new("bash")
        .current_dir(repo_root)
        .arg("-lc")
        .arg("timeout 8 git ls-remote --heads origin 'chump/*' 2>/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output();
    let Ok(out) = out else {
        return set;
    };
    if !out.status.success() {
        return set;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        // "<sha>\trefs/heads/chump/INFRA-3966-fleet-abc"
        let Some(refname) = line.split_whitespace().nth(1) else {
            continue;
        };
        let Some(rest) = refname.strip_prefix("refs/heads/chump/") else {
            continue;
        };
        if let Some(gid) = gap_id_from_branch_tail(rest) {
            set.insert(gid);
        }
    }
    set
}

/// From `INFRA-3966-fleet-abc` extract `INFRA-3966`.
fn gap_id_from_branch_tail(tail: &str) -> Option<String> {
    let mut it = tail.splitn(3, '-');
    let prefix = it.next()?;
    let num = it.next()?;
    let prefix_ok = !prefix.is_empty()
        && prefix
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit());
    let num_ok = !num.is_empty() && num.chars().all(|c| c.is_ascii_digit());
    if prefix_ok && num_ok {
        Some(format!("{prefix}-{num}"))
    } else {
        None
    }
}

// ── the pick ────────────────────────────────────────────────────────────────

/// Ranking key mirroring the canonical picker sort tuple.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct SortKey {
    prio_rank: i32,
    mission_rank: i32,
    wedge_rank: i32,
    effort_rank: i32,
    age: i64,
    id: String,
}

fn prio_rank(p: &str) -> i32 {
    match p.to_uppercase().as_str() {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 9,
    }
}

fn effort_rank(e: &str) -> i32 {
    match e.to_lowercase().as_str() {
        "xs" => 0,
        "s" => 1,
        "m" => 2,
        "l" => 3,
        "xl" => 4,
        _ => 9,
    }
}

/// Open the canonical gap store, apply the picker's ranking + filters, and
/// return the single best pickable gap (read-only — no claim). Blocking; call
/// from `spawn_blocking`.
pub fn pick_next_gap(
    repo_root: &Path,
    _worker: &str,
    priority_filter: &[String],
    effort_filter: &[String],
    worker_skills: &HashSet<String>,
) -> anyhow::Result<Option<GapRow>> {
    let store = GapStore::open(repo_root)?;
    let open_gaps = store.list(Some("open"))?;
    let active_leases = store.active_leases()?; // gap_id -> session_id
    let ship_history = store.recent_ship_history(REBALANCE_WINDOW)?;
    // Store handle done with its blocking work before we touch the network.
    drop(store);

    let in_progress = in_progress_from_branches(repo_root);
    let active_mission = load_active_mission();
    let (monopoly_domain, starved_pillars) =
        compute_rebalance_boosts(&ship_history, REBALANCE_DOMAIN_THRESHOLD);

    let prio_up: Vec<String> = priority_filter.iter().map(|s| s.to_uppercase()).collect();
    let effort_lo: Vec<String> = effort_filter.iter().map(|s| s.to_lowercase()).collect();

    let mut best: Option<(SortKey, usize)> = None;

    for (idx, g) in open_gaps.iter().enumerate() {
        if g.status != "open" {
            continue;
        }
        // Exclude in-progress: DB leases + open chump/* branches.
        if active_leases.contains_key(&g.id) || in_progress.contains(&g.id) {
            continue;
        }
        if g.notes
            .trim_start()
            .to_uppercase()
            .starts_with("SUPERSEDED")
        {
            continue;
        }
        if is_manufactured_pillar_starved_junk(&g.title) {
            continue;
        }
        let p_up = g.priority.to_uppercase();
        if !prio_up.is_empty() && !prio_up.contains(&p_up) {
            continue;
        }
        let e_lo = g.effort.to_lowercase();
        if !effort_lo.is_empty() && !effort_lo.contains(&e_lo) {
            continue;
        }
        let d_lo = g.domain.to_lowercase();
        // META-044: META-* is only fleet-pickable at effort xs|s.
        if d_lo == "meta" && !(e_lo == "xs" || e_lo == "s") {
            continue;
        }
        // depends_on: any non-empty dependency list blocks the gap. A parse
        // failure (non-JSON) mirrors the picker's `continue` (skip).
        match parse_json_list(&g.depends_on) {
            Some(list) if !list.is_empty() => continue,
            None => continue,
            Some(_) => {}
        }

        // INFRA-314 skill affinity. skills_required parsed like the picker
        // (json.loads; non-JSON → empty = no requirement).
        let skills_required: HashSet<String> = parse_json_list(&g.skills_required)
            .unwrap_or_default()
            .into_iter()
            .map(|s| s.to_lowercase())
            .collect();
        if !skills_required.is_empty() && !skills_required.is_subset(worker_skills) {
            continue;
        }
        let affinity_score = skills_required.intersection(worker_skills).count() as i32;

        // FLEET-046 ship-history rebalance boost (within-band tiebreak only).
        let mut rebalance_boost = 0i32;
        let gap_domain = d_lo.to_uppercase();
        let gap_pillar = extract_pillar(&g.title);
        if !monopoly_domain.is_empty() && gap_domain != monopoly_domain {
            rebalance_boost += 2;
        }
        if let Some(pillar) = gap_pillar {
            if starved_pillars.contains(pillar) {
                rebalance_boost += 2;
            }
        }

        let key = SortKey {
            prio_rank: prio_rank(&g.priority),
            mission_rank: if is_mission_linked(g, &active_mission) {
                0
            } else {
                1
            },
            wedge_rank: -(affinity_score + rebalance_boost),
            effort_rank: effort_rank(&g.effort),
            age: g.created_at,
            id: g.id.clone(),
        };

        match &best {
            Some((best_key, _)) if *best_key <= key => {}
            _ => best = Some((key, idx)),
        }
    }

    Ok(best.map(|(_, idx)| open_gaps[idx].clone()))
}

// ── the claim ───────────────────────────────────────────────────────────────

/// Atomically claim a gap via the store's DB lease mechanism
/// (`GapStore::claim`), returning the lease record. Blocking; call from
/// `spawn_blocking`.
pub fn claim_gap(
    repo_root: &Path,
    gap_id: &str,
    worker: &str,
    ttl_secs: i64,
) -> Result<ClaimRecord, ClaimError> {
    let store = GapStore::open(repo_root)
        .map_err(|e| ClaimError::Internal(format!("opening gap store: {e}")))?;
    match store.claim(gap_id, worker, "", ttl_secs) {
        Ok(()) => Ok(ClaimRecord {
            gap_id: gap_id.to_string(),
            worker: worker.to_string(),
            worktree: String::new(),
            // GapStore::claim writes expires_at = unix_now() + ttl_secs; we
            // recompute it here (within-1s of the stored value).
            expires_at: now_secs() + ttl_secs,
            ttl_secs,
            status: "claimed".to_string(),
        }),
        Err(e) => {
            let msg = e.to_string();
            let low = msg.to_lowercase();
            if low.contains("live-claimed") || low.contains("already done") {
                Err(ClaimError::Conflict(msg))
            } else if low.contains("not found") {
                Err(ClaimError::NotFound(msg))
            } else {
                Err(ClaimError::Internal(msg))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_splits_and_trims() {
        assert_eq!(csv(Some("P0, P1 ,,P2")), vec!["P0", "P1", "P2"]);
        assert!(csv(None).is_empty());
        assert!(csv(Some("")).is_empty());
    }

    #[test]
    fn prio_and_effort_ranks() {
        assert!(prio_rank("P0") < prio_rank("P1"));
        assert!(prio_rank("P3") < prio_rank("garbage"));
        assert_eq!(prio_rank("p0"), 0);
        assert!(effort_rank("xs") < effort_rank("xl"));
        assert_eq!(effort_rank("weird"), 9);
    }

    #[test]
    fn extract_pillar_matches_prefix() {
        assert_eq!(extract_pillar("EFFECTIVE: do a thing"), Some("EFFECTIVE"));
        assert_eq!(extract_pillar("  zero-waste: trim"), Some("ZERO-WASTE"));
        assert_eq!(extract_pillar("INFRA: not a pillar"), None);
    }

    #[test]
    fn manufactured_junk_is_detected() {
        assert!(is_manufactured_pillar_starved_junk(
            "MISSION-RESILIENT: pillar starved refill"
        ));
        assert!(is_manufactured_pillar_starved_junk(
            "mission-zero-waste: the pillar starved again"
        ));
        assert!(!is_manufactured_pillar_starved_junk("INFRA: real work"));
        assert!(!is_manufactured_pillar_starved_junk(
            "MISSION-EFFECTIVE: ship a feature"
        ));
    }

    #[test]
    fn gap_id_from_branch_tail_parses() {
        assert_eq!(
            gap_id_from_branch_tail("INFRA-3966-fleet-abc").as_deref(),
            Some("INFRA-3966")
        );
        assert_eq!(
            gap_id_from_branch_tail("MISSION-42-x").as_deref(),
            Some("MISSION-42")
        );
        assert_eq!(gap_id_from_branch_tail("no-gap-here"), None);
        assert_eq!(gap_id_from_branch_tail("JUSTONE"), None);
    }

    #[test]
    fn parse_json_list_behaves_like_python_picker() {
        assert_eq!(parse_json_list(""), Some(Vec::new()));
        assert_eq!(parse_json_list("[]"), Some(Vec::new()));
        assert_eq!(
            parse_json_list("[\"INFRA-1\",\"INFRA-2\"]"),
            Some(vec!["INFRA-1".to_string(), "INFRA-2".to_string()])
        );
        // Non-JSON CSV → None (picker treats as skip for deps / empty for skills).
        assert_eq!(parse_json_list("rust,sqlite"), None);
    }

    #[test]
    fn rebalance_detects_monopoly_and_starvation() {
        let hist = vec![
            ("INFRA".to_string(), "INFRA: a".to_string()),
            ("INFRA".to_string(), "INFRA: b".to_string()),
            ("INFRA".to_string(), "EFFECTIVE: c".to_string()),
        ];
        let (monopoly, starved) = compute_rebalance_boosts(&hist, 70);
        assert_eq!(monopoly, "INFRA");
        // EFFECTIVE appeared, so it is NOT starved; CREDIBLE never did.
        assert!(!starved.contains("EFFECTIVE"));
        assert!(starved.contains("CREDIBLE"));
    }
}
