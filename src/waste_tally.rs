//! INFRA-488: Zero Waste mission pillar — track and measure fleet waste.
//!
//! The mission is now: build *credible, effective, resilient,* AND
//! *zero-waste* agents. This module is the primitive measurement layer.
//!
//! The taxonomy uses event kinds already emitted into
//! `.chump-locks/ambient.jsonl` by various subsystems — no new
//! emissions in this MVP. Future gaps extend the taxonomy by tagging
//! more events with `event=ALERT` and one of the kinds below.
//!
//! ## Waste taxonomy (existing event kinds, classified)
//!
//! | Kind                    | Source         | Cost it represents               |
//! |-------------------------|----------------|----------------------------------|
//! | `fleet_wedge`           | INFRA-483      | claude -p 0-byte cycle (~600s)  |
//! | `fleet_starved`         | INFRA-315      | idle worker, no pickable work   |
//! | `lease_expired_server`  | reaper         | session abandoned mid-work      |
//! | `reaper_silent`         | INFRA-120      | reaper job missed its cadence    |
//! | `queue_stuck`           | merge-queue    | PR queue jammed                 |
//! | `ambient_oversize`      | INFRA-122      | rotation didn't run              |
//! | `pr_stuck`              | INFRA-307      | PR stalled needing attention    |
//! | `silent_agent`          | coord          | live session stopped heartbeat  |
//! | `lease_overlap`         | coord          | two sessions claim same files   |
//! | `edit_burst`            | coord          | rapid mutations, rebase risk    |
//! | `session_abandoned`     | INFRA-477/492  | session ended without shipping  |
//! | `session_starved`       | INFRA-477/492  | session timed out (rc=124)      |
//! | `session_shipped_not_valuable` | FLEET-050 | session shipped code with no user value |
//! | `bot_merge_hang`        | INFRA-587      | bot-merge phase exceeded timeout — re-run is pure waste |
//! | `bot_merge_hot_file`    | bot-merge      | sibling collision on same file — re-rebase tax           |
//! | `pr_stuck_cluster`      | INFRA-848      | 3+ PRs stuck simultaneously — fleet-wide signal         |
//! | `fleet_auth_fallback`   | INFRA-622      | auth path failed; retry round burns probe tokens        |
//! | `slo_breach`            | INFRA-848      | curator detected SLO violation; downstream cost likely  |
//! | `missing_attribution`   | ambient hook   | session has no CHUMP_AGENT_HARNESS — telemetry blind   |
//!
//! ## Output
//!
//! `chump waste-tally [--since 24h] [--json]` prints a per-kind tally
//! plus rough cost estimates where measurable (e.g. `fleet_wedge`
//! events have `cooldown_secs` field — sum them).

use std::collections::BTreeMap;
use std::path::Path;

/// Per-kind aggregate across the time window.
#[derive(Debug, Clone, Default)]
pub struct WasteEntry {
    pub kind: String,
    pub count: u64,
    /// INFRA-489: number of unique incidents after deduplicating by
    /// (kind, entity). A single stuck reaper that re-emits every 30min
    /// for 12h shows as `count=24, incidents=1`. `incidents` is the
    /// headline metric going forward; `count` is preserved for
    /// forensics. Equals `count` when no entity can be extracted.
    pub incidents: u64,
    /// Sum of any `cooldown_secs`/`elapsed_seconds` field on these events.
    /// Best-effort — not all kinds carry a cost number.
    pub estimated_cost_secs: u64,
    /// INFRA-534: actual API cost in USD derived from token counts on
    /// `session_end` events. Zero for event kinds that don't carry tokens.
    pub cost_usd: f64,
    /// INFRA-641: total tokens burned across the events that contributed
    /// to this entry. Sum of `input_tokens + output_tokens` (or analogues)
    /// from any session_end / session_token_orphan events bucketed here.
    /// Zero for event kinds that don't carry token counts.
    pub tokens_burned: u64,
}

#[derive(Debug, Clone, Default)]
pub struct WasteReport {
    pub since_seconds: u64,
    pub total_events: u64,
    /// INFRA-489: total unique incidents (deduplicated). Always
    /// `<= total_events`. The 7-day baseline measured 169 events but
    /// only ~50 unique incidents — the rest were re-fired alerts on
    /// the same problem.
    pub total_incidents: u64,
    pub entries: Vec<WasteEntry>,
    /// INFRA-534: total actual API cost (USD) across all waste entries
    /// that carried token counts.
    pub total_cost_usd: f64,
    /// INFRA-641: total tokens burned across all waste entries.
    /// Useful when paired with `chump waste-tally --tokens` to size the
    /// daily token spend a single waste class is consuming.
    pub total_tokens_burned: u64,
}

/// INFRA-951: default token estimate per waste kind for events that don't
/// carry `input_tokens`/`output_tokens` (only `session_end` does).
///
/// These are deliberately conservative lower-bounds, sourced from rough
/// observation of typical retry/probe patterns:
///
///   * `fleet_auth_fallback` — one auth probe (POST + 401 retry) ≈ 200 tokens
///     of system-prompt overhead before the real call lands.
///   * `bot_merge_hot_file` — rebase round runs cargo check on a few files;
///     no LLM tokens directly, but the agent typically re-evaluates the
///     conflict resolution (~3k tokens per round).
///   * `slo_breach` — curator audit run is sonnet-3.7 reading state.db +
///     ambient tail ≈ 8k input + 1k output.
///   * `pr_stuck_cluster` — operator (or curator) triage ≈ 5k tokens.
///   * `bot_merge_hang` — wedge implies a stalled `claude -p` call that has
///     accumulated full system prompt + tools (~15k tokens) before timing
///     out — input tokens were paid for but produced no useful output.
///   * `missing_attribution` — no direct token cost; it's an observability
///     gap that hides cost elsewhere.
///
/// Returns 0 when no estimate applies (kind is a session_end derivative or
/// is otherwise observed-cost-only). Total cost is computed in USD via
/// session_ledger::cost_usd_from_tokens at the "unknown" price tier.
pub fn default_tokens_per_kind(kind: &str) -> u64 {
    match kind {
        "fleet_auth_fallback" => 200,
        "bot_merge_hot_file" => 3_000,
        "slo_breach" => 9_000,
        "pr_stuck_cluster" => 5_000,
        "bot_merge_hang" => 15_000,
        "missing_attribution" => 0,
        _ => 0,
    }
}

/// The set of `kind` values we classify as waste. Order matches the
/// taxonomy table in the module-level docs.
///
/// **INFRA-493:** synthetic kinds `session_abandoned` and
/// `session_starved` are also counted — these are derived from
/// INFRA-477's `session_end` events filtered by `outcome`. They have
/// no event line literally tagged `kind=session_abandoned`; the
/// classifier promotes `event=session_end` + `outcome=abandoned` into
/// that synthetic kind for tally purposes.
pub const WASTE_KINDS: &[&str] = &[
    "fleet_wedge",
    "fleet_starved",
    "lease_expired_server",
    "reaper_silent",
    "queue_stuck",
    "ambient_oversize",
    "pr_stuck",
    "silent_agent",
    "lease_overlap",
    "edit_burst",
    "session_abandoned", // INFRA-493 synthetic — from session_end outcome=abandoned
    "session_starved",   // INFRA-493 synthetic — from session_end outcome=starved
    "session_shipped_not_valuable", // FLEET-050 synthetic — from session_end outcome=shipped-not-valuable
    "worker_exit_timeout",          // INFRA-572 synthetic — from worker_exit exit_class=TIMEOUT
    "worker_exit_oom",              // INFRA-572 synthetic — from worker_exit exit_class=OOM_KILL
    "session_token_orphan",         // INFRA-639 synthetic — token_usage_partial with no session_end
    "review_handoff_failed", // INFRA-773 — handoff applied but CI still red (reviewer effort wasted)
    "review_handoff_timeout", // INFRA-773 — no author push within 15 min (reviewer effort wasted)
    // INFRA-950 expansion (2026-05-12) — kinds the ambient stream already emits
    // but waste-tally previously ignored.
    "bot_merge_hang", // INFRA-587 — bot-merge phase timeout; the wasted phase has to be re-run
    "bot_merge_hot_file", // bot-merge — sibling collision on same file; rebase tax
    "pr_stuck_cluster", // INFRA-848 — 3+ PRs stuck; correlated waste signal
    "fleet_auth_fallback", // INFRA-622 — auth fallback path triggered; probe + retry cost
    "slo_breach",     // INFRA-848 — curator-observed SLO breach (downstream cost)
    "missing_attribution", // ambient hook — session lacks CHUMP_AGENT_HARNESS; observability waste
];

/// Domain-level aggregate for `--by-domain` output (INFRA-574, INFRA-934).
#[derive(Debug, Clone, Default)]
pub struct WasteDomainEntry {
    pub domain: String,
    pub incidents: u64,
    pub gaps_run: u64,
    pub tokens_est: u64, // total tokens from all session_end events for this domain
    pub pct_of_total: f64, // tokens_est / total_tokens * 100.0
    pub estimated_cost_secs: u64,
    pub cost_usd: f64,
}

pub struct WasteDomainReport {
    pub since_seconds: u64,
    pub total_incidents: u64,
    pub total_tokens: u64,
    pub has_breach: bool,
    pub domains: Vec<WasteDomainEntry>,
}

