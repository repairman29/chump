//! INFRA-617 / INFRA-640: `chump kpi report` — exec-summary view of mission progress.
//!
//! Sections:
//!   1. Ship rate trend (1d/7d/30d) with pillar breakdown
//!   2. Mission grade history (last 10 snapshots from ambient.jsonl)
//!   3. Cost-saving vs Anthropic-only baseline
//!   4. Leverage ranking: top gaps by depends_on frequency
//!   5. Tokens-per-ship (P50/P90/Max, top-5 most expensive)
//!
//! Output: markdown to stdout, optional `--json` for machine-readable.

use std::collections::BTreeMap;
use std::path::Path;

// ── Existing INFRA-640 types (unchanged) ─────────────────────────────────────

/// Per-ship token summary.
#[derive(Debug, Clone)]
pub struct ShipTokens {
    pub gap_id: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub total_tokens: u64,
    pub cost_usd: f64,
}

/// Full tokens-per-ship report.
#[derive(Debug)]
pub struct TokensPerShipReport {
    pub window_days: u64,
    pub ship_count: usize,
    pub p50_tokens: Option<u64>,
    pub p90_tokens: Option<u64>,
    pub max_tokens: Option<u64>,
    pub p50_cost_usd: Option<f64>,
    pub p90_cost_usd: Option<f64>,
    pub max_cost_usd: Option<f64>,
    pub top5: Vec<ShipTokens>,
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
        let fmt_tok = |v: Option<u64>| {
            v.map(|n| format!("{:>10}", n))
                .unwrap_or_else(|| "         —".to_string())
        };
        let fmt_usd = |v: Option<f64>| {
            v.map(|d| format!("${:.4}", d))
                .unwrap_or_else(|| "      —".to_string())
        };
        out.push_str("\n  Tokens per ship:\n");
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
        let top5_json: Vec<String> = self
            .top5
            .iter()
            .map(|s| {
                format!(
                    r#"{{"gap_id":"{}","input_tokens":{},"output_tokens":{},"cache_read_tokens":{},"total_tokens":{},"cost_usd":{:.6}}}"#,
                    json_escape(&s.gap_id),
                    s.input_tokens,
                    s.output_tokens,
                    s.cache_read_tokens,
                    s.total_tokens,
                    s.cost_usd
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
            r#"{{"window_days":{},"ship_count":{},"p50_tokens":{},"p90_tokens":{},"max_tokens":{},"p50_cost_usd":{},"p90_cost_usd":{},"max_cost_usd":{},"top5":[{}]}}"#,
            self.window_days,
            self.ship_count,
            opt_u64(self.p50_tokens),
            opt_u64(self.p90_tokens),
            opt_u64(self.max_tokens),
            opt_f64(self.p50_cost_usd),
            opt_f64(self.p90_cost_usd),
            opt_f64(self.max_cost_usd),
            top5_json.join(",")
        )
    }
}

// ── INFRA-617 new sections ───────────────────────────────────────────────────

/// Ship counts per window (1d/7d/30d), broken down by pillar.
#[derive(Debug, Default)]
pub struct ShipRateSection {
    pub windows: Vec<WindowShipCount>,
}

#[derive(Debug)]
pub struct WindowShipCount {
    pub label: String,
    pub total: u64,
    pub effective: u64,
    pub credible: u64,
    pub resilient: u64,
    pub zero_waste: u64,
    pub untagged: u64,
}

impl ShipRateSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Ship Rate Trend ═══\n");
        if self.windows.is_empty() {
            out.push_str("  No shipped gaps found.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<8} {:>8} {:>10} {:>9} {:>10} {:>11} {:>10}\n",
            "window", "total", "effective", "credible", "resilient", "zero-waste", "untagged"
        ));
        for w in &self.windows {
            out.push_str(&format!(
                "  {:<8} {:>8} {:>10} {:>9} {:>10} {:>11} {:>10}\n",
                w.label, w.total, w.effective, w.credible, w.resilient, w.zero_waste, w.untagged
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let windows_json: Vec<String> = self
            .windows
            .iter()
            .map(|w| {
                format!(
                    r#"{{"label":"{}","total":{},"effective":{},"credible":{},"resilient":{},"zero_waste":{},"untagged":{}}}"#,
                    w.label, w.total, w.effective, w.credible, w.resilient, w.zero_waste, w.untagged
                )
            })
            .collect();
        format!(r#"{{"windows":[{}]}}"#, windows_json.join(","))
    }
}

/// A single mission-grade snapshot from ambient.jsonl.
#[derive(Debug, Clone)]
pub struct MissionGradeSnapshot {
    pub ts: String,
    pub effective_shipped: u64,
    pub credible_shipped: u64,
    pub resilient_shipped: u64,
    pub zero_waste_shipped: u64,
    pub total_pickable: u64,
    pub total_in_flight: u64,
}

#[derive(Debug, Default)]
pub struct MissionGradeHistorySection {
    pub snapshots: Vec<MissionGradeSnapshot>,
}

impl MissionGradeHistorySection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Mission Grade History (last 10) ═══\n");
        if self.snapshots.is_empty() {
            out.push_str("  No mission-grade snapshots recorded yet.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<22} {:>8} {:>9} {:>10} {:>11} {:>10} {:>11}\n",
            "ts", "eff", "cred", "resil", "z-waste", "pickable", "in-flight"
        ));
        for s in &self.snapshots {
            let short_ts = if s.ts.len() > 19 { &s.ts[..19] } else { &s.ts };
            out.push_str(&format!(
                "  {:<22} {:>8} {:>9} {:>10} {:>11} {:>10} {:>11}\n",
                short_ts,
                s.effective_shipped,
                s.credible_shipped,
                s.resilient_shipped,
                s.zero_waste_shipped,
                s.total_pickable,
                s.total_in_flight
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let snaps_json: Vec<String> = self
            .snapshots
            .iter()
            .map(|s| {
                format!(
                    r#"{{"ts":"{}","effective_shipped":{},"credible_shipped":{},"resilient_shipped":{},"zero_waste_shipped":{},"total_pickable":{},"total_in_flight":{}}}"#,
                    s.ts, s.effective_shipped, s.credible_shipped, s.resilient_shipped,
                    s.zero_waste_shipped, s.total_pickable, s.total_in_flight
                )
            })
            .collect();
        format!(r#"{{"snapshots":[{}]}}"#, snaps_json.join(","))
    }
}

/// Cost-saving estimate vs Anthropic-only baseline.
#[derive(Debug, Default)]
pub struct CostSavingsSection {
    /// Total actual cost (USD) across all sessions in window.
    pub actual_cost_usd: f64,
    /// Estimated cost if all sessions used Anthropic Sonnet rates.
    pub anthropic_only_cost_usd: f64,
    pub window_days: u64,
}

impl CostSavingsSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Cost Savings vs Anthropic-Only (last {} days) ═══\n",
            self.window_days
        ));
        let saved = self.anthropic_only_cost_usd - self.actual_cost_usd;
        let pct = if self.anthropic_only_cost_usd > 0.0 {
            (saved / self.anthropic_only_cost_usd) * 100.0
        } else {
            0.0
        };
        out.push_str(&format!(
            "  Actual cost:        ${:.4}\n",
            self.actual_cost_usd
        ));
        out.push_str(&format!(
            "  Anthropic-only:     ${:.4}\n",
            self.anthropic_only_cost_usd
        ));
        out.push_str(&format!(
            "  Savings:            ${:.4} ({:.1}%)\n",
            saved, pct
        ));
        out
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"actual_cost_usd":{:.6},"anthropic_only_cost_usd":{:.6},"window_days":{}}}"#,
            self.actual_cost_usd, self.anthropic_only_cost_usd, self.window_days
        )
    }
}

