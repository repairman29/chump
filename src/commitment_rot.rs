//! RESILIENT-254 — Layer 5: commitment aging ("rot") SLOs.
//!
//! Layers 1–4 measure FLOW (ship-time, waste, restart success, silent agents)
//! and CAPACITY (P0 budget, pillar balance). None of them measures whether a
//! PROMISE is rotting. On 2026-08-08 four instances were found in one session
//! and not one of them tripped an SLO:
//!
//!   * the opus curator had been dead 12 days, exiting 78 every 600 s
//!     (RESILIENT-246) — nothing noticed;
//!   * MOP-BUCKET sat at 0 % with two open children and no shipped child;
//!   * the software-factory matrix's missing chairs sat parked since 08-05;
//!   * a large P2 tier looked like a one-way door.
//!
//! This module is the mechanical half of that. Authoritative definitions,
//! targets and escalations live in `docs/process/FLEET_SLOS.md` Layer 5; the
//! numbers below must match that document.
//!
//! Design constraints (from the gap, deliberate — not oversights):
//!
//!   * **The unit is the CLASS, never the individual gap.** No per-gap due
//!     dates are introduced anywhere in this file. A deadline on every gap is
//!     theatre; the honest unit is "this tier", "this outcome", "this organ".
//!   * **Deliberate parking must be expressible and must not breach.** A layer
//!     that pages for parked-on-purpose work teaches the operator to ignore it.
//!     Organs park via `parked:` in the registry; outcomes park via
//!     `chump outcome park <id> --reason "…"`.
//!   * **It rides the existing SLO plumbing.** These results are ordinary
//!     `SloResult`s appended by `fleet_health::check_slos`, so a breach exits
//!     non-zero from `chump health --slo-check` exactly like every other layer.
//!
//! Performance note: this module deliberately does NOT use
//! `fleet_health::parse_iso8601_to_unix`, which forks `date(1)` per line. The
//! operator's ambient log is ~69k lines; forking per line is what makes a full
//! `chump health --slo-check` take minutes. `parse_iso8601` below is pure Rust
//! so the L5 fast path (`--layer L5`) stays fast enough for the fleet-brief.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::fleet_health::SloResult;

// ── Tunables ──────────────────────────────────────────────────────────────────
// Every threshold is overridable by env so tests (and the operator) can probe a
// breach without waiting real days for one. Defaults are the documented targets.

/// L5-SLO-2: an open outcome with open children must show a shipped child
/// inside this window.
const OUTCOME_MOVEMENT_MAX_DAYS: u64 = 14;

/// L5-SLO-3: an open gap older than this is an aged commitment.
const AGED_OPEN_MAX_DAYS: u64 = 45;

/// L5-SLO-3: how many aged commitments one priority tier may hold before the
/// tier itself is judged a one-way door.
const AGED_TIER_BUDGET: usize = 5;

/// L5-SLO-1 is only evaluable where the fleet actually runs. If ambient shows
/// no events at all in this window we are on a laptop / CI box / fresh clone,
/// not the fleet host, and organ liveness is reported as "no data" rather than
/// breaching every organ at once.
const FLEET_HOST_ACTIVITY_WINDOW_SECS: u64 = 86_400;

/// Evidence timestamps further in the future than this are ignored. Observed
/// live on 2026-08-09: a `paramedic_heartbeat` carrying ts=2026-08-22 (clock
/// skew on one node). Trusting it would have made a dead organ look alive for
/// twelve days — exactly the failure this layer exists to catch.
const FUTURE_TS_TOLERANCE_SECS: u64 = 300;

/// Gap statuses that count as "still owed". Anything else has been adjudicated
/// (done/shipped/wontfix/superseded) or explicitly parked (`blocked`,
/// `perpetual`) and is therefore not rot.
const OPEN_STATUSES: &[&str] = &["open", "claimed", "in_progress", "in-progress"];

/// Gap statuses that count as movement — a child that actually got finished.
const SHIPPED_STATUSES: &[&str] = &["done", "closed", "shipped"];

/// Outcome statuses that L5-SLO-2 evaluates. Anything else (`done`, `parked`,
/// …) is out of scope by construction.
const EVALUATED_OUTCOME_STATUS: &str = "open";

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

// ── Organ registry ────────────────────────────────────────────────────────────