/// Extract the domain prefix from a gap_id like "INFRA-574" → "INFRA".
/// Falls back to "(unknown)" if gap_id is absent or has no prefix.
fn domain_from_gap_id(gap_id: Option<&str>) -> String {
    let id = match gap_id {
        Some(s) if !s.is_empty() => s,
        _ => return "(unknown)".to_string(),
    };
    let end = id
        .find(|c: char| c == '-' || c.is_ascii_digit())
        .unwrap_or(id.len());
    if end == 0 {
        "(unknown)".to_string()
    } else {
        id[..end].to_ascii_uppercase()
    }
}

/// Build a by-domain waste report. INFRA-934: scans ALL session_end events
/// (any outcome) to compute token consumption per domain. pct_of_total is
/// tokens-based so CI can detect when one domain dominates spend. Waste
/// incident counts are also tracked for reference. `since_secs` is the
/// lookback window.
pub fn build_domain_report(repo_root: &Path, since_secs: u64) -> WasteDomainReport {
    // INFRA-934: honour CHUMP_AMBIENT_LOG env override (matches shell scripts).
    let ambient = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks/ambient.jsonl"));
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    use std::collections::HashSet;
    // domain → (entry, incident_set, gap_id_set)
    let mut by_domain: BTreeMap<String, (WasteDomainEntry, HashSet<String>, HashSet<String>)> =
        BTreeMap::new();
    let mut anon_seq: u64 = 0;

    // Pass 1: collect waste incidents (same logic as before, unchanged).
    for line in contents.lines() {
        let is_alert = line.contains(r#""event":"ALERT""#) || line.contains(r#""kind":""#);
        let is_session_end = line.contains(r#""kind":"session_end""#);
        let is_worker_exit = line.contains(r#""kind":"worker_exit""#);
        if !is_alert && !is_session_end && !is_worker_exit {
            continue;
        }
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts) {
                if unix < cutoff {
                    continue;
                }
            }
        }

        let raw_kind = extract_field(line, "kind").unwrap_or_default();
        let is_session_end_event = raw_kind == "session_end";
        let is_worker_exit_event = raw_kind == "worker_exit";
        let kind = if is_session_end_event {
            match extract_field(line, "outcome").as_deref() {
                Some("abandoned") => "session_abandoned".to_string(),
                Some("starved") => "session_starved".to_string(),
                Some("shipped-not-valuable") => "session_shipped_not_valuable".to_string(),
                _ => continue,
            }
        } else if is_worker_exit_event {
            match extract_field(line, "exit_class").as_deref() {
                Some("TIMEOUT") => "worker_exit_timeout".to_string(),
                Some("OOM_KILL") => "worker_exit_oom".to_string(),
                _ => continue,
            }
        } else {
            raw_kind
        };
        if !WASTE_KINDS.iter().any(|&k| k == kind) {
            continue;
        }

        let gap_id = extract_field(line, "gap_id");
        let domain = domain_from_gap_id(gap_id.as_deref());
        let cost = extract_int_field(line, "cooldown_secs")
            .or_else(|| extract_int_field(line, "elapsed_seconds"))
            // INFRA-950: explicit timeout_secs for bot_merge_hang events.
            .or_else(|| extract_int_field(line, "timeout_secs"))
            // INFRA-950: default-cost table for kinds without a duration field.
            // Conservative lower-bounds; INFRA-951 will refine with tokens.
            .or(match kind.as_str() {
                "bot_merge_hot_file" => Some(60),
                "fleet_auth_fallback" => Some(5),
                "slo_breach" => Some(120),
                "pr_stuck_cluster" => Some(300),
                "missing_attribution" => Some(0),
                _ => None,
            })
            .unwrap_or(0);
        let event_cost_usd = if is_session_end_event {
            let input = extract_int_field(line, "input_tokens").unwrap_or(0);
            let output = extract_int_field(line, "output_tokens").unwrap_or(0);
            let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
            let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
            crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache)
        } else {
            // INFRA-951: non-session_end kinds — apply default token estimate
            // and price via the "unknown" tier so the USD column is non-zero.
            let est_tokens = default_tokens_per_kind(&kind);
            if est_tokens > 0 {
                crate::session_ledger::cost_usd_from_tokens("unknown", est_tokens, 0, 0)
            } else {
                0.0
            }
        };
        let entity = match kind.as_str() {
            "silent_agent" | "lease_expired_server" | "lease_overlap" | "edit_burst" => {
                extract_session_from_note(line).or_else(|| extract_field(line, "gap_id"))
            }
            "reaper_silent" => extract_field(line, "reaper"),
            "pr_stuck" => extract_int_field(line, "pr")
                .map(|n| n.to_string())
                .or_else(|| {
                    let note = extract_field(line, "note").unwrap_or_default();
                    if note.starts_with('#') {
                        let end = note.find(' ').unwrap_or(note.len());
                        Some(note[..end].to_string())
                    } else {
                        None
                    }
                }),
            "fleet_wedge" | "fleet_starved" => {
                extract_field(line, "gap_id").or_else(|| extract_field(line, "agent"))
            }
            "worker_exit_timeout" | "worker_exit_oom" => extract_field(line, "gap_id")
                .or_else(|| extract_field(line, "agent_id"))
                .or_else(|| extract_field(line, "agent")),
            "session_abandoned" | "session_starved" | "session_shipped_not_valuable" => {
                extract_field(line, "session_id")
                    .or_else(|| extract_field(line, "session"))
                    .or_else(|| extract_field(line, "gap_id"))
            }
            // INFRA-950: entity extraction for the newly classified kinds.
            "bot_merge_hang" | "bot_merge_hot_file" => extract_field(line, "gap_id")
                .or_else(|| extract_int_field(line, "pr").map(|n| n.to_string()))
                .or_else(|| extract_field(line, "session")),
            "pr_stuck_cluster" => {
                extract_field(line, "root_cause").or_else(|| extract_field(line, "session"))
            }
            "fleet_auth_fallback" => {
                extract_field(line, "failed_mode").or_else(|| extract_field(line, "fallback_mode"))
            }
            "slo_breach" => extract_field(line, "severity"),
            "missing_attribution" => {
                extract_field(line, "session").or_else(|| extract_field(line, "worktree"))
            }
            _ => extract_field(line, "session")
                .or_else(|| extract_field(line, "reaper"))
                .or_else(|| extract_int_field(line, "pr").map(|n| n.to_string()))
                .or_else(|| extract_field(line, "gap_id"))
                .or_else(|| extract_field(line, "agent"))
                .or_else(|| extract_session_from_note(line)),
        }
        .unwrap_or_else(|| {
            anon_seq += 1;
            format!("__anon_{}", anon_seq)
        });

        let bucket = by_domain.entry(domain.clone()).or_insert_with(|| {
            (
                WasteDomainEntry {
                    domain: domain.clone(),
                    ..Default::default()
                },
                HashSet::new(),
                HashSet::new(),
            )
        });
        let incident_key = format!("{}:{}", kind, entity);
        bucket.0.estimated_cost_secs = bucket.0.estimated_cost_secs.saturating_add(cost);
        bucket.0.cost_usd += event_cost_usd;
        bucket.1.insert(incident_key);
        if let Some(gid) = gap_id.as_deref() {
            if !gid.is_empty() {
                bucket.2.insert(gid.to_string());
            }
        }
    }

    // Pass 2 (INFRA-934): scan ALL session_end events (any outcome) to collect
    // tokens_est and gaps_run per domain. This is the primary basis for pct_of_total.
    let mut total_tokens: u64 = 0;
    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        let gap_id = extract_field(line, "gap_id");
        let domain = domain_from_gap_id(gap_id.as_deref());
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
        let tokens = input.saturating_add(output).saturating_add(cache);
        total_tokens = total_tokens.saturating_add(tokens);

        let bucket = by_domain.entry(domain.clone()).or_insert_with(|| {
            (
                WasteDomainEntry {
                    domain: domain.clone(),
                    ..Default::default()
                },
                HashSet::new(),
                HashSet::new(),
            )
        });
        bucket.0.tokens_est = bucket.0.tokens_est.saturating_add(tokens);
        if let Some(gid) = gap_id.as_deref() {
            if !gid.is_empty() {
                bucket.2.insert(gid.to_string());
            }
        }
    }

    let mut total_incidents = 0u64;
    let mut domains: Vec<WasteDomainEntry> = by_domain
        .into_values()
        .map(|(mut e, incident_set, gap_set)| {
            e.incidents = incident_set.len() as u64;
            e.gaps_run = gap_set.len() as u64;
            total_incidents += e.incidents;
            // pct_of_total: prefer token-based when data available, fall back to
            // incident-based when no session_end token data exists (INFRA-934).
            e.pct_of_total = if total_tokens > 0 {
                (e.tokens_est as f64 / total_tokens as f64) * 100.0
            } else {
                // pct set in second pass below once total_incidents is known
                0.0
            };
            e
        })
        .collect();

    // If no token data, fill pct_of_total from incident share instead.
    if total_tokens == 0 {
        for e in &mut domains {
            e.pct_of_total = if total_incidents > 0 {
                (e.incidents as f64 / total_incidents as f64) * 100.0
            } else {
                0.0
            };
        }
    }

    // Sort by pct_of_total (tokens) descending (INFRA-934).
    domains.sort_by(|a, b| {
        b.pct_of_total
            .partial_cmp(&a.pct_of_total)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let has_breach = domains.iter().any(|e| e.pct_of_total > 40.0);

    WasteDomainReport {
        since_seconds: since_secs,
        total_incidents,
        total_tokens,
        has_breach,
        domains,
    }
}

impl WasteDomainReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let hours = self.since_seconds / 3600;
        out.push_str(&format!(
            "═══ Zero Waste Report (by domain) ═══ (last {} h, {} incidents)\n",
            hours.max(1),
            self.total_incidents
        ));
        if self.domains.is_empty() {
            out.push_str("  (no session events in window)\n");
            return out;
        }
        // INFRA-934: table with domain | gaps_run | tokens_est | pct
        out.push_str(&format!(
            "  {:<12}  {:>8}  {:>12}  {:>8}\n",
            "domain", "gaps_run", "tokens_est", "pct"
        ));
        out.push_str(&format!(
            "  {:<12}  {:>8}  {:>12}  {:>8}\n",
            "────────────", "────────", "────────────", "────────"
        ));
        for e in &self.domains {
            let tokens_str = if e.tokens_est > 0 {
                format!("{}", e.tokens_est)
            } else {
                "—".to_string()
            };
            out.push_str(&format!(
                "  {:<12}  {:>8}  {:>12}  {:>7.1}%\n",
                e.domain, e.gaps_run, tokens_str, e.pct_of_total
            ));
        }
        let total_mins: u64 = self
            .domains
            .iter()
            .map(|e| e.estimated_cost_secs)
            .sum::<u64>()
            / 60;
        if total_mins > 0 {
            out.push_str(&format!(
                "  ─────────────────────────────\n  Estimated wasted compute: ~{}m\n",
                total_mins
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let domains_json: Vec<String> = self
            .domains
            .iter()
            .map(|e| {
                format!(
                    r#"{{"domain":"{}","incidents":{},"gaps_run":{},"tokens_est":{},"pct_of_total":{:.2},"estimated_cost_secs":{},"cost_usd":{:.6}}}"#,
                    json_escape(&e.domain),
                    e.incidents,
                    e.gaps_run,
                    e.tokens_est,
                    e.pct_of_total,
                    e.estimated_cost_secs,
                    e.cost_usd
                )
            })
            .collect();
        format!(
            r#"{{"since_seconds":{},"total_incidents":{},"total_tokens":{},"has_breach":{},"domains":[{}]}}"#,
            self.since_seconds,
            self.total_incidents,
            self.total_tokens,
            self.has_breach,
            domains_json.join(",")
        )
    }

    /// Returns the first *named* domain (excluding `(unknown)`) that exceeds
    /// `threshold_pct` of total spend. Used by `chump waste-tally --domain`
    /// to exit non-zero on breach (INFRA-934). `(unknown)` is excluded because
    /// it is an attribution artifact, not a real gap domain.
    pub fn any_domain_exceeds(&self, threshold_pct: f64) -> Option<&WasteDomainEntry> {
        self.domains
            .iter()
            .find(|e| e.domain != "(unknown)" && e.pct_of_total > threshold_pct)
    }
}

/// Build a waste report for the given time window. `since_secs` is the
/// lookback window; events older than `now - since_secs` are excluded.
///
/// **INFRA-489:** also computes per-kind unique incidents by
/// deduplicating against an entity key extracted from each event. Most
/// re-fire alerts (reaper_silent every 30min, silent_agent every cycle)
/// share the same entity, so a 12h-stuck reaper collapses from 24
/// alerts to 1 incident. The entity comes from any of `session`,
/// `reaper`, `pr`, `gap_id`, `agent` — whichever the event carries.
/// Falls back to a per-event unique key (counts as its own incident)
/// when no entity field is present.
pub fn build_report(repo_root: &Path, since_secs: u64) -> WasteReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    use std::collections::HashSet;
    let mut by_kind: BTreeMap<String, (WasteEntry, HashSet<String>)> = BTreeMap::new();
    let mut total_in_window = 0u64;
    let mut anon_seq: u64 = 0;

    for line in contents.lines() {
        // Only inspect lines that look like JSON ALERT events OR the
        // INFRA-477 session_end events (INFRA-493 promotes those with
        // outcome=abandoned|starved into synthetic waste kinds).
        // INFRA-572: also inspect worker_exit events (classified by exit_class).
        let is_alert = line.contains(r#""event":"ALERT""#) || line.contains(r#""kind":""#);
        let is_session_end = line.contains(r#""kind":"session_end""#);
        let is_worker_exit = line.contains(r#""kind":"worker_exit""#);
        if !is_alert && !is_session_end && !is_worker_exit {
            continue;
        }

        // INFRA-493: classify session_end by outcome before the WASTE_KINDS
        // filter. session_end events themselves are not waste — only the
        // ones with outcome=abandoned|starved are.
        // FLEET-050: also classify outcome=shipped-not-valuable as waste.
        // INFRA-572: classify worker_exit by exit_class — TIMEOUT and
        // OOM_KILL are waste; CLEAN and INTERRUPT are not.
        let raw_kind = extract_field(line, "kind").unwrap_or_default();
        let is_session_end_event = raw_kind == "session_end";
        let is_worker_exit_event = raw_kind == "worker_exit";
        let kind = if is_session_end_event {
            match extract_field(line, "outcome").as_deref() {
                Some("abandoned") => "session_abandoned".to_string(),
                Some("starved") => "session_starved".to_string(),
                Some("shipped-not-valuable") => "session_shipped_not_valuable".to_string(),
                _ => continue, // outcome=shipped is not waste; skip.
            }
        } else if is_worker_exit_event {
            match extract_field(line, "exit_class").as_deref() {
                Some("TIMEOUT") => "worker_exit_timeout".to_string(),
                Some("OOM_KILL") => "worker_exit_oom".to_string(),
                _ => continue, // CLEAN, INTERRUPT, ERROR_* not waste
            }
        } else {
            raw_kind
        };
        if !WASTE_KINDS.iter().any(|&k| k == kind) {
            continue;
        }
        // Time-window filter: events without parseable ts are kept (be
        // generous; under-counting is worse than over-counting).
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        total_in_window += 1;
        let cost = extract_int_field(line, "cooldown_secs")
            .or_else(|| extract_int_field(line, "elapsed_seconds"))
            // INFRA-950: explicit timeout_secs for bot_merge_hang events.
            .or_else(|| extract_int_field(line, "timeout_secs"))
            // INFRA-950: default-cost table for kinds without a duration field.
            // Conservative lower-bounds; INFRA-951 will refine with tokens.
            .or(match kind.as_str() {
                "bot_merge_hot_file" => Some(60),
                "fleet_auth_fallback" => Some(5),
                "slo_breach" => Some(120),
                "pr_stuck_cluster" => Some(300),
                "missing_attribution" => Some(0),
                _ => None,
            })
            .unwrap_or(0);
        // INFRA-534: token-based cost only on session_end events.
        // INFRA-641: also harvest tokens_burned for the per-class report.
        let (event_cost_usd, event_tokens_burned) = if is_session_end_event {
            let input = extract_int_field(line, "input_tokens").unwrap_or(0);
            let output = extract_int_field(line, "output_tokens").unwrap_or(0);
            let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
            let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
            (
                crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache),
                input.saturating_add(output).saturating_add(cache),
            )
        } else {
            // INFRA-951: non-session_end kinds — apply default token estimate
            // so the cost rollup includes them. Priced at "unknown" tier.
            let est_tokens = default_tokens_per_kind(&kind);
            if est_tokens > 0 {
                (
                    crate::session_ledger::cost_usd_from_tokens("unknown", est_tokens, 0, 0),
                    est_tokens,
                )
            } else {
                (0.0, 0u64)
            }
        };

        // INFRA-489: kind-aware entity extraction. The naive "first
        // session field wins" approach picks the WATCHER (the coord
        // process emitting the alert), not the entity the alert is
        // ABOUT. silent_agent and lease_expired_server hide the actual
        // session in the `note` field's "session=X" substring; the
        // top-level `session` field is just the coord watcher and is
        // identical across all alerts.
        let entity = match kind.as_str() {
            "silent_agent" | "lease_expired_server" | "lease_overlap" | "edit_burst" => {
                // Entity is in the note's session= substring; gap_id is
                // a fallback for events that omit session.
                extract_session_from_note(line).or_else(|| extract_field(line, "gap_id"))
            }
            "reaper_silent" => extract_field(line, "reaper"),
            "pr_stuck" => extract_int_field(line, "pr")
                .map(|n| n.to_string())
                .or_else(|| {
                    // Legacy text form: '#1115 DIRTY ...'
                    let note = extract_field(line, "note").unwrap_or_default();
                    if note.starts_with('#') {
                        let end = note.find(' ').unwrap_or(note.len());
                        Some(note[..end].to_string())
                    } else {
                        None
                    }
                }),
            "fleet_wedge" | "fleet_starved" => {
                extract_field(line, "gap_id").or_else(|| extract_field(line, "agent"))
            }
            // INFRA-572: synthetic kinds — (gap_id, agent) pair is the entity.
            "worker_exit_timeout" | "worker_exit_oom" => extract_field(line, "gap_id")
                .or_else(|| extract_field(line, "agent_id"))
                .or_else(|| extract_field(line, "agent")),
            // INFRA-493: synthetic kinds — session_id is the entity.
            // FLEET-050: include shipped_not_valuable outcome.
            "session_abandoned" | "session_starved" | "session_shipped_not_valuable" => {
                extract_field(line, "session_id")
                    .or_else(|| extract_field(line, "session"))
                    .or_else(|| extract_field(line, "gap_id"))
            }
            // INFRA-950: entity extraction for the newly classified kinds.
            "bot_merge_hang" | "bot_merge_hot_file" => extract_field(line, "gap_id")
                .or_else(|| extract_int_field(line, "pr").map(|n| n.to_string()))
                .or_else(|| extract_field(line, "session")),
            "pr_stuck_cluster" => {
                extract_field(line, "root_cause").or_else(|| extract_field(line, "session"))
            }
            "fleet_auth_fallback" => {
                extract_field(line, "failed_mode").or_else(|| extract_field(line, "fallback_mode"))
            }
            "slo_breach" => extract_field(line, "severity"),
            "missing_attribution" => {
                extract_field(line, "session").or_else(|| extract_field(line, "worktree"))
            }
            // queue_stuck, ambient_oversize, silent_agent's siblings:
            // fall through to the generic search.
            _ => extract_field(line, "session")
                .or_else(|| extract_field(line, "reaper"))
                .or_else(|| extract_int_field(line, "pr").map(|n| n.to_string()))
                .or_else(|| extract_field(line, "gap_id"))
                .or_else(|| extract_field(line, "agent"))
                .or_else(|| extract_session_from_note(line)),
        }
        .unwrap_or_else(|| {
            anon_seq += 1;
            format!("__anon_{}", anon_seq)
        });

        let bucket = by_kind.entry(kind.clone()).or_insert_with(|| {
            (
                WasteEntry {
                    kind: kind.clone(),
                    count: 0,
                    incidents: 0,
                    estimated_cost_secs: 0,
                    cost_usd: 0.0,
                    tokens_burned: 0,
                },
                HashSet::new(),
            )
        });
        bucket.0.count += 1;
        bucket.0.estimated_cost_secs = bucket.0.estimated_cost_secs.saturating_add(cost);
        bucket.0.cost_usd += event_cost_usd;
        bucket.0.tokens_burned = bucket.0.tokens_burned.saturating_add(event_tokens_burned);
        bucket.1.insert(entity);
    }

    // INFRA-639: aggregate token_usage_partial events for sessions that never
    // emitted session_end (killed workers). Tracks the LAST seen values per
    // session_id because claude streams cumulative usage — the final partial
    // event has the most complete token count before the worker was killed.
    {
        // Collect session_ids that DID emit session_end within the window.
        let mut session_end_ids: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for line in contents.lines() {
            if !line.contains(r#""kind":"session_end""#) {
                continue;
            }
            if let Some(ts) = extract_field(line, "ts") {
                if let Some(unix) = parse_iso8601_to_unix(&ts) {
                    if unix < cutoff {
                        continue;
                    }
                }
            }
            if let Some(sid) =
                extract_field(line, "session_id").or_else(|| extract_field(line, "session"))
            {
                session_end_ids.insert(sid);
            }
        }

        // For each token_usage_partial event with no matching session_end,
        // track the last-seen token values per session_id.
        let mut orphan_tokens: BTreeMap<String, (u64, u64, u64)> = BTreeMap::new();
        for line in contents.lines() {
            if !line.contains(r#""kind":"token_usage_partial""#) {
                continue;
            }
            if let Some(ts) = extract_field(line, "ts") {
                if let Some(unix) = parse_iso8601_to_unix(&ts) {
                    if unix < cutoff {
                        continue;
                    }
                }
            }
            let sid = match extract_field(line, "session_id")
                .or_else(|| extract_field(line, "session"))
            {
                Some(s) => s,
                None => continue,
            };
            if session_end_ids.contains(&sid) {
                continue; // session_end carries the definitive cumulative count
            }
            let inp = extract_int_field(line, "input").unwrap_or(0);
            let out = extract_int_field(line, "output").unwrap_or(0);
            let crd = extract_int_field(line, "cache_read").unwrap_or(0);
            // Overwrite with latest values (API sends cumulative per-stream).
            orphan_tokens.insert(sid, (inp, out, crd));
        }

        for (sid, (inp, out, crd)) in orphan_tokens {
            total_in_window += 1;
            let cost = crate::session_ledger::cost_usd_from_tokens("unknown", inp, out, crd);
            let bucket = by_kind
                .entry("session_token_orphan".to_string())
                .or_insert_with(|| {
                    (
                        WasteEntry {
                            kind: "session_token_orphan".to_string(),
                            ..Default::default()
                        },
                        std::collections::HashSet::new(),
                    )
                });
            bucket.0.count += 1;
            bucket.0.cost_usd += cost;
            // INFRA-641: orphan token totals also feed the --tokens report.
            bucket.0.tokens_burned = bucket
                .0
                .tokens_burned
                .saturating_add(inp.saturating_add(out).saturating_add(crd));
            bucket.1.insert(sid);
        }
    }

    // Realize incidents = unique entity count.
    let mut total_incidents = 0u64;
    let entries: Vec<WasteEntry> = by_kind
        .into_values()
        .map(|(mut e, set)| {
            e.incidents = set.len() as u64;
            total_incidents += e.incidents;
            e
        })
        .collect();

    let total_cost_usd: f64 = entries.iter().map(|e| e.cost_usd).sum();
    let total_tokens_burned: u64 = entries
        .iter()
        .map(|e| e.tokens_burned)
        .fold(0u64, u64::saturating_add);

    WasteReport {
        since_seconds: since_secs,
        total_events: total_in_window,
        total_incidents,
        entries,
        total_cost_usd,
        total_tokens_burned,
    }
}

/// Parse the legacy free-text `note` field for `session=<id>`. Coord ALERTs
/// emit JSON like `{"kind":"silent_agent","note":"session=infra-470-fix gap=..."}` —
/// the entity for dedup is hidden inside `note`.
fn extract_session_from_note(line: &str) -> Option<String> {
    let note = extract_field(line, "note")?;
    let needle = "session=";
    let start = note.find(needle)? + needle.len();
    let rest = &note[start..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ',')
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    Some(rest[..end].to_string())
}

impl WasteReport {
    /// Render a human-readable summary for the terminal.
    /// INFRA-489: headlines unique incidents (deduped by entity), with
    /// raw event count shown alongside in parentheses for forensic
    /// transparency. The 7-day baseline of 169 events compressed to ~50
    /// incidents — the rest were re-fired alerts on the same problem.
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let hours = self.since_seconds / 3600;
        out.push_str(&format!(
            "═══ Zero Waste Report ═══ (last {} h, {} incidents from {} alerts)\n",
            hours.max(1),
            self.total_incidents,
            self.total_events
        ));
        if self.entries.is_empty() {
            out.push_str("  (no waste events in window — fleet healthy 🎉)\n");
            return out;
        }
        // Sort by incidents descending — re-fired alerts shouldn't dominate.
        let mut sorted = self.entries.clone();
        sorted.sort_by_key(|e| std::cmp::Reverse(e.incidents));
        for e in &sorted {
            let inflation = if e.incidents > 0 && e.count > e.incidents {
                format!(" (×{} alerts)", e.count)
            } else {
                String::new()
            };
            if e.estimated_cost_secs > 0 {
                let mins = e.estimated_cost_secs / 60;
                out.push_str(&format!(
                    "  {:>4} × {:24}{}  ~{}m est. cost\n",
                    e.incidents, e.kind, inflation, mins
                ));
            } else {
                out.push_str(&format!("  {:>4} × {}{}\n", e.incidents, e.kind, inflation));
            }
        }
        let total_mins: u64 = sorted.iter().map(|e| e.estimated_cost_secs).sum::<u64>() / 60;
        if total_mins > 0 {
            out.push_str(&format!(
                "  ─────────────────────────────\n  Estimated wasted compute: ~{}m\n",
                total_mins
            ));
        }
        out
    }

    /// Render as JSON for tooling consumption.
    /// INFRA-489: each entry now carries `incidents` (deduped) alongside
    /// `count` (raw); top level adds `total_incidents`.
    /// INFRA-534: each entry includes `cost_usd`; top level adds `total_cost_usd`.
    /// INFRA-641: each entry includes `tokens_burned`; top level adds
    /// `total_tokens_burned`.
    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                format!(
                    r#"{{"kind":"{}","count":{},"incidents":{},"estimated_cost_secs":{},"cost_usd":{:.6},"tokens_burned":{}}}"#,
                    json_escape(&e.kind),
                    e.count,
                    e.incidents,
                    e.estimated_cost_secs,
                    e.cost_usd,
                    e.tokens_burned
                )
            })
            .collect();
        format!(
            r#"{{"since_seconds":{},"total_events":{},"total_incidents":{},"total_cost_usd":{:.6},"total_tokens_burned":{},"entries":[{}]}}"#,
            self.since_seconds,
            self.total_events,
            self.total_incidents,
            self.total_cost_usd,
            self.total_tokens_burned,
            entries_json.join(",")
        )
    }

    /// INFRA-641: render a token-focused summary table.
    /// Sorts entries by `tokens_burned` descending so the heaviest waste
    /// classes lead. Pairs with `chump waste-tally --tokens` for sizing
    /// daily token budgets against waste classes.
    pub fn render_text_tokens(&self) -> String {
        let mut out = String::new();
        let hours = self.since_seconds / 3600;
        out.push_str(&format!(
            "═══ Zero Waste — Token Burn ═══ (last {} h, {} total tokens, ${:.2} est.)\n",
            hours.max(1),
            format_tokens(self.total_tokens_burned),
            self.total_cost_usd
        ));
        if self.entries.is_empty() || self.total_tokens_burned == 0 {
            out.push_str("  (no token-bearing waste events in window)\n");
            return out;
        }
        let mut sorted: Vec<&WasteEntry> = self
            .entries
            .iter()
            .filter(|e| e.tokens_burned > 0)
            .collect();
        sorted.sort_by_key(|e| std::cmp::Reverse(e.tokens_burned));
        for e in &sorted {
            let pct = if self.total_tokens_burned > 0 {
                (e.tokens_burned as f64 / self.total_tokens_burned as f64) * 100.0
            } else {
                0.0
            };
            out.push_str(&format!(
                "  {:>4} × {:24}  {:>9} tokens ({:>4.1}%)  ${:.2}\n",
                e.incidents,
                e.kind,
                format_tokens(e.tokens_burned),
                pct,
                e.cost_usd
            ));
        }
        out
    }
}

