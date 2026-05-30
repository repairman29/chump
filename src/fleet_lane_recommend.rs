//! META-152: `chump fleet lane-recommend` — data-driven curator-lane bottleneck picker.
//!
//! Replaces the ad-hoc "which lane should I onboard into?" AskUserQuestion with a
//! scored recommendation based on live fleet state (ambient.jsonl + gap queue).
//!
//! ## Scoring inputs (AC #2)
//!   (a) lane_darkness      — 0 heartbeats in last 4 h → highest urgency
//!   (b) alive_but_idle     — heartbeats present but no action events
//!   (c) pickable_depth     — open pickable gaps whose skills_required tag matches the lane
//!   (d) shipped_rate       — shipped-PR events for this lane in last 24 h (low = starved)
//!   (e) roadmap_alignment  — alignment with the bottleneck pillar from docs/ROADMAP.md
//!   (f) stuck_age          — age in hours of the oldest stuck item in this lane
//!
//! ## Cold-start (AC #4)
//! When ambient has < 10 events in 24 h, rank by roadmap-bottleneck-pillar only.
//!
//! ## Ambient event (AC #6)
//! Emits `kind=lane_recommended {top_lane, score, runner_up, reason}` on every run.
//! # scanner-anchor: "kind":"lane_recommended"
//!
//! ## Output modes
//!   default  — human table
//!   --json   — JSON array sorted by score desc
//!   --explain — add per-lane input breakdown column

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Lane catalogue (AC #3)
// ---------------------------------------------------------------------------

/// Canonical lane list.  Add new lanes by adding docs/agents/<role>.md.
/// (dynamic discovery via that file scan is AC #3 stretch; for now we hardcode)
pub static KNOWN_LANES: &[&str] = &[
    "target",
    "ci-audit",
    "handoff",
    "shepherd",
    "decompose",
    "observability",
    "external-collab",
    "md-links",
    "infra-watcher",
    "deliberator",
    "fresh-eyes",
];

/// Maps a lane name to the pillar keyword(s) whose gaps are most relevant.
fn lane_pillar(lane: &str) -> &'static str {
    match lane {
        "target" => "EFFECTIVE",
        "ci-audit" => "RESILIENT",
        "handoff" => "EFFECTIVE",
        "shepherd" => "RESILIENT",
        "decompose" => "EFFECTIVE",
        "observability" => "CREDIBLE",
        "external-collab" => "EFFECTIVE",
        "md-links" => "CREDIBLE",
        "infra-watcher" => "RESILIENT",
        "deliberator" => "EFFECTIVE",
        "fresh-eyes" => "CREDIBLE",
        _ => "EFFECTIVE",
    }
}

// ---------------------------------------------------------------------------
// Ambient-log parsing helpers
// ---------------------------------------------------------------------------

/// A lightweight parsed ambient event (only the fields we care about).
#[derive(Debug, Clone)]
struct AmbientEvent {
    ts: u64, // unix seconds
    kind: String,
    source: String, // typically the lane/curator name
    gap_id: String, // empty if absent
}

fn parse_ambient(log_path: &Path) -> Vec<AmbientEvent> {
    let text = match std::fs::read_to_string(log_path) {
        Ok(t) => t,
        Err(_) => return vec![],
    };
    let mut events = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let ts = ts_to_unix(v.get("ts").and_then(|t| t.as_str()).unwrap_or(""));
        let kind = v
            .get("kind")
            .or_else(|| v.get("event"))
            .and_then(|k| k.as_str())
            .unwrap_or("")
            .to_string();
        let source = v
            .get("source")
            .and_then(|s| s.as_str())
            .or_else(|| v.get("harness").and_then(|s| s.as_str()))
            .unwrap_or("")
            .to_string();
        let gap_id = v
            .get("gap_id")
            .or_else(|| v.get("gap"))
            .and_then(|g| g.as_str())
            .unwrap_or("")
            .to_string();
        events.push(AmbientEvent {
            ts,
            kind,
            source,
            gap_id,
        });
    }
    events
}

