//! INFRA-640 / INFRA-729: `chump kpi report --tokens-per-ship N`
//!
//! Extends INFRA-617 with a rolling tokens-per-ship calculation.
//! For each shipped gap in the last N days, sums token_usage events
//! (kind=token_usage_partial and kind=session_end) linked to its gap_id.
//!
//! Output:
//!   - Per-ship detail table: PR #, gap_id, backend, model, calls, tokens, cost
//!   - P50 / P90 / Max tokens-per-ship per backend
//!   - $/ship at current Sonnet pricing
//!   - Top-5 most expensive ships (gap_id, tokens, cost)

use std::collections::BTreeMap;
use std::path::Path;

/// Per-ship token summary.
#[derive(Debug, Clone)]
pub struct ShipTokens {
    pub gap_id: String,
    pub pr_number: Option<i64>,
    pub backend: String,
    pub model: String,
    pub call_count: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub total_tokens: u64,
    pub cost_usd: f64,
    pub shipped: bool,
}

/// Full tokens-per-ship report.
#[derive(Debug)]
pub struct TokensPerShipReport {
    pub window_days: u64,
    pub ship_count: usize,
    /// All shipped gaps with token counts, sorted by cost descending.
    pub ships: Vec<ShipTokens>,
    /// Per-backend stats
    pub backend_stats: BTreeMap<String, BackendStats>,
    /// P50 total tokens across ships (None if no ships).
    pub p50_tokens: Option<u64>,
    /// P90 total tokens across ships (None if no ships).
    pub p90_tokens: Option<u64>,
    /// Max total tokens across ships (None if no ships).
    pub max_tokens: Option<u64>,
    /// P50 cost in USD.
    pub p50_cost_usd: Option<f64>,
    /// P90 cost in USD.
    pub p90_cost_usd: Option<f64>,
    /// Max cost in USD.
    pub max_cost_usd: Option<f64>,
    /// Top-5 most expensive ships, sorted descending by cost.
    pub top5: Vec<ShipTokens>,
}

#[derive(Debug, Clone)]
pub struct BackendStats {
    pub backend: String,
    pub ship_count: usize,
    pub p50_tokens: Option<u64>,
    pub p90_tokens: Option<u64>,
    pub max_tokens: Option<u64>,
    pub p50_cost_usd: Option<f64>,
    pub p90_cost_usd: Option<f64>,
    pub max_cost_usd: Option<f64>,
}

