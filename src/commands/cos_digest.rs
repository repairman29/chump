//! INFRA-1616: `chump cos digest --week` Curriculum section — top-by-yield,
//! moved, new, decaying, anomalies. Operator weekly visibility into skill
//! health movement (docs/process/COS_OPERATING_MODEL.md,
//! docs/strategy/MISSION_YIELD.md).
//!
//! `chump cos digest` renders `## Mission Yield` (minimal — reads the
//! `chump_pr_chip_tag` table, which is populated by CREDIBLE-071's chip-tag
//! surface once that lands; reads as all-zero counts until then, which is
//! honest, not faked) followed by `## Curriculum` (this gap): skill health
//! built on `skill_metrics::skill_health_ranking` (already-shipped Wilson /
//! composite-score machinery) plus a weekly Wilson-midpoint snapshot table
//! (`chump_skill_wilson_snapshot`) for movement detection.
//!
//! Per-skill marcus/fleet/dev/noise chip counts (AC2) read from
//! `chump_skill_yield_count`, which INFRA-1614 is responsible for populating
//! via the `pr_chip_tagged.skills_invoked` correlation. Until INFRA-1614
//! ships, every skill reads 0 counts / 0 yield_weight — correct given no
//! correlation data exists yet, not a placeholder fake.
//!
//! Acceptance criteria satisfied:
//!   AC1 — `## Curriculum` renders after `## Mission Yield`
//!   AC2 — top-by-yield-weight table, top 5-8 rows
//!   AC3 — Moved subsection (|Wilson midpoint delta| > 0.15 vs last week)
//!   AC4 — New subsection (skills created within the window)
//!   AC5 — Decaying subsection (no outcomes in 14d)
//!   AC6 — Anomalies subsection (n>=10, reliability<0.5)
//!   AC7 — `--json` includes the same data under `.curriculum`
//!   AC8 — scripts/ci/test-cos-digest-curriculum.sh
//!   AC9 — per-subsection env var disable (CHUMP_COS_HIDE_CURRICULUM_<NAME>)

use anyhow::Result;
use chrono::Datelike;
use serde::Serialize;
use serde_json::json;

const DECAY_DAYS: u32 = 14;
const ANOMALY_MIN_N: u64 = 10;
const ANOMALY_MAX_RELIABILITY: f64 = 0.5;
const MOVED_THRESHOLD: f64 = 0.15;
const TOP_N: usize = 8;

pub fn run(args: &[String]) -> i32 {
    if args.first().map(String::as_str) != Some("digest") {
        eprintln!("usage: chump cos digest [--week] [--since YYYY-MM-DD] [--json]");
        return 2;
    }
    let rest = &args[1..];
    match run_digest(rest) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("chump cos digest: {e}");
            1
        }
    }
}

fn run_digest(args: &[String]) -> Result<i32> {
    let json_out = args.iter().any(|a| a == "--json");
    let since = parse_since(args)?;

    let mission_yield = compute_mission_yield(&since)?;
    let curriculum = compute_curriculum(&since)?;

    if json_out {
        let v = json!({
            "window_since": since.to_rfc3339(),
            "mission_yield": mission_yield,
            "curriculum": curriculum,
        });
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        print!("{}", render_markdown(&since, &mission_yield, &curriculum));
    }
    Ok(0)
}

fn parse_since(args: &[String]) -> Result<chrono::DateTime<chrono::Utc>> {
    let now = chrono::Utc::now();
    if let Some(pos) = args.iter().position(|a| a == "--since") {
        let raw = args
            .get(pos + 1)
            .ok_or_else(|| anyhow::anyhow!("--since requires a YYYY-MM-DD value"))?;
        let naive = chrono::NaiveDate::parse_from_str(raw, "%Y-%m-%d")
            .map_err(|e| anyhow::anyhow!("invalid --since date '{raw}': {e}"))?;
        let dt = naive
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| anyhow::anyhow!("invalid --since date"))?;
        return Ok(chrono::DateTime::from_naive_utc_and_offset(dt, chrono::Utc));
    }
    // Default and `--week` both mean "last 7 days".
    Ok(now - chrono::Duration::days(7))
}

fn week_start_key(now: &chrono::DateTime<chrono::Utc>) -> String {
    // ISO week Monday, as a stable "which week is this" partition key for the
    // wilson-snapshot table.
    let monday =
        now.date_naive() - chrono::Duration::days(now.weekday().num_days_from_monday() as i64);
    monday.format("%Y-%m-%d").to_string()
}

// ── Mission Yield (minimal; full computation is CREDIBLE-071's scope) ──────

#[derive(Debug, Clone, Default, Serialize)]
pub struct MissionYield {
    pub marcus: u64,
    pub fleet_quality: u64,
    pub dev_tool: u64,
    pub noise: u64,
    pub reverts_7d: u64,
}