/// One load-bearing organ, as declared in the `load_bearing_organs:` section of
/// `scripts/coord/daemon-expectations.yaml`.
#[derive(Debug, Clone, Deserialize)]
pub struct OrganSpec {
    /// launchd label. Documentation only — see the registry header for why
    /// liveness is never read from `launchctl`.
    pub organ: String,
    #[serde(default)]
    pub description: String,
    /// Ambient `kind` values that prove the organ acted.
    #[serde(default)]
    pub evidence_kinds: Vec<String>,
    #[serde(default = "default_max_silence")]
    pub max_silence_secs: u64,
    /// Non-empty = deliberately parked, with the reason. Never breaches.
    #[serde(default)]
    pub parked: Option<String>,
}

fn default_max_silence() -> u64 {
    3600
}

#[derive(Debug, Deserialize)]
struct RegistryDoc {
    #[serde(default)]
    load_bearing_organs: Vec<OrganSpec>,
}

impl OrganSpec {
    /// A parked organ carries a non-empty reason.
    pub fn park_reason(&self) -> Option<&str> {
        self.parked
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }
}

/// Where the organ registry lives. `CHUMP_ORGAN_REGISTRY` overrides for tests.
pub fn organ_registry_path(repo_root: &Path) -> PathBuf {
    std::env::var("CHUMP_ORGAN_REGISTRY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join("scripts/coord/daemon-expectations.yaml"))
}

/// Parse the `load_bearing_organs:` section. `Err` carries a human reason so a
/// broken registry is reported loudly instead of silently passing.
pub fn load_organ_registry(repo_root: &Path) -> Result<Vec<OrganSpec>, String> {
    let path = organ_registry_path(repo_root);
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("cannot read organ registry {}: {}", path.display(), e))?;
    let doc: RegistryDoc = serde_yaml::from_str(&raw)
        .map_err(|e| format!("cannot parse organ registry {}: {}", path.display(), e))?;
    Ok(doc.load_bearing_organs)
}

// ── Ambient scanning (pure Rust, no per-line fork) ────────────────────────────

/// Extract the `kind` value from an ambient line, tolerating both shapes seen
/// live: `{"kind":"x"}` (compact emitters) and `{"kind": "x"}` (the Python and
/// jq emitters). `fleet_health::count_kind_since` only matches the first and
/// therefore under-counts — do not copy that pattern.
pub fn extract_kind(line: &str) -> Option<&str> {
    let idx = line.find("\"kind\"")?;
    let rest = &line[idx + 6..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(&rest[..end])
}

/// Extract the `ts` value from an ambient line (same two shapes).
fn extract_ts(line: &str) -> Option<&str> {
    let idx = line.find("\"ts\"")?;
    let rest = &line[idx + 4..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(&rest[..end])
}

/// Pure-Rust ISO-8601 → unix seconds for the `YYYY-MM-DDTHH:MM:SS[.fff][Z|±hh:mm]`
/// shapes the ambient stream actually contains. Returns None on anything else
/// rather than guessing.
pub fn parse_iso8601(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let num = |a: usize, z: usize| -> Option<i64> { s.get(a..z)?.parse::<i64>().ok() };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    // days_from_civil (Howard Hinnant), valid for the proleptic Gregorian calendar.
    let y_adj = if mo <= 2 { y - 1 } else { y };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = y_adj - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let mut secs = days * 86_400 + h * 3600 + mi * 60 + sec;
    // Trailing numeric offset, e.g. "+00:00" / "-07:00". A "Z" suffix is UTC.
    if let Some(tail) = s.get(19..) {
        let tail = tail.trim_end();
        let tail = tail.strip_prefix('.').map_or(tail, |frac| {
            let cut = frac
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(frac.len());
            &frac[cut..]
        });
        if let Some(off) = tail.strip_prefix('+').or_else(|| tail.strip_prefix('-')) {
            let sign = if tail.starts_with('-') { 1 } else { -1 };
            let oh: i64 = off.get(0..2).and_then(|v| v.parse().ok()).unwrap_or(0);
            let om: i64 = off.get(3..5).and_then(|v| v.parse().ok()).unwrap_or(0);
            secs += sign * (oh * 3600 + om * 60);
        }
    }
    u64::try_from(secs).ok()
}

/// Newest evidence timestamp per ambient `kind`, plus a count of events inside
/// the fleet-host activity window. One pass, no forks.
pub struct AmbientScan {
    pub last_seen: HashMap<String, u64>,
    pub events_in_activity_window: u64,
    /// Evidence lines rejected for carrying an implausible future timestamp.
    pub future_dated_skipped: u64,
}

pub fn scan_ambient(ambient_path: &Path, wanted: &[String], now: u64) -> AmbientScan {
    let mut scan = AmbientScan {
        last_seen: HashMap::new(),
        events_in_activity_window: 0,
        future_dated_skipped: 0,
    };
    let Ok(contents) = std::fs::read_to_string(ambient_path) else {
        return scan;
    };
    let activity_cutoff = now.saturating_sub(FLEET_HOST_ACTIVITY_WINDOW_SECS);
    let future_cutoff = now.saturating_add(FUTURE_TS_TOLERANCE_SECS);
    for line in contents.lines() {
        let Some(ts_raw) = extract_ts(line) else {
            continue;
        };
        let Some(ts) = parse_iso8601(ts_raw) else {
            continue;
        };
        if ts >= activity_cutoff && ts <= future_cutoff {
            scan.events_in_activity_window += 1;
        }
        let Some(kind) = extract_kind(line) else {
            continue;
        };
        if !wanted.iter().any(|w| w == kind) {
            continue;
        }
        if ts > future_cutoff {
            scan.future_dated_skipped += 1;
            continue;
        }
        let slot = scan.last_seen.entry(kind.to_string()).or_insert(0);
        if ts > *slot {
            *slot = ts;
        }
    }
    scan
}

// ── L5-SLO-1: organ liveness ──────────────────────────────────────────────────

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn ambient_path(repo_root: &Path) -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks/ambient.jsonl"))
}

fn fmt_age(secs: u64) -> String {
    if secs >= 86_400 {
        format!("{}d", secs / 86_400)
    } else if secs >= 3600 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}m", secs / 60)
    }
}

