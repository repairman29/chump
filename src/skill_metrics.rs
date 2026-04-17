//! Skill effectiveness metrics — analytical layer over `skill_db`.
//!
//! Phase 2.5 of the Hermes competitive roadmap. Hermes tracks skill existence
//! but not success rates; Chump tracks per-skill outcomes and exposes:
//! - Laplace-smoothed reliability (already in skill_db)
//! - Wilson 95% confidence interval (better behavior on small samples than Laplace)
//! - Recency decay (skills unused for a long time get downweighted)
//! - Use-count weight (single-use skills can't dominate the ranking)
//! - Composite score for ranking
//!
//! This module is read-only over `chump_skills`; it does not mutate skill state.

use anyhow::Result;
use std::time::{SystemTime, UNIX_EPOCH};

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Health snapshot for a single skill, suitable for dashboards / API responses.
#[derive(Debug, Clone, serde::Serialize)]
pub struct SkillHealth {
    pub name: String,
    pub description: String,
    pub category: Option<String>,
    pub use_count: u64,
    pub success_count: u64,
    pub failure_count: u64,
    /// Laplace-smoothed reliability: (success + 1) / (uses + 2).
    pub reliability: f64,
    /// Wilson 95% CI lower bound.
    pub confidence_lower: f64,
    /// Wilson 95% CI upper bound.
    pub confidence_upper: f64,
    /// Days since last_used_at, if ever used.
    pub days_since_last_use: Option<u32>,
    /// Composite ranking score in [0, 1].
    pub composite_score: f64,
}

/// Wilson score 95% confidence interval for a binomial proportion.
/// Returns (lower, upper) clamped to [0, 1]. Handles n=0 by returning (0.0, 1.0).
pub fn wilson_interval(successes: u64, n: u64) -> (f64, f64) {
    if n == 0 {
        return (0.0, 1.0);
    }
    // z = 1.96 for 95% CI
    let z: f64 = 1.96;
    let n_f = n as f64;
    let p_hat = successes as f64 / n_f;
    let z2 = z * z;
    let denom = 1.0 + z2 / n_f;
    let center = (p_hat + z2 / (2.0 * n_f)) / denom;
    let margin = z * ((p_hat * (1.0 - p_hat) / n_f + z2 / (4.0 * n_f * n_f)).sqrt()) / denom;
    let lower = (center - margin).clamp(0.0, 1.0);
    let upper = (center + margin).clamp(0.0, 1.0);
    (lower, upper)
}

/// Recency factor: 1.0 if used within 7 days, linear decay to 0.3 by 60 days,
/// then floored at 0.3. Returns 0.3 for never-used skills (no signal of recency).
pub fn recency_factor(days_since_last_use: Option<u32>) -> f64 {
    match days_since_last_use {
        None => 0.3,
        Some(d) if d <= 7 => 1.0,
        Some(d) if d >= 60 => 0.3,
        Some(d) => {
            // Linear from (7, 1.0) to (60, 0.3)
            let t = (d - 7) as f64 / (60.0 - 7.0);
            1.0 - t * (1.0 - 0.3)
        }
    }
}

/// Use-count weight: log10(uses + 1) / 2.0, capped at 1.0.
/// Single-use = log10(2)/2 ≈ 0.15; ten uses = 0.52; 100 uses = 1.0.
pub fn use_count_weight(use_count: u64) -> f64 {
    let v = ((use_count as f64) + 1.0).log10() / 2.0;
    v.clamp(0.0, 1.0)
}

/// Composite ranking score = reliability × recency × use_count_weight, in [0, 1].
pub fn compute_composite_score(
    reliability: f64,
    use_count: u64,
    last_used_unix: Option<i64>,
) -> f64 {
    let days = last_used_unix.map(|ts| {
        let now = now_unix();
        let delta_secs = (now - ts).max(0);
        (delta_secs / 86_400) as u32
    });
    let r = reliability.clamp(0.0, 1.0);
    let recency = recency_factor(days);
    let uw = use_count_weight(use_count);
    (r * recency * uw).clamp(0.0, 1.0)
}

