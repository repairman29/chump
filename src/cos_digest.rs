//! INFRA-1616: `chump cos digest` — Curriculum section.
//!
//! Renders the operator-facing weekly view into skill/procedure health so
//! the agent learning loop (chump_skills reliability tracking, see
//! `skill_db.rs` / `skill_metrics.rs`) doesn't silently decay unnoticed.
//!
//! The full Mission Yield computation (marcus/fleet-quality/dev-tool/noise
//! chip-tag aggregation, see `docs/strategy/MISSION_YIELD.md`) is owned by
//! CREDIBLE-071 and is not yet wired — the per-skill marcus/fleet/dev/noise
//! attribution in the "top by yield" table below is owned by INFRA-1614
//! (`pr_chip_tagged.skills_invoked` correlation) and defaults to zero until
//! that lands. This module renders the Curriculum section with the data
//! that exists today (`chump_skills` reliability/use-count/recency) and is
//! additive-safe: it does not block on either dependency.
//!
//! ## Ambient events
//!
//! `cos_digest_skill_snapshot` — one per skill, emitted only when the CLI is
//! invoked with `--emit`. Used to detect week-over-week Wilson-interval
//! movement (the "Moved" subsection) by diffing against the most recent
//! prior-week snapshot found in `.chump-locks/ambient.jsonl`.
//!
//! ```json
//! {"ts":"...","kind":"cos_digest_skill_snapshot","name":"foo","wilson_mid":0.62}
//! ```

use std::path::Path;

use crate::skill_db;
use crate::skill_metrics;

