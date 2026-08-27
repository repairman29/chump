//! `chump cos digest` — operator Sunday digest (COS_OPERATING_MODEL.md Phase 1).
//!
//! INFRA-1616: adds the `## Curriculum` section — top skills by yield-weight,
//! skills whose Wilson CI moved week-over-week, new agent-proposed skills
//! awaiting operator approval, decaying (unused) skills, and anomalies
//! (high-attempt, low-success — likely a broken procedure).
//!
//! The Mission Yield section itself (chip-tag counts marcus/fleet-quality/
//! dev-tool/noise per PR) has no data source wired up yet — see
//! docs/process/COS_OPERATING_MODEL.md — so it renders a placeholder here.
//! This module focuses on the Curriculum section, which is fully backed by
//! `chump_skills` + the new `chump_skill_health_snapshots` table.

use anyhow::Result;

const DECAY_THRESHOLD_DAYS: u32 = 14;
const ANOMALY_MIN_N: u64 = 10;
const ANOMALY_MAX_RELIABILITY: f64 = 0.5;
const MOVED_THRESHOLD: f64 = 0.15;
const TOP_N: usize = 8;

fn env_hidden(name: &str) -> bool {
    std::env::var(name).map(|v| v == "1").unwrap_or(false)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TopSkillRow {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
    pub marcus: u64,
    pub fleet: u64,
    pub dev: u64,
    pub noise: u64,
    pub yield_weight: f64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct MovedSkillRow {
    pub name: String,
    pub prior_midpoint: f64,
    pub current_midpoint: f64,
    pub delta: f64,
    pub direction: &'static str,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct NewSkillRow {
    pub name: String,
    pub description: String,
    pub created_at: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AnomalySkillRow {
    pub name: String,
    pub n: u64,
    pub reliability: f64,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct CurriculumSection {
    pub top: Vec<TopSkillRow>,
    pub moved: Vec<MovedSkillRow>,
    pub new_skills: Vec<NewSkillRow>,
    pub decaying: Vec<String>,
    pub anomalies: Vec<AnomalySkillRow>,
}

/// Wilson CI midpoint — a single scalar proxy for "where does this skill's
/// reliability estimate currently sit" used for the week-over-week "moved" diff.
fn ci_midpoint(lower: f64, upper: f64) -> f64 {
    (lower + upper) / 2.0
}

/// Build the Curriculum section from current skill health + the prior week's
/// snapshot, taking (idempotently) this week's snapshot along the way so next
/// week's digest has something to diff against.
pub fn build_curriculum_section() -> Result<CurriculumSection> {
    let ranking = crate::skill_metrics::skill_health_ranking()?;

    // Record this week's snapshot (no-op if already taken this week_id).
    let week_id = crate::skill_db::current_week_id();
    let snapshots: Vec<crate::skill_db::SkillSnapshot> = ranking
        .iter()
        .map(|s| crate::skill_db::SkillSnapshot {
            name: s.name.clone(),
            use_count: s.use_count,
            success_count: s.success_count,
            failure_count: s.failure_count,
            reliability: s.reliability,
            confidence_lower: s.confidence_lower,
            confidence_upper: s.confidence_upper,
        })
        .collect();
    let _ = crate::skill_db::record_weekly_snapshot(week_id, &snapshots);

    let mut section = CurriculumSection::default();

    // Top-by-yield-weight (INFRA-1616 AC2). No chip-tag-to-skill attribution
    // pipeline exists yet (chip tags are per-PR, not per-skill-invocation), so
    // marcus/fleet/dev/noise columns are placeholders (0) pending that wiring;
    // yield_weight reuses the existing composite_score (reliability × recency
    // × use-count-weight) as the best available proxy.
    if !env_hidden("CHUMP_COS_HIDE_CURRICULUM_TOP") {
        let mut top: Vec<&crate::skill_metrics::SkillHealth> = ranking.iter().collect();
        top.sort_by(|a, b| {
            b.composite_score
                .partial_cmp(&a.composite_score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        section.top = top
            .into_iter()
            .take(TOP_N)
            .map(|s| TopSkillRow {
                name: s.name.clone(),
                n: s.use_count,
                reliability: s.reliability,
                marcus: 0,
                fleet: 0,
                dev: 0,
                noise: 0,
                yield_weight: s.composite_score,
            })
            .collect();
    }

    // Moved: Wilson CI midpoint shifted >0.15 vs the most recent prior week.
    if !env_hidden("CHUMP_COS_HIDE_CURRICULUM_MOVED") {
        let prior = crate::skill_db::latest_prior_snapshots(week_id)?;
        let prior_by_name: std::collections::HashMap<String, crate::skill_db::SkillSnapshot> =
            prior.into_iter().map(|s| (s.name.clone(), s)).collect();
        for s in &ranking {
            if let Some(p) = prior_by_name.get(&s.name) {
                let prior_mid = ci_midpoint(p.confidence_lower, p.confidence_upper);
                let current_mid = ci_midpoint(s.confidence_lower, s.confidence_upper);
                let delta = current_mid - prior_mid;
                if delta.abs() > MOVED_THRESHOLD {
                    section.moved.push(MovedSkillRow {
                        name: s.name.clone(),
                        prior_midpoint: prior_mid,
                        current_midpoint: current_mid,
                        delta,
                        direction: if delta > 0.0 { "up" } else { "down" },
                    });
                }
            }
        }
        section.moved.sort_by(|a, b| {
            b.delta
                .abs()
                .partial_cmp(&a.delta.abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    // New: agent-proposed via skill_manage create, not yet operator-endorsed.
    if !env_hidden("CHUMP_COS_HIDE_CURRICULUM_NEW") {
        if let Ok(records) = crate::skill_db::list_skill_records() {
            section.new_skills = records
                .into_iter()
                .filter(|r| !r.endorsed)
                .map(|r| NewSkillRow {
                    name: r.name,
                    description: r.description,
                    created_at: r.created_at,
                })
                .collect();
        }
    }

    // Decaying: no outcomes in 14d — retirement candidates.
    if !env_hidden("CHUMP_COS_HIDE_CURRICULUM_DECAYING") {
        section.decaying = ranking
            .iter()
            .filter(|s| match s.days_since_last_use {
                None => true,
                Some(d) => d >= DECAY_THRESHOLD_DAYS,
            })
            .map(|s| s.name.clone())
            .collect();
    }

    // Anomalies: n>=10 and reliability<0.5 — procedure-broken candidates.
    if !env_hidden("CHUMP_COS_HIDE_CURRICULUM_ANOMALIES") {
        section.anomalies = ranking
            .iter()
            .filter(|s| s.use_count >= ANOMALY_MIN_N && s.reliability < ANOMALY_MAX_RELIABILITY)
            .map(|s| AnomalySkillRow {
                name: s.name.clone(),
                n: s.use_count,
                reliability: s.reliability,
            })
            .collect();
    }

    Ok(section)
}

impl CurriculumSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("## Curriculum\n\n");

        if !self.top.is_empty() {
            out.push_str("### Top by yield-weight\n\n");
            out.push_str(
                "| skill | n | reliability | marcus | fleet | dev | noise | yield_weight |\n",
            );
            out.push_str("|---|---|---|---|---|---|---|---|\n");
            for r in &self.top {
                out.push_str(&format!(
                    "| {} | {} | {:.2} | {} | {} | {} | {} | {:.3} |\n",
                    r.name, r.n, r.reliability, r.marcus, r.fleet, r.dev, r.noise, r.yield_weight
                ));
            }
            out.push('\n');
        }

        out.push_str("### Moved\n\n");
        if self.moved.is_empty() {
            out.push_str("(no skills shifted >0.15 this week)\n\n");
        } else {
            for r in &self.moved {
                let arrow = if r.direction == "up" {
                    "\u{2191}"
                } else {
                    "\u{2193}"
                };
                out.push_str(&format!(
                    "- {} {} {:.2} \u{2192} {:.2} ({:+.2})\n",
                    r.name, arrow, r.prior_midpoint, r.current_midpoint, r.delta
                ));
            }
            out.push('\n');
        }

        out.push_str("### New\n\n");
        if self.new_skills.is_empty() {
            out.push_str("(no skills awaiting approval)\n\n");
        } else {
            for r in &self.new_skills {
                out.push_str(&format!("- {} — {}\n", r.name, r.description));
            }
            out.push('\n');
        }

        out.push_str("### Decaying\n\n");
        if self.decaying.is_empty() {
            out.push_str("(no decaying skills)\n\n");
        } else {
            for name in &self.decaying {
                out.push_str(&format!("- {}\n", name));
            }
            out.push('\n');
        }

        out.push_str("### Anomalies\n\n");
        if self.anomalies.is_empty() {
            out.push_str("(no anomalies)\n\n");
        } else {
            for r in &self.anomalies {
                out.push_str(&format!(
                    "- {} — n={} reliability={:.2}\n",
                    r.name, r.n, r.reliability
                ));
            }
            out.push('\n');
        }

        out
    }

    pub fn render_json(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or_else(|_| serde_json::json!({}))
    }
}

/// Full `chump cos digest --week` render (Mission Yield placeholder + Curriculum).
pub fn render_digest_text() -> Result<String> {
    let mut out = String::new();
    out.push_str("# COS Weekly Digest\n\n");
    out.push_str("## Mission Yield\n\n");
    out.push_str(
        "(chip-tag data source not wired up yet — see docs/process/COS_OPERATING_MODEL.md; \
         hand-generate per Phase 0 until INFRA lands the chip-tag pipeline)\n\n",
    );
    let curriculum = build_curriculum_section()?;
    out.push_str(&curriculum.render_text());
    Ok(out)
}

pub fn render_digest_json() -> Result<serde_json::Value> {
    let curriculum = build_curriculum_section()?;
    Ok(serde_json::json!({
        "mission_yield": serde_json::Value::Null,
        "curriculum": curriculum.render_json(),
    }))
}
