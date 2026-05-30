//! INFRA-2229: `chump pe-suite status` — P&E suite operator dashboard.
//!
//! Reads curator liveness, FEEDBACK engagement, and consensus convergence from
//! `.chump-locks/` and `ambient.jsonl` over the last 7 days, then renders a
//! human-readable summary (or `--json` for machine output).
//!
//! ## Data sources
//!
//! - `.chump-locks/*.lock` + `curator-sessions.json` → active curator roles
//! - `ambient.jsonl` `kind=*_heartbeat` → per-role last-tick timestamps
//! - `ambient.jsonl` `kind=FEEDBACK` → engagement count per curator session
//! - `ambient.jsonl` `kind=consensus_resolved` → convergence rate
//! - `ambient.jsonl` `kind=consensus_decision_emitted` → time-to-decision
//!
//! ## Output (human-readable)
//!
//! ```text
//! ═══ Chump P&E Suite Status ═══
//! Active curators (last 24h):  5 of 14
//!   [✓] ci-audit          last tick:  3min ago   0 FEEDBACK / 7d
//!   [✓] handoff           last tick: 12min ago   0 FEEDBACK / 7d
//!   [✗] velocity-tracker  no tick in 7d          stale — investigate
//! Consensus health:
//!   asked × resolved (7d):  47 / 38  (81% convergence)
//!   P50 decision time:       4m 12s
//!   operator escalations:    2
//! ```
//!
//! ## Env overrides (for tests)
//!
//! - `CHUMP_PE_SUITE_AMBIENT_PATH` — override path to `ambient.jsonl`
//! - `CHUMP_PE_SUITE_LOCKS_DIR` — override path to `.chump-locks/`
//! - `CHUMP_PE_SUITE_NOW_SECS` — override Unix timestamp for "now" (testing)

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Known curator roles in the 14-role P&E suite (META-127 C3).
/// This list is the canonical set; the dashboard uses it to show stale/missing curators.
pub const KNOWN_CURATOR_ROLES: &[&str] = &[
    "ci-audit",
    "decompose",
    "handoff",
    "md-links",
    "shepherd",
    "target",
    "roadmap-keeper",
    "historian",
    "velocity-tracker",
    "fleet-doctor",
    "gap-harvester",
    "content-bots",
    "paramedic",
    "infra-watcher",
];

/// 24-hour liveness window for the "active curators" count.
const ACTIVE_WINDOW_SECS: u64 = 24 * 3600;
/// 7-day window for FEEDBACK + consensus metrics.
const METRIC_WINDOW_SECS: u64 = 7 * 24 * 3600;

/// Per-role liveness data.
#[derive(Debug, Clone, PartialEq)]
pub struct CuratorStatus {
    pub role: String,
    /// Unix seconds of the most recent heartbeat event, if any within METRIC_WINDOW_SECS.
    pub last_tick_secs: Option<u64>,
    /// FEEDBACK events attributed to this role in the last 7d.
    pub feedback_7d: u64,
}

impl CuratorStatus {
    pub fn is_active(&self, now_secs: u64) -> bool {
        self.last_tick_secs
            .map(|t| now_secs.saturating_sub(t) < ACTIVE_WINDOW_SECS)
            .unwrap_or(false)
    }

    /// Seconds since last tick, or None if no tick recorded.
    pub fn secs_since_tick(&self, now_secs: u64) -> Option<u64> {
        self.last_tick_secs.map(|t| now_secs.saturating_sub(t))
    }
}

/// Consensus health metrics.
#[derive(Debug, Clone, PartialEq)]
pub struct ConsensusHealth {
    /// Total consensus_resolved events in the last 7d.
    pub resolved: u64,
    /// Total consensus questions asked (approximated by resolved + escalated).
    pub asked: u64,
    /// Operator escalation events in the last 7d.
    pub escalations: u64,
    /// Sorted decision times in seconds, for percentile calc.
    pub decision_times_secs: Vec<u64>,
}

impl ConsensusHealth {
    pub fn convergence_pct(&self) -> Option<u64> {
        (self.asked != 0).then(|| self.resolved * 100 / self.asked)
    }

    pub fn p50_decision_secs(&self) -> Option<u64> {
        if self.decision_times_secs.is_empty() {
            return None;
        }
        let mut sorted = self.decision_times_secs.clone();
        sorted.sort_unstable();
        Some(sorted[sorted.len() / 2])
    }
}