/// Wilson-CI shift threshold that qualifies a skill for the "Moved" subsection.
const MOVED_THRESHOLD: f64 = 0.15;
/// Days of no outcomes before a skill is considered decaying / a retirement candidate.
const DECAY_DAYS: u32 = 14;
/// Minimum use count for a skill to be eligible for the anomaly (broken-procedure) check.
const ANOMALY_MIN_N: u64 = 10;
/// Reliability ceiling below which a well-exercised skill is flagged as an anomaly.
const ANOMALY_MAX_RELIABILITY: f64 = 0.5;
/// Max rows rendered in the top-by-yield table.
const TOP_MAX_ROWS: usize = 8;

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct TopSkillRow {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
    /// Placeholder until INFRA-1614 wires per-skill chip attribution.
    pub marcus: u64,
    pub fleet: u64,
    pub dev: u64,
    pub noise: u64,
    pub yield_weight: f64,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct MovedSkill {
    pub name: String,
    pub from_wilson_mid: f64,
    pub to_wilson_mid: f64,
    /// "up" or "down".
    pub direction: String,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct NewSkill {
    pub name: String,
    pub description: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct DecayingSkill {
    pub name: String,
    pub days_since_last_use: Option<u32>,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct AnomalySkill {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Curriculum {
    pub top: Vec<TopSkillRow>,
    pub moved: Vec<MovedSkill>,
    pub new_skills: Vec<NewSkill>,
    pub decaying: Vec<DecayingSkill>,
    pub anomalies: Vec<AnomalySkill>,
}

/// Build the Curriculum snapshot for the given window. Gracefully returns an
/// empty (but correctly-shaped) `Curriculum` when the skill DB is unavailable
/// or empty — this is a normal state (fresh install / no skills yet).
pub fn build_curriculum(repo_root: &Path, since_secs: u64) -> Curriculum {
    let records = skill_db::list_skill_records().unwrap_or_default();
    let ranking = skill_metrics::skill_health_ranking().unwrap_or_default();

    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs as i64);

    // Top-by-yield-weight: composite_score stands in for yield_weight until
    // INFRA-1614 wires real marcus/fleet/dev/noise chip attribution per skill.
    let mut top: Vec<TopSkillRow> = ranking
        .iter()
        .map(|h| TopSkillRow {
            name: h.name.clone(),
            n: h.use_count,
            reliability: h.reliability,
            marcus: 0,
            fleet: 0,
            dev: 0,
            noise: 0,
            yield_weight: h.composite_score,
        })
        .collect();
    top.truncate(TOP_MAX_ROWS);

    // Moved: diff current Wilson midpoint against the most recent snapshot
    // from before this window, read out of ambient.jsonl.
    let prior_snapshots = read_prior_snapshots(repo_root, cutoff);
    let mut moved = Vec::new();
    for h in &ranking {
        if let Some(&prev_mid) = prior_snapshots.get(&h.name) {
            let cur_mid = (h.confidence_lower + h.confidence_upper) / 2.0;
            let delta = cur_mid - prev_mid;
            if delta.abs() > MOVED_THRESHOLD {
                moved.push(MovedSkill {
                    name: h.name.clone(),
                    from_wilson_mid: prev_mid,
                    to_wilson_mid: cur_mid,
                    direction: if delta > 0.0 {
                        "up".to_string()
                    } else {
                        "down".to_string()
                    },
                });
            }
        }
    }
    moved.sort_by(|a, b| {
        (b.to_wilson_mid - b.from_wilson_mid)
            .abs()
            .partial_cmp(&(a.to_wilson_mid - a.from_wilson_mid).abs())
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // New: proposed within the window and never yet exercised — the closest
    // proxy we have to "awaiting operator approval" without a dedicated
    // endorsed/proposed column in `chump_skills`.
    let mut new_skills: Vec<NewSkill> = records
        .iter()
        .filter(|r| r.use_count == 0)
        .filter(|r| {
            parse_sqlite_utc(&r.created_at)
                .map(|ts| ts >= cutoff)
                .unwrap_or(true)
        })
        .map(|r| NewSkill {
            name: r.name.clone(),
            description: r.description.clone(),
            created_at: r.created_at.clone(),
        })
        .collect();
    new_skills.sort_by(|a, b| a.name.cmp(&b.name));

    // Decaying: no outcomes (or never exercised) in DECAY_DAYS+.
    let mut decaying: Vec<DecayingSkill> = ranking
        .iter()
        .filter(|h| match h.days_since_last_use {
            Some(d) => d >= DECAY_DAYS,
            None => {
                // Never used — decaying only once it's old enough that "new" no
                // longer applies (avoids double-counting fresh proposals).
                records
                    .iter()
                    .find(|r| r.name == h.name)
                    .and_then(|r| parse_sqlite_utc(&r.created_at))
                    .map(|ts| now.saturating_sub(ts) >= DECAY_DAYS as i64 * 86_400)
                    .unwrap_or(false)
            }
        })
        .map(|h| DecayingSkill {
            name: h.name.clone(),
            days_since_last_use: h.days_since_last_use,
        })
        .collect();
    decaying.sort_by(|a, b| a.name.cmp(&b.name));

    // Anomalies: heavily-used but unreliable — likely a broken procedure.
    let mut anomalies: Vec<AnomalySkill> = ranking
        .iter()
        .filter(|h| h.use_count >= ANOMALY_MIN_N && h.reliability < ANOMALY_MAX_RELIABILITY)
        .map(|h| AnomalySkill {
            name: h.name.clone(),
            n: h.use_count,
            reliability: h.reliability,
        })
        .collect();
    anomalies.sort_by(|a, b| {
        a.reliability
            .partial_cmp(&b.reliability)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Curriculum {
        top,
        moved,
        new_skills,
        decaying,
        anomalies,
    }
}

/// Emit one `cos_digest_skill_snapshot` event per currently-known skill so a
/// future digest run can compute week-over-week movement.
pub fn emit_snapshots(repo_root: &Path) {
    let ranking = skill_metrics::skill_health_ranking().unwrap_or_default();
    if ranking.is_empty() {
        return;
    }
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    use std::io::Write as IoWrite;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        for h in &ranking {
            let mid = (h.confidence_lower + h.confidence_upper) / 2.0;
            let _ = writeln!(
                f,
                r#"{{"ts":"{ts}","kind":"cos_digest_skill_snapshot","name":"{name}","wilson_mid":{mid:.6}}}"#,
                ts = ts,
                name = json_escape(&h.name),
                mid = mid,
            );
        }
    }
}

/// Read the most recent `cos_digest_skill_snapshot` per skill name, from
/// events strictly older than `cutoff` (unix seconds) — i.e. from before the
/// current digest window began.
fn read_prior_snapshots(repo_root: &Path, cutoff: i64) -> std::collections::HashMap<String, f64> {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let mut latest: std::collections::HashMap<String, (i64, f64)> =
        std::collections::HashMap::new();
    for line in contents.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("cos_digest_skill_snapshot") {
            continue;
        }
        let ts = v
            .get("ts")
            .and_then(|t| t.as_str())
            .and_then(parse_iso8601_to_unix)
            .unwrap_or(0);
        if ts >= cutoff {
            continue; // only interested in snapshots from before this window
        }
        let name = match v.get("name").and_then(|n| n.as_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let mid = v.get("wilson_mid").and_then(|m| m.as_f64()).unwrap_or(0.0);
        latest
            .entry(name)
            .and_modify(|(prev_ts, prev_mid)| {
                if ts > *prev_ts {
                    *prev_ts = ts;
                    *prev_mid = mid;
                }
            })
            .or_insert((ts, mid));
    }
    latest.into_iter().map(|(k, (_, mid))| (k, mid)).collect()
}

// ── Rendering ────────────────────────────────────────────────────────────────

fn hidden(env_var: &str) -> bool {
    std::env::var(env_var).map(|v| v == "1").unwrap_or(false)
}

/// Render the (currently stub) Mission Yield section. Full computation is
/// CREDIBLE-071's scope; this exists only so the Curriculum section has a
/// well-defined anchor to render "after" per INFRA-1616 AC1.
pub fn render_mission_yield_stub_markdown() -> String {
    "## Mission Yield\n\n\
     (chip-tag aggregation not yet wired — see CREDIBLE-071)\n\n"
        .to_string()
}

pub fn render_curriculum_markdown(c: &Curriculum) -> String {
    let mut out = String::from("## Curriculum\n\n");

    if !hidden("CHUMP_COS_HIDE_CURRICULUM_TOP") {
        out.push_str("### Top by yield-weight\n\n");
        if c.top.is_empty() {
            out.push_str("(no skills recorded yet)\n\n");
        } else {
            out.push_str(
                "| skill | n | reliability | marcus | fleet | dev | noise | yield_weight |\n",
            );
            out.push_str("|---|---|---|---|---|---|---|---|\n");
            for r in &c.top {
                out.push_str(&format!(
                    "| {} | {} | {:.2} | {} | {} | {} | {} | {:.3} |\n",
                    r.name, r.n, r.reliability, r.marcus, r.fleet, r.dev, r.noise, r.yield_weight
                ));
            }
            out.push('\n');
        }
    }

    if !hidden("CHUMP_COS_HIDE_CURRICULUM_MOVED") {
        out.push_str("### Moved\n\n");
        if c.moved.is_empty() {
            out.push_str("(no skills shifted >0.15 Wilson CI this week)\n\n");
        } else {
            for m in &c.moved {
                let arrow = if m.direction == "up" { "^" } else { "v" };
                out.push_str(&format!(
                    "- {} {} {:.2} -> {:.2}\n",
                    m.name, arrow, m.from_wilson_mid, m.to_wilson_mid
                ));
            }
            out.push('\n');
        }
    }

    if !hidden("CHUMP_COS_HIDE_CURRICULUM_NEW") {
        out.push_str("### New\n\n");
        if c.new_skills.is_empty() {
            out.push_str("(no new skills proposed this week)\n\n");
        } else {
            for n in &c.new_skills {
                out.push_str(&format!("- {} — {}\n", n.name, n.description));
            }
            out.push('\n');
        }
    }

    if !hidden("CHUMP_COS_HIDE_CURRICULUM_DECAYING") {
        out.push_str("### Decaying\n\n");
        if c.decaying.is_empty() {
            out.push_str("(no retirement candidates)\n\n");
        } else {
            for d in &c.decaying {
                match d.days_since_last_use {
                    Some(days) => out.push_str(&format!("- {} — unused {}d\n", d.name, days)),
                    None => out.push_str(&format!("- {} — never used\n", d.name)),
                }
            }
            out.push('\n');
        }
    }

    if !hidden("CHUMP_COS_HIDE_CURRICULUM_ANOMALIES") {
        out.push_str("### Anomalies\n\n");
        if c.anomalies.is_empty() {
            out.push_str("(no broken-procedure candidates)\n\n");
        } else {
            for a in &c.anomalies {
                out.push_str(&format!(
                    "- {} — n={} reliability={:.2}\n",
                    a.name, a.n, a.reliability
                ));
            }
            out.push('\n');
        }
    }

    out
}

pub fn render_curriculum_json(c: &Curriculum) -> serde_json::Value {
    serde_json::json!({
        "top": c.top,
        "moved": c.moved,
        "new": c.new_skills,
        "decaying": c.decaying,
        "anomalies": c.anomalies,
    })
}

// ── Small time helpers (mirrors health.rs's local helpers) ────────────────────

fn current_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn current_iso8601() -> String {
    let secs = current_unix();
    iso8601_from_unix(secs)
}

fn iso8601_from_unix(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let hh = rem / 3600;
    let mm = (rem % 3600) / 60;
    let ss = rem % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, hh, mm, ss)
}

fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d)
}

fn parse_iso8601_to_unix(s: &str) -> Option<i64> {
    parse_sqlite_utc(s.replace('T', " ").trim_end_matches('Z'))
}

/// Parse a SQLite "YYYY-MM-DD HH:MM:SS" (or ISO8601-ish) UTC timestamp into a
/// unix timestamp. Mirrors `skill_metrics::parse_sqlite_utc` (private there).
fn parse_sqlite_utc(s: &str) -> Option<i64> {
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let year: i32 = s.get(0..4)?.parse().ok()?;
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    let sep = bytes[10];
    if sep != b' ' && sep != b'T' {
        return None;
    }
    let hour: u32 = s.get(11..13)?.parse().ok()?;
    let minute: u32 = s.get(14..16)?.parse().ok()?;
    let second: u32 = s.get(17..19)?.parse().ok()?;
    days_from_civil(year, month, day)
        .map(|days| days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64)
}

fn days_from_civil(y: i32, m: u32, d: u32) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let m = m as i64;
    let d = d as i64;
    let doy = ((153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1) as u64;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146_097 + doe as i64 - 719_468)
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_roundtrip_is_stable_for_known_date() {
        // 2026-05-16T00:00:00Z
        let secs = parse_sqlite_utc("2026-05-16 00:00:00").unwrap();
        assert_eq!(iso8601_from_unix(secs), "2026-05-16T00:00:00Z");
    }

    #[test]
    fn empty_curriculum_has_empty_but_valid_shape() {
        let c = Curriculum::default();
        assert!(c.top.is_empty());
        assert!(c.moved.is_empty());
        assert!(c.new_skills.is_empty());
        assert!(c.decaying.is_empty());
        assert!(c.anomalies.is_empty());
        let md = render_curriculum_markdown(&c);
        assert!(md.contains("### Top by yield-weight"));
        assert!(md.contains("### Moved"));
        assert!(md.contains("### New"));
        assert!(md.contains("### Decaying"));
        assert!(md.contains("### Anomalies"));
    }

    #[test]
    fn hide_env_var_suppresses_subsection() {
        std::env::set_var("CHUMP_COS_HIDE_CURRICULUM_ANOMALIES", "1");
        let c = Curriculum::default();
        let md = render_curriculum_markdown(&c);
        assert!(!md.contains("### Anomalies"));
        std::env::remove_var("CHUMP_COS_HIDE_CURRICULUM_ANOMALIES");
    }
}