/// Parse an RFC3339 or a bare unix-second timestamp string to unix seconds.
fn ts_to_unix(s: &str) -> u64 {
    if s.is_empty() {
        return 0;
    }
    // Try plain integer first (unix seconds stored as string).
    if let Ok(n) = s.parse::<u64>() {
        return n;
    }
    // Minimal RFC3339 parser: "YYYY-MM-DDTHH:MM:SSZ"
    // We do not pull `chrono` here to avoid any import issues; simple math suffices.
    // Format: 2026-05-30T06:21:47Z
    let s = s.trim_end_matches('Z');
    let parts: Vec<&str> = s.splitn(2, 'T').collect();
    if parts.len() < 2 {
        return 0;
    }
    let date_parts: Vec<u64> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<u64> = parts[1]
        .split(':')
        .filter_map(|p| p.parse::<u64>().ok())
        .collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return 0;
    }
    let (y, mo, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, min, sec) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days since Unix epoch (1970-01-01). Approximate: no leap-second.
    days_since_epoch(y, mo, d) * 86400 + h * 3600 + min * 60 + sec
}

fn days_since_epoch(y: u64, mo: u64, d: u64) -> u64 {
    // Gregorian to JDN minus epoch JDN.  Epoch JDN = 2440588 (1970-01-01).
    let a = (14u64.saturating_sub(mo)) / 12;
    let y2 = y + 4800 - a;
    let m2 = mo + 12 * a - 3;
    let jdn = d + (153 * m2 + 2) / 5 + 365 * y2 + y2 / 4 - y2 / 100 + y2 / 400 - 32045;
    jdn.saturating_sub(2440588)
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Per-lane scoring
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct LaneScore {
    pub lane: String,
    /// Composite 0–100 score (higher = more urgently needs coverage).
    pub score: f64,
    pub why: String,
    // Per-input breakdown for --explain
    pub darkness: f64,
    pub idle: f64,
    pub queue_depth: f64,
    pub ship_starvation: f64,
    pub roadmap_alignment: f64,
    pub stuck_age: f64,
}

/// Internal per-lane counters derived from ambient events.
#[derive(Debug, Default)]
struct LaneCounters {
    heartbeats_4h: u32,
    action_events_4h: u32, // sub_agent_dispatched, DONE, lane_shipped, etc.
    ships_24h: u32,
    oldest_stuck_secs: u64,
}

fn score_lane(
    lane: &str,
    counters: &LaneCounters,
    pickable_depth: u32,
    bottleneck_pillar: &str,
    cold_start: bool,
    now: u64,
) -> LaneScore {
    let (darkness, idle, queue_depth, ship_starvation, roadmap_alignment, stuck_age);

    // (e) Roadmap alignment — 0.0 or 1.0 based on pillar match.
    roadmap_alignment = if lane_pillar(lane).eq_ignore_ascii_case(bottleneck_pillar) {
        1.0
    } else {
        0.0
    };

    if cold_start {
        // AC #4: cold-start — only roadmap alignment matters.
        let score = roadmap_alignment * 100.0;
        let why = if roadmap_alignment > 0.0 {
            format!("cold-start: matches roadmap bottleneck pillar {bottleneck_pillar}")
        } else {
            "cold-start: no ambient data; pillar mismatch".to_string()
        };
        return LaneScore {
            lane: lane.to_string(),
            score,
            why,
            darkness: 0.0,
            idle: 0.0,
            queue_depth: 0.0,
            ship_starvation: 0.0,
            roadmap_alignment,
            stuck_age: 0.0,
        };
    }

    // (a) Lane darkness — 1.0 if zero heartbeats in last 4 h.
    darkness = if counters.heartbeats_4h == 0 {
        1.0
    } else {
        0.0
    };

    // (b) Alive-but-idle — heartbeats present but no action events.
    idle = if counters.heartbeats_4h > 0 && counters.action_events_4h == 0 {
        0.8
    } else {
        0.0
    };

    // (c) Pickable queue depth — normalized 0..1 over a ceiling of 10.
    queue_depth = (pickable_depth.min(10) as f64) / 10.0;

    // (d) Ship starvation — 1.0 when 0 ships last 24 h, 0.5 when ≤ 2, else 0.
    ship_starvation = if counters.ships_24h == 0 {
        1.0
    } else if counters.ships_24h <= 2 {
        0.5
    } else {
        0.0
    };

    // (f) Stuck age — 1.0 if oldest stuck item > 24 h, scaled linearly below.
    let max_stuck_secs = 24 * 3600u64;
    let _ = now; // used above in scoring but stored in counters directly
    stuck_age = if counters.oldest_stuck_secs == 0 {
        0.0
    } else {
        (counters.oldest_stuck_secs.min(max_stuck_secs) as f64) / (max_stuck_secs as f64)
    };

    // Weighted composite (weights sum to 1.0).
    let score = (darkness * 0.30
        + idle * 0.20
        + queue_depth * 0.20
        + ship_starvation * 0.15
        + roadmap_alignment * 0.10
        + stuck_age * 0.05)
        * 100.0;

    // Human-readable "why" — pick the dominant driver.
    let why = if darkness > 0.0 {
        "lane is dark (no heartbeats in 4h)".to_string()
    } else if idle > 0.0 {
        format!(
            "alive-but-idle: {} heartbeats, 0 actions in 4h",
            counters.heartbeats_4h
        )
    } else if queue_depth > 0.5 {
        format!("{} pickable gaps waiting", pickable_depth)
    } else if ship_starvation > 0.5 {
        format!("{} ships in last 24h — starved", counters.ships_24h)
    } else if roadmap_alignment > 0.0 {
        format!("aligns with roadmap bottleneck pillar {bottleneck_pillar}")
    } else if stuck_age > 0.3 {
        let hours = counters.oldest_stuck_secs / 3600;
        format!("oldest stuck item {hours}h old")
    } else {
        "no strong signal".to_string()
    };

    LaneScore {
        lane: lane.to_string(),
        score,
        why,
        darkness,
        idle,
        queue_depth,
        ship_starvation,
        roadmap_alignment,
        stuck_age,
    }
}

// ---------------------------------------------------------------------------
// Gap queue depth per lane
// ---------------------------------------------------------------------------

/// Return count of open, non-blocked gaps whose skills_required or title contains
/// the lane keyword.
fn pickable_depth_for_lane(gaps: &[chump_gap_store::GapRow], lane: &str) -> u32 {
    let lane_lower = lane.to_lowercase();
    let lane_upper = lane.to_uppercase();
    gaps.iter()
        .filter(|g| g.status == "open")
        .filter(|g| {
            g.skills_required.to_lowercase().contains(&lane_lower)
                || g.title.to_lowercase().contains(&lane_lower)
                || g.title.contains(&lane_upper)
                || g.domain.to_uppercase() == "META" && g.title.to_lowercase().contains(&lane_lower)
        })
        .count() as u32
}

// ---------------------------------------------------------------------------
// Roadmap bottleneck pillar
// ---------------------------------------------------------------------------

/// Scan docs/ROADMAP.md for a `bottleneck:` marker.
/// Falls back to EFFECTIVE if absent.
fn detect_bottleneck_pillar(repo_root: &Path) -> String {
    let path = repo_root.join("docs/ROADMAP.md");
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    for line in text.lines() {
        let l = line.trim().to_lowercase();
        if l.starts_with("bottleneck:") {
            // Extract the value after "bottleneck:"
            let val = line[line.find(':').unwrap_or(0) + 1..]
                .trim()
                .to_uppercase();
            if !val.is_empty() {
                return val;
            }
        }
        // Also check "## Current milestone" heading next line for a pillar keyword.
        if l.starts_with("## current milestone") || l.starts_with("### current bottleneck") {
            // Look ahead by scanning same line for pillar names.
            for pillar in &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"] {
                if line.to_uppercase().contains(pillar) {
                    return pillar.to_string();
                }
            }
        }
    }
    // Default to EFFECTIVE (user-facing impact is the most common bottleneck)
    "EFFECTIVE".to_string()
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

pub struct RecommendOpts {
    pub json: bool,
    pub explain: bool,
    /// Override ambient.jsonl path (used by tests via CHUMP_AMBIENT_LOG env).
    pub ambient_path_override: Option<PathBuf>,
    /// Override gap DB path (tests).
    pub db_path_override: Option<PathBuf>,
    /// Override repo root (tests).
    pub repo_root_override: Option<PathBuf>,
}

pub fn run(opts: &RecommendOpts) {
    use crate::repo_path;

    let repo_root = opts
        .repo_root_override
        .clone()
        .unwrap_or_else(repo_path::repo_root);

    // --- 1. Load ambient events ---
    let ambient_path = opts.ambient_path_override.clone().unwrap_or_else(|| {
        std::env::var("CHUMP_AMBIENT_LOG")
            .ok()
            .map(PathBuf::from)
            .unwrap_or_else(|| repo_root.join(".chump-locks/ambient.jsonl"))
    });

    let events = parse_ambient(&ambient_path);
    let now = now_unix();
    let window_24h = now.saturating_sub(24 * 3600);
    let window_4h = now.saturating_sub(4 * 3600);

    // Cold-start guard (AC #4): < 10 events in last 24 h.
    let recent_count = events.iter().filter(|e| e.ts >= window_24h).count();
    let cold_start = recent_count < 10;

    // --- 2. Load gap queue ---
    // `GapStore::open` takes a repo_root and infers .chump/state.db from it.
    // opts.db_path_override lets tests inject a custom DB dir (we override
    // CHUMP_REPO env so open() picks the right path).
    let gaps: Vec<chump_gap_store::GapRow> = {
        let effective_root = opts.db_path_override.as_deref().unwrap_or(&repo_root);
        match chump_gap_store::GapStore::open(effective_root) {
            Ok(store) => store.list(Some("open")).unwrap_or_default(),
            Err(_) => vec![],
        }
    };

    // --- 3. Detect roadmap bottleneck pillar ---
    let bottleneck_pillar = detect_bottleneck_pillar(&repo_root);

    // --- 4. Build per-lane counters from ambient events ---
    let mut lane_counters: HashMap<&str, LaneCounters> = HashMap::new();
    for lane in KNOWN_LANES {
        lane_counters.insert(lane, LaneCounters::default());
    }

    for ev in &events {
        // Determine which lane this event belongs to by scanning source field.
        let source_lower = ev.source.to_lowercase();
        for lane in KNOWN_LANES {
            let lane_lower = lane.to_lowercase();
            // Heuristic: source contains the lane keyword (e.g. "ci-audit" or "ci_audit")
            let matches = source_lower.contains(&lane_lower)
                || source_lower.contains(&lane_lower.replace('-', "_"))
                || ev.gap_id.to_lowercase().contains(&lane_lower);
            if !matches {
                continue;
            }
            let c = lane_counters.get_mut(lane).unwrap();

            if ev.ts >= window_4h {
                // Count heartbeats
                if ev.kind.contains("heartbeat") || ev.kind.contains("curator_tick") {
                    c.heartbeats_4h += 1;
                }
                // Count action events (any substantive work signal)
                if ev.kind == "sub_agent_dispatched"
                    || ev.kind.contains("done")
                    || ev.kind.contains("shipped")
                    || ev.kind.contains("gap_claimed")
                    || ev.kind.contains("lane_shipped")
                    || ev.kind == "pr_merged"
                {
                    c.action_events_4h += 1;
                }
            }
            if ev.ts >= window_24h {
                if ev.kind.contains("shipped") || ev.kind == "pr_merged" {
                    c.ships_24h += 1;
                }
            }
        }
    }

    // Compute oldest stuck item age per lane from gap queue (simplified:
    // any open gap older than 48 h with this lane's skill tag = stuck candidate).
    let stuck_threshold_secs = 48 * 3600u64;
    for lane in KNOWN_LANES {
        let lane_lower = lane.to_lowercase();
        let c = lane_counters.get_mut(lane).unwrap();
        for gap in &gaps {
            if gap.status != "open" {
                continue;
            }
            let is_lane_gap = gap.skills_required.to_lowercase().contains(&lane_lower)
                || gap.title.to_lowercase().contains(&lane_lower);
            if !is_lane_gap {
                continue;
            }
            let age_secs = now.saturating_sub(gap.created_at as u64);
            if age_secs > stuck_threshold_secs && age_secs > c.oldest_stuck_secs {
                c.oldest_stuck_secs = age_secs;
            }
        }
    }

    // --- 5. Score each lane ---
    let mut scores: Vec<LaneScore> = KNOWN_LANES
        .iter()
        .map(|lane| {
            let counters = lane_counters.get(lane).unwrap();
            let depth = pickable_depth_for_lane(&gaps, lane);
            score_lane(lane, counters, depth, &bottleneck_pillar, cold_start, now)
        })
        .collect();

    scores.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // --- 6. Emit ambient event (AC #6) ---
    let top = scores.first();
    let runner_up = scores.get(1);
    let emit_result = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "lane_recommended".to_string(),
        source: Some("fleet_lane_recommend".to_string()),
        fields: {
            let mut f = vec![
                (
                    "top_lane".to_string(),
                    top.map(|s| s.lane.as_str()).unwrap_or("none").to_string(),
                ),
                (
                    "score".to_string(),
                    top.map(|s| format!("{:.1}", s.score)).unwrap_or_default(),
                ),
                (
                    "runner_up".to_string(),
                    runner_up
                        .map(|s| s.lane.as_str())
                        .unwrap_or("none")
                        .to_string(),
                ),
                (
                    "reason".to_string(),
                    top.map(|s| s.why.clone()).unwrap_or_default(),
                ),
                ("cold_start".to_string(), cold_start.to_string()),
                ("bottleneck_pillar".to_string(), bottleneck_pillar.clone()),
            ];
            if let Some(r) = runner_up {
                f.push(("runner_up_score".to_string(), format!("{:.1}", r.score)));
            }
            f
        },
        ..Default::default()
    });
    if let Err(e) = emit_result {
        eprintln!("warn: could not emit lane_recommended to ambient: {e}");
    }

    // --- 7. Output ---
    if opts.json {
        let arr: Vec<serde_json::Value> = scores
            .iter()
            .map(|s| {
                let mut obj = serde_json::json!({
                    "lane": s.lane,
                    "score": (s.score * 10.0).round() / 10.0,
                    "why": s.why,
                });
                if opts.explain {
                    obj["inputs"] = serde_json::json!({
                        "darkness": (s.darkness * 100.0).round() / 100.0,
                        "alive_but_idle": (s.idle * 100.0).round() / 100.0,
                        "queue_depth": (s.queue_depth * 100.0).round() / 100.0,
                        "ship_starvation": (s.ship_starvation * 100.0).round() / 100.0,
                        "roadmap_alignment": (s.roadmap_alignment * 100.0).round() / 100.0,
                        "stuck_age": (s.stuck_age * 100.0).round() / 100.0,
                    });
                }
                obj
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&arr).unwrap_or_default());
    } else {
        // Human table (AC #1)
        let header_lane = "LANE";
        let header_score = "SCORE";
        let header_why = "WHY";
        let w_lane = KNOWN_LANES
            .iter()
            .map(|l| l.len())
            .max()
            .unwrap_or(12)
            .max(header_lane.len());
        let w_score = 6usize.max(header_score.len());

        println!(
            "{:<width$}  {:>ws$}  {}",
            header_lane,
            header_score,
            header_why,
            width = w_lane,
            ws = w_score,
        );
        println!("{}", "-".repeat(w_lane + w_score + 30));

        for (i, s) in scores.iter().enumerate() {
            let marker = if i == 0 { " <-- RECOMMEND" } else { "" };
            if opts.explain {
                println!(
                    "{:<width$}  {:>ws$.1}  {}{}",
                    s.lane,
                    s.score,
                    s.why,
                    marker,
                    width = w_lane,
                    ws = w_score,
                );
                println!(
                    "{:<width$}  {:>ws$}  darkness={:.2} idle={:.2} queue={:.2} ship_starv={:.2} roadmap={:.2} stuck={:.2}",
                    "",
                    "",
                    s.darkness,
                    s.idle,
                    s.queue_depth,
                    s.ship_starvation,
                    s.roadmap_alignment,
                    s.stuck_age,
                    width = w_lane,
                    ws = w_score,
                );
            } else {
                println!(
                    "{:<width$}  {:>ws$.1}  {}{}",
                    s.lane,
                    s.score,
                    s.why,
                    marker,
                    width = w_lane,
                    ws = w_score,
                );
            }
        }

        if cold_start {
            eprintln!(
                "\nnote: cold-start mode (< 10 ambient events in 24h) — ranked by roadmap-bottleneck-pillar ({bottleneck_pillar}) only"
            );
        } else {
            println!("\nbottleneck_pillar={bottleneck_pillar}  ambient_events_24h={recent_count}");
        }
    }
}