/// INFRA-641: human-readable token count helper. Compresses big numbers
/// to k/M form so a 12.4M token waste class is readable at a glance.
fn format_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Parse ISO-8601 "YYYY-MM-DDTHH:MM:SSZ" via date(1). Permissive: returns
/// None on any failure; caller should fall through.
fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if !out2.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out2.stdout).trim().parse().ok()
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                'u' => {
                    for _ in 0..4 {
                        chars.next()?;
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse().ok()
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        // INFRA-1070: pid+nanos can collide on platforms with sub-nanosecond
        // SystemTime resolution (macOS clamps to microseconds, so nanos =
        // micros*1000 and two close-together calls produce identical paths).
        // Adding a process-local atomic counter guarantees uniqueness even
        // when nanos repeat across parallel cargo test threads.
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);

        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra488-test-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            n
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_ambient(root: &Path, lines: &[&str]) {
        let lock_dir = root.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        let path = lock_dir.join("ambient.jsonl");
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    }

    #[test]
    fn infra488_empty_window_is_healthy() {
        let tmp = tempdir();
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 0);
        let text = report.render_text();
        assert!(text.contains("fleet healthy"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_classifies_known_waste_kinds() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let l1 = format!(
            r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1","cooldown_secs":14400}}"#,
            now_iso
        );
        let l2 = format!(
            r#"{{"event":"ALERT","kind":"fleet_starved","ts":"{}"}}"#,
            now_iso
        );
        let l3 = format!(
            r#"{{"event":"ALERT","kind":"lease_expired_server","ts":"{}"}}"#,
            now_iso
        );
        // Non-waste kind — should be ignored.
        let l4 = format!(
            r#"{{"event":"ALERT","kind":"file_edit","ts":"{}"}}"#,
            now_iso
        );
        write_ambient(&tmp, &[l1.as_str(), l2.as_str(), l3.as_str(), l4.as_str()]);
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 3, "only 3 of 4 lines are waste");
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"fleet_wedge"));
        assert!(kinds.contains(&"fleet_starved"));
        assert!(kinds.contains(&"lease_expired_server"));
        // fleet_wedge has cooldown_secs=14400 — picked up as cost.
        let wedge = report
            .entries
            .iter()
            .find(|e| e.kind == "fleet_wedge")
            .unwrap();
        assert_eq!(wedge.estimated_cost_secs, 14400);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra951_default_tokens_per_kind_returns_estimates() {
        // INFRA-951: each of the new waste kinds has a deliberate non-zero
        // token estimate (except missing_attribution which is observability-only).
        // Cargo-cult prevention: assert each one explicitly rather than range.
        assert_eq!(default_tokens_per_kind("fleet_auth_fallback"), 200);
        assert_eq!(default_tokens_per_kind("bot_merge_hot_file"), 3_000);
        assert_eq!(default_tokens_per_kind("slo_breach"), 9_000);
        assert_eq!(default_tokens_per_kind("pr_stuck_cluster"), 5_000);
        assert_eq!(default_tokens_per_kind("bot_merge_hang"), 15_000);
        assert_eq!(default_tokens_per_kind("missing_attribution"), 0);

        // Unknown kinds get zero — caller must opt-in via the table.
        assert_eq!(default_tokens_per_kind("nonsense_kind_xyz"), 0);

        // Pre-existing kinds get zero (token cost comes from session_end pass).
        assert_eq!(default_tokens_per_kind("fleet_wedge"), 0);
        assert_eq!(default_tokens_per_kind("session_abandoned"), 0);
    }

    #[test]
    fn infra950_classifies_new_waste_kinds() {
        // Each of the 6 INFRA-950 additions must (1) be classified as waste,
        // (2) carry a non-zero cost where the kind has a meaningful one.
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            format!(
                r#"{{"kind":"bot_merge_hang","ts":"{}","gap_id":"INFRA-X","phase":"clippy","timeout_secs":300,"session":"s1"}}"#,
                now_iso
            ),
            format!(
                r#"{{"kind":"bot_merge_hot_file","ts":"{}","gap_id":"INFRA-Y","pr":1234,"path":"src/foo.rs","session":"s2"}}"#,
                now_iso
            ),
            format!(
                r#"{{"kind":"pr_stuck_cluster","ts":"{}","count":3,"root_cause":"merge_queue","session":"s3"}}"#,
                now_iso
            ),
            format!(
                r#"{{"kind":"fleet_auth_fallback","ts":"{}","failed_mode":"api-key","fallback_mode":"oauth"}}"#,
                now_iso
            ),
            format!(
                r#"{{"kind":"slo_breach","ts":"{}","severity":"high"}}"#,
                now_iso
            ),
            format!(
                r#"{{"kind":"missing_attribution","ts":"{}","session":"s6","worktree":"wt1"}}"#,
                now_iso
            ),
        ];
        let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        write_ambient(&tmp, &refs);

        let report = build_report(&tmp, 86400);
        assert_eq!(
            report.total_events, 6,
            "all 6 new kinds should be counted (got {})",
            report.total_events
        );

        let by_kind: std::collections::HashMap<&str, &WasteEntry> = report
            .entries
            .iter()
            .map(|e| (e.kind.as_str(), e))
            .collect();

        // bot_merge_hang carries its real timeout_secs as cost.
        assert_eq!(
            by_kind["bot_merge_hang"].estimated_cost_secs, 300,
            "bot_merge_hang should pick up timeout_secs as cost"
        );
        // Default-cost table kinds get conservative lower bounds.
        assert_eq!(
            by_kind["bot_merge_hot_file"].estimated_cost_secs, 60,
            "bot_merge_hot_file default cost"
        );
        assert_eq!(
            by_kind["fleet_auth_fallback"].estimated_cost_secs, 5,
            "fleet_auth_fallback default cost"
        );
        assert_eq!(
            by_kind["slo_breach"].estimated_cost_secs, 120,
            "slo_breach default cost"
        );
        assert_eq!(
            by_kind["pr_stuck_cluster"].estimated_cost_secs, 300,
            "pr_stuck_cluster default cost"
        );
        // missing_attribution is an observability gap, not direct compute waste.
        assert_eq!(
            by_kind["missing_attribution"].estimated_cost_secs, 0,
            "missing_attribution has no direct compute cost"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_excludes_events_outside_window() {
        let tmp = tempdir();
        // Old timestamp — way outside any reasonable window.
        let old = r#"{"event":"ALERT","kind":"fleet_wedge","ts":"2020-01-01T00:00:00Z","cooldown_secs":3600}"#;
        write_ambient(&tmp, &[old]);
        // 1-hour window — old event excluded.
        let report = build_report(&tmp, 3600);
        assert_eq!(report.total_events, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_render_text_shows_cost_estimate() {
        // INFRA-489: use ..Default::default() so new fields don't churn
        // every test site (lesson from INFRA-482).
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 2,
            total_incidents: 2,
            entries: vec![WasteEntry {
                kind: "fleet_wedge".into(),
                count: 2,
                incidents: 2,
                estimated_cost_secs: 28800, // 8 hours
                ..Default::default()
            }],
            ..Default::default()
        };
        let text = report.render_text();
        assert!(text.contains("Zero Waste Report"));
        assert!(text.contains("fleet_wedge"));
        assert!(text.contains("~480m est. cost"), "got: {}", text);
        assert!(text.contains("Estimated wasted compute"));
    }

    #[test]
    fn infra488_render_json_is_parseable() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 1,
            total_incidents: 1,
            entries: vec![WasteEntry {
                kind: "fleet_starved".into(),
                count: 5,
                incidents: 1,
                estimated_cost_secs: 0,
                ..Default::default()
            }],
            ..Default::default()
        };
        let json = report.render_json();
        // Quick structural checks — not full parser.
        assert!(json.starts_with("{"));
        assert!(json.contains(r#""since_seconds":86400"#));
        assert!(json.contains(r#""total_events":1"#));
        assert!(json.contains(r#""kind":"fleet_starved""#));
        assert!(json.contains(r#""count":5"#));
    }

    #[test]
    fn infra489_dedup_collapses_refired_alerts() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Same reaper re-fires 5 times, plus one different reaper.
        let mut lines = Vec::new();
        for _ in 0..5 {
            lines.push(format!(
                r#"{{"event":"ALERT","kind":"reaper_silent","reaper":"pr","ts":"{}","age_hours":6}}"#,
                now_iso
            ));
        }
        lines.push(format!(
            r#"{{"event":"ALERT","kind":"reaper_silent","reaper":"worktree","ts":"{}","age_hours":4}}"#,
            now_iso
        ));
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 6);
        assert_eq!(
            report.total_incidents, 2,
            "5+1 alerts collapse to 2 unique reapers"
        );
        let entry = report
            .entries
            .iter()
            .find(|e| e.kind == "reaper_silent")
            .unwrap();
        assert_eq!(entry.count, 6);
        assert_eq!(entry.incidents, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra489_dedup_extracts_session_from_note_field() {
        // silent_agent ALERTs put the entity in the legacy `note` field.
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines: Vec<String> = (0..3)
            .map(|_| format!(
                r#"{{"event":"ALERT","kind":"silent_agent","ts":"{}","note":"session=infra-470-fix gap=INFRA-470 last_event_age=701m"}}"#,
                now_iso
            ))
            .chain(std::iter::once(format!(
                r#"{{"event":"ALERT","kind":"silent_agent","ts":"{}","note":"session=infra-471-fix gap=INFRA-471 last_event_age=620m"}}"#,
                now_iso
            )))
            .collect();
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 4);
        let entry = report
            .entries
            .iter()
            .find(|e| e.kind == "silent_agent")
            .unwrap();
        assert_eq!(entry.count, 4);
        assert_eq!(entry.incidents, 2, "2 unique sessions despite 4 alerts");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra489_render_text_shows_inflation_marker() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 40,
            total_incidents: 1,
            entries: vec![WasteEntry {
                kind: "reaper_silent".into(),
                count: 40,
                incidents: 1,
                estimated_cost_secs: 0,
                ..Default::default()
            }],
            ..Default::default()
        };
        let text = report.render_text();
        // Headline shows incidents AND alert count.
        assert!(text.contains("1 incidents from 40 alerts"));
        // Per-entry shows the inflation marker.
        assert!(text.contains("(×40 alerts)"));
    }

    #[test]
    fn infra488_taxonomy_has_all_documented_kinds() {
        // INFRA-493: 10 original + 2 session-end synthetic = 12.
        // INFRA-572: +2 worker_exit synthetic (timeout + oom) = 14.
        // INFRA-639: +1 session_token_orphan (partial tokens, no session_end) = 15.
        // FLEET-050: +1 session_shipped_not_valuable (shipped but no user value) = 16.
        // INFRA-773: +2 review_handoff_failed + review_handoff_timeout = 18.
        // INFRA-950: +6 (bot_merge_hang, bot_merge_hot_file, pr_stuck_cluster,
        //             fleet_auth_fallback, slo_breach, missing_attribution) = 24.
        assert_eq!(WASTE_KINDS.len(), 24);
    }

    #[test]
    fn infra493_session_end_abandoned_classified_as_waste() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            // shipped session — should NOT count as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-A","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":600}}"#,
                now_iso
            ),
            // abandoned session — counts as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-B","gap_id":"INFRA-2","outcome":"abandoned","elapsed_seconds":300}}"#,
                now_iso
            ),
            // starved (timeout) — counts as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-C","gap_id":"INFRA-3","outcome":"starved","elapsed_seconds":600}}"#,
                now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        // 2 waste events (abandoned + starved); shipped excluded.
        assert_eq!(report.total_events, 2);
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"session_abandoned"));
        assert!(kinds.contains(&"session_starved"));
        // Cost summed from elapsed_seconds.
        let abandoned = report
            .entries
            .iter()
            .find(|e| e.kind == "session_abandoned")
            .unwrap();
        assert_eq!(abandoned.estimated_cost_secs, 300);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra493_session_end_dedupes_by_session_id() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Same session abandoned twice (shouldn't happen but test the dedup).
        let lines: Vec<String> = (0..3)
            .map(|i| format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-X","gap_id":"INFRA-{}","outcome":"abandoned","elapsed_seconds":100}}"#,
                now_iso, i
            ))
            .collect();
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        let abandoned = report
            .entries
            .iter()
            .find(|e| e.kind == "session_abandoned")
            .unwrap();
        assert_eq!(abandoned.count, 3);
        assert_eq!(
            abandoned.incidents, 1,
            "same session_id collapses to 1 incident"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn fleet050_session_end_shipped_not_valuable_classified_as_waste() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            // shipped session with value — should NOT count as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-A","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":600}}"#,
                now_iso
            ),
            // shipped but not valuable — counts as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-B","gap_id":"INFRA-2","outcome":"shipped-not-valuable","elapsed_seconds":300}}"#,
                now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        // Only 1 waste event (shipped-not-valuable); shipped excluded.
        assert_eq!(report.total_events, 1);
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"session_shipped_not_valuable"));
        assert!(!kinds.contains(&"session_abandoned"));
        // Cost summed from elapsed_seconds.
        let not_valuable = report
            .entries
            .iter()
            .find(|e| e.kind == "session_shipped_not_valuable")
            .unwrap();
        assert_eq!(not_valuable.estimated_cost_secs, 300);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra572_worker_exit_classified_by_exit_class() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            // CLEAN — not waste
            format!(
                r#"{{"ts":"{}","event":"worker_exit","kind":"worker_exit","agent_id":"1","gap_id":"INFRA-A","rc":0,"exit_class":"CLEAN"}}"#,
                now_iso
            ),
            // TIMEOUT — waste
            format!(
                r#"{{"ts":"{}","event":"worker_exit","kind":"worker_exit","agent_id":"1","gap_id":"INFRA-B","rc":124,"exit_class":"TIMEOUT"}}"#,
                now_iso
            ),
            // OOM_KILL — waste
            format!(
                r#"{{"ts":"{}","event":"worker_exit","kind":"worker_exit","agent_id":"2","gap_id":"INFRA-C","rc":137,"exit_class":"OOM_KILL"}}"#,
                now_iso
            ),
            // INTERRUPT — not waste
            format!(
                r#"{{"ts":"{}","event":"worker_exit","kind":"worker_exit","agent_id":"2","gap_id":"INFRA-D","rc":130,"exit_class":"INTERRUPT"}}"#,
                now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        assert_eq!(
            report.total_events, 2,
            "only TIMEOUT and OOM_KILL are waste"
        );
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"worker_exit_timeout"));
        assert!(kinds.contains(&"worker_exit_oom"));
        assert!(!kinds.contains(&"worker_exit_clean"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-574: by-domain tests ─────────────────────────────────────────

    #[test]
    fn infra574_domain_from_gap_id_extracts_prefix() {
        assert_eq!(domain_from_gap_id(Some("INFRA-574")), "INFRA");
        assert_eq!(domain_from_gap_id(Some("COG-12")), "COG");
        assert_eq!(domain_from_gap_id(Some("EVAL-1")), "EVAL");
        assert_eq!(domain_from_gap_id(Some("META-99")), "META");
        assert_eq!(domain_from_gap_id(None), "(unknown)");
        assert_eq!(domain_from_gap_id(Some("")), "(unknown)");
    }

    #[test]
    fn infra574_build_domain_report_buckets_by_domain() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            format!(
                r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1","cooldown_secs":3600}}"#,
                now_iso
            ),
            format!(
                r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-2","cooldown_secs":1800}}"#,
                now_iso
            ),
            format!(
                r#"{{"event":"ALERT","kind":"fleet_starved","ts":"{}","gap_id":"COG-5"}}"#,
                now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_domain_report(&tmp, 86400);
        assert_eq!(report.total_incidents, 3);
        let infra = report.domains.iter().find(|d| d.domain == "INFRA").unwrap();
        assert_eq!(infra.incidents, 2);
        assert_eq!(infra.estimated_cost_secs, 5400);
        let cog = report.domains.iter().find(|d| d.domain == "COG").unwrap();
        assert_eq!(cog.incidents, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra574_build_domain_report_unknown_for_no_gap_id() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let line = format!(
            r#"{{"event":"ALERT","kind":"reaper_silent","ts":"{}","reaper":"pr"}}"#,
            now_iso
        );
        write_ambient(&tmp, &[line.as_str()]);
        let report = build_domain_report(&tmp, 86400);
        assert_eq!(report.total_incidents, 1);
        let unknown = report
            .domains
            .iter()
            .find(|d| d.domain == "(unknown)")
            .unwrap();
        assert_eq!(unknown.incidents, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra574_domain_report_render_text_and_json() {
        let report = WasteDomainReport {
            since_seconds: 86400,
            total_incidents: 3,
            total_tokens: 5000,
            has_breach: true,
            domains: vec![
                WasteDomainEntry {
                    domain: "INFRA".into(),
                    incidents: 2,
                    gaps_run: 1,
                    tokens_est: 4000,
                    pct_of_total: 80.0,
                    estimated_cost_secs: 7200,
                    cost_usd: 0.0,
                },
                WasteDomainEntry {
                    domain: "COG".into(),
                    incidents: 1,
                    gaps_run: 0,
                    tokens_est: 1000,
                    pct_of_total: 20.0,
                    estimated_cost_secs: 0,
                    cost_usd: 0.0,
                },
            ],
        };
        let text = report.render_text();
        assert!(text.contains("by domain"), "got: {}", text);
        assert!(text.contains("INFRA"));
        assert!(text.contains("COG"));
        // INFRA-934: table format shows tokens_est column
        assert!(text.contains("tokens_est"), "got: {}", text);
        let json = report.render_json();
        assert!(json.contains(r#""domain":"INFRA""#));
        assert!(json.contains(r#""incidents":2"#));
        assert!(json.contains(r#""total_incidents":3"#));
        // INFRA-934: new fields in JSON
        assert!(json.contains(r#""gaps_run":1"#));
        assert!(json.contains(r#""tokens_est":4000"#));
    }

    #[test]
    fn infra639_partial_tokens_without_session_end_create_orphan_entry() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Two partial events for the same orphaned session (no session_end).
        // Second event has higher counts — build_report should take last-seen.
        let lines = [
            format!(
                r#"{{"ts":"{now}","kind":"token_usage_partial","session_id":"orphan-1","gap_id":"INFRA-639","cycle_id":"1-INFRA-639-20260506","input":500,"output":100,"cache_read":200,"cache_creation":0}}"#,
                now = now_iso
            ),
            format!(
                r#"{{"ts":"{now}","kind":"token_usage_partial","session_id":"orphan-1","gap_id":"INFRA-639","cycle_id":"1-INFRA-639-20260506","input":1000,"output":300,"cache_read":400,"cache_creation":0}}"#,
                now = now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        let orphan = report
            .entries
            .iter()
            .find(|e| e.kind == "session_token_orphan");
        assert!(
            orphan.is_some(),
            "session_token_orphan entry expected; got: {:?}",
            report.entries.iter().map(|e| &e.kind).collect::<Vec<_>>()
        );
        let orphan = orphan.unwrap();
        assert_eq!(orphan.incidents, 1, "one unique orphaned session");
        assert!(
            orphan.cost_usd > 0.0,
            "cost_usd should be nonzero for orphaned tokens"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra639_partial_tokens_suppressed_when_session_end_present() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Partial event + matching session_end for same session_id → no orphan.
        let lines = [
            format!(
                r#"{{"ts":"{now}","kind":"token_usage_partial","session_id":"sess-done","gap_id":"INFRA-639","cycle_id":"1-INFRA-639-20260506","input":1000,"output":200,"cache_read":0,"cache_creation":0}}"#,
                now = now_iso
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{now}","session_id":"sess-done","gap_id":"INFRA-639","outcome":"shipped","elapsed_seconds":600,"input_tokens":1000,"output_tokens":200,"cache_read_tokens":0}}"#,
                now = now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        let orphan = report
            .entries
            .iter()
            .find(|e| e.kind == "session_token_orphan");
        assert!(
            orphan.is_none(),
            "no orphan entry when session_end covers the session; entries: {:?}",
            report.entries.iter().map(|e| &e.kind).collect::<Vec<_>>()
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-641: --tokens flag tests ───────────────────────────────────

    #[test]
    fn infra641_render_text_tokens_shows_per_class_breakdown() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 4,
            total_incidents: 3,
            entries: vec![
                WasteEntry {
                    kind: "session_abandoned".into(),
                    count: 2,
                    incidents: 2,
                    tokens_burned: 1_200_000,
                    cost_usd: 4.8,
                    ..Default::default()
                },
                WasteEntry {
                    kind: "session_token_orphan".into(),
                    count: 1,
                    incidents: 1,
                    tokens_burned: 300_000,
                    cost_usd: 1.2,
                    ..Default::default()
                },
            ],
            total_cost_usd: 6.0,
            total_tokens_burned: 1_500_000,
        };
        let text = report.render_text_tokens();
        assert!(
            text.contains("Token Burn"),
            "header missing — got:\n{}",
            text
        );
        // Heaviest class leads (sorted by tokens_burned desc).
        let abandoned_pos = text.find("session_abandoned").expect("abandoned line");
        let orphan_pos = text.find("session_token_orphan").expect("orphan line");
        assert!(
            abandoned_pos < orphan_pos,
            "session_abandoned (1.2M tokens) should sort above session_token_orphan (300k); got:\n{}",
            text
        );
        // Compressed token formatting: 1.2M / 300.0k.
        assert!(text.contains("1.2M"), "got:\n{}", text);
        assert!(text.contains("300.0k"), "got:\n{}", text);
        // Cost shown alongside token counts.
        assert!(text.contains("$4.80"), "got:\n{}", text);
    }

    #[test]
    fn infra641_render_text_tokens_handles_empty_window() {
        let empty = WasteReport::default();
        let text = empty.render_text_tokens();
        assert!(text.contains("Token Burn"));
        assert!(text.contains("no token-bearing waste events"));
    }

    #[test]
    fn infra641_render_json_includes_tokens_fields() {
        let report = WasteReport {
            since_seconds: 3600,
            total_events: 1,
            total_incidents: 1,
            entries: vec![WasteEntry {
                kind: "session_abandoned".into(),
                count: 1,
                incidents: 1,
                tokens_burned: 42_000,
                cost_usd: 0.17,
                ..Default::default()
            }],
            total_cost_usd: 0.17,
            total_tokens_burned: 42_000,
        };
        let json = report.render_json();
        assert!(
            json.contains(r#""tokens_burned":42000"#),
            "per-entry tokens_burned missing — got:\n{}",
            json
        );
        assert!(
            json.contains(r#""total_tokens_burned":42000"#),
            "top-level total_tokens_burned missing — got:\n{}",
            json
        );
    }

    #[test]
    fn infra641_format_tokens_compresses_big_numbers() {
        assert_eq!(format_tokens(0), "0");
        assert_eq!(format_tokens(999), "999");
        assert_eq!(format_tokens(1_000), "1.0k");
        assert_eq!(format_tokens(1_500), "1.5k");
        assert_eq!(format_tokens(1_000_000), "1.0M");
        assert_eq!(format_tokens(12_400_000), "12.4M");
    }

    fn chrono_now_iso() -> String {
        // Use date(1) — same as the production helper.
        std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "2026-05-05T20:00:00Z".to_string())
    }

    /// INFRA-1070 regression: exercise the tempdir() helper from many threads
    /// to confirm the atomic counter eliminates the pid+nanos collision class.
    /// Without the fix, 100 parallel runs would occasionally produce
    /// duplicate paths on macOS (microsecond SystemTime resolution).
    #[test]
    fn infra1070_tempdir_unique_under_parallel_calls() {
        use std::sync::Arc;
        use std::sync::Mutex;
        let paths = Arc::new(Mutex::new(Vec::new()));
        let mut handles = vec![];
        for _ in 0..8 {
            let paths = Arc::clone(&paths);
            handles.push(std::thread::spawn(move || {
                let mut local = Vec::with_capacity(50);
                for _ in 0..50 {
                    local.push(tempdir());
                }
                paths.lock().unwrap().extend(local);
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        let all = paths.lock().unwrap();
        // 8 threads × 50 calls = 400 paths; all must be unique.
        let unique: std::collections::HashSet<_> = all.iter().collect();
        assert_eq!(
            unique.len(),
            400,
            "tempdir() returned duplicate paths under parallel calls; {} unique of {}",
            unique.len(),
            all.len()
        );
        // Cleanup.
        for p in all.iter() {
            let _ = std::fs::remove_dir_all(p);
        }
    }
}

// ── INFRA-998: --by-close-reason categorization ───────────────────────────
//
// Classifies closed-not-merged PRs by their last close comment so the
// operator can see WHICH waste class is dominant (superseded vs duplicate
// vs scratch-commit, etc.) — each class has a distinct prevention gap.
//
// Patterns derived from the 2026-05-13 PR closure audit
// (docs/syntheses/2026-05-13-fleet-unblock-pwa-cockpit.md §4).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ClosureReason {
    /// "gap already shipped via another path", "superseded by #N", "already in main"
    Superseded,
    /// duplicate-claim race (two agents picked the same gap)
    DuplicateClaim,
    /// stale branch with fmt/merge-conflict failures after sitting too long
    StaleBranch,
    /// catastrophic-delete scratch commit (the 378K-deletion class)
    ScratchCommit,
    /// CI failure that was never fixed before the branch went stale/closed
    CiFailOrphan,
    /// pre-rebase staging branch opened as a PR with no real gap work
    StagingBranch,
    /// fallback — close comment doesn't match any known pattern
    Other,
}

impl ClosureReason {
    pub fn as_str(self) -> &'static str {
        match self {
            ClosureReason::Superseded => "superseded",
            ClosureReason::DuplicateClaim => "duplicate_claim",
            ClosureReason::StaleBranch => "stale_branch",
            ClosureReason::ScratchCommit => "scratch_commit",
            ClosureReason::CiFailOrphan => "ci_fail_orphan",
            ClosureReason::StagingBranch => "staging_branch",
            ClosureReason::Other => "other",
        }
    }
}

/// Classify a close-comment body into one of the seven taxonomy buckets.
///
/// Order matters — more specific patterns are checked first so generic
/// substrings (e.g. "stale") don't out-match a more meaningful pattern
/// (e.g. "duplicate"). The Other bucket catches everything else.
pub fn classify_close_reason(comment: &str) -> ClosureReason {
    let lc = comment.to_ascii_lowercase();
    // Scratch-commit is the most distinctive — match before anything else.
    // Threshold "100000 deletions" or explicit phrase.
    if lc.contains("scratch-commit")
        || lc.contains("scratch commit")
        || lc.contains("382,778 deletions")
        || lc.contains("382778 deletions")
        || lc.contains("catastrophic-delete")
    {
        return ClosureReason::ScratchCommit;
    }
    // Staging-branch — explicit phrase.
    if lc.contains("pre-rebase staging")
        || lc.contains("no meaningful work")
        || lc.contains("staging-only branch")
    {
        return ClosureReason::StagingBranch;
    }
    // Duplicate-claim before "superseded" since dup language is more specific.
    if lc.contains("duplicate") || lc.contains("same as #") || lc.contains("dup of #") {
        return ClosureReason::DuplicateClaim;
    }
    // Superseded class — broad signals that work landed elsewhere.
    if lc.contains("superseded")
        || lc.contains("already marked done")
        || lc.contains("already in main")
        || lc.contains("cherry-picked")
        || lc.contains("gap shipped via")
        || lc.contains("commit already merged")
    {
        return ClosureReason::Superseded;
    }
    // Stale-branch: fmt/merge-conflict patterns after sitting too long.
    if lc.contains("too stale")
        || lc.contains("fmt failure")
        || lc.contains("merge conflict")
        || lc.contains("rebase failed")
        || lc.contains("commits behind main")
    {
        return ClosureReason::StaleBranch;
    }
    // CI-fail-orphan: explicit CI failure language + abandonment phrasing.
    if (lc.contains("ci fail") || lc.contains("ci failure") || lc.contains("e2e fail"))
        && (lc.contains("preserve") || lc.contains("re-open") || lc.contains("never fixed"))
    {
        return ClosureReason::CiFailOrphan;
    }
    if lc.contains("audit ci failure") || lc.contains("test failure") {
        return ClosureReason::CiFailOrphan;
    }
    ClosureReason::Other
}

#[derive(Debug, Clone)]
pub struct ClosureReasonEntry {
    pub reason: ClosureReason,
    pub count: u64,
    pub pr_numbers: Vec<u64>,
}

#[derive(Debug, Clone)]
pub struct ClosureReasonReport {
    pub entries: Vec<ClosureReasonEntry>,
    pub total: u64,
    pub window_secs: u64,
    /// True if the data fetch failed (gh CLI missing, rate limited, etc.).
    /// Reports a single Other entry covering all PRs we couldn't classify.
    pub fetch_failed: bool,
}

impl ClosureReasonReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "== chump waste-tally --by-close-reason (window {}s, {} PRs) ==\n\n",
            self.window_secs, self.total
        ));
        if self.fetch_failed {
            out.push_str("(WARN: gh CLI fetch failed — partial data. Set GH_TOKEN and rerun.)\n\n");
        }
        if self.total == 0 {
            out.push_str("No closed-not-merged PRs in window. Either the fleet is shipping\nclean, or there's a fetch problem. Check gh auth status.\n");
            return out;
        }
        out.push_str("category         count    %      sample PRs\n");
        out.push_str("---------------- -----  -----  ----------\n");
        for e in &self.entries {
            let pct = if self.total > 0 {
                (e.count as f64) * 100.0 / (self.total as f64)
            } else {
                0.0
            };
            let sample: Vec<String> = e
                .pr_numbers
                .iter()
                .take(3)
                .map(|n| format!("#{}", n))
                .collect();
            out.push_str(&format!(
                "{:16} {:>5}  {:>5.1}%  {}\n",
                e.reason.as_str(),
                e.count,
                pct,
                sample.join(" ")
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let entries: Vec<serde_json::Value> = self
            .entries
            .iter()
            .map(|e| {
                let pct = if self.total > 0 {
                    (e.count as f64) * 100.0 / (self.total as f64)
                } else {
                    0.0
                };
                serde_json::json!({
                    "category": e.reason.as_str(),
                    "count": e.count,
                    "percent": (pct * 10.0).round() / 10.0,
                    "pr_numbers": e.pr_numbers,
                })
            })
            .collect();
        serde_json::json!({
            "window_secs": self.window_secs,
            "total": self.total,
            "fetch_failed": self.fetch_failed,
            "categories": entries,
        })
        .to_string()
    }

    /// Emit `kind=waste_category_report` to ambient.jsonl. Best-effort —
    /// silently no-ops if the file isn't writable. Called when the operator
    /// passes `--emit-ambient` (or when a scheduled cron job runs).
    pub fn emit_ambient(&self, repo_root: &Path) {
        let event = serde_json::json!({
            "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "kind": "waste_category_report",
            "window_secs": self.window_secs,
            "total": self.total,
            "by_category": self.entries.iter()
                .map(|e| serde_json::json!({"category": e.reason.as_str(), "count": e.count}))
                .collect::<Vec<_>>(),
        });
        let path = repo_root.join(".chump-locks").join("ambient.jsonl");
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            use std::io::Write;
            let _ = writeln!(f, "{}", event);
        }
    }
}

/// Build the report by shelling out to `gh pr list` and `gh pr view --comments`.
/// Slow (one gh call per closed PR) — acceptable for a weekly cron.
pub fn build_close_reason_report(window_secs: u64) -> ClosureReasonReport {
    let cutoff_days = ((window_secs as f64) / 86400.0).ceil().max(1.0) as u64;
    let search = format!(
        "is:closed -is:merged closed:>={}",
        iso_date_n_days_ago(cutoff_days)
    );
    let list_out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--search",
            &search,
            "--limit",
            "100",
            "--state",
            "closed",
            "--json",
            "number,closedAt",
        ])
        .output();
    let list_json: Vec<serde_json::Value> = match list_out {
        Ok(o) if o.status.success() => serde_json::from_slice(&o.stdout).unwrap_or_default(),
        _ => {
            return ClosureReasonReport {
                entries: vec![],
                total: 0,
                window_secs,
                fetch_failed: true,
            };
        }
    };

    let mut buckets: BTreeMap<&'static str, (ClosureReason, Vec<u64>)> = BTreeMap::new();
    for pr_v in &list_json {
        let n = pr_v.get("number").and_then(|v| v.as_u64()).unwrap_or(0);
        if n == 0 {
            continue;
        }
        // Fetch the last comment (cheaper than --comments which can be huge).
        let body = fetch_last_close_comment(n).unwrap_or_default();
        let reason = classify_close_reason(&body);
        let key = reason.as_str();
        buckets
            .entry(key)
            .or_insert_with(|| (reason, vec![]))
            .1
            .push(n);
    }

    let mut entries: Vec<ClosureReasonEntry> = buckets
        .into_iter()
        .map(|(_k, (reason, prs))| ClosureReasonEntry {
            reason,
            count: prs.len() as u64,
            pr_numbers: prs,
        })
        .collect();
    entries.sort_by(|a, b| b.count.cmp(&a.count));
    let total = entries.iter().map(|e| e.count).sum();
    ClosureReasonReport {
        entries,
        total,
        window_secs,
        fetch_failed: false,
    }
}

fn fetch_last_close_comment(pr: u64) -> Option<String> {
    let out = std::process::Command::new("gh")
        .args(["pr", "view", &pr.to_string(), "--json", "comments"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    let comments = v.get("comments")?.as_array()?;
    // Most recent comment (sorted by createdAt ascending in gh output).
    let last = comments.last()?;
    Some(last.get("body")?.as_str()?.to_string())
}

fn iso_date_n_days_ago(n: u64) -> String {
    // Shell out to date(1) for parity with the rest of this module.
    let out = std::process::Command::new("date")
        .args(["-u", "-v", &format!("-{}d", n), "+%Y-%m-%d"])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            // Linux date(1) doesn't support -v; try GNU syntax.
            let alt = std::process::Command::new("date")
                .args(["-u", "-d", &format!("{} days ago", n), "+%Y-%m-%d"])
                .output();
            match alt {
                Ok(o) if o.status.success() => {
                    String::from_utf8_lossy(&o.stdout).trim().to_string()
                }
                _ => "2026-01-01".to_string(),
            }
        }
    }
}

#[cfg(test)]
mod close_reason_tests {
    use super::*;

    #[test]
    fn classify_superseded_synonyms() {
        for body in &[
            "Superseded by #1234 which landed the same fix.",
            "gap INFRA-XXX already marked done; closing.",
            "Cherry-picked to main as commit abc123.",
            "Commit already merged (cherry-picked). Closing stale PR.",
            "gap shipped via chump gap ship; branch is 175 commits behind main",
        ] {
            assert_eq!(
                classify_close_reason(body),
                ClosureReason::Superseded,
                "body: {}",
                body
            );
        }
    }

    #[test]
    fn classify_duplicate_claim() {
        for body in &[
            "Duplicate of #1700",
            "Same as #1733 (same gap)",
            "dup of #999",
        ] {
            assert_eq!(classify_close_reason(body), ClosureReason::DuplicateClaim);
        }
    }

    #[test]
    fn classify_stale_branch() {
        for body in &[
            "Closing — branch is too stale, fmt failures everywhere.",
            "Merge conflict; rebase failed; closing.",
            "200 commits behind main — too far to rebase cleanly.",
        ] {
            assert_eq!(classify_close_reason(body), ClosureReason::StaleBranch);
        }
    }

    #[test]
    fn classify_scratch_commit() {
        for body in &[
            "Scratch-commit catastrophe: +2/-378,778 across 1912 files.",
            "Detected as catastrophic-delete by the new guard.",
            "382,778 deletions — pure scratch commit.",
        ] {
            assert_eq!(classify_close_reason(body), ClosureReason::ScratchCommit);
        }
    }

    #[test]
    fn classify_staging_branch() {
        for body in &[
            "Pre-rebase staging branch with no meaningful work.",
            "Staging-only branch — guard fired.",
            "No meaningful work; INFRA-997 caught it.",
        ] {
            assert_eq!(classify_close_reason(body), ClosureReason::StagingBranch);
        }
    }

    #[test]
    fn classify_ci_fail_orphan() {
        let body = "Closing: audit CI failure (e2e fail). Parent gap shipped. Branch preserved; re-open with fix if content needs to land.";
        assert_eq!(classify_close_reason(body), ClosureReason::CiFailOrphan);
    }

    #[test]
    fn classify_other_fallback() {
        for body in &[
            "Closing for unrelated reasons.",
            "operator decided not to ship this.",
            "",
        ] {
            assert_eq!(classify_close_reason(body), ClosureReason::Other);
        }
    }

    #[test]
    fn report_renders_text_and_json() {
        let report = ClosureReasonReport {
            entries: vec![
                ClosureReasonEntry {
                    reason: ClosureReason::Superseded,
                    count: 14,
                    pr_numbers: vec![1614, 1616, 1655],
                },
                ClosureReasonEntry {
                    reason: ClosureReason::ScratchCommit,
                    count: 2,
                    pr_numbers: vec![1441, 1452],
                },
            ],
            total: 16,
            window_secs: 604800,
            fetch_failed: false,
        };
        let text = report.render_text();
        assert!(text.contains("superseded"));
        assert!(text.contains("scratch_commit"));
        assert!(text.contains("87.5%")); // 14/16
        let json: serde_json::Value = serde_json::from_str(&report.render_json()).unwrap();
        assert_eq!(json["total"], 16);
        assert_eq!(json["categories"][0]["category"], "superseded");
    }
}