/// One gap's leverage score: how many other gaps depend on it.
#[derive(Debug)]
pub struct LeverageEntry {
    pub gap_id: String,
    pub depended_by_count: usize,
}

#[derive(Debug, Default)]
pub struct LeverageSection {
    pub entries: Vec<LeverageEntry>,
}

impl LeverageSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Top Productizations by Leverage ═══\n");
        if self.entries.is_empty() {
            out.push_str("  No dependency data available.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<4} {:<22} {:>10}\n",
            "rank", "gap_id", "unblocks"
        ));
        for (i, e) in self.entries.iter().enumerate() {
            out.push_str(&format!(
                "  {:<4} {:<22} {:>10}\n",
                i + 1,
                e.gap_id,
                e.depended_by_count
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                format!(
                    r#"{{"gap_id":"{}","depended_by_count":{}}}"#,
                    e.gap_id, e.depended_by_count
                )
            })
            .collect();
        format!(r#"{{"leverage":[{}]}}"#, entries_json.join(","))
    }
}

// ── Handoff self-heal rate (INFRA-773) ───────────────────────────────────────

/// Tracks the Review-as-Handoff self-heal rate over the report window.
///
/// Self-heal rate = applied / initiated. Reviewer-error rate = (failed + timeout) / initiated.
/// Source: ambient.jsonl kinds review_handoff_initiated / applied / failed / timeout.
#[derive(Debug, Default)]
pub struct HandoffRateSection {
    pub initiated: u64,
    pub applied: u64,
    pub failed: u64,
    pub timeout: u64,
}

impl HandoffRateSection {
    pub fn self_heal_rate(&self) -> f64 {
        if self.initiated == 0 {
            0.0
        } else {
            self.applied as f64 / self.initiated as f64
        }
    }

    pub fn reviewer_error_rate(&self) -> f64 {
        if self.initiated == 0 {
            0.0
        } else {
            (self.failed + self.timeout) as f64 / self.initiated as f64
        }
    }

    pub fn render_text(&self) -> String {
        if self.initiated == 0 {
            return "Review-as-Handoff: no handoffs initiated in window.\n".to_string();
        }
        format!(
            "Review-as-Handoff (INFRA-773)\n  Initiated: {}  Applied: {}  Failed: {}  Timeout: {}\n  Self-heal rate: {:.0}%  Reviewer-error rate: {:.0}%\n",
            self.initiated,
            self.applied,
            self.failed,
            self.timeout,
            self.self_heal_rate() * 100.0,
            self.reviewer_error_rate() * 100.0,
        )
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"initiated":{},"applied":{},"failed":{},"timeout":{},"self_heal_rate_pct":{:.1},"reviewer_error_rate_pct":{:.1}}}"#,
            self.initiated,
            self.applied,
            self.failed,
            self.timeout,
            self.self_heal_rate() * 100.0,
            self.reviewer_error_rate() * 100.0,
        )
    }
}

/// Scan ambient.jsonl and count review_handoff_* events within the time window.
fn build_handoff_rate_section(repo_root: &Path, window_days: u64) -> HandoffRateSection {
    use crate::kpi_report::{extract_field, parse_iso8601_to_unix};

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    };
    let cutoff = now.saturating_sub(window_days * 86400);

    let mut section = HandoffRateSection::default();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if !kind.starts_with("review_handoff_") {
            continue;
        }
        if let Some(ts_str) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts_str) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        match kind.as_str() {
            "review_handoff_initiated" => section.initiated += 1,
            "review_handoff_applied" => section.applied += 1,
            "review_handoff_failed" => section.failed += 1,
            "review_handoff_timeout" => section.timeout += 1,
            _ => {}
        }
    }
    section
}

// ── Combined KPI Report ──────────────────────────────────────────────────────