impl TokensPerShipReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Tokens-per-Ship Report (last {} days) ═══\n",
            self.window_days
        ));
        out.push_str(&format!("  Ships analysed: {}\n", self.ship_count));
        if self.ship_count == 0 {
            out.push_str("  No shipped gaps with token data in window.\n");
            return out;
        }

        out.push_str("\n  Per-Ship Details:\n");
        out.push_str(&format!(
            "    {:<8}  {:<15}  {:<10}  {:<15}  {:<7}  {:>12}  {:>10}\n",
            "PR#", "gap_id", "backend", "model", "calls", "total_tokens", "cost_usd"
        ));
        for s in &self.ships {
            let pr_str = s
                .pr_number
                .map(|n| format!("#{}", n))
                .unwrap_or_else(|| "-".to_string());
            out.push_str(&format!(
                "    {:<8}  {:<15}  {:<10}  {:<15}  {:<7}  {:>12}  ${:.4}\n",
                pr_str, s.gap_id, s.backend, s.model, s.call_count, s.total_tokens, s.cost_usd
            ));
        }

        let fmt_tok = |v: Option<u64>| {
            v.map(|n| format!("{:>10}", n))
                .unwrap_or_else(|| "         —".to_string())
        };
        let fmt_usd = |v: Option<f64>| {
            v.map(|d| format!("${:.4}", d))
                .unwrap_or_else(|| "      —".to_string())
        };

        out.push_str("\n  Overall Tokens per ship:\n");
        out.push_str(&format!(
            "    P50:  {}  ({})\n",
            fmt_tok(self.p50_tokens),
            fmt_usd(self.p50_cost_usd)
        ));
        out.push_str(&format!(
            "    P90:  {}  ({})\n",
            fmt_tok(self.p90_tokens),
            fmt_usd(self.p90_cost_usd)
        ));
        out.push_str(&format!(
            "    Max:  {}  ({})\n",
            fmt_tok(self.max_tokens),
            fmt_usd(self.max_cost_usd)
        ));

        if !self.backend_stats.is_empty() {
            out.push_str("\n  Per-Backend Stats:\n");
            for (backend, stats) in &self.backend_stats {
                out.push_str(&format!("    {}:\n", backend));
                out.push_str(&format!(
                    "      P50:  {}  ({})\n",
                    fmt_tok(stats.p50_tokens),
                    fmt_usd(stats.p50_cost_usd)
                ));
                out.push_str(&format!(
                    "      P90:  {}  ({})\n",
                    fmt_tok(stats.p90_tokens),
                    fmt_usd(stats.p90_cost_usd)
                ));
                out.push_str(&format!(
                    "      Max:  {}  ({})\n",
                    fmt_tok(stats.max_tokens),
                    fmt_usd(stats.max_cost_usd)
                ));
            }
        }

        if !self.top5.is_empty() {
            out.push_str("\n  Top-5 most expensive ships:\n");
            out.push_str(&format!(
                "    {:<20}  {:>12}  {:>10}\n",
                "gap_id", "total_tokens", "cost_usd"
            ));
            for s in &self.top5 {
                out.push_str(&format!(
                    "    {:<20}  {:>12}  ${:.4}\n",
                    s.gap_id, s.total_tokens, s.cost_usd
                ));
            }
        }
        out
    }

    pub fn render_json(&self) -> String {
        let ships_json: Vec<String> = self
            .ships
            .iter()
            .map(|s| {
                let pr_str = s.pr_number
                    .map(|n| format!("\"pr_number\":{}", n))
                    .unwrap_or_else(|| "\"pr_number\":null".to_string());
                format!(
                    r#"{{"gap_id":"{}",{},"backend":"{}","model":"{}","calls":{},"input_tokens":{},"output_tokens":{},"cache_read_tokens":{},"total_tokens":{},"cost_usd":{:.6},"shipped":{}}}"#,
                    json_escape(&s.gap_id),
                    pr_str,
                    json_escape(&s.backend),
                    json_escape(&s.model),
                    s.call_count,
                    s.input_tokens,
                    s.output_tokens,
                    s.cache_read_tokens,
                    s.total_tokens,
                    s.cost_usd,
                    s.shipped
                )
            })
            .collect();
        let opt_u64 = |v: Option<u64>| {
            v.map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        };
        let opt_f64 = |v: Option<f64>| {
            v.map(|d| format!("{:.6}", d))
                .unwrap_or_else(|| "null".to_string())
        };
        format!(
            r#"{{"window_days":{},"ship_count":{},"ships":[{}],"p50_tokens":{},"p90_tokens":{},"max_tokens":{},"p50_cost_usd":{},"p90_cost_usd":{},"max_cost_usd":{}}}"#,
            self.window_days,
            self.ship_count,
            ships_json.join(","),
            opt_u64(self.p50_tokens),
            opt_u64(self.p90_tokens),
            opt_u64(self.max_tokens),
            opt_f64(self.p50_cost_usd),
            opt_f64(self.p90_cost_usd),
            opt_f64(self.max_cost_usd)
        )
    }
}