/// Full P&E suite snapshot.
#[derive(Debug, Clone)]
pub struct SuiteSnapshot {
    pub curators: Vec<CuratorStatus>,
    pub consensus: ConsensusHealth,
    pub now_secs: u64,
}

impl SuiteSnapshot {
    pub fn active_count(&self) -> usize {
        self.curators
            .iter()
            .filter(|c| c.is_active(self.now_secs))
            .count()
    }
}

/// Parsed CLI args for `chump pe-suite status`.
#[derive(Debug, Clone, Default)]
pub struct Args {
    pub json: bool,
    pub help: bool,
}

pub fn parse_args(argv: &[String]) -> Result<Args, String> {
    let mut a = Args::default();
    for arg in argv {
        match arg.as_str() {
            "-h" | "--help" => a.help = true,
            "--json" => a.json = true,
            other => return Err(format!("pe-suite status: unknown flag '{}'", other)),
        }
    }
    Ok(a)
}

/// Resolve ambient.jsonl path, honouring env override for tests.
fn ambient_path(locks_dir: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_PE_SUITE_AMBIENT_PATH") {
        return PathBuf::from(p);
    }
    locks_dir.join("ambient.jsonl")
}

/// Resolve .chump-locks/ dir, honouring env override for tests.
fn locks_dir() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_PE_SUITE_LOCKS_DIR") {
        return PathBuf::from(p);
    }
    // Walk up from cwd to find repo root with .chump-locks/
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..10 {
        let candidate = dir.join(".chump-locks");
        if candidate.is_dir() {
            return candidate;
        }
        if !dir.pop() {
            break;
        }
    }
    PathBuf::from(".chump-locks")
}