/// Full KPI report wrapping all sections.
#[derive(Debug)]
pub struct KpiReport {
    pub ship_rate: ShipRateSection,
    pub mission_history: MissionGradeHistorySection,
    pub cost_savings: CostSavingsSection,
    pub leverage: LeverageSection,
    pub tokens_per_ship: TokensPerShipReport,
    pub handoff_rate: HandoffRateSection,
}

impl KpiReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("╔══════════════════════════════════════════════╗\n");
        out.push_str("║        Chump KPI Report (INFRA-617)        ║\n");
        out.push_str("╚══════════════════════════════════════════════╝\n\n");
        out.push_str(&self.ship_rate.render_text());
        out.push('\n');
        out.push_str(&self.mission_history.render_text());
        out.push('\n');
        out.push_str(&self.cost_savings.render_text());
        out.push('\n');
        out.push_str(&self.leverage.render_text());
        out.push('\n');
        out.push_str(&self.tokens_per_ship.render_text());
        out.push('\n');
        out.push_str(&self.handoff_rate.render_text());
        out
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"ship_rate":{},"mission_history":{},"cost_savings":{},"leverage":{},"tokens_per_ship":{},"handoff_rate":{}}}"#,
            self.ship_rate.render_json(),
            self.mission_history.render_json(),
            self.cost_savings.render_json(),
            self.leverage.render_json(),
            self.tokens_per_ship.render_json(),
            self.handoff_rate.render_json(),
        )
    }
}

// ── Agent Throughput Section (FLEET-044) ────────────────────────────────────

/// Per-agent throughput row parsed from .chump/metrics/agent-throughput-DATE.json.
#[derive(Debug, Clone)]
pub struct AgentThroughputRow {
    pub agent_id: String,
    pub ships: u64,
    pub fails: u64,
    pub p50_minutes_per_ship: Option<f64>,
    pub top_fail_modes: Vec<String>,
}

#[derive(Debug, Default)]
pub struct AgentThroughputSection {
    pub date: String,
    pub rows: Vec<AgentThroughputRow>,
    pub total_ships: u64,
    pub total_fails: u64,
}

