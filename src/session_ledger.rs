//! INFRA-477 / INFRA-534: per-session cost ledger.
//!
//! INFRA-477 MVP: elapsed-seconds + outcome.
//! INFRA-534 follow-up: token counts (input/output/cache_read) captured
//! into session_end so we can compute actual $ cost per shipped gap.
//!
//! Two events:
//!   - `session_start` — written by `chump session-track --start <GAP>`
//!     at the moment work begins (typically right after `chump claim`).
//!   - `session_end`   — written by `chump session-track --end <GAP>
//!     --outcome <shipped|abandoned|starved>` when the session
//!     terminates (typically right after `bot-merge.sh` ships or after
//!     manual abandon).
//!
//! Briefing surfaces aggregate stats for past sessions on the same
//! domain: "Recent sessions on INFRA gaps: median elapsed 24m, range
//! 8-67m." This is the cost feedback loop — agents (and operators) see
//! how long similar work has historically taken.
//!
//! Best-effort: all writes silently no-op on I/O failure. Telemetry
//! that gates work would defeat its own purpose.

use std::path::Path;

/// Token usage counts from an Anthropic API response.
#[derive(Debug, Clone, Copy, Default)]
pub struct TokenCounts {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
}

/// Compute actual API cost in USD from token counts.
///
/// Default rates match Sonnet 4 pricing; override via env vars:
/// - `CHUMP_COST_INPUT_PER_MTK`      (default 3.00  $/MTok)
/// - `CHUMP_COST_OUTPUT_PER_MTK`     (default 15.00 $/MTok)
/// - `CHUMP_COST_CACHE_READ_PER_MTK` (default 0.30  $/MTok)
pub fn cost_usd_from_tokens(input: u64, output: u64, cache_read: u64) -> f64 {
    let rate = |var: &str, default: f64| -> f64 {
        std::env::var(var)
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default)
    };
    let input_rate = rate("CHUMP_COST_INPUT_PER_MTK", 3.00_f64);
    let output_rate = rate("CHUMP_COST_OUTPUT_PER_MTK", 15.00_f64);
    let cache_rate = rate("CHUMP_COST_CACHE_READ_PER_MTK", 0.30_f64);
    (input as f64 * input_rate + output as f64 * output_rate + cache_read as f64 * cache_rate)
        / 1_000_000.0
}

/// Session outcome — kept narrow on purpose. Adding new variants is a
/// breaking change for downstream readers; do it deliberately.
#[derive(Debug, Clone, Copy)]
pub enum Outcome {
    Shipped,
    Abandoned,
    Starved,
}

impl Outcome {
    pub fn as_str(&self) -> &'static str {
        match self {
            Outcome::Shipped => "shipped",
            Outcome::Abandoned => "abandoned",
            Outcome::Starved => "starved",
        }
    }
    pub fn from_str(s: &str) -> Option<Outcome> {
        match s.to_lowercase().as_str() {
            "shipped" | "ship" | "s" => Some(Outcome::Shipped),
            "abandoned" | "abandon" | "a" => Some(Outcome::Abandoned),
            "starved" | "starve" | "t" => Some(Outcome::Starved),
            _ => None,
        }
    }
}