/// L5-SLO-1 — every load-bearing organ acted inside its own grace window.
pub fn check_organ_liveness(repo_root: &Path) -> SloResult {
    let organs = match load_organ_registry(repo_root) {
        Ok(o) => o,
        Err(e) => {
            return SloResult {
                id: "L5-SLO-1",
                target: ORGAN_TARGET,
                current: "no registry".into(),
                // A missing registry on a fresh clone is not a fleet regression;
                // it is an un-measurable state, and it says so out loud.
                breached: false,
                detail: format!("{e} — organ liveness NOT EVALUATED"),
            };
        }
    };
    evaluate_organs(&organs, &ambient_path(repo_root), now_unix())
}

const ORGAN_TARGET: &str = "every load-bearing organ acted within its grace window";

/// The measurable core of L5-SLO-1, split out so tests drive it with explicit
/// inputs instead of process-wide env vars (which race under `cargo test`).
pub fn evaluate_organs(organs: &[OrganSpec], ambient: &Path, now: u64) -> SloResult {
    let target = ORGAN_TARGET;
    if organs.is_empty() {
        return SloResult {
            id: "L5-SLO-1",
            target,
            current: "no organs".into(),
            breached: false,
            detail: "organ registry has no load_bearing_organs entries — nothing to measure".into(),
        };
    }

    let wanted: Vec<String> = organs
        .iter()
        .flat_map(|o| o.evidence_kinds.iter().cloned())
        .collect();
    let scan = scan_ambient(ambient, &wanted, now);

    // Not the fleet host → not evaluable. Reported, never breached: breaching
    // here would fire on every contributor's clone and in CI, and an SLO that
    // cries wolf on a laptop is an SLO the operator learns to skip.
    if scan.events_in_activity_window == 0 {
        return SloResult {
            id: "L5-SLO-1",
            target,
            current: "no data".into(),
            breached: false,
            detail: format!(
                "no ambient events in the last {}h — not a fleet host; organ liveness NOT EVALUATED",
                FLEET_HOST_ACTIVITY_WINDOW_SECS / 3600
            ),
        };
    }

    let mut dead: Vec<String> = Vec::new();
    let mut parked: Vec<String> = Vec::new();
    let mut alive = 0usize;
    for organ in organs {
        if let Some(reason) = organ.park_reason() {
            parked.push(format!("{} (parked: {})", organ.organ, reason));
            continue;
        }
        let last = organ
            .evidence_kinds
            .iter()
            .filter_map(|k| scan.last_seen.get(k).copied())
            .max();
        match last {
            Some(ts) if now.saturating_sub(ts) <= organ.max_silence_secs => alive += 1,
            Some(ts) => dead.push(format!(
                "{} silent {} (grace {})",
                organ.organ,
                fmt_age(now.saturating_sub(ts)),
                fmt_age(organ.max_silence_secs)
            )),
            None => dead.push(format!(
                "{} NO evidence in ambient at all (expects {})",
                organ.organ,
                organ.evidence_kinds.join("|")
            )),
        }
    }

    let mut detail = if dead.is_empty() {
        format!("{alive} load-bearing organ(s) acting inside grace")
    } else {
        format!("SILENT: {}", dead.join("; "))
    };
    if !parked.is_empty() {
        detail.push_str(&format!(" | {}", parked.join("; ")));
    }
    if scan.future_dated_skipped > 0 {
        detail.push_str(&format!(
            " | {} future-dated evidence line(s) ignored (clock skew)",
            scan.future_dated_skipped
        ));
    }
    // Parked organs are named in `current`, not just `detail`: the text
    // renderer only prints the detail line on a BREACH, so a parked organ that
    // lived only in `detail` would be invisible on every passing run — and
    // silent parking is how "deliberately parked" quietly becomes "forgotten".
    let mut current = format!("{} silent / {} organs", dead.len(), organs.len());
    if !parked.is_empty() {
        current.push_str(&format!(", {} parked", parked.len()));
    }
    SloResult {
        id: "L5-SLO-1",
        target,
        current,
        breached: !dead.is_empty(),
        detail,
    }
}