impl AgentThroughputSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Agent Throughput ═══\n");
        if self.date.is_empty() {
            out.push_str(
                "  No throughput data found. Run: scripts/ops/agent-throughput-tracker.sh\n",
            );
            return out;
        }
        out.push_str(&format!("  Date: {}\n", self.date));
        out.push_str(&format!(
            "  Total ships: {}  Total fails: {}\n\n",
            self.total_ships, self.total_fails
        ));
        if self.rows.is_empty() {
            out.push_str("  No agent sessions recorded.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<36} {:>6} {:>6} {:>16}  {}\n",
            "agent_id", "ships", "fails", "P50_min/ship", "top_fail_modes"
        ));
        for row in &self.rows {
            let p50 = row
                .p50_minutes_per_ship
                .map(|v| format!("{:.1}", v))
                .unwrap_or_else(|| "—".to_string());
            out.push_str(&format!(
                "  {:<36} {:>6} {:>6} {:>16}  {}\n",
                row.agent_id,
                row.ships,
                row.fails,
                p50,
                row.top_fail_modes.join(", ")
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let rows_json: Vec<String> = self
            .rows
            .iter()
            .map(|r| {
                let p50 = r
                    .p50_minutes_per_ship
                    .map(|v| format!("{:.1}", v))
                    .unwrap_or_else(|| "null".to_string());
                let modes = r
                    .top_fail_modes
                    .iter()
                    .map(|m| format!(r#""{}""#, json_escape(m)))
                    .collect::<Vec<_>>()
                    .join(",");
                format!(
                    r#"{{"agent_id":"{}","ships":{},"fails":{},"P50_minutes_per_ship":{},"top_fail_modes":[{}]}}"#,
                    json_escape(&r.agent_id),
                    r.ships,
                    r.fails,
                    p50,
                    modes
                )
            })
            .collect();
        format!(
            r#"{{"date":"{}","total_ships":{},"total_fails":{},"agents":[{}]}}"#,
            json_escape(&self.date),
            self.total_ships,
            self.total_fails,
            rows_json.join(",")
        )
    }
}

/// Read agent throughput from .chump/metrics/agent-throughput-DATE.json.
pub fn build_agent_throughput_section(
    repo_root: &Path,
    date_str: Option<&str>,
) -> AgentThroughputSection {
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let date = date_str.unwrap_or(today.as_str());
    let metrics_path = repo_root
        .join(".chump/metrics")
        .join(format!("agent-throughput-{date}.json"));
    let content = match std::fs::read_to_string(&metrics_path) {
        Ok(c) => c,
        Err(_) => return AgentThroughputSection::default(),
    };
    let json: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return AgentThroughputSection::default(),
    };
    let mut section = AgentThroughputSection {
        date: json
            .get("date")
            .and_then(|v| v.as_str())
            .unwrap_or(date)
            .to_string(),
        total_ships: json
            .get("total_ships")
            .and_then(|v| v.as_u64())
            .unwrap_or(0),
        total_fails: json
            .get("total_fails")
            .and_then(|v| v.as_u64())
            .unwrap_or(0),
        rows: vec![],
    };
    if let Some(agents) = json.get("agents").and_then(|v| v.as_array()) {
        for a in agents {
            section.rows.push(AgentThroughputRow {
                agent_id: a
                    .get("agent_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                ships: a.get("ships").and_then(|v| v.as_u64()).unwrap_or(0),
                fails: a.get("fails").and_then(|v| v.as_u64()).unwrap_or(0),
                p50_minutes_per_ship: a.get("P50_minutes_per_ship").and_then(|v| v.as_f64()),
                top_fail_modes: a
                    .get("top_fail_modes")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|m| m.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default(),
            });
        }
    }
    section
}

// ── Build functions ──────────────────────────────────────────────────────────

/// Build the full KPI report for the given repo.
pub fn build_full_report(repo_root: &Path, window_days: u64) -> KpiReport {
    KpiReport {
        ship_rate: build_ship_rate_section(repo_root),
        mission_history: build_mission_history_section(repo_root),
        cost_savings: build_cost_savings_section(repo_root, window_days),
        leverage: build_leverage_section(repo_root),
        tokens_per_ship: build_report(repo_root, window_days),
        handoff_rate: build_handoff_rate_section(repo_root, window_days),
    }
}

fn build_ship_rate_section(repo_root: &Path) -> ShipRateSection {
    let store = match crate::gap_store::GapStore::open(repo_root) {
        Ok(s) => s,
        Err(_) => return ShipRateSection::default(),
    };
    let done_gaps = match store.list(Some("done")) {
        Ok(v) => v,
        Err(_) => return ShipRateSection::default(),
    };
    let now = current_unix();

    let pillar_of = |title: &str| -> Option<&'static str> {
        let up = title.to_uppercase();
        if up.starts_with("EFFECTIVE:") {
            Some("effective")
        } else if up.starts_with("CREDIBLE:") {
            Some("credible")
        } else if up.starts_with("RESILIENT:") {
            Some("resilient")
        } else if up.starts_with("ZERO-WASTE:") {
            Some("zero_waste")
        } else {
            None
        }
    };

    let mut windows = Vec::new();
    for (label, days) in [("1d", 1u64), ("7d", 7), ("30d", 30)] {
        let cutoff = now.saturating_sub(days * 86_400);
        let mut total = 0u64;
        let mut effective = 0;
        let mut credible = 0;
        let mut resilient = 0;
        let mut zero_waste = 0;
        let mut untagged = 0;

        for g in &done_gaps {
            if let Some(closed) = g.closed_at {
                if (closed as u64) >= cutoff {
                    total += 1;
                    match pillar_of(&g.title) {
                        Some("effective") => effective += 1,
                        Some("credible") => credible += 1,
                        Some("resilient") => resilient += 1,
                        Some("zero_waste") => zero_waste += 1,
                        _ => untagged += 1,
                    }
                }
            }
        }

        windows.push(WindowShipCount {
            label: label.to_string(),
            total,
            effective,
            credible,
            resilient,
            zero_waste,
            untagged,
        });
    }

    ShipRateSection { windows }
}

fn build_mission_history_section(repo_root: &Path) -> MissionGradeHistorySection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let mut snapshots = Vec::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "mission_grade" {
            continue;
        }
        let ts = extract_field(line, "ts").unwrap_or_default();
        let extract_pillar = |pfx: &str, field: &str| -> u64 {
            let needle = format!(r#""{}":{{"#, pfx);
            let start = line.find(&needle);
            start
                .and_then(|s| {
                    let rest = &line[s..];
                    let f = format!(r#""{}":"#, field);
                    rest.find(&f).and_then(|p| {
                        let val_start = p + f.len();
                        let val_rest = &rest[val_start..];
                        let end = val_rest.find([',', '}']).unwrap_or(val_rest.len());
                        val_rest[..end].trim().parse().ok()
                    })
                })
                .unwrap_or(0)
        };
        snapshots.push(MissionGradeSnapshot {
            ts,
            effective_shipped: extract_pillar("effective", "count_shipped_24h"),
            credible_shipped: extract_pillar("credible", "count_shipped_24h"),
            resilient_shipped: extract_pillar("resilient", "count_shipped_24h"),
            zero_waste_shipped: extract_pillar("zero_waste", "count_shipped_24h"),
            total_pickable: {
                let ep = extract_pillar("effective", "count_pickable");
                let cp = extract_pillar("credible", "count_pickable");
                let rp = extract_pillar("resilient", "count_pickable");
                let zp = extract_pillar("zero_waste", "count_pickable");
                ep + cp + rp + zp
            },
            total_in_flight: {
                let ei = extract_pillar("effective", "count_in_flight");
                let ci = extract_pillar("credible", "count_in_flight");
                let ri = extract_pillar("resilient", "count_in_flight");
                let zi = extract_pillar("zero_waste", "count_in_flight");
                ei + ci + ri + zi
            },
        });
    }

    // Keep last 10, most recent first.
    snapshots.reverse();
    snapshots.truncate(10);

    MissionGradeHistorySection { snapshots }
}

fn build_cost_savings_section(repo_root: &Path, window_days: u64) -> CostSavingsSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    let mut actual_cost = 0.0_f64;
    let mut anthropic_cost = 0.0_f64;

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff {
            continue;
        }
        if kind != "session_end" && kind != "token_usage_partial" {
            continue;
        }
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);

        // Actual cost: use the model_id if present, else "unknown".
        let model = extract_field(line, "model_id").unwrap_or_default();
        let model_ref = if model.is_empty() { "unknown" } else { &model };
        actual_cost += crate::session_ledger::cost_usd_from_tokens(model_ref, input, output, cache);

        // Anthropic-only cost: always use Sonnet rates ("unknown" → Sonnet).
        anthropic_cost +=
            crate::session_ledger::cost_usd_from_tokens("unknown", input, output, cache);
    }

    CostSavingsSection {
        actual_cost_usd: actual_cost,
        anthropic_only_cost_usd: anthropic_cost,
        window_days,
    }
}

fn build_leverage_section(repo_root: &Path) -> LeverageSection {
    let store = match crate::gap_store::GapStore::open(repo_root) {
        Ok(s) => s,
        Err(_) => return LeverageSection::default(),
    };
    let all_gaps = match store.list(None) {
        Ok(v) => v,
        Err(_) => return LeverageSection::default(),
    };

    let mut dep_count: BTreeMap<String, usize> = BTreeMap::new();
    for g in &all_gaps {
        if g.depends_on.is_empty() {
            continue;
        }
        for dep in g.depends_on.split(',') {
            let dep = dep.trim();
            if !dep.is_empty() {
                *dep_count.entry(dep.to_string()).or_insert(0) += 1;
            }
        }
    }

    // Also count how many gaps have a `depends_on` referencing another gap.
    // We already counted above. Now sort by count descending.
    let mut entries: Vec<LeverageEntry> = dep_count
        .into_iter()
        .map(|(gap_id, count)| LeverageEntry {
            gap_id,
            depended_by_count: count,
        })
        .collect();
    entries.sort_by_key(|b| std::cmp::Reverse(b.depended_by_count));
    entries.truncate(10);

    LeverageSection { entries }
}