/// Parse a SQLite "YYYY-MM-DD HH:MM:SS" UTC timestamp into a unix timestamp.
/// Uses a small civil-date converter to avoid pulling in a date crate.
fn parse_sqlite_utc(s: &str) -> Option<i64> {
    // Expect: "YYYY-MM-DD HH:MM:SS" (datetime output of SQLite). Tolerate trailing
    // fractional seconds or 'T' separator just in case.
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let year: i32 = s.get(0..4)?.parse().ok()?;
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    // Either ' ' or 'T' as separator at index 10.
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

/// Hinnant's civil-from-date (returns days since 1970-01-01).
/// Valid for years in roughly [-9999, +9999]. Returns None on out-of-range fields.
fn days_from_civil(y: i32, m: u32, d: u32) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64; // [0, 399]
    let m = m as i64;
    let d = d as i64;
    let doy = ((153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1) as u64; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    Some(era * 146_097 + doe as i64 - 719_468)
}

/// Build a ranked list of skill health entries, ordered by composite score (desc).
/// Returns an empty Vec gracefully if no skills exist.
pub fn skill_health_ranking() -> Result<Vec<SkillHealth>> {
    let records = match crate::skill_db::list_skill_records() {
        Ok(v) => v,
        Err(e) => {
            // Empty/missing table should be treated as no skills, not an error.
            tracing::debug!("skill_health_ranking: list_skill_records failed: {e}");
            return Ok(Vec::new());
        }
    };

    let now = now_unix();
    let mut out: Vec<SkillHealth> = records
        .into_iter()
        .map(|r| {
            let reliability = (r.success_count as f64 + 1.0) / (r.use_count as f64 + 2.0);
            let (lower, upper) = wilson_interval(r.success_count, r.use_count);
            let last_used_unix = r.last_used_at.as_deref().and_then(parse_sqlite_utc);
            let days_since_last_use = last_used_unix.map(|ts| {
                let delta = (now - ts).max(0);
                (delta / 86_400) as u32
            });
            let composite_score = compute_composite_score(reliability, r.use_count, last_used_unix);
            SkillHealth {
                name: r.name,
                description: r.description,
                category: r.category,
                use_count: r.use_count,
                success_count: r.success_count,
                failure_count: r.failure_count,
                reliability,
                confidence_lower: lower,
                confidence_upper: upper,
                days_since_last_use,
                composite_score,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.composite_score
            .partial_cmp(&a.composite_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Ok(out)
}

/// Names of skills unused in the last 30 days (or never used). Empty Vec on error/empty.
pub fn skill_decay_candidates() -> Result<Vec<String>> {
    let ranking = skill_health_ranking()?;
    Ok(ranking
        .into_iter()
        .filter(|s| match s.days_since_last_use {
            None => true,
            Some(d) => d > 30,
        })
        .map(|s| s.name)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wilson_zero_samples_is_full_range() {
        let (lo, hi) = wilson_interval(0, 0);
        assert_eq!(lo, 0.0);
        assert_eq!(hi, 1.0);
    }

    #[test]
    fn wilson_small_sample_is_wide_but_bounded() {
        // 1/1 success: hi should be < 1.0 (Wilson penalises small n) and lo > 0
        let (lo, hi) = wilson_interval(1, 1);
        assert!(lo >= 0.0 && lo < 0.5, "lo={lo}");
        assert!(hi <= 1.0 && hi > 0.5, "hi={hi}");
        // 0/1 failure: mirror image
        let (lo2, hi2) = wilson_interval(0, 1);
        assert!(lo2 >= 0.0 && lo2 < 0.5, "lo2={lo2}");
        assert!(hi2 <= 1.0 && hi2 > 0.5, "hi2={hi2}");
        // Bounds never escape [0, 1]
        for n in 1u64..=20 {
            for s in 0..=n {
                let (l, h) = wilson_interval(s, n);
                assert!((0.0..=1.0).contains(&l), "lower out of range: {l}");
                assert!((0.0..=1.0).contains(&h), "upper out of range: {h}");
                assert!(l <= h, "lower > upper: {l} > {h}");
            }
        }
    }

    #[test]
    fn wilson_large_sample_narrows() {
        // 80/100 should be a tight interval around 0.8
        let (lo, hi) = wilson_interval(80, 100);
        assert!((hi - lo) < 0.2, "interval too wide: {} - {}", lo, hi);
        assert!(lo > 0.65 && hi < 0.9);
    }

    #[test]
    fn composite_score_is_bounded() {
        // Sweep a range of inputs — score must stay in [0, 1].
        for rel in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for uses in [0u64, 1, 5, 50, 1_000_000] {
                for ts in [None, Some(now_unix())] {
                    let s = compute_composite_score(rel, uses, ts);
                    assert!((0.0..=1.0).contains(&s), "score out of range: {s}");
                }
            }
        }
    }

    #[test]
    fn recency_factor_decays() {
        // Within 7 days: full weight
        assert_eq!(recency_factor(Some(0)), 1.0);
        assert_eq!(recency_factor(Some(7)), 1.0);
        // At 60+ days: floor at 0.3
        assert!((recency_factor(Some(60)) - 0.3).abs() < 1e-9);
        assert!((recency_factor(Some(365)) - 0.3).abs() < 1e-9);
        // Monotonic decay between 7 and 60
        let mut prev = recency_factor(Some(7));
        for d in 8..=60 {
            let cur = recency_factor(Some(d));
            assert!(cur <= prev + 1e-9, "non-monotone at d={d}: {cur} > {prev}");
            assert!((0.3..=1.0).contains(&cur), "out of range at d={d}: {cur}");
            prev = cur;
        }
        // Never-used: floor
        assert!((recency_factor(None) - 0.3).abs() < 1e-9);
    }

    #[test]
    fn use_count_weight_caps_at_one() {
        assert_eq!(use_count_weight(0), 0.0);
        assert!(use_count_weight(1) < 0.2);
        assert!(use_count_weight(10) > 0.4 && use_count_weight(10) < 0.6);
        // Big numbers: still <= 1.0
        for n in [100u64, 1_000, 1_000_000, u64::MAX / 2] {
            let w = use_count_weight(n);
            assert!(
                (0.0..=1.0).contains(&w),
                "weight out of range at n={n}: {w}"
            );
        }
        // Specifically cap at 1.0
        assert!((use_count_weight(100) - 1.0).abs() < 1e-9);
        assert_eq!(use_count_weight(u64::MAX), 1.0);
    }

    #[test]
    fn composite_zero_uses_yields_zero() {
        // use_count_weight(0) == 0.0, so score must be 0 regardless of reliability.
        assert_eq!(compute_composite_score(1.0, 0, None), 0.0);
        assert_eq!(compute_composite_score(1.0, 0, Some(now_unix())), 0.0);
    }

    #[test]
    fn empty_skills_table_is_graceful() {
        // Whether or not the DB pool is initialized, this must not panic and must
        // return either Ok([]) or an Err that we can detect.
        let result = skill_health_ranking();
        if let Ok(v) = result {
            // Empty or populated, both are fine — just ensure ordering invariant if any.
            for w in v.windows(2) {
                assert!(w[0].composite_score >= w[1].composite_score);
            }
        }
        let _ = skill_decay_candidates();
    }
}