// ── L5-SLO-2: outcome movement ────────────────────────────────────────────────

/// L5-SLO-2 — an open outcome with open children shipped a child inside the
/// window. Parked outcomes (`status='parked'`) are out of scope by construction.
/// Driven from [`check_rot_slos`], which owns the single store load.
const OUTCOME_TARGET: &str = "open outcome with open children moved within 14d";

/// The measurable core of L5-SLO-2, split out for direct unit testing.
pub fn evaluate_outcome_movement(
    outcomes: &[chump_gap_store::OutcomeRow],
    gaps: &[chump_gap_store::GapRow],
    now: u64,
    window: u64,
) -> SloResult {
    let target = OUTCOME_TARGET;
    let max_days = window / 86_400;

    let mut open_children: HashMap<&str, usize> = HashMap::new();
    let mut last_ship: HashMap<&str, u64> = HashMap::new();
    for gap in gaps {
        let Some(oid) = gap.outcome_id.as_deref() else {
            continue;
        };
        if oid.is_empty() {
            continue;
        }
        if OPEN_STATUSES.contains(&gap.status.as_str()) {
            *open_children.entry(oid).or_insert(0) += 1;
        }
        if !SHIPPED_STATUSES.contains(&gap.status.as_str()) {
            continue;
        }
        let Some(closed) = gap.closed_at.filter(|c| *c > 0) else {
            continue;
        };
        let slot = last_ship.entry(oid).or_insert(0);
        if closed as u64 > *slot {
            *slot = closed as u64;
        }
    }

    let mut stalled: Vec<String> = Vec::new();
    let mut parked = 0usize;
    let mut evaluated = 0usize;
    for o in outcomes {
        if o.status != EVALUATED_OUTCOME_STATUS {
            if o.status == "parked" {
                parked += 1;
            }
            continue;
        }
        let kids = open_children.get(o.id.as_str()).copied().unwrap_or(0);
        if kids == 0 {
            // No open children = nothing is being owed. An outcome with NO
            // children at all is a planning gap, not rot; L5-SLO-2 does not
            // claim to catch it, and FLEET_SLOS.md says so.
            continue;
        }
        // Grace: an outcome younger than the window has not had time to move.
        if now.saturating_sub(o.created_at.max(0) as u64) < window {
            continue;
        }
        evaluated += 1;
        let moved = last_ship.get(o.id.as_str()).copied().unwrap_or(0);
        if now.saturating_sub(moved) > window {
            let since = if moved == 0 {
                "never".to_string()
            } else {
                fmt_age(now.saturating_sub(moved))
            };
            stalled.push(format!("{} ({} open, last ship {})", o.id, kids, since));
        }
    }

    let mut detail = if stalled.is_empty() {
        format!("{evaluated} evaluated outcome(s) shipped a child within {max_days}d")
    } else {
        format!("NO MOVEMENT in {}d: {}", max_days, stalled.join("; "))
    };
    if parked > 0 {
        detail.push_str(&format!(
            " | {parked} outcome(s) parked on purpose (not evaluated)"
        ));
    }
    SloResult {
        id: "L5-SLO-2",
        target,
        current: format!("{} stalled / {} evaluated", stalled.len(), evaluated),
        breached: !stalled.is_empty(),
        detail,
    }
}

// ── L5-SLO-3: no priority tier is a one-way door ──────────────────────────────

/// L5-SLO-3 — no priority tier holds more than `AGED_TIER_BUDGET` gaps that
/// have been open past `AGED_OPEN_MAX_DAYS` without adjudication.
///
/// The unit is the TIER, not the gap: nothing here puts a date on any single
/// gap. A tier over budget means the tier has become a one-way door, and the
/// escalation is to adjudicate the class — demote it, mark it `blocked` with a
/// named blocker, or refine it. Any of those three moves the gap out of
/// `status='open'`, so saying which is what clears the breach.
/// Driven from [`check_rot_slos`], which owns the single store load.
const AGED_TARGET: &str = "no priority tier > 5 gaps open past 45d unadjudicated";