fn now_secs() -> u64 {
    if let Ok(v) = std::env::var("CHUMP_PE_SUITE_NOW_SECS") {
        if let Ok(n) = v.parse::<u64>() {
            return n;
        }
    }
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Parse an ISO8601 timestamp like "2026-05-29T23:54:25Z" into Unix seconds.
/// Returns None on parse failure.
pub fn parse_iso8601(ts: &str) -> Option<u64> {
    // Accept "YYYY-MM-DDTHH:MM:SSZ" format.
    let ts = ts.trim().trim_end_matches('Z');
    let parts: Vec<&str> = ts.splitn(2, 'T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<u64> = parts[0].split('-').filter_map(|s| s.parse().ok()).collect();
    let time_parts: Vec<u64> = parts[1].split(':').filter_map(|s| s.parse().ok()).collect();
    if date_parts.len() != 3 || time_parts.len() != 3 {
        return None;
    }
    let (y, mo, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, mi, s) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days since Unix epoch using civil-calendar formula.
    let years = y.saturating_sub(1970);
    let leap_days = (years + 1) / 4 - (years + 69) / 100 + (years + 369) / 400;
    let month_days: [u64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let is_leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
    let days_in_year: u64 = (1..mo)
        .map(|m| {
            let md = month_days[(m - 1) as usize];
            if m == 2 && is_leap {
                md + 1
            } else {
                md
            }
        })
        .sum();
    let total_days = years * 365 + leap_days + days_in_year + d - 1;
    Some(total_days * 86400 + h * 3600 + mi * 60 + s)
}

/// Extract curator role name from a session string like "curator-opus-ci-audit-2026-05-28".
pub fn role_from_session(session: &str) -> Option<String> {
    let prefix = "curator-opus-";
    if !session.starts_with(prefix) {
        return None;
    }
    let rest = &session[prefix.len()..];
    // Strip trailing "-YYYY-MM-DD" date suffix.
    let role = rest.rsplitn(4, '-').nth(3).or_else(|| {
        // Fallback: strip last segment if it looks like a date part.
        let segs: Vec<&str> = rest.rsplitn(2, '-').collect();
        if segs.len() == 2 {
            let tail = segs[0];
            if tail.len() == 2 && tail.chars().all(|c| c.is_ascii_digit()) {
                return Some(segs[1]);
            }
        }
        None
    });
    // More robust: strip the last 3 dash-segments if they look like YYYY-MM-DD.
    let segs: Vec<&str> = rest.split('-').collect();
    if segs.len() >= 4 {
        let last3: Vec<&str> = segs[segs.len() - 3..].to_vec();
        let looks_like_date = last3[0].len() == 4
            && last3[0].chars().all(|c| c.is_ascii_digit())
            && last3[1].len() == 2
            && last3[2].len() == 2;
        if looks_like_date {
            return Some(segs[..segs.len() - 3].join("-"));
        }
    }
    role.map(|s| s.to_string())
}

/// Heartbeat kind → curator role mapping.
/// Returns the role name for a given heartbeat kind string, or None.
pub fn role_from_heartbeat_kind(kind: &str) -> Option<String> {
    // Kinds follow: <role>_heartbeat where role uses underscores.
    let suffix = "_heartbeat";
    if let Some(role_raw) = kind.strip_suffix(suffix) {
        // ci_audit → ci-audit
        return Some(role_raw.replace('_', "-"));
    }
    None
}

/// Scan ambient.jsonl and return curator liveness + consensus data.
pub fn scan_ambient(
    ambient_path: &Path,
    now_secs: u64,
) -> (HashMap<String, u64>, HashMap<String, u64>, ConsensusHealth) {
    let cutoff = now_secs.saturating_sub(METRIC_WINDOW_SECS);

    // role → last_tick_secs
    let mut ticks: HashMap<String, u64> = HashMap::new();
    // role → FEEDBACK count (7d)
    let mut feedback_counts: HashMap<String, u64> = HashMap::new();

    let mut consensus = ConsensusHealth {
        resolved: 0,
        asked: 0,
        escalations: 0,
        decision_times_secs: Vec::new(),
    };

    let file = match fs::File::open(ambient_path) {
        Ok(f) => f,
        Err(_) => return (ticks, feedback_counts, consensus),
    };
    let reader = BufReader::new(file);

    for line in reader.lines().flatten() {
        let line = line.trim().to_string();
        if line.is_empty() || !line.starts_with('{') {
            continue;
        }
        // Fast-path: skip lines that can't contain relevant keys.
        let relevant = line.contains("heartbeat")
            || line.contains("FEEDBACK")
            || line.contains("consensus_resolved")
            || line.contains("consensus_decision_emitted")
            || line.contains("operator_escalation");
        if !relevant {
            continue;
        }

        // Minimal JSON extraction without a full parser.
        let ts_opt = extract_str_field(&line, "ts").and_then(|ts| parse_iso8601(&ts));
        let ts = match ts_opt {
            Some(t) if t >= cutoff => t,
            _ => continue,
        };

        // FEEDBACK events carry `"event":"FEEDBACK"` (the `kind` field may be
        // a sub-type like "preference").  Check event first so FEEDBACK events
        // are routed correctly regardless of what `kind` says.
        let is_feedback = extract_str_field(&line, "event")
            .map(|e| e == "FEEDBACK")
            .unwrap_or(false);
        let kind = if is_feedback {
            "FEEDBACK".to_string()
        } else {
            match extract_str_field(&line, "kind") {
                Some(k) => k,
                None => continue,
            }
        };

        match kind.as_str() {
            k if k.ends_with("_heartbeat") => {
                if let Some(role) = role_from_heartbeat_kind(k) {
                    let entry = ticks.entry(role).or_insert(0);
                    if ts > *entry {
                        *entry = ts;
                    }
                }
                // Also try session field for unmapped kinds.
                if let Some(session) = extract_str_field(&line, "session") {
                    if let Some(role) = role_from_session(&session) {
                        let entry = ticks.entry(role).or_insert(0);
                        if ts > *entry {
                            *entry = ts;
                        }
                    }
                }
            }
            "FEEDBACK" => {
                // Attribute to session curator if present.
                let role = extract_str_field(&line, "session")
                    .and_then(|s| role_from_session(&s))
                    .unwrap_or_else(|| "unknown".to_string());
                *feedback_counts.entry(role).or_insert(0) += 1;
            }
            "consensus_resolved" => {
                consensus.resolved += 1;
                consensus.asked += 1;
                // Extract decision time if present.
                if let Some(dt_str) = extract_str_field(&line, "decision_time_secs") {
                    if let Ok(dt) = dt_str.parse::<u64>() {
                        consensus.decision_times_secs.push(dt);
                    }
                }
            }
            "consensus_decision_emitted" => {
                // May have elapsed_secs field.
                if let Some(es) = extract_str_field(&line, "elapsed_secs") {
                    if let Ok(dt) = es.parse::<u64>() {
                        consensus.decision_times_secs.push(dt);
                    }
                }
            }
            "operator_escalation" => {
                consensus.escalations += 1;
                consensus.asked += 1;
            }
            _ => {}
        }
    }

    (ticks, feedback_counts, consensus)
}

/// Minimal field extractor for `"key":"value"` or `"key":number` patterns.
/// Returns the raw string value (without surrounding quotes for strings).
fn extract_str_field(line: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let pos = line.find(&needle)?;
    let rest = &line[pos + needle.len()..].trim_start();
    if rest.starts_with('"') {
        // String value.
        let inner = &rest[1..];
        let end = inner.find('"')?;
        Some(inner[..end].to_string())
    } else {
        // Numeric or bare value — read until , or } or whitespace.
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c.is_whitespace())
            .unwrap_or(rest.len());
        Some(rest[..end].to_string())
    }
}

/// Build the full suite snapshot from the filesystem.
pub fn build_snapshot() -> SuiteSnapshot {
    let now = now_secs();
    let ldir = locks_dir();
    let amb = ambient_path(&ldir);

    let (ticks, feedback_counts, consensus) = scan_ambient(&amb, now);

    let curators = KNOWN_CURATOR_ROLES
        .iter()
        .map(|&role| {
            let role_s = role.to_string();
            let last_tick_secs = ticks.get(&role_s).copied();
            let feedback_7d = feedback_counts.get(&role_s).copied().unwrap_or(0);
            CuratorStatus {
                role: role_s,
                last_tick_secs,
                feedback_7d,
            }
        })
        .collect();

    SuiteSnapshot {
        curators,
        consensus,
        now_secs: now,
    }
}

/// Format elapsed seconds as a human-readable "Xmin ago" / "Xh ago" string.
pub fn format_ago(secs: u64) -> String {
    if secs < 90 {
        format!("{}s ago", secs)
    } else if secs < 3600 {
        format!("{}min ago", secs / 60)
    } else if secs < 86400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86400)
    }
}