/// Build the tokens-per-ship report by scanning `ambient.jsonl`.
pub fn build_report(repo_root: &Path, window_days: u64) -> TokensPerShipReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    let mut per_gap: BTreeMap<String, (u64, u64, u64)> = BTreeMap::new();
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

                let entry = per_gap.entry(gap_id.clone()).or_insert((0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;

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
                let entry = per_gap.entry(gap_id).or_insert((0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;
            }
            _ => {}
        }
    }

    let mut ships: Vec<ShipTokens> = per_gap
        .into_iter()
        .filter(|(gap_id, _)| shipped_gaps.contains(gap_id))
        .map(|(gap_id, (input, output, cache))| {
            let cost = crate::session_ledger::cost_usd_from_tokens("unknown", input, output, cache);
            ShipTokens {
                gap_id,
                input_tokens: input,
                output_tokens: output,
                cache_read_tokens: cache,
                total_tokens: input + output + cache,
                cost_usd: cost,
            }
        })
        .collect();

    let ship_count = ships.len();
    if ship_count == 0 {
        return TokensPerShipReport {
            window_days,
            ship_count: 0,
            p50_tokens: None,
            p90_tokens: None,
            max_tokens: None,
            p50_cost_usd: None,
            p90_cost_usd: None,
            max_cost_usd: None,
            top5: vec![],
        };
    }

    ships.sort_by_key(|s| s.total_tokens);

    let p50_tokens = percentile_u64(&ships, 50);
    let p90_tokens = percentile_u64(&ships, 90);
    let max_tokens = ships.last().map(|s| s.total_tokens);

    let p50_cost_usd = p50_tokens.map(|t| {
        ships
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let p90_cost_usd = p90_tokens.map(|t| {
        ships
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let max_cost_usd = ships.last().map(|s| s.cost_usd);

    ships.sort_by(|a, b| {
        b.cost_usd
            .partial_cmp(&a.cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let top5 = ships.into_iter().take(5).collect();

    TokensPerShipReport {
        window_days,
        ship_count,
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

// ── FLEET-048: Gap impact ratings ────────────────────────────────────────────

/// One operator-rated gap.
#[derive(Debug, Clone)]
pub struct ImpactRatingEntry {
    pub gap_id: String,
    pub rating: u8,
    pub comment: String,
    pub ts: String,
    pub pr_number: Option<i64>,
}

/// Aggregated impact ratings section for `chump kpi report --impact`.
#[derive(Debug, Clone, Default)]
pub struct ImpactRatingSection {
    pub entries: Vec<ImpactRatingEntry>,
    pub fleet_avg: Option<f64>,
    pub total_ratings: usize,
    /// INFRA-1555: mean rating per domain class (e.g. "INFRA", "FLEET").
    /// Populated by `build_impact_section`; empty when no ratings exist.
    pub class_ratings: Vec<ClassRatingRow>,
}

/// One row in the "Gap rating by class" subsection (INFRA-1555).
#[derive(Debug, Clone)]
pub struct ClassRatingRow {
    pub class: String,
    pub mean: f64,
    pub count: usize,
    /// `true` when mean < 2.5 and count >= 2 — picker applies one-tier demotion.
    pub demoted: bool,
}

impl ImpactRatingSection {
    pub fn render_text(&self) -> String {
        if self.entries.is_empty() {
            return "## Gap Impact Ratings\n\nNo ratings recorded yet.\n\
                    Run: chump gap rate <ID> <1-5> [--comment \"text\"]\n\n"
                .to_string();
        }
        let avg_str = self
            .fleet_avg
            .map(|a| format!("{:.2}", a))
            .unwrap_or_else(|| "n/a".to_string());
        let mut out = format!(
            "## Gap Impact Ratings ({} rated, fleet avg {}/5)\n\n",
            self.total_ratings, avg_str
        );
        out.push_str(&format!(
            "{:<14} {:>6}  {}\n",
            "Gap ID", "Rating", "Comment"
        ));
        out.push_str(&format!("{:-<14} {:->6}  {:-<40}\n", "", "", ""));
        let mut sorted = self.entries.clone();
        sorted.sort_by(|a, b| b.rating.cmp(&a.rating).then(a.gap_id.cmp(&b.gap_id)));
        for e in &sorted {
            let comment = if e.comment.is_empty() {
                "(no comment)".to_string()
            } else if e.comment.len() > 60 {
                format!("{}…", &e.comment[..59])
            } else {
                e.comment.clone()
            };
            out.push_str(&format!("{:<14} {:>6}  {}\n", e.gap_id, e.rating, comment));
        }
        out.push('\n');

        // INFRA-1555: "Gap rating by class" subsection.
        if !self.class_ratings.is_empty() {
            out.push_str("### Gap rating by class\n\n");
            out.push_str(&format!(
                "{:<12} {:>6}  {:>6}  {}\n",
                "Class", "Mean", "Count", "Picker effect"
            ));
            out.push_str(&format!(
                "{:-<12} {:->6}  {:->6}  {:-<20}\n",
                "", "", "", ""
            ));
            let mut rows = self.class_ratings.clone();
            rows.sort_by(|a, b| a.class.cmp(&b.class));
            for row in &rows {
                let effect = if row.demoted {
                    "demoted 1 tier"
                } else {
                    "no change"
                };
                out.push_str(&format!(
                    "{:<12} {:>6.2}  {:>6}  {}\n",
                    row.class, row.mean, row.count, effect
                ));
            }
            out.push('\n');
        }

        out
    }

    pub fn render_json(&self) -> String {
        let avg_str = self
            .fleet_avg
            .map(|a| format!("{:.2}", a))
            .unwrap_or_else(|| "null".to_string());
        let avg_json = if avg_str == "null" {
            "null".to_string()
        } else {
            avg_str
        };
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                let pr = e
                    .pr_number
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "null".to_string());
                format!(
                    "{{\"gap_id\":\"{}\",\"rating\":{},\"comment\":\"{}\",\"ts\":\"{}\",\"pr_number\":{}}}",
                    json_escape(&e.gap_id),
                    e.rating,
                    json_escape(&e.comment),
                    json_escape(&e.ts),
                    pr
                )
            })
            .collect();
        // INFRA-1555: include class_ratings in JSON output.
        let class_json: Vec<String> = self
            .class_ratings
            .iter()
            .map(|r| {
                format!(
                    "{{\"class\":\"{}\",\"mean\":{:.2},\"count\":{},\"demoted\":{}}}",
                    json_escape(&r.class),
                    r.mean,
                    r.count,
                    r.demoted
                )
            })
            .collect();
        format!(
            "{{\"total_ratings\":{},\"fleet_avg\":{},\"entries\":[{}],\"class_ratings\":[{}]}}",
            self.total_ratings,
            avg_json,
            entries_json.join(","),
            class_json.join(",")
        )
    }
}

/// Build impact rating section by scanning ambient.jsonl for `gap_impact_rated` events.
/// INFRA-1555: also computes per-class (domain) mean ratings for the picker subsection.
pub fn build_impact_section(repo_root: &Path) -> ImpactRatingSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut entries: Vec<ImpactRatingEntry> = Vec::new();
    // INFRA-1555: accumulate (sum, count) per domain class for the subsection.
    let mut class_acc: std::collections::HashMap<String, (f64, usize)> =
        std::collections::HashMap::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "gap_impact_rated" {
            continue;
        }
        let gap_id = match extract_field(line, "gap_id") {
            Some(g) => g,
            None => continue,
        };
        let rating: u8 = match extract_int_field(line, "rating") {
            Some(r) if (1..=5).contains(&r) => r as u8,
            _ => continue,
        };
        let comment = extract_field(line, "comment").unwrap_or_default();
        let ts = extract_field(line, "ts").unwrap_or_default();
        let pr_number = extract_int_field(line, "pr_number").map(|n| n as i64);

        // Accumulate class stats (domain prefix of gap_id, e.g. "INFRA").
        let class = gap_id.split('-').next().unwrap_or("UNKNOWN").to_uppercase();
        let e = class_acc.entry(class).or_insert((0.0, 0));
        e.0 += rating as f64;
        e.1 += 1;

        entries.push(ImpactRatingEntry {
            gap_id,
            rating,
            comment,
            ts,
            pr_number,
        });
    }

    let total_ratings = entries.len();
    let fleet_avg = if total_ratings == 0 {
        None
    } else {
        let sum: u32 = entries.iter().map(|e| e.rating as u32).sum();
        Some(sum as f64 / total_ratings as f64)
    };

    // INFRA-1555: build class_ratings rows (demotion threshold mirrors atomic_claim).
    const LOW_THRESHOLD: f64 = 2.5;
    const MIN_SAMPLES: usize = 2;
    let mut class_ratings: Vec<ClassRatingRow> = class_acc
        .into_iter()
        .map(|(class, (sum, count))| {
            let mean = sum / count as f64;
            let demoted = count >= MIN_SAMPLES && mean < LOW_THRESHOLD;
            ClassRatingRow {
                class,
                mean,
                count,
                demoted,
            }
        })
        .collect();
    class_ratings.sort_by(|a, b| a.class.cmp(&b.class));

    ImpactRatingSection {
        entries,
        fleet_avg,
        total_ratings,
        class_ratings,
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra617-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    /// Create a minimal git repo + .chump/state.db with synthetic done gaps.
    /// `entries`: (title, closed_unix_ts). IDs are auto-generated (INFRA-NNN).
    /// Uses raw SQL because set_fields doesn't update the `closed_at` column
    /// (only `closed_date`), but the gap store's `list()` method reads `closed_at`.
    fn seed_gap_store(dir: &Path, entries: &[(&str, i64)]) {
        let chump_dir = dir.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();

        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(dir)
            .output();

        let store = crate::gap_store::GapStore::open(dir).unwrap();
        for (title, closed_ts) in entries {
            let reserved = store.reserve("INFRA", title, "P1", "s").unwrap();
            let iso = unix_to_iso_date(*closed_ts);
            let conn = store.conn_for_test();
            conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2, closed_pr=999 WHERE id=?3",
                rusqlite::params![closed_ts, iso, reserved],
            )
            .unwrap();
        }
    }

    fn unix_to_iso_date(ts: i64) -> String {
        let d = (ts / 86_400) + 2_440_588;
        let f = d + 1401 + ((((4 * d + 274_277) / 146_097) * 3) / 4) - 38;
        let e = 4 * f + 3;
        let g = (e % 1461) / 4;
        let h = 5 * g + 2;
        let day = (h % 153) / 5 + 1;
        let month = (h / 153 + 2) % 12 + 1;
        let year = e / 1461 - 4716 + (14 - month) / 12;
        format!("{:04}-{:02}-{:02}", year, month, day)
    }

    fn write_ambient(dir: &Path, lines: &[&str]) {
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

    fn fixture_ts() -> String {
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

    // ── INFRA-640 tests (unchanged) ────────────────────────────────────────

    #[test]
    fn infra640_empty_window_returns_zero_ships() {
        let tmp = tempdir();
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 0);
        assert!(report.p50_tokens.is_none());
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
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-1","outcome":"shipped","elapsed_seconds":300,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":500}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s2","gap_id":"TEST-2","outcome":"abandoned","elapsed_seconds":100,"input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "only shipped gaps counted");
        assert_eq!(report.top5.len(), 1);
        assert_eq!(report.top5[0].gap_id, "TEST-1");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_percentiles_and_top5() {
        let tmp = tempdir();
        let ts = fixture_ts();
        let lines: Vec<String> = (1..=5u64)
            .map(|i| {
                format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s{i}","gap_id":"TEST-{i}","outcome":"shipped","elapsed_seconds":60,"input_tokens":{tok},"output_tokens":0,"cache_read_tokens":0}}"#,
                    tok = i * 1000
                )
            })
            .collect();
        let lines_ref: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient(&tmp, &lines_ref);
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 5);
        assert_eq!(report.p50_tokens, Some(3000));
        assert_eq!(report.p90_tokens, Some(5000));
        assert_eq!(report.max_tokens, Some(5000));
        assert_eq!(report.top5[0].gap_id, "TEST-5");
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
                &format!(
                    r#"{{"kind":"token_usage_partial","ts":"{ts}","session_id":"s1","gap_id":"TEST-10","input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-10","outcome":"shipped","elapsed_seconds":300,"input_tokens":3000,"output_tokens":500,"cache_read_tokens":200}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1);
        let ship = &report.top5[0];
        assert_eq!(ship.input_tokens, 8000);
        assert_eq!(ship.output_tokens, 1500);
        assert_eq!(ship.cache_read_tokens, 200);
        assert_eq!(ship.total_tokens, 9700);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_window_filters_old_events() {
        let tmp = tempdir();
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
                &format!(
                    r#"{{"kind":"session_end","ts":"{old_ts}","session_id":"s-old","gap_id":"TEST-99","outcome":"shipped","elapsed_seconds":60,"input_tokens":9000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{recent_ts}","session_id":"s-new","gap_id":"TEST-100","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "old event filtered by window");
        assert_eq!(report.top5[0].gap_id, "TEST-100");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_dollar_math() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-200","outcome":"shipped","elapsed_seconds":60,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":0}}"#
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
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-300","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":500,"cache_read_tokens":0}}"#
            )],
        );
        let report = build_report(&tmp, 7);
        let text = report.render_text();
        assert!(text.contains("Ships analysed: 1"));
        assert!(text.contains("TEST-300"));
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

    // ── INFRA-617 new tests ────────────────────────────────────────────────

    #[test]
    fn infra617_ship_rate_returns_windows() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(&tmp, &[("EFFECTIVE: ship faster", now)]);
        let section = build_ship_rate_section(&tmp);
        assert_eq!(section.windows.len(), 3);
        assert!(
            section.windows[0].total >= 1,
            "1d window should have at least 1"
        );
        assert_eq!(section.windows[0].effective, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_ship_rate_pillar_classification() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(
            &tmp,
            &[
                ("EFFECTIVE: speed up", now),
                ("CREDIBLE: add scorecard", now),
                ("RESILIENT: watchdog", now),
                ("ZERO-WASTE: trim", now),
                ("untagged work", now),
            ],
        );
        let section = build_ship_rate_section(&tmp);
        assert!(section.windows[0].effective >= 1, "effective pillar");
        assert!(section.windows[0].credible >= 1, "credible pillar");
        assert!(section.windows[0].resilient >= 1, "resilient pillar");
        assert!(section.windows[0].zero_waste >= 1, "zero_waste pillar");
        assert!(section.windows[0].untagged >= 1, "untagged");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_mission_history_parses_ambient() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"ts":"{ts}","kind":"mission_grade","effective":{{"count_pickable":5,"count_in_flight":2,"count_shipped_24h":1}},"credible":{{"count_pickable":3,"count_in_flight":1,"count_shipped_24h":0}},"resilient":{{"count_pickable":2,"count_in_flight":0,"count_shipped_24h":0}},"zero_waste":{{"count_pickable":1,"count_in_flight":0,"count_shipped_24h":0}}}}"#
            )],
        );
        let section = build_mission_history_section(&tmp);
        assert_eq!(section.snapshots.len(), 1);
        assert_eq!(section.snapshots[0].effective_shipped, 1);
        assert_eq!(section.snapshots[0].credible_shipped, 0);
        assert_eq!(section.snapshots[0].total_pickable, 11);
        assert_eq!(section.snapshots[0].total_in_flight, 3);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_cost_savings_computes_baseline() {
        let tmp = tempdir();
        let ts = fixture_ts();
        // Session with together-deepseek-v3 (cheaper than Sonnet fallback).
        // together-deepseek-v3: $0.85/$0.85/$0.0 per MTok
        // unknown (Sonnet):     $3/$15/$0.30 per MTok
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-S","outcome":"shipped","elapsed_seconds":60,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":0,"model_id":"together-deepseek-v3"}}"#
            )],
        );
        let section = build_cost_savings_section(&tmp, 30);
        assert!(
            section.actual_cost_usd < section.anthropic_only_cost_usd,
            "deepseek model ({}) should cost less than anthropic-only baseline ({})",
            section.actual_cost_usd,
            section.anthropic_only_cost_usd
        );
        assert!(section.anthropic_only_cost_usd > 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_leverage_counts_depends_on() {
        let tmp = tempdir();
        let chump_dir = tmp.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&tmp)
            .output();

        let now = current_unix() as i64;
        let store = crate::gap_store::GapStore::open(&tmp).unwrap();

        // Reserve 3 gaps, capture auto-generated IDs.
        let id_x = store
            .reserve("INFRA", "EFFECTIVE: infra core", "P1", "s")
            .unwrap();
        let id_y = store
            .reserve("INFRA", "CREDIBLE: depends on X", "P1", "s")
            .unwrap();
        let id_z = store
            .reserve("INFRA", "RESILIENT: also depends on X", "P1", "s")
            .unwrap();

        // Mark all three done (raw SQL to set both closed_at and closed_date).
        let iso = unix_to_iso_date(now);
        for id in &[&id_x, &id_y, &id_z] {
            store
                .conn_for_test()
                .execute(
                    "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2, closed_pr=999 WHERE id=?3",
                    rusqlite::params![now, iso, id],
                )
                .unwrap();
        }

        // Set depends_on: Y→X, Z→X
        store
            .set_fields(
                &id_y,
                crate::gap_store::GapFieldUpdate {
                    depends_on: Some(id_x.clone()),
                    status: None,
                    closed_date: None,
                    closed_pr: None,
                    title: None,
                    description: None,
                    acceptance_criteria: None,
                    notes: None,
                    source_doc: None,
                    priority: None,
                    effort: None,
                    opened_date: None,
                    skills_required: None,
                    preferred_backend: None,
                    preferred_machine: None,
                    estimated_minutes: None,
                    required_model: None,
                    outcome_id: None,
                    evidence: None,
                },
            )
            .unwrap();
        store
            .set_fields(
                &id_z,
                crate::gap_store::GapFieldUpdate {
                    depends_on: Some(id_x.clone()),
                    status: None,
                    closed_date: None,
                    closed_pr: None,
                    title: None,
                    description: None,
                    acceptance_criteria: None,
                    notes: None,
                    source_doc: None,
                    priority: None,
                    effort: None,
                    opened_date: None,
                    skills_required: None,
                    preferred_backend: None,
                    preferred_machine: None,
                    estimated_minutes: None,
                    required_model: None,
                    outcome_id: None,
                    evidence: None,
                },
            )
            .unwrap();

        let section = build_leverage_section(&tmp);
        assert!(!section.entries.is_empty(), "should have leverage entries");
        let top = &section.entries[0];
        assert_eq!(top.gap_id, id_x);
        assert_eq!(top.depended_by_count, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_full_report_renders_all_sections() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(&tmp, &[("EFFECTIVE: full report", now)]);
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{ts}","kind":"mission_grade","effective":{{"count_pickable":1,"count_in_flight":0,"count_shipped_24h":1}},"credible":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}},"resilient":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}},"zero_waste":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}}}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-R","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":500,"cache_read_tokens":0}}"#
                ),
            ],
        );

        let report = build_full_report(&tmp, 7);
        let text = report.render_text();
        assert!(text.contains("Ship Rate Trend"));
        assert!(text.contains("Mission Grade History"));
        assert!(text.contains("Cost Savings vs Anthropic-Only"));
        assert!(text.contains("Productizations by Leverage"));
        assert!(text.contains("Tokens-per-Ship"));

        let json = report.render_json();
        assert!(json.contains(r#""ship_rate""#));
        assert!(json.contains(r#""mission_history""#));
        assert!(json.contains(r#""cost_savings""#));
        assert!(json.contains(r#""leverage""#));
        assert!(json.contains(r#""tokens_per_ship""#));
        assert!(json.contains(r#""handoff_rate""#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-773: HandoffRateSection tests ──────────────────────────────────

    fn write_ambient_handoff(root: &std::path::Path, lines: &[&str]) {
        let locks = root.join(".chump-locks");
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

    fn recent_ts() -> String {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Approximate ISO-8601 with just the unix timestamp as string; extract_field parses it
        format!("{secs}")
    }

    #[test]
    fn handoff_rate_zero_when_no_events() {
        let tmp = tempdir();
        let section = build_handoff_rate_section(&tmp, 7);
        assert_eq!(section.initiated, 0);
        assert_eq!(section.self_heal_rate(), 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn handoff_rate_counts_correctly() {
        let tmp = tempdir();
        let ts = recent_ts();
        write_ambient_handoff(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_initiated","pr":"123","reviewer_session":"s1","failure_surface":"test"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_initiated","pr":"124","reviewer_session":"s2","failure_surface":"lint"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_applied","pr":"123","author_session":"s3","handoff_comment_id":"c1"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_failed","pr":"124","author_session":"s4","failure_detail":"still red"}}"#
                ),
            ],
        );
        let section = build_handoff_rate_section(&tmp, 7);
        assert_eq!(section.initiated, 2);
        assert_eq!(section.applied, 1);
        assert_eq!(section.failed, 1);
        assert_eq!(section.timeout, 0);
        assert!((section.self_heal_rate() - 0.5).abs() < 0.01);
        assert!((section.reviewer_error_rate() - 0.5).abs() < 0.01);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn handoff_rate_render_text_no_handoffs() {
        let section = HandoffRateSection::default();
        let text = section.render_text();
        assert!(text.contains("no handoffs initiated"));
    }

    #[test]
    fn handoff_rate_render_text_with_data() {
        let section = HandoffRateSection {
            initiated: 4,
            applied: 3,
            failed: 1,
            timeout: 0,
        };
        let text = section.render_text();
        assert!(text.contains("Self-heal rate: 75%"));
        assert!(text.contains("Reviewer-error rate: 25%"));
    }

    #[test]
    fn handoff_rate_render_json() {
        let section = HandoffRateSection {
            initiated: 2,
            applied: 2,
            failed: 0,
            timeout: 0,
        };
        let json = section.render_json();
        assert!(json.contains(r#""initiated":2"#));
        assert!(json.contains(r#""applied":2"#));
        assert!(json.contains(r#""self_heal_rate_pct":100"#));
    }

    #[test]
    fn waste_kinds_includes_handoff_failed_and_timeout() {
        use crate::waste_tally::WASTE_KINDS;
        assert!(WASTE_KINDS.contains(&"review_handoff_failed"));
        assert!(WASTE_KINDS.contains(&"review_handoff_timeout"));
    }
}