/// Build the tokens-per-ship report by scanning `ambient.jsonl`.
///
/// Algorithm:
/// 1. Collect all `kind=session_end` rows with `outcome=shipped` in the
///    window, accumulating tokens per gap_id.
/// 2. Also fold in any `kind=token_usage_partial` rows that carry a gap_id
///    (forward-compat: these may arrive before session_end in future).
/// 3. Count events per gap for call_count.
/// 4. Look up PR numbers from gap store.
/// 5. Compute P50/P90/Max across ships; rank top-5 by cost.
/// 6. Compute per-backend stats.
pub fn build_report(repo_root: &Path, window_days: u64) -> TokensPerShipReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    // gap_id → (input, output, cache, event_count)
    let mut per_gap: BTreeMap<String, (u64, u64, u64, u32)> = BTreeMap::new();
    // gap_ids that were shipped (to filter non-shipped gaps).
    let mut shipped_gaps: std::collections::HashSet<String> = std::collections::HashSet::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff {
            continue;
        }

        match kind.as_str() {
            "session_end" => {
                let gap_id = match extract_field(line, "gap_id") {
                    Some(g) => g,
                    None => continue,
                };
                let outcome = extract_field(line, "outcome").unwrap_or_default();
                let input = extract_int_field(line, "input_tokens").unwrap_or(0);
                let output = extract_int_field(line, "output_tokens").unwrap_or(0);
                let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);

                let entry = per_gap.entry(gap_id.clone()).or_insert((0, 0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;
                entry.3 += 1;

                if outcome == "shipped" {
                    shipped_gaps.insert(gap_id);
                }
            }
            "token_usage_partial" => {
                let gap_id = match extract_field(line, "gap_id") {
                    Some(g) => g,
                    None => continue,
                };
                let input = extract_int_field(line, "input_tokens").unwrap_or(0);
                let output = extract_int_field(line, "output_tokens").unwrap_or(0);
                let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
                let entry = per_gap.entry(gap_id).or_insert((0, 0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;
                entry.3 += 1;
            }
            _ => {}
        }
    }

    // Load gap store to get PR numbers.
    let gap_store = crate::gap_store::GapStore::open(repo_root).ok();

    // Only keep shipped gaps.
    let mut ships: Vec<ShipTokens> = per_gap
        .into_iter()
        .filter(|(gap_id, _)| shipped_gaps.contains(gap_id))
        .map(|(gap_id, (input, output, cache, call_count))| {
            let pr_number = gap_store
                .as_ref()
                .and_then(|store| store.get(&gap_id).ok().flatten())
                .and_then(|row| row.closed_pr);
            let cost = crate::session_ledger::cost_usd_from_tokens(input, output, cache);
            ShipTokens {
                gap_id,
                pr_number,
                backend: "claude".to_string(),
                model: "sonnet".to_string(),
                call_count,
                input_tokens: input,
                output_tokens: output,
                cache_read_tokens: cache,
                total_tokens: input + output + cache,
                cost_usd: cost,
                shipped: true,
            }
        })
        .collect();

    let ship_count = ships.len();
    if ship_count == 0 {
        return TokensPerShipReport {
            window_days,
            ship_count: 0,
            ships: vec![],
            backend_stats: BTreeMap::new(),
            p50_tokens: None,
            p90_tokens: None,
            max_tokens: None,
            p50_cost_usd: None,
            p90_cost_usd: None,
            max_cost_usd: None,
            top5: vec![],
        };
    }

    // Sort by cost descending for the main ships list.
    ships.sort_by(|a, b| {
        b.cost_usd
            .partial_cmp(&a.cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // Take top 5 for top5 list.
    let top5 = ships.iter().take(5).cloned().collect();

    // For percentile computation, sort by total_tokens.
    let mut ships_for_percentiles = ships.clone();
    ships_for_percentiles.sort_by_key(|s| s.total_tokens);

    let p50_tokens = percentile_u64(&ships_for_percentiles, 50);
    let p90_tokens = percentile_u64(&ships_for_percentiles, 90);
    let max_tokens = ships_for_percentiles.last().map(|s| s.total_tokens);

    let p50_cost_usd = p50_tokens.map(|t| {
        ships_for_percentiles
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let p90_cost_usd = p90_tokens.map(|t| {
        ships_for_percentiles
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let max_cost_usd = ships_for_percentiles.last().map(|s| s.cost_usd);

    // Compute per-backend stats.
    let mut backend_stats: BTreeMap<String, Vec<ShipTokens>> = BTreeMap::new();
    for ship in &ships_for_percentiles {
        backend_stats
            .entry(ship.backend.clone())
            .or_default()
            .push(ship.clone());
    }

    let mut backend_summary = BTreeMap::new();
    for (backend, mut ships_by_backend) in backend_stats {
        ships_by_backend.sort_by_key(|s| s.total_tokens);
        let p50 = percentile_u64(&ships_by_backend, 50);
        let p90 = percentile_u64(&ships_by_backend, 90);
        let max = ships_by_backend.last().map(|s| s.total_tokens);

        let p50_cost = p50.map(|t| {
            ships_by_backend
                .iter()
                .min_by_key(|s| {
                    let d = s.total_tokens as i64 - t as i64;
                    d.unsigned_abs()
                })
                .map(|s| s.cost_usd)
                .unwrap_or(0.0)
        });
        let p90_cost = p90.map(|t| {
            ships_by_backend
                .iter()
                .min_by_key(|s| {
                    let d = s.total_tokens as i64 - t as i64;
                    d.unsigned_abs()
                })
                .map(|s| s.cost_usd)
                .unwrap_or(0.0)
        });
        let max_cost = ships_by_backend.last().map(|s| s.cost_usd);

        backend_summary.insert(
            backend.clone(),
            BackendStats {
                backend,
                ship_count: ships_by_backend.len(),
                p50_tokens: p50,
                p90_tokens: p90,
                max_tokens: max,
                p50_cost_usd: p50_cost,
                p90_cost_usd: p90_cost,
                max_cost_usd: max_cost,
            },
        );
    }

    TokensPerShipReport {
        window_days,
        ship_count,
        ships,
        backend_stats: backend_summary,
        p50_tokens,
        p90_tokens,
        max_tokens,
        p50_cost_usd,
        p90_cost_usd,
        max_cost_usd,
        top5,
    }
}

fn percentile_u64(sorted: &[ShipTokens], pct: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    // Nearest-rank method: ceiling(pct/100 * n), 1-indexed → 0-indexed.
    let rank = (pct * sorted.len()).div_ceil(100);
    let idx = rank.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx].total_tokens)
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
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
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32_045;
    let unix_epoch_jdn: i64 = 2_440_588;
    let days = (jdn - unix_epoch_jdn) as u64;
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    if let Some(inner) = rest.strip_prefix('"') {
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
    use std::io::Write;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra640-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_ambient(dir: &std::path::Path, lines: &[&str]) {
        let locks = dir.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        for line in lines {
            writeln!(f, "{}", line).unwrap();
        }
    }

    /// Fixture: 3 shipped gaps with known token counts in the last 7 days.
    /// Gaps use timestamps far in the past relative to current time to
    /// guarantee they fall within a 30-day window but remain deterministic.
    fn fixture_ts() -> String {
        // 2 days ago (well within any test window).
        let ts = current_unix() - 2 * 86_400;
        let d = ts / 86_400;
        let j = d as i64 + 2_440_588;
        let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
        let e = 4 * f + 3;
        let g = (e % 1461) / 4;
        let h = 5 * g + 2;
        let day = (h % 153) / 5 + 1;
        let month = (h / 153 + 2) % 12 + 1;
        let year = e / 1461 - 4716 + (14 - month) / 12;
        let hh = (ts % 86_400) / 3600;
        let mm = (ts % 3600) / 60;
        let ss = ts % 60;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            year, month, day, hh, mm, ss
        )
    }

    #[test]
    fn infra640_empty_window_returns_zero_ships() {
        let tmp = tempdir();
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 0);
        assert!(report.p50_tokens.is_none());
        assert!(report.ships.is_empty());
        assert!(report.top5.is_empty());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_only_shipped_gaps_counted() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                // shipped — should be counted
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":300,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":500}}"#
                ),
                // abandoned — should NOT be counted
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s2","gap_id":"INFRA-2","outcome":"abandoned","elapsed_seconds":100,"input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "only shipped gaps counted");
        assert_eq!(report.ships.len(), 1);
        assert_eq!(report.top5.len(), 1);
        assert_eq!(report.top5[0].gap_id, "INFRA-1");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_percentiles_and_top5() {
        let tmp = tempdir();
        let ts = fixture_ts();
        // 5 shipped gaps with different token counts: 1k, 2k, 3k, 4k, 5k total input.
        // With output=0 cache=0, total_tokens == input_tokens.
        let lines: Vec<String> = (1..=5u64)
            .map(|i| {
                format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s{i}","gap_id":"INFRA-{i}","outcome":"shipped","elapsed_seconds":60,"input_tokens":{tok},"output_tokens":0,"cache_read_tokens":0}}"#,
                    tok = i * 1000
                )
            })
            .collect();
        let lines_ref: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient(&tmp, &lines_ref);

        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 5);
        // sorted: 1000, 2000, 3000, 4000, 5000
        // P50 = ceiling(50/100 * 5) = 3rd element = 3000
        assert_eq!(report.p50_tokens, Some(3000));
        // P90 = ceiling(90/100 * 5) = ceiling(4.5) = 5th element = 5000
        assert_eq!(report.p90_tokens, Some(5000));
        assert_eq!(report.max_tokens, Some(5000));
        // top5 sorted by cost desc → INFRA-5 first (most tokens)
        assert_eq!(report.ships.len(), 5);
        assert_eq!(report.top5[0].gap_id, "INFRA-5");
        assert_eq!(report.top5.len(), 5);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_token_usage_partial_accumulated() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                // partial event mid-session
                &format!(
                    r#"{{"kind":"token_usage_partial","ts":"{ts}","session_id":"s1","gap_id":"INFRA-10","input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
                // session_end adds more tokens + ships
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-10","outcome":"shipped","elapsed_seconds":300,"input_tokens":3000,"output_tokens":500,"cache_read_tokens":200}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1);
        assert_eq!(report.ships.len(), 1);
        let ship = &report.ships[0];
        // total = (5000+3000) input + (1000+500) output + (0+200) cache = 9700
        assert_eq!(ship.input_tokens, 8000);
        assert_eq!(ship.output_tokens, 1500);
        assert_eq!(ship.cache_read_tokens, 200);
        assert_eq!(ship.total_tokens, 9700);
        assert_eq!(ship.call_count, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_window_filters_old_events() {
        let tmp = tempdir();
        // Old event: 10 days ago (outside 7-day window).
        let old_ts = {
            let ts = current_unix() - 10 * 86_400;
            let d = ts / 86_400;
            let j = d as i64 + 2_440_588;
            let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
            let e = 4 * f + 3;
            let g = (e % 1461) / 4;
            let h = 5 * g + 2;
            let day = (h % 153) / 5 + 1;
            let month = (h / 153 + 2) % 12 + 1;
            let year = e / 1461 - 4716 + (14 - month) / 12;
            let hh = (ts % 86_400) / 3600;
            let mm = (ts % 3600) / 60;
            let ss = ts % 60;
            format!(
                "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
                year, month, day, hh, mm, ss
            )
        };
        let recent_ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                // old — outside window
                &format!(
                    r#"{{"kind":"session_end","ts":"{old_ts}","session_id":"s-old","gap_id":"INFRA-99","outcome":"shipped","elapsed_seconds":60,"input_tokens":9000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
                // recent — inside window
                &format!(
                    r#"{{"kind":"session_end","ts":"{recent_ts}","session_id":"s-new","gap_id":"INFRA-100","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "old event filtered by window");
        assert_eq!(report.top5[0].gap_id, "INFRA-100");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_dollar_math() {
        // 10k input + 2k output + 0 cache at default Sonnet rates:
        // = (10000*3 + 2000*15) / 1e6 = (30000 + 30000) / 1e6 = $0.060000
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-200","outcome":"shipped","elapsed_seconds":60,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":0}}"#
            )],
        );
        let report = build_report(&tmp, 7);
        let expected = 0.060_f64;
        let got = report.max_cost_usd.unwrap_or(0.0);
        assert!(
            (got - expected).abs() < 1e-9,
            "expected ${:.4} got ${:.4}",
            expected,
            got
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_render_text_contains_key_fields() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-300","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":500,"cache_read_tokens":0}}"#
            )],
        );
        let report = build_report(&tmp, 7);
        let text = report.render_text();
        assert!(text.contains("Ships analysed: 1"));
        assert!(text.contains("INFRA-300"));
        assert!(text.contains("Per-Ship Details"));
        assert!(text.contains("backend"));
        assert!(text.contains("model"));
        assert!(text.contains("P50"));
        assert!(text.contains("P90"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_render_json_valid_structure() {
        let tmp = tempdir();
        let report = build_report(&tmp, 7);
        let json = report.render_json();
        assert!(json.contains(r#""window_days":7"#));
        assert!(json.contains(r#""ship_count":0"#));
        assert!(json.contains(r#""top5":[]"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