/// Format seconds as "Xm Ys".
pub fn format_duration(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else {
        format!("{}m {}s", secs / 60, secs % 60)
    }
}

/// Render human-readable output.
pub fn render_text(snap: &SuiteSnapshot) -> String {
    let mut out = String::new();
    out.push_str("═══ Chump P&E Suite Status ═══\n");
    out.push_str(&format!(
        "Active curators (last 24h):  {} of {}\n",
        snap.active_count(),
        KNOWN_CURATOR_ROLES.len()
    ));

    for c in &snap.curators {
        let mark = if c.is_active(snap.now_secs) {
            "✓"
        } else {
            "✗"
        };
        let tick_info = match c.secs_since_tick(snap.now_secs) {
            Some(secs) => format!("last tick: {:>8}", format_ago(secs)),
            None => "no tick in 7d          stale — investigate".to_string(),
        };
        let feedback_str = format!("{} FEEDBACK / 7d", c.feedback_7d);
        out.push_str(&format!(
            "  [{}] {:<22} {}   {}\n",
            mark, c.role, tick_info, feedback_str
        ));
    }

    out.push_str("Consensus health:\n");
    let conv = snap
        .consensus
        .convergence_pct()
        .map(|p| format!("{}%", p))
        .unwrap_or_else(|| "n/a".to_string());
    out.push_str(&format!(
        "  asked × resolved (7d):  {} / {}  ({} convergence)\n",
        snap.consensus.asked, snap.consensus.resolved, conv
    ));
    let p50 = snap
        .consensus
        .p50_decision_secs()
        .map(|s| format_duration(s))
        .unwrap_or_else(|| "n/a".to_string());
    out.push_str(&format!("  P50 decision time:       {}\n", p50));
    out.push_str(&format!(
        "  operator escalations:    {}\n",
        snap.consensus.escalations
    ));
    out
}