/// The measurable core of L5-SLO-3, split out for direct unit testing.
pub fn evaluate_aged_commitments(
    gaps: &[chump_gap_store::GapRow],
    now: u64,
    max_days: u64,
    budget: usize,
) -> SloResult {
    let target = AGED_TARGET;
    let cutoff = now.saturating_sub(max_days * 86_400);

    let mut per_tier: HashMap<String, Vec<String>> = HashMap::new();
    for gap in gaps {
        if !OPEN_STATUSES.contains(&gap.status.as_str()) {
            continue;
        }
        if gap.created_at.max(0) as u64 >= cutoff {
            continue;
        }
        let tier = if gap.priority.trim().is_empty() {
            "unprioritised".to_string()
        } else {
            gap.priority.trim().to_string()
        };
        per_tier.entry(tier).or_default().push(gap.id.clone());
    }

    let mut over: Vec<(String, usize)> = per_tier
        .iter()
        .filter(|(_, ids)| ids.len() > budget)
        .map(|(t, ids)| (t.clone(), ids.len()))
        .collect();
    over.sort();
    let mut all: Vec<(String, usize)> =
        per_tier.iter().map(|(t, v)| (t.clone(), v.len())).collect();
    all.sort();
    let census = all
        .iter()
        .map(|(t, n)| format!("{t}:{n}"))
        .collect::<Vec<_>>()
        .join(" ");

    SloResult {
        id: "L5-SLO-3",
        target,
        current: format!("{} tier(s) over budget", over.len()),
        breached: !over.is_empty(),
        detail: if over.is_empty() {
            format!("aged-open census (>{max_days}d, budget {budget}/tier): [{census}]")
        } else {
            format!(
                "ONE-WAY DOOR: {} — aged-open census (>{}d, budget {}/tier): [{}]. Adjudicate the class: demote, mark blocked with a named blocker, or refine.",
                over.iter()
                    .map(|(t, n)| format!("{t} has {n}"))
                    .collect::<Vec<_>>()
                    .join(", "),
                max_days,
                budget,
                census
            )
        },
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

/// Evaluate every Layer-5 SLO. Called by `fleet_health::check_slos` (full run)
/// and directly by `chump health --slo-check --layer L5` (fast path).
///
/// Opens the gap store ONCE and shares one gap list across L5-SLO-2 and
/// L5-SLO-3. This runs on every fleet-brief, i.e. every session start; loading
/// ~3.5k rows twice to answer two questions is the kind of small, permanent
/// waste the fleet is supposed to notice.
pub fn check_rot_slos(repo_root: &Path) -> Vec<SloResult> {
    let organs = check_organ_liveness(repo_root);
    let now = now_unix();
    let outcome_window = env_u64("CHUMP_ROT_OUTCOME_MAX_DAYS", OUTCOME_MOVEMENT_MAX_DAYS) * 86_400;
    let aged_days = env_u64("CHUMP_ROT_AGED_MAX_DAYS", AGED_OPEN_MAX_DAYS);
    let aged_budget = env_usize("CHUMP_ROT_AGED_BUDGET", AGED_TIER_BUDGET);

    let Ok(store) = crate::gap_store::GapStore::open(repo_root) else {
        return vec![
            organs,
            store_unavailable("L5-SLO-2", OUTCOME_TARGET, "outcome movement"),
            store_unavailable("L5-SLO-3", AGED_TARGET, "aged commitments"),
        ];
    };
    let outcomes = store.list_outcomes().unwrap_or_default();
    let gaps = store.list(None).unwrap_or_default();

    vec![
        organs,
        evaluate_outcome_movement(&outcomes, &gaps, now, outcome_window),
        evaluate_aged_commitments(&gaps, now, aged_days, aged_budget),
    ]
}

fn store_unavailable(id: &'static str, target: &'static str, what: &str) -> SloResult {
    SloResult {
        id,
        target,
        current: "no store".into(),
        breached: false,
        detail: format!("gap store unavailable — {what} NOT EVALUATED"),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-r254-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn iso(ts: u64) -> String {
        // Inverse of parse_iso8601, good enough for fixtures.
        let days = ts / 86_400;
        let rem = ts % 86_400;
        let (mut y, mut doy) = (1970i64, days as i64);
        loop {
            let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
            let len = if leap { 366 } else { 365 };
            if doy < len {
                break;
            }
            doy -= len;
            y += 1;
        }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let ml = [
            31,
            if leap { 29 } else { 28 },
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        ];
        let mut m = 0;
        while doy >= ml[m] {
            doy -= ml[m];
            m += 1;
        }
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            y,
            m + 1,
            doy + 1,
            rem / 3600,
            (rem % 3600) / 60,
            rem % 60
        )
    }

    /// Parse a registry snippet through the SAME serde path production uses,
    /// so a schema mistake in `daemon-expectations.yaml` fails a test rather
    /// than silently disabling the layer.
    fn organs(body: &str) -> Vec<OrganSpec> {
        let doc: RegistryDoc = serde_yaml::from_str(body).expect("registry snippet must parse");
        doc.load_bearing_organs
    }

    fn ambient(root: &Path, lines: &[String]) -> PathBuf {
        std::fs::create_dir_all(root.join(".chump-locks")).unwrap();
        let p = root.join(".chump-locks/ambient.jsonl");
        std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        p
    }

    fn ev(ts: u64, kind: &str) -> String {
        format!("{{\"ts\":\"{}\",\"kind\":\"{}\"}}", iso(ts), kind)
    }

    #[test]
    fn parse_iso8601_roundtrips_known_instants() {
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso8601("2026-08-09T16:46:09Z"), Some(1_786_293_969));
        // Fractional seconds and explicit offsets both land on the same instant.
        assert_eq!(
            parse_iso8601("2026-08-09T16:46:09.123Z"),
            Some(1_786_293_969)
        );
        assert_eq!(
            parse_iso8601("2026-08-09T17:46:09+01:00"),
            Some(1_786_293_969)
        );
        assert_eq!(parse_iso8601("garbage"), None);
    }

    #[test]
    fn extract_kind_handles_both_emitter_shapes() {
        // Compact shape — the Rust/printf emitters.
        assert_eq!(
            extract_kind(r#"{"ts":"2026-08-09T00:00:00Z","kind":"reaper_run"}"#),
            Some("reaper_run")
        );
        // Spaced shape — the Python emitters. fleet_health::count_kind_since
        // misses this one; L5 must not.
        assert_eq!(
            extract_kind(r#"{"event": "reaper_run", "kind": "reaper_run", "x": 1}"#),
            Some("reaper_run")
        );
        assert_eq!(extract_kind(r#"{"ts":"x"}"#), None);
    }

    const CURATOR_REG: &str = "load_bearing_organs:\n  - organ: com.chump.opus-curator\n    evidence_kinds: [curator_decision, system_gap_tick]\n    max_silence_secs: 3600\n";

    /// AC-2: the curator's 12-day silence must be CAUGHT, not asserted.
    #[test]
    fn organ_liveness_catches_a_twelve_day_silence() {
        let root = tmpdir("organ-dead");
        let now = now_unix();
        // Curator last acted 12 days ago while the fleet is demonstrably alive
        // right now — that combination is the whole horror of RESILIENT-246.
        let amb = ambient(
            &root,
            &[
                ev(now - 12 * 86_400, "curator_decision"),
                ev(now - 60, "farmer_heartbeat"),
            ],
        );
        let r = evaluate_organs(&organs(CURATOR_REG), &amb, now);
        assert!(r.breached, "12-day curator silence must breach: {r:?}");
        assert!(r.detail.contains("opus-curator"), "names the organ: {r:?}");
        assert!(r.detail.contains("12d"), "states the silence: {r:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The same silence in the shape the live log actually had it: the curator
    /// emitted NOTHING at all (its events had rotated out of ambient).
    #[test]
    fn organ_liveness_catches_an_organ_with_no_evidence_at_all() {
        let root = tmpdir("organ-never");
        let now = now_unix();
        let amb = ambient(&root, &[ev(now - 60, "farmer_heartbeat")]);
        let r = evaluate_organs(&organs(CURATOR_REG), &amb, now);
        assert!(r.breached, "no evidence at all must breach: {r:?}");
        assert!(r.detail.contains("NO evidence"), "{r:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn organ_liveness_passes_when_the_organ_is_acting() {
        let root = tmpdir("organ-alive");
        let now = now_unix();
        let amb = ambient(&root, &[ev(now - 300, "curator_decision")]);
        let r = evaluate_organs(&organs(CURATOR_REG), &amb, now);
        assert!(!r.breached, "a fresh decision must pass: {r:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// AC-4: parking is expressible and must NOT breach.
    #[test]
    fn a_parked_organ_never_breaches() {
        let root = tmpdir("organ-parked");
        let now = now_unix();
        let reg = organs(
            "load_bearing_organs:\n  - organ: com.chump.acg-advisory\n    evidence_kinds: [acg_tick]\n    max_silence_secs: 3600\n    parked: \"ACG advisory track is parked ON PURPOSE\"\n",
        );
        let amb = ambient(&root, &[ev(now - 60, "farmer_heartbeat")]);
        let r = evaluate_organs(&reg, &amb, now);
        assert!(!r.breached, "parked-on-purpose must not page: {r:?}");
        assert!(r.detail.contains("parked"), "says it is parked: {r:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A future-dated heartbeat must not resurrect a dead organ. Observed live
    /// 2026-08-09: paramedic_heartbeat carrying ts=2026-08-22.
    #[test]
    fn future_dated_evidence_cannot_fake_liveness() {
        let root = tmpdir("organ-future");
        let now = now_unix();
        let amb = ambient(
            &root,
            &[
                ev(now + 13 * 86_400, "curator_decision"),
                ev(now - 60, "farmer_heartbeat"),
            ],
        );
        let r = evaluate_organs(&organs(CURATOR_REG), &amb, now);
        assert!(r.breached, "clock skew must not mask a dead organ: {r:?}");
        assert!(
            r.detail.contains("future-dated"),
            "says why it was ignored: {r:?}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn organ_liveness_is_not_evaluated_off_the_fleet_host() {
        let root = tmpdir("organ-nohost");
        let now = now_unix();
        // A clone whose ambient only holds long-rotated history: no events in
        // the activity window, so we are not on the fleet host.
        let amb = ambient(&root, &[ev(now - 40 * 86_400, "farmer_heartbeat")]);
        let r = evaluate_organs(&organs(CURATOR_REG), &amb, now);
        assert!(!r.breached, "a clone with no fleet must not page: {r:?}");
        assert!(r.current.contains("no data"), "{r:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    // ── L5-SLO-2 ─────────────────────────────────────────────────────────────

    fn outcome(id: &str, status: &str, age_days: u64, now: u64) -> chump_gap_store::OutcomeRow {
        chump_gap_store::OutcomeRow {
            id: id.into(),
            status: status.into(),
            created_at: (now - age_days * 86_400) as i64,
            ..Default::default()
        }
    }

    fn child(
        id: &str,
        outcome_id: &str,
        status: &str,
        closed_days_ago: Option<u64>,
        now: u64,
    ) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.into(),
            status: status.into(),
            outcome_id: Some(outcome_id.into()),
            created_at: (now - 30 * 86_400) as i64,
            closed_at: closed_days_ago.map(|d| (now - d * 86_400) as i64),
            ..Default::default()
        }
    }

    /// AC-3, in the shape MOP-BUCKET actually has: an outcome with two open
    /// children and not one shipped child.
    #[test]
    fn outcome_with_open_children_and_no_shipped_child_breaches() {
        let now = now_unix();
        let window = 14 * 86_400;
        let outs = vec![outcome("MOP-BUCKET", "open", 20, now)];
        let kids = vec![
            child("EFFECTIVE-374", "MOP-BUCKET", "open", None, now),
            child("CREDIBLE-209", "MOP-BUCKET", "open", None, now),
        ];
        let r = evaluate_outcome_movement(&outs, &kids, now, window);
        assert!(r.breached, "0% for 20d must breach: {r:?}");
        assert!(r.detail.contains("MOP-BUCKET"), "names it: {r:?}");
        assert!(r.detail.contains("never"), "says it never moved: {r:?}");
    }

    /// A young outcome gets grace — it has not had time to move yet. This is
    /// why MOP-BUCKET does not breach on the day it was created.
    #[test]
    fn a_young_outcome_is_inside_grace() {
        let now = now_unix();
        let outs = vec![outcome("MOP-BUCKET", "open", 2, now)];
        let kids = vec![child("EFFECTIVE-374", "MOP-BUCKET", "open", None, now)];
        let r = evaluate_outcome_movement(&outs, &kids, now, 14 * 86_400);
        assert!(!r.breached, "a 2-day-old outcome must not breach: {r:?}");
    }

    #[test]
    fn a_recently_shipped_child_is_movement() {
        let now = now_unix();
        let outs = vec![outcome("MOP-BUCKET", "open", 40, now)];
        let kids = vec![
            child("EFFECTIVE-374", "MOP-BUCKET", "open", None, now),
            child("CREDIBLE-209", "MOP-BUCKET", "done", Some(3), now),
        ];
        let r = evaluate_outcome_movement(&outs, &kids, now, 14 * 86_400);
        assert!(!r.breached, "a child shipped 3d ago is movement: {r:?}");
    }

    /// AC-4 for outcomes: the ACG-advisory case — parked on purpose, stalled
    /// for a year, and it must NOT page.
    #[test]
    fn a_parked_outcome_never_breaches() {
        let now = now_unix();
        let outs = vec![outcome("ACG-ADVISORY", "parked", 365, now)];
        let kids = vec![child("PRODUCT-001", "ACG-ADVISORY", "open", None, now)];
        let r = evaluate_outcome_movement(&outs, &kids, now, 14 * 86_400);
        assert!(!r.breached, "parked ON PURPOSE must not page: {r:?}");
        assert!(r.detail.contains("parked on purpose"), "{r:?}");
    }

    /// An outcome with no open children owes nothing — silence there is done,
    /// not rot.
    #[test]
    fn an_outcome_with_no_open_children_is_out_of_scope() {
        let now = now_unix();
        let outs = vec![outcome("DONE-ISH", "open", 365, now)];
        let kids = vec![child("X-1", "DONE-ISH", "done", Some(300), now)];
        let r = evaluate_outcome_movement(&outs, &kids, now, 14 * 86_400);
        assert!(!r.breached, "{r:?}");
    }

    // ── L5-SLO-3 ─────────────────────────────────────────────────────────────

    fn aged(
        id: &str,
        priority: &str,
        status: &str,
        age_days: u64,
        now: u64,
    ) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.into(),
            priority: priority.into(),
            status: status.into(),
            created_at: (now - age_days * 86_400) as i64,
            ..Default::default()
        }
    }

    #[test]
    fn a_tier_over_its_aged_budget_is_a_one_way_door() {
        let now = now_unix();
        let gaps: Vec<_> = (0..6)
            .map(|i| aged(&format!("P2-{i}"), "P2", "open", 60, now))
            .collect();
        let r = evaluate_aged_commitments(&gaps, now, 45, 5);
        assert!(r.breached, "6 > budget 5 must breach: {r:?}");
        assert!(r.detail.contains("P2 has 6"), "names the tier: {r:?}");
        // AC-5: the class is the unit — no individual gap id is dated or named
        // as overdue.
        assert!(
            !r.detail.contains("P2-0"),
            "must not put a due date on any single gap: {r:?}"
        );
    }

    #[test]
    fn a_tier_inside_budget_passes() {
        let now = now_unix();
        let gaps: Vec<_> = (0..5)
            .map(|i| aged(&format!("P2-{i}"), "P2", "open", 60, now))
            .collect();
        let r = evaluate_aged_commitments(&gaps, now, 45, 5);
        assert!(!r.breached, "{r:?}");
    }

    /// AC-4 for tiers: saying WHICH — demote, block, or refine — clears it.
    /// `blocked` is an adjudicated state, so it stops counting as rot.
    #[test]
    fn adjudicated_gaps_stop_counting_as_rot() {
        let now = now_unix();
        let mut gaps: Vec<_> = (0..6)
            .map(|i| aged(&format!("P2-{i}"), "P2", "open", 60, now))
            .collect();
        gaps[0].status = "blocked".into();
        gaps[1].status = "wontfix".into();
        let r = evaluate_aged_commitments(&gaps, now, 45, 5);
        assert!(!r.breached, "adjudication must clear the breach: {r:?}");
    }

    #[test]
    fn young_gaps_are_not_aged_commitments() {
        let now = now_unix();
        let gaps: Vec<_> = (0..50)
            .map(|i| aged(&format!("P2-{i}"), "P2", "open", 3, now))
            .collect();
        let r = evaluate_aged_commitments(&gaps, now, 45, 5);
        assert!(!r.breached, "a big young backlog is not rot: {r:?}");
    }

    /// The registry that actually ships must parse, declare organs, and give
    /// every one of them evidence kinds — a registry entry with no evidence
    /// kinds can never pass and would page forever.
    #[test]
    fn shipped_registry_is_well_formed() {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let specs = load_organ_registry(&root).expect("shipped registry must parse");
        assert!(
            !specs.is_empty(),
            "the shipped registry must declare load-bearing organs"
        );
        for s in &specs {
            assert!(
                !s.evidence_kinds.is_empty(),
                "{} has no evidence_kinds — it could never pass",
                s.organ
            );
            assert!(s.max_silence_secs > 0, "{} has zero grace", s.organ);
        }
        assert!(
            specs.iter().any(|s| s.organ.contains("opus-curator")),
            "the curator is the case this layer exists for; it must be registered"
        );
    }
}