fn compute_mission_yield(since: &chrono::DateTime<chrono::Utc>) -> Result<MissionYield> {
    let conn = crate::db_pool::get()?;
    let since_str = since.format("%Y-%m-%d %H:%M:%S").to_string();
    let mut out = MissionYield::default();
    // chump_pr_chip_tag is CREDIBLE-071's table; guard against it not
    // existing yet so `cos digest` works standalone.
    let table_exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chump_pr_chip_tag'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0)
        > 0;
    if !table_exists {
        return Ok(out);
    }
    let mut stmt = conn
        .prepare("SELECT tag, COUNT(*) FROM chump_pr_chip_tag WHERE set_at >= ?1 GROUP BY tag")?;
    let rows = stmt.query_map([&since_str], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))
    })?;
    for row in rows {
        let (tag, n) = row?;
        match tag.as_str() {
            "marcus" => out.marcus = n,
            "fleet-quality" => out.fleet_quality = n,
            "dev-tool" => out.dev_tool = n,
            "noise" => out.noise = n,
            _ => {}
        }
    }
    Ok(out)
}

// ── Curriculum (this gap) ───────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct TopSkillEntry {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
    pub marcus: u64,
    pub fleet_quality: u64,
    pub dev_tool: u64,
    pub noise: u64,
    pub yield_weight: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct MovedSkillEntry {
    pub name: String,
    pub prior_wilson: f64,
    pub current_wilson: f64,
    pub delta: f64,
    pub direction: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct NewSkillEntry {
    pub name: String,
    pub description: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DecayingSkillEntry {
    pub name: String,
    pub days_since_last_use: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AnomalySkillEntry {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Curriculum {
    pub top_by_yield: Vec<TopSkillEntry>,
    pub moved: Vec<MovedSkillEntry>,
    pub new_skills: Vec<NewSkillEntry>,
    pub decaying: Vec<DecayingSkillEntry>,
    pub anomalies: Vec<AnomalySkillEntry>,
}

fn yield_chip_counts(conn: &rusqlite::Connection, skill_name: &str) -> (u64, u64, u64, u64) {
    conn.query_row(
        "SELECT marcus, fleet_quality, dev_tool, noise FROM chump_skill_yield_count WHERE skill_name = ?1",
        [skill_name],
        |r| {
            Ok((
                r.get::<_, i64>(0)? as u64,
                r.get::<_, i64>(1)? as u64,
                r.get::<_, i64>(2)? as u64,
                r.get::<_, i64>(3)? as u64,
            ))
        },
    )
    .unwrap_or((0, 0, 0, 0))
}

fn compute_curriculum(since: &chrono::DateTime<chrono::Utc>) -> Result<Curriculum> {
    let conn = crate::db_pool::get()?;
    let ranking = crate::skill_metrics::skill_health_ranking()?;
    let records = crate::skill_db::list_skill_records().unwrap_or_default();

    // Top-by-yield-weight.
    let mut top: Vec<TopSkillEntry> = ranking
        .iter()
        .map(|h| {
            let (marcus, fleet_quality, dev_tool, noise) = yield_chip_counts(&conn, &h.name);
            let attempts = marcus + fleet_quality + dev_tool + noise;
            let yield_weight = if attempts == 0 {
                0.0
            } else {
                (marcus + fleet_quality + dev_tool) as f64 / attempts as f64
            };
            TopSkillEntry {
                name: h.name.clone(),
                n: h.use_count,
                reliability: h.reliability,
                marcus,
                fleet_quality,
                dev_tool,
                noise,
                yield_weight,
            }
        })
        .collect();
    top.sort_by(|a, b| {
        b.yield_weight
            .partial_cmp(&a.yield_weight)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.reliability
                    .partial_cmp(&a.reliability)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });
    top.truncate(TOP_N);

    // Moved: compare this week's Wilson midpoint against last week's stored snapshot.
    let now = chrono::Utc::now();
    let this_week = week_start_key(&now);
    let last_week = week_start_key(&(now - chrono::Duration::days(7)));
    let mut moved = Vec::new();
    for h in &ranking {
        let current_wilson = (h.confidence_lower + h.confidence_upper) / 2.0;
        let prior: Option<f64> = conn
            .query_row(
                "SELECT wilson_point FROM chump_skill_wilson_snapshot WHERE skill_name = ?1 AND week_start = ?2",
                rusqlite::params![h.name, last_week],
                |r| r.get(0),
            )
            .ok();
        if let Some(prior_wilson) = prior {
            let delta = current_wilson - prior_wilson;
            if delta.abs() > MOVED_THRESHOLD {
                moved.push(MovedSkillEntry {
                    name: h.name.clone(),
                    prior_wilson,
                    current_wilson,
                    delta,
                    direction: if delta > 0.0 { "up" } else { "down" },
                });
            }
        }
        // Record this week's snapshot so next week's run has something to diff against.
        conn.execute(
            "INSERT INTO chump_skill_wilson_snapshot (skill_name, week_start, wilson_point) \
             VALUES (?1, ?2, ?3) \
             ON CONFLICT(skill_name, week_start) DO UPDATE SET wilson_point = excluded.wilson_point",
            rusqlite::params![h.name, this_week, current_wilson],
        )?;
    }
    moved.sort_by(|a, b| {
        b.delta
            .abs()
            .partial_cmp(&a.delta.abs())
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // New: skills created within the window.
    let since_str = since.format("%Y-%m-%d %H:%M:%S").to_string();
    let mut new_skills: Vec<NewSkillEntry> = records
        .iter()
        .filter(|r| r.created_at.as_str() >= since_str.as_str())
        .map(|r| NewSkillEntry {
            name: r.name.clone(),
            description: r.description.clone(),
            created_at: r.created_at.clone(),
        })
        .collect();
    new_skills.sort_by(|a, b| b.created_at.cmp(&a.created_at));

    // Decaying: no outcomes in DECAY_DAYS.
    let mut decaying: Vec<DecayingSkillEntry> = ranking
        .iter()
        .filter(|h| match h.days_since_last_use {
            None => true,
            Some(d) => d > DECAY_DAYS,
        })
        .map(|h| DecayingSkillEntry {
            name: h.name.clone(),
            days_since_last_use: h.days_since_last_use,
        })
        .collect();
    decaying.sort_by(|a, b| {
        b.days_since_last_use
            .unwrap_or(u32::MAX)
            .cmp(&a.days_since_last_use.unwrap_or(u32::MAX))
    });

    // Anomalies: n >= ANOMALY_MIN_N and reliability < ANOMALY_MAX_RELIABILITY.
    let mut anomalies: Vec<AnomalySkillEntry> = ranking
        .iter()
        .filter(|h| h.use_count >= ANOMALY_MIN_N && h.reliability < ANOMALY_MAX_RELIABILITY)
        .map(|h| AnomalySkillEntry {
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

    Ok(Curriculum {
        top_by_yield: top,
        moved,
        new_skills,
        decaying,
        anomalies,
    })
}

// ── Rendering ────────────────────────────────────────────────────────────

fn hide(env_suffix: &str) -> bool {
    std::env::var(format!("CHUMP_COS_HIDE_CURRICULUM_{env_suffix}"))
        .map(|v| v == "1")
        .unwrap_or(false)
}

fn render_markdown(
    since: &chrono::DateTime<chrono::Utc>,
    my: &MissionYield,
    c: &Curriculum,
) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "# COS Digest ({} → now)\n\n",
        since.format("%Y-%m-%d")
    ));

    out.push_str("## Mission Yield\n\n");
    out.push_str(&format!(
        "  marcus:        {}\n  fleet-quality: {}\n  dev-tool:      {}\n  noise:         {}\n  reverts (7d):  {}\n\n",
        my.marcus, my.fleet_quality, my.dev_tool, my.noise, my.reverts_7d
    ));

    if hide("ALL") {
        return out;
    }

    out.push_str("## Curriculum\n\n");

    if !hide("TOP") {
        out.push_str("### Top by yield\n\n");
        if c.top_by_yield.is_empty() {
            out.push_str("(no skills recorded)\n\n");
        } else {
            out.push_str(
                "| skill | n | reliability | marcus | fleet | dev | noise | yield_weight |\n",
            );
            out.push_str("|---|---|---|---|---|---|---|---|\n");
            for s in &c.top_by_yield {
                out.push_str(&format!(
                    "| {} | {} | {:.2} | {} | {} | {} | {} | {:.2} |\n",
                    s.name,
                    s.n,
                    s.reliability,
                    s.marcus,
                    s.fleet_quality,
                    s.dev_tool,
                    s.noise,
                    s.yield_weight
                ));
            }
            out.push('\n');
        }
    }

    if !hide("MOVED") {
        out.push_str("### Moved\n\n");
        if c.moved.is_empty() {
            out.push_str("(no skills shifted > 0.15 this week)\n\n");
        } else {
            for m in &c.moved {
                let arrow = if m.direction == "up" { "↑" } else { "↓" };
                out.push_str(&format!(
                    "- {arrow} {} — {:.2} → {:.2} ({:+.2})\n",
                    m.name, m.prior_wilson, m.current_wilson, m.delta
                ));
            }
            out.push('\n');
        }
    }

    if !hide("NEW") {
        out.push_str("### New\n\n");
        if c.new_skills.is_empty() {
            out.push_str("(no new skills proposed this window)\n\n");
        } else {
            for s in &c.new_skills {
                out.push_str(&format!(
                    "- {} — {} (created {})\n",
                    s.name, s.description, s.created_at
                ));
            }
            out.push('\n');
        }
    }

    if !hide("DECAYING") {
        out.push_str("### Decaying\n\n");
        if c.decaying.is_empty() {
            out.push_str("(no retirement candidates)\n\n");
        } else {
            for s in &c.decaying {
                match s.days_since_last_use {
                    Some(d) => out.push_str(&format!("- {} — unused {}d\n", s.name, d)),
                    None => out.push_str(&format!("- {} — never used\n", s.name)),
                }
            }
            out.push('\n');
        }
    }

    if !hide("ANOMALIES") {
        out.push_str("### Anomalies\n\n");
        if c.anomalies.is_empty() {
            out.push_str("(no broken-procedure candidates)\n\n");
        } else {
            for s in &c.anomalies {
                out.push_str(&format!(
                    "- {} — n={}, reliability={:.2}\n",
                    s.name, s.n, s.reliability
                ));
            }
            out.push('\n');
        }
    }

    out
}