/// Emit a `session_start` event. Best-effort.
pub fn emit_session_start(repo_root: &Path, session_id: &str, gap_id: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    let json = format!(
        r#"{{"event":"session_start","kind":"session_start","ts":"{ts}","session_id":"{}","gap_id":"{}"}}"#,
        json_escape_inline(session_id),
        json_escape_inline(gap_id)
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

/// Emit a `session_end` event with elapsed seconds derived from the
/// most-recent matching `session_start` for `(gap_id, session_id)`.
/// If no matching start is found, elapsed_seconds is `null` and the
/// event still records the outcome — partial signal beats none.
///
/// `tokens` is optional; when provided the event includes
/// `input_tokens`, `output_tokens`, and `cache_read_tokens` so that
/// downstream tools (waste-tally, fleet-status) can compute actual
/// cost in USD.
pub fn emit_session_end(
    repo_root: &Path,
    session_id: &str,
    gap_id: &str,
    outcome: Outcome,
    tokens: Option<TokenCounts>,
) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let now = current_unix();
    let elapsed = find_matching_start_unix(&ambient, session_id, gap_id)
        .map(|start_ts| now.saturating_sub(start_ts));
    let ts = current_iso8601();

    let elapsed_field = match elapsed {
        Some(s) => format!(r#""elapsed_seconds":{}"#, s),
        None => r#""elapsed_seconds":null"#.to_string(),
    };
    let token_fields = match tokens {
        Some(t) => format!(
            r#","input_tokens":{},"output_tokens":{},"cache_read_tokens":{}"#,
            t.input_tokens, t.output_tokens, t.cache_read_tokens
        ),
        None => String::new(),
    };
    let json = format!(
        r#"{{"event":"session_end","kind":"session_end","ts":"{ts}","session_id":"{}","gap_id":"{}","outcome":"{}",{}{}}}"#,
        json_escape_inline(session_id),
        json_escape_inline(gap_id),
        outcome.as_str(),
        elapsed_field,
        token_fields
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

/// Compute aggregate session stats for a domain prefix (e.g. "INFRA").
/// Used by briefing.rs to surface cost feedback.
pub fn session_stats_for_domain(repo_root: &Path, domain: &str) -> SessionStats {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let domain_prefix = format!("{}-", domain.to_uppercase());

    let mut elapsed_secs: Vec<u64> = Vec::new();
    let mut shipped = 0u64;
    let mut abandoned = 0u64;
    let mut starved = 0u64;

    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        let gap = extract_field(line, "gap_id").unwrap_or_default();
        if !gap.starts_with(&domain_prefix) {
            continue;
        }
        if let Some(es) = extract_int_field(line, "elapsed_seconds") {
            elapsed_secs.push(es);
        }
        match extract_field(line, "outcome").as_deref() {
            Some("shipped") => shipped += 1,
            Some("abandoned") => abandoned += 1,
            Some("starved") => starved += 1,
            _ => {}
        }
    }

    let n = elapsed_secs.len();
    elapsed_secs.sort_unstable();
    let median = if n == 0 {
        None
    } else if n % 2 == 1 {
        Some(elapsed_secs[n / 2])
    } else {
        Some((elapsed_secs[n / 2 - 1] + elapsed_secs[n / 2]) / 2)
    };
    let min = elapsed_secs.first().copied();
    let max = elapsed_secs.last().copied();

    SessionStats {
        n,
        median_elapsed_seconds: median,
        min_elapsed_seconds: min,
        max_elapsed_seconds: max,
        shipped,
        abandoned,
        starved,
    }
}

#[derive(Debug, Clone, Default)]
pub struct SessionStats {
    pub n: usize,
    pub median_elapsed_seconds: Option<u64>,
    pub min_elapsed_seconds: Option<u64>,
    pub max_elapsed_seconds: Option<u64>,
    pub shipped: u64,
    pub abandoned: u64,
    pub starved: u64,
}

impl SessionStats {
    /// Render a one-line human summary suitable for the briefing.
    /// Empty when n=0.
    pub fn render_oneline(&self, domain: &str) -> String {
        if self.n == 0 {
            return String::new();
        }
        let med_min = self.median_elapsed_seconds.map(|s| s / 60).unwrap_or(0);
        let min_min = self.min_elapsed_seconds.map(|s| s / 60).unwrap_or(0);
        let max_min = self.max_elapsed_seconds.map(|s| s / 60).unwrap_or(0);
        format!(
            "Recent sessions on {} gaps (n={}): median {}m, range {}–{}m. shipped={} abandoned={} starved={}.",
            domain, self.n, med_min, min_min, max_min, self.shipped, self.abandoned, self.starved
        )
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn current_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    if let Ok(out) = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
    {
        if out.status.success() {
            return String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}Z", secs)
}

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    // Permissive: parse "YYYY-MM-DDTHH:MM:SSZ" via date(1). Avoids
    // pulling chrono just for this.
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if !out.status.success() {
        // Fallback for GNU date.
        let out2 = std::process::Command::new("date")
            .args(["-u", "-d", s, "+%s"])
            .output()
            .ok()?;
        if !out2.status.success() {
            return None;
        }
        return String::from_utf8_lossy(&out2.stdout).trim().parse().ok();
    }
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

fn find_matching_start_unix(ambient: &Path, session_id: &str, gap_id: &str) -> Option<u64> {
    let contents = std::fs::read_to_string(ambient).ok()?;
    let mut latest: Option<u64> = None;
    for line in contents.lines() {
        if !line.contains(r#""kind":"session_start""#) {
            continue;
        }
        if extract_field(line, "session_id").as_deref() != Some(session_id) {
            continue;
        }
        if extract_field(line, "gap_id").as_deref() != Some(gap_id) {
            continue;
        }
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(u) = parse_iso8601_to_unix(&ts) {
                latest = Some(latest.map(|l| l.max(u)).unwrap_or(u));
            }
        }
    }
    latest
}

fn json_escape_inline(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
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
    // "field":<digits>
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra477-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn infra477_outcome_parsing() {
        assert!(matches!(
            Outcome::from_str("shipped"),
            Some(Outcome::Shipped)
        ));
        assert!(matches!(
            Outcome::from_str("ABANDONED"),
            Some(Outcome::Abandoned)
        ));
        assert!(matches!(Outcome::from_str("s"), Some(Outcome::Shipped)));
        assert!(Outcome::from_str("nonsense").is_none());
    }

    #[test]
    fn infra477_emit_start_writes_jsonl() {
        let tmp = tempdir();
        emit_session_start(&tmp, "sess-1", "INFRA-100");
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl exists");
        assert!(log.contains(r#""kind":"session_start""#));
        assert!(log.contains("INFRA-100"));
        assert!(log.contains("sess-1"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra477_emit_end_writes_outcome_and_elapsed_or_null() {
        let tmp = tempdir();
        // No matching start → elapsed_seconds:null but event still written
        emit_session_end(&tmp, "sess-orphan", "INFRA-200", Outcome::Abandoned, None);
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl exists");
        assert!(log.contains(r#""kind":"session_end""#));
        assert!(log.contains(r#""outcome":"abandoned""#));
        assert!(log.contains(r#""elapsed_seconds":null"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra477_session_stats_aggregates() {
        let tmp = tempdir();
        // Manually craft 3 session_end events for INFRA-* gaps with
        // different elapsed times, plus one COG-* (filtered out).
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();
        let lines = [
            r#"{"event":"session_end","kind":"session_end","ts":"2026-05-05T10:00:00Z","session_id":"a","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":600}"#,
            r#"{"event":"session_end","kind":"session_end","ts":"2026-05-05T10:00:00Z","session_id":"b","gap_id":"INFRA-2","outcome":"shipped","elapsed_seconds":1800}"#,
            r#"{"event":"session_end","kind":"session_end","ts":"2026-05-05T10:00:00Z","session_id":"c","gap_id":"INFRA-3","outcome":"abandoned","elapsed_seconds":300}"#,
            r#"{"event":"session_end","kind":"session_end","ts":"2026-05-05T10:00:00Z","session_id":"d","gap_id":"COG-1","outcome":"shipped","elapsed_seconds":99999}"#,
        ];
        std::fs::write(&amb, lines.join("\n") + "\n").unwrap();

        let stats = session_stats_for_domain(&tmp, "INFRA");
        assert_eq!(stats.n, 3);
        // 300, 600, 1800 sorted → median 600
        assert_eq!(stats.median_elapsed_seconds, Some(600));
        assert_eq!(stats.min_elapsed_seconds, Some(300));
        assert_eq!(stats.max_elapsed_seconds, Some(1800));
        assert_eq!(stats.shipped, 2);
        assert_eq!(stats.abandoned, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra477_session_stats_empty_ok() {
        let tmp = tempdir();
        let stats = session_stats_for_domain(&tmp, "INFRA");
        assert_eq!(stats.n, 0);
        assert!(stats.median_elapsed_seconds.is_none());
        assert!(stats.render_oneline("INFRA").is_empty());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra534_emit_end_includes_token_fields() {
        let tmp = tempdir();
        emit_session_end(
            &tmp,
            "sess-tok",
            "INFRA-534",
            Outcome::Shipped,
            Some(TokenCounts {
                input_tokens: 1000,
                output_tokens: 500,
                cache_read_tokens: 200,
            }),
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl exists");
        assert!(log.contains(r#""input_tokens":1000"#), "got: {}", log);
        assert!(log.contains(r#""output_tokens":500"#), "got: {}", log);
        assert!(log.contains(r#""cache_read_tokens":200"#), "got: {}", log);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra534_cost_usd_from_tokens_dollar_math() {
        // Default Sonnet rates: $3/MTok input, $15/MTok output, $0.30/MTok cache
        // 1000 input + 500 output + 200 cache_read
        // = (1000*3 + 500*15 + 200*0.30) / 1_000_000
        // = (3000 + 7500 + 60) / 1_000_000 = 10560 / 1_000_000 = 0.01056
        let cost = cost_usd_from_tokens(1000, 500, 200);
        let expected = 0.01056_f64;
        assert!(
            (cost - expected).abs() < 1e-9,
            "expected ~${:.5} got ${:.5}",
            expected,
            cost
        );
    }

    #[test]
    fn infra534_five_fake_session_ends_dollar_math() {
        // 5 events each with input=10k output=2k cache=5k (Sonnet rates)
        // per event: (10000*3 + 2000*15 + 5000*0.30)/1e6 = (30000+30000+1500)/1e6 = 0.0615
        // total: 5 * 0.0615 = 0.3075
        let tmp = tempdir();
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();
        let lines: Vec<String> = (1..=5)
            .map(|i| format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"2026-05-06T10:00:00Z","session_id":"sess-{}","gap_id":"INFRA-{}","outcome":"shipped","elapsed_seconds":600,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":5000}}"#,
                i, i
            ))
            .collect();
        std::fs::write(&amb, lines.join("\n") + "\n").unwrap();
        // verify the math directly
        let cost_per = cost_usd_from_tokens(10000, 2000, 5000);
        let expected = 0.0615_f64;
        assert!(
            (cost_per - expected).abs() < 1e-9,
            "per-event cost: expected ${:.4} got ${:.4}",
            expected,
            cost_per
        );
        let total = cost_per * 5.0;
        assert!(
            (total - 0.3075_f64).abs() < 1e-9,
            "total: expected $0.3075 got ${:.4}",
            total
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra477_render_oneline_includes_minutes_and_outcomes() {
        let stats = SessionStats {
            n: 3,
            median_elapsed_seconds: Some(900),
            min_elapsed_seconds: Some(300),
            max_elapsed_seconds: Some(1800),
            shipped: 2,
            abandoned: 1,
            starved: 0,
        };
        let s = stats.render_oneline("INFRA");
        assert!(s.contains("INFRA gaps (n=3)"));
        assert!(s.contains("median 15m"));
        assert!(s.contains("range 5–30m"));
        assert!(s.contains("shipped=2"));
        assert!(s.contains("abandoned=1"));
    }
}