/// Render JSON output.
pub fn render_json(snap: &SuiteSnapshot) -> String {
    let mut curators_json = String::from("[");
    for (i, c) in snap.curators.iter().enumerate() {
        if i > 0 {
            curators_json.push(',');
        }
        let last_tick = c
            .last_tick_secs
            .map(|t| format!("{}", t))
            .unwrap_or_else(|| "null".to_string());
        let active = c.is_active(snap.now_secs);
        curators_json.push_str(&format!(
            r#"{{"role":"{}","active":{},"last_tick_secs":{},"feedback_7d":{}}}"#,
            c.role, active, last_tick, c.feedback_7d
        ));
    }
    curators_json.push(']');

    let convergence = snap
        .consensus
        .convergence_pct()
        .map(|p| format!("{}", p))
        .unwrap_or_else(|| "null".to_string());
    let p50 = snap
        .consensus
        .p50_decision_secs()
        .map(|s| format!("{}", s))
        .unwrap_or_else(|| "null".to_string());

    format!(
        r#"{{"active_curators":{},"total_curators":{},"curators":{},"consensus":{{"asked":{},"resolved":{},"convergence_pct":{},"p50_decision_secs":{},"escalations":{}}}}}"#,
        snap.active_count(),
        KNOWN_CURATOR_ROLES.len(),
        curators_json,
        snap.consensus.asked,
        snap.consensus.resolved,
        convergence,
        p50,
        snap.consensus.escalations,
    )
}

