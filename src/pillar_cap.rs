//! CREDIBLE-072: per-pillar weekly merge-share cap and floor, applied at
//! `chump gap reserve` time.
//!
//! The share is computed over gaps closed (status `done`) in the last 7 days,
//! bucketed by pillar. A NEW gap whose pillar is already over
//! [`CAP_PCT`] of the week's merges is demoted to P2. When EFFECTIVE and
//! CREDIBLE together are under [`FLOOR_PCT`], a NEW gap in either of those
//! pillars is bumped one tier (P2→P1, P1→P0), with P0 bumps held to the
//! P0 budget of [`P0_BUDGET`]. `--cap-override <reason>` skips both rules.
//!
//! Disable entirely with `CHUMP_PILLAR_CAP=0` (e.g. synthetic test fixtures).

use std::collections::BTreeMap;

pub const PILLARS: [&str; 5] = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE", "MISSION"];
pub const CAP_PCT: f64 = 30.0;
pub const FLOOR_PCT: f64 = 50.0;
pub const WINDOW_SECS: i64 = 7 * 86_400;
pub const P0_BUDGET: usize = 5;

/// Pillar of a gap: the title's prefix tag (`RESILIENT: ...`) first, else a
/// domain that names a pillar (`CREDIBLE`, `ZERO`/`ZERO-WASTE`, ...).
pub fn pillar_of(title: &str, domain: &str) -> Option<&'static str> {
    let t = title.trim_start();
    if let Some(p) = PILLARS
        .iter()
        .find(|p| t.strip_prefix(**p).is_some_and(|rest| rest.starts_with(':')))
    {
        return Some(p);
    }
    match domain.trim().to_ascii_uppercase().as_str() {
        "ZERO" | "ZERO-WASTE" => Some("ZERO-WASTE"),
        d => PILLARS.iter().find(|p| **p == d).copied(),
    }
}

/// Rolling merge counts per pillar. `total` counts every merged gap in the
/// window, including ones with no pillar, so shares are of all merges.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Shares {
    pub total: u64,
    pub counts: BTreeMap<&'static str, u64>,
}

impl Shares {
    pub fn pct(&self, pillar: &str) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        let n = self.counts.get(pillar).copied().unwrap_or(0);
        n as f64 * 100.0 / self.total as f64
    }

    fn effective_plus_credible_pct(&self) -> f64 {
        self.pct("EFFECTIVE") + self.pct("CREDIBLE")
    }

    /// `Pillars: RESILIENT 63% [OVER CAP], EFFECTIVE 11% [under floor], ...`
    pub fn status_line(&self) -> String {
        if self.total == 0 {
            return "Pillars: no merges in the last 7d".to_string();
        }
        let under_floor = self.effective_plus_credible_pct() < FLOOR_PCT;
        let mut rows: Vec<(&str, f64)> = PILLARS.iter().map(|p| (*p, self.pct(p))).collect();
        rows.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let parts: Vec<String> = rows
            .iter()
            .map(|(p, pct)| {
                let tag = if *pct > CAP_PCT {
                    " [OVER CAP]"
                } else if under_floor && (*p == "EFFECTIVE" || *p == "CREDIBLE") {
                    " [under floor]"
                } else {
                    ""
                };
                format!("{p} {pct:.0}%{tag}")
            })
            .collect();
        format!("Pillars: {} ({} merges/7d)", parts.join(", "), self.total)
    }
}

