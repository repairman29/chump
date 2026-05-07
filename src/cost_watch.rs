//! INFRA-608: `chump cost-watch` — running tally of Anthropic spend vs per-cycle budget.
//!
//! Reads `kind=session_end` rows from `.chump-locks/ambient.jsonl`, groups by model,
//! computes today's spend (UTC), projects monthly, and warns when over budget.
//!
//! Budget threshold: `--budget X` flag or `CHUMP_DAILY_BUDGET` env var (default $5.00/day).
//! Hard-cap mode: `--hard-cap` exits 1 when today's spend exceeds the budget.

use std::collections::BTreeMap;
use std::path::Path;

/// Per-model spend summary.
#[derive(Debug, Default, Clone)]
pub struct ModelSpend {
    pub model: String,
    pub sessions: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cost_usd: f64,
}

/// Full cost-watch report.
#[derive(Debug)]
pub struct CostWatchReport {
    pub today_spend_usd: f64,
    pub projected_monthly_usd: f64,
    pub budget_usd_per_day: f64,
    pub over_budget: bool,
    pub by_model: Vec<ModelSpend>,
    /// UTC date string for display, e.g. "2026-05-06"
    pub date_utc: String,
}

impl CostWatchReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let indicator = if self.over_budget { "🔴" } else { "🟢" };
        out.push_str(&format!("═══ Cost Watch ({}) ═══\n", self.date_utc));
        out.push_str(&format!(
            "  Today:     ${:.4}  (budget ${:.2}/day)  {}\n",
            self.today_spend_usd, self.budget_usd_per_day, indicator
        ));
        out.push_str(&format!(
            "  Monthly ▶  ${:.2}  (projected)\n",
            self.projected_monthly_usd
        ));
        if !self.by_model.is_empty() {
            out.push_str("\n  By model:\n");
            for m in &self.by_model {
                out.push_str(&format!(
                    "    {:<30}  sessions={:>3}  ${:.4}\n",
                    m.model, m.sessions, m.cost_usd
                ));
            }
        }
        out
    }

    pub fn render_json(&self) -> String {
        let models_json: Vec<String> = self
            .by_model
            .iter()
            .map(|m| {
                format!(
                    r#"{{"model":"{}","sessions":{},"input_tokens":{},"output_tokens":{},"cache_read_tokens":{},"cost_usd":{:.6}}}"#,
                    json_escape(&m.model),
                    m.sessions,
                    m.input_tokens,
                    m.output_tokens,
                    m.cache_read_tokens,
                    m.cost_usd
                )
            })
            .collect();
        format!(
            r#"{{"date_utc":"{}","today_spend_usd":{:.6},"projected_monthly_usd":{:.4},"budget_usd_per_day":{:.2},"over_budget":{},"by_model":[{}]}}"#,
            self.date_utc,
            self.today_spend_usd,
            self.projected_monthly_usd,
            self.budget_usd_per_day,
            self.over_budget,
            models_json.join(",")
        )
    }
}

/// Build the cost-watch report by scanning `ambient.jsonl`.
pub fn build_report(repo_root: &Path, budget_usd_per_day: f64) -> CostWatchReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // UTC midnight for today (seconds since epoch).
    let now_unix = current_unix();
    let today_start_unix = now_unix - (now_unix % 86_400);
    let date_utc = unix_to_date_utc(today_start_unix);

    let mut by_model: BTreeMap<String, ModelSpend> = BTreeMap::new();

    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < today_start_unix {
            continue;
        }
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
        let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
        let cost = crate::session_ledger::cost_usd_from_tokens(input, output, cache);

        let entry = by_model.entry(model.clone()).or_insert_with(|| ModelSpend {
            model: model.clone(),
            ..Default::default()
        });
        entry.sessions += 1;
        entry.input_tokens += input;
        entry.output_tokens += output;
        entry.cache_read_tokens += cache;
        entry.cost_usd += cost;
    }

    let today_spend_usd: f64 = by_model.values().map(|m| m.cost_usd).sum();
    // Project: today's spend extrapolated to 30 days.
    let hours_elapsed = ((now_unix - today_start_unix) as f64 / 3600.0).max(1.0);
    let daily_rate = today_spend_usd * 24.0 / hours_elapsed;
    let projected_monthly_usd = daily_rate * 30.0;

    let over_budget = today_spend_usd > budget_usd_per_day;

    let by_model_vec: Vec<ModelSpend> = by_model.into_values().collect();

    CostWatchReport {
        today_spend_usd,
        projected_monthly_usd,
        budget_usd_per_day,
        over_budget,
        by_model: by_model_vec,
        date_utc,
    }
}