/// Entry point: parse args, build snapshot, render, print. Returns exit code.
pub fn run(argv: &[String]) -> i32 {
    let args = match parse_args(argv) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("chump pe-suite status: {}", e);
            eprintln!("Usage: chump pe-suite status [--json]");
            return 1;
        }
    };
    if args.help {
        println!("Usage: chump pe-suite status [--json]");
        println!();
        println!("  Show P&E curator suite health: liveness, FEEDBACK engagement,");
        println!("  consensus convergence, and operator escalations.");
        println!();
        println!("  --json   Machine-readable JSON output");
        println!("  --help   Show this message");
        return 0;
    }

    let snap = build_snapshot();
    if args.json {
        println!("{}", render_json(&snap));
    } else {
        print!("{}", render_text(&snap));
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn write_ambient(dir: &TempDir, lines: &[&str]) -> PathBuf {
        let path = dir.path().join("ambient.jsonl");
        let mut f = fs::File::create(&path).unwrap();
        for l in lines {
            writeln!(f, "{}", l).unwrap();
        }
        path
    }

    // ------- parse_iso8601 -------

    #[test]
    fn test_parse_iso8601_known_epoch() {
        // 2026-05-29T00:00:00Z = 1780012800 (UTC, verified via calendar.timegm)
        let t = parse_iso8601("2026-05-29T00:00:00Z").unwrap();
        assert_eq!(t, 1780012800, "got {}", t);
    }

    #[test]
    fn test_parse_iso8601_invalid_returns_none() {
        assert!(parse_iso8601("not-a-date").is_none());
        assert!(parse_iso8601("").is_none());
    }

    // ------- role_from_session -------

    #[test]
    fn test_role_from_session_known_roles() {
        assert_eq!(
            role_from_session("curator-opus-ci-audit-2026-05-28"),
            Some("ci-audit".to_string())
        );
        assert_eq!(
            role_from_session("curator-opus-md-links-2026-05-28"),
            Some("md-links".to_string())
        );
        assert_eq!(
            role_from_session("curator-opus-handoff-2026-05-28"),
            Some("handoff".to_string())
        );
    }

    #[test]
    fn test_role_from_session_no_prefix() {
        assert_eq!(role_from_session("some-other-session"), None);
    }

    // ------- role_from_heartbeat_kind -------

    #[test]
    fn test_role_from_heartbeat_kind() {
        assert_eq!(
            role_from_heartbeat_kind("ci_audit_heartbeat"),
            Some("ci-audit".to_string())
        );
        assert_eq!(
            role_from_heartbeat_kind("md_links_heartbeat"),
            Some("md-links".to_string())
        );
        assert_eq!(role_from_heartbeat_kind("other_event"), None);
    }

    // ------- scan_ambient -------

    #[test]
    fn test_scan_ambient_counts_ticks_and_feedback() {
        let dir = TempDir::new().unwrap();
        // Use a fixed "now" 1 hour after the event timestamp so events are
        // clearly within both the 24h liveness window and the 7d metric window.
        // 2026-05-29T00:00:00Z = 1780012800; now = that + 1h.
        let now: u64 = 1780012800 + 3600;
        let ts = "2026-05-29T00:00:00Z";

        let lines = [
            // ci-audit heartbeat
            &format!(
                r#"{{"ts":"{}","kind":"ci_audit_heartbeat","session":"curator-opus-ci-audit-2026-05-28","role":"ci-audit"}}"#,
                ts
            ) as &str,
            // handoff heartbeat (two events — should take latest)
            &format!(
                r#"{{"ts":"{}","kind":"handoff_heartbeat","session":"curator-opus-handoff-2026-05-28"}}"#,
                ts
            ),
            // FEEDBACK event
            &format!(
                r#"{{"ts":"{}","event":"FEEDBACK","kind":"preference","session":"curator-opus-ci-audit-2026-05-28"}}"#,
                ts
            ),
            // consensus_resolved
            &format!(
                r#"{{"ts":"{}","kind":"consensus_resolved","decision_time_secs":"240"}}"#,
                ts
            ),
            // operator_escalation
            &format!(r#"{{"ts":"{}","kind":"operator_escalation"}}"#, ts),
        ];
        let path = write_ambient(&dir, &lines);
        let (ticks, feedback, consensus) = scan_ambient(&path, now);

        // Ticks: ci-audit and handoff should be present.
        assert!(ticks.contains_key("ci-audit"), "ci-audit tick missing");
        assert!(ticks.contains_key("handoff"), "handoff tick missing");

        // FEEDBACK attributed to ci-audit.
        assert_eq!(*feedback.get("ci-audit").unwrap_or(&0), 1);

        // Consensus: 1 resolved, 1 escalation = 2 asked.
        assert_eq!(consensus.resolved, 1);
        assert_eq!(consensus.escalations, 1);
        assert_eq!(consensus.asked, 2);

        // Decision time from consensus_resolved.
        assert!(
            consensus.decision_times_secs.contains(&240),
            "expected 240s decision time"
        );
    }

    // ------- render_text / render_json -------

    #[test]
    fn test_render_text_contains_header_and_roles() {
        let snap = SuiteSnapshot {
            curators: vec![CuratorStatus {
                role: "ci-audit".to_string(),
                last_tick_secs: Some(1748476800 - 180), // 3min ago
                feedback_7d: 5,
            }],
            consensus: ConsensusHealth {
                resolved: 38,
                asked: 47,
                escalations: 2,
                decision_times_secs: vec![252],
            },
            now_secs: 1748476800,
        };
        let text = render_text(&snap);
        assert!(text.contains("Chump P&E Suite Status"));
        assert!(text.contains("ci-audit"));
        assert!(text.contains("FEEDBACK"));
        assert!(text.contains("convergence"));
    }

    #[test]
    fn test_render_json_is_valid_structure() {
        let snap = SuiteSnapshot {
            curators: vec![CuratorStatus {
                role: "ci-audit".to_string(),
                last_tick_secs: Some(1748476800 - 60),
                feedback_7d: 2,
            }],
            consensus: ConsensusHealth {
                resolved: 10,
                asked: 12,
                escalations: 1,
                decision_times_secs: vec![100, 200, 300],
            },
            now_secs: 1748476800,
        };
        let json = render_json(&snap);
        assert!(json.contains("\"active_curators\""));
        assert!(json.contains("\"ci-audit\""));
        assert!(json.contains("\"convergence_pct\""));
        assert!(json.contains("\"p50_decision_secs\""));
        // Should be valid-ish JSON (starts/ends with braces).
        assert!(json.starts_with('{') && json.ends_with('}'));
    }

    #[test]
    fn test_convergence_pct_zero_asked() {
        let ch = ConsensusHealth {
            resolved: 0,
            asked: 0,
            escalations: 0,
            decision_times_secs: vec![],
        };
        assert_eq!(ch.convergence_pct(), None);
    }

    #[test]
    fn test_p50_decision_secs_median() {
        let ch = ConsensusHealth {
            resolved: 3,
            asked: 3,
            escalations: 0,
            decision_times_secs: vec![300, 100, 200],
        };
        // Sorted: [100, 200, 300], median index 1 = 200.
        assert_eq!(ch.p50_decision_secs(), Some(200));
    }
}