/// Count gaps closed as `done` within `WINDOW_SECS` of `now`.
/// Each item is `(title, domain, status, closed_at_unix)`.
pub fn compute_shares<'a, I>(gaps: I, now: i64) -> Shares
where
    I: IntoIterator<Item = (&'a str, &'a str, &'a str, Option<i64>)>,
{
    let cutoff = now - WINDOW_SECS;
    let mut s = Shares::default();
    for (title, domain, status, closed_at) in gaps {
        if status != "done" || !closed_at.is_some_and(|c| c >= cutoff) {
            continue;
        }
        s.total += 1;
        if let Some(p) = pillar_of(title, domain) {
            *s.counts.entry(p).or_default() += 1;
        }
    }
    s
}

#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    Keep,
    Demote { to: &'static str },
    Bump { to: &'static str },
}

impl Decision {
    pub fn label(&self) -> &'static str {
        match self {
            Decision::Keep => "keep",
            Decision::Demote { .. } => "demote",
            Decision::Bump { .. } => "bump",
        }
    }
}

/// Priority decision for a NEW gap in `pillar` at `priority`.
pub fn decide(pillar: &str, priority: &str, shares: &Shares, open_p0: usize) -> Decision {
    if shares.total == 0 {
        return Decision::Keep;
    }
    if shares.pct(pillar) > CAP_PCT {
        return match priority {
            "P0" | "P1" => Decision::Demote { to: "P2" },
            _ => Decision::Keep,
        };
    }
    if (pillar == "EFFECTIVE" || pillar == "CREDIBLE")
        && shares.effective_plus_credible_pct() < FLOOR_PCT
    {
        return match priority {
            "P2" => Decision::Bump { to: "P1" },
            "P1" if open_p0 < P0_BUDGET => Decision::Bump { to: "P0" },
            _ => Decision::Keep,
        };
    }
    Decision::Keep
}

pub fn enabled() -> bool {
    std::env::var("CHUMP_PILLAR_CAP").map(|v| v != "0").unwrap_or(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn shares(rows: &[(&str, u64)], other: u64) -> Shares {
        let mut s = Shares::default();
        for (p, n) in rows {
            let p = PILLARS.iter().find(|x| *x == p).unwrap();
            s.counts.insert(p, *n);
            s.total += n;
        }
        s.total += other;
        s
    }

    #[test]
    fn pillar_of_prefers_title_tag_then_domain() {
        assert_eq!(pillar_of("RESILIENT: fix x", "INFRA"), Some("RESILIENT"));
        assert_eq!(pillar_of("ZERO-WASTE: trim", "INFRA"), Some("ZERO-WASTE"));
        assert_eq!(pillar_of("plain title", "CREDIBLE"), Some("CREDIBLE"));
        assert_eq!(pillar_of("plain title", "ZERO"), Some("ZERO-WASTE"));
        assert_eq!(pillar_of("RESILIENTLY: no", "INFRA"), None);
        assert_eq!(pillar_of("plain", "INFRA"), None);
    }

    #[test]
    fn compute_shares_counts_only_recent_done() {
        let old = NOW - WINDOW_SECS - 1;
        let gaps = [
            ("RESILIENT: a", "INFRA", "done", Some(NOW - 10)),
            ("RESILIENT: b", "INFRA", "done", Some(old)),
            ("EFFECTIVE: c", "INFRA", "open", None),
            ("plain", "INFRA", "done", Some(NOW - 5)),
        ];
        let s = compute_shares(gaps, NOW);
        assert_eq!(s.total, 2);
        assert_eq!(s.counts.get("RESILIENT"), Some(&1));
        assert_eq!(s.pct("RESILIENT"), 50.0);
    }

    #[test]
    fn over_cap_demotes_p0_p1_to_p2() {
        let s = shares(&[("RESILIENT", 5), ("EFFECTIVE", 3), ("CREDIBLE", 2)], 0);
        assert_eq!(decide("RESILIENT", "P1", &s, 0), Decision::Demote { to: "P2" });
        assert_eq!(decide("RESILIENT", "P0", &s, 0), Decision::Demote { to: "P2" });
        assert_eq!(decide("RESILIENT", "P2", &s, 0), Decision::Keep);
    }

    #[test]
    fn under_floor_bumps_effective_and_credible() {
        let s = shares(&[("RESILIENT", 3), ("EFFECTIVE", 1), ("ZERO-WASTE", 3)], 3);
        assert_eq!(decide("EFFECTIVE", "P2", &s, 0), Decision::Bump { to: "P1" });
        assert_eq!(decide("CREDIBLE", "P1", &s, 0), Decision::Bump { to: "P0" });
        // P0 budget full: no P1→P0 bump.
        assert_eq!(decide("CREDIBLE", "P1", &s, P0_BUDGET), Decision::Keep);
        assert_eq!(decide("CREDIBLE", "P3", &s, 0), Decision::Keep);
    }

    #[test]
    fn cap_wins_over_floor_and_no_data_keeps() {
        // EFFECTIVE alone is over cap while EFF+CRED is under the floor.
        let s = shares(&[("EFFECTIVE", 4)], 6);
        assert_eq!(decide("EFFECTIVE", "P1", &s, 0), Decision::Demote { to: "P2" });
        assert_eq!(decide("RESILIENT", "P1", &Shares::default(), 0), Decision::Keep);
    }

    #[test]
    fn status_line_flags_cap_and_floor() {
        let s = shares(&[("RESILIENT", 6), ("EFFECTIVE", 1)], 3);
        let line = s.status_line();
        assert!(line.starts_with("Pillars: RESILIENT 60% [OVER CAP]"), "{line}");
        assert!(line.contains("EFFECTIVE 10% [under floor]"), "{line}");
        assert_eq!(Shares::default().status_line(), "Pillars: no merges in the last 7d");
    }
}