fn current_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn unix_to_date_utc(ts: u64) -> String {
    // Simple Julian-day conversion — no chrono needed.
    let days = ts / 86_400;
    // Algorithm from https://en.wikipedia.org/wiki/Julian_day#Julian_or_Gregorian_calendar_from_Julian_day_number
    let j = days as i64 + 2_440_588; // Unix epoch = JD 2440588
    let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h = 5 * g + 2;
    let day = (h % 153) / 5 + 1;
    let month = (h / 153 + 2) % 12 + 1;
    let year = e / 1461 - 4716 + (14 - month as i64) / 12;
    format!("{:04}-{:02}-{:02}", year, month, day)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    // Expect format "2026-05-06T12:34:56Z" (subset only).
    let s = s.trim_end_matches('Z');
    let mut parts = s.splitn(2, 'T');
    let date_part = parts.next()?;
    let time_part = parts.next().unwrap_or("00:00:00");
    let mut dp = date_part.splitn(3, '-');
    let year: i64 = dp.next()?.parse().ok()?;
    let month: i64 = dp.next()?.parse().ok()?;
    let day: i64 = dp.next()?.parse().ok()?;
    let mut tp = time_part.splitn(3, ':');
    let hour: u64 = tp.next()?.parse().ok()?;
    let min: u64 = tp.next()?.parse().ok()?;
    let sec: u64 = tp
        .next()
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    // Days since Unix epoch via simplified formula.
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32_045;
    let unix_epoch_jdn: i64 = 2_440_588;
    let days = (jdn - unix_epoch_jdn) as u64;
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":" "#, field).replace(" ", "");
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    if rest.starts_with('"') {
        let inner = &rest[1..];
        let end = inner.find('"')?;
        Some(inner[..end].to_string())
    } else {
        let end = rest.find([',', '}']).unwrap_or(rest.len());
        let v = rest[..end].trim().to_string();
        if v == "null" {
            None
        } else {
            Some(v)
        }
    }
}

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    extract_field(line, field)?.parse().ok()
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unix_to_date_utc() {
        // 2026-05-06T00:00:00Z = 1746489600
        assert_eq!(unix_to_date_utc(1_746_489_600), "2026-05-06");
    }

    #[test]
    fn test_parse_iso8601() {
        assert_eq!(
            parse_iso8601_to_unix("2026-05-06T00:00:00Z"),
            Some(1_746_489_600)
        );
    }

    #[test]
    fn test_extract_field() {
        let line = r#"{"kind":"session_end","model":"claude-sonnet","input_tokens":1000}"#;
        assert_eq!(
            extract_field(line, "model").as_deref(),
            Some("claude-sonnet")
        );
        assert_eq!(extract_int_field(line, "input_tokens"), Some(1000));
    }

    #[test]
    fn test_build_report_empty() {
        let dir = tempfile::tempdir().unwrap();
        let report = build_report(dir.path(), 5.0);
        assert_eq!(report.today_spend_usd, 0.0);
        assert!(!report.over_budget);
    }

    #[test]
    fn test_over_budget_flag() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Write a session_end with today's timestamp and huge token counts.
        let now = current_unix();
        let ts = format!("{}T12:00:00Z", unix_to_date_utc(now - now % 86_400));
        let line = format!(
            r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000000,"output_tokens":500000,"cache_read_tokens":0}}"#
        );
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        writeln!(f, "{}", line).unwrap();
        let report = build_report(dir.path(), 1.0); // $1 budget
        assert!(report.today_spend_usd > 1.0);
        assert!(report.over_budget);
    }
}
