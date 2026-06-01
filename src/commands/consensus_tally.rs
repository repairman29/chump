//! META-159: `chump consensus-tally [--corr-id X | --all] [--since <dur>]`
//! — aggregate FEEDBACK kind=vote events from ambient.jsonl per corr_id
//! and compute a verdict.
//!
//! Reads ambient.jsonl (path: `.chump-locks/ambient.jsonl` or
//! `$CHUMP_AMBIENT_LOG` env override). Filters events with
//! `"event":"FEEDBACK"` AND `"kind":"vote"`, optionally filtered to a
//! single corr_id, within a time window (default 24h; `--since` accepts
//! e.g. `1h`, `4h`, `7d`).
//!
//! Verdict logic (AC3):
//!   PASSED     — yes >= 3 AND yes > no
//!   FAILED     — no > yes AND no >= 2
//!   NO_QUORUM  — total < 3
//!   EXTENDED   — PASSED/FAILED/NO_QUORUM but deadline > now
//!
//! Output (one block per corr_id):
//!   corr_id=<id>  yes=<n>  no=<m>  abstain=<k>  total=<t>  weighted=<w>  verdict=<V>
//!
//! CREDIBLE-082 — Vote Weighting (anti-echo-chamber):
//!   Events with a non-empty `parent_corr_id` matching the proposal's corr_id
//!   are classified as *reactions* and receive a fractional weight
//!   (default 0.3; override via `CHUMP_CONSENSUS_REACT_WEIGHT` env var).
//!   Events without `parent_corr_id` (or with an empty/null value) are
//!   *originals* and receive weight 1.0.
//!
//!   If no events carry `parent_corr_id` at all (EFFECTIVE-028 not yet
//!   shipped), all votes are treated as originals — backward compatible.
//!
//!   Echo-chamber warning: when `weighted / raw_count < echo_warn_threshold`
//!   (default 0.5; `--echo-warn-threshold <f>` flag), the row is prefixed
//!   with "[echo-warn]" to flag "consensus is mostly reactions."
//!
//! consensus-tally ALWAYS runs regardless of feature flag (read-only is safe).
//!
//! Acceptance criteria satisfied:
//!   AC2 — consensus_tally.rs implements chump consensus-tally [--corr-id X | --all] [--since <dur>]
//!   AC3 — verdict logic: PASSED/FAILED/NO_QUORUM/EXTENDED
//!   AC4 — registered in src/main.rs
//!   AC6 — test-chump-consensus-tally.sh seeds votes and checks output
//!   CREDIBLE-082 — vote weighting + echo-warn column + backward compat

use std::collections::HashMap;
use std::path::PathBuf;

/// One vote event parsed from ambient.jsonl.
#[derive(Debug, Clone)]
struct VoteEvent {
    corr_id: String,
    vote: i32, // +1, -1, 0
    /// Optional deadline ISO-8601 string attached to the event.
    deadline: Option<String>,
    /// CREDIBLE-082: non-empty → this is a reaction to the proposal with that corr_id.
    /// Empty/None → original emission; weight = 1.0.
    parent_corr_id: Option<String>,
}

/// Aggregated tally per corr_id.
#[derive(Debug, Default)]
struct Tally {
    yes: u32,
    no: u32,
    abstain: u32,
    /// CREDIBLE-082: sum of per-vote weights (1.0 for originals, react_weight for reactions).
    weighted: f64,
    /// Latest deadline seen for this corr_id (ISO-8601).
    deadline: Option<String>,
}

impl Tally {
    fn total(&self) -> u32 {
        self.yes + self.no + self.abstain
    }

    /// Compute verdict per AC3.
    fn verdict(&self, now_secs: i64) -> &'static str {
        // Check deadline first.
        let deadline_future = self
            .deadline
            .as_deref()
            .and_then(|d| parse_iso8601(d))
            .map(|ts| ts > now_secs)
            .unwrap_or(false);

        let base = if self.total() < 3 {
            "NO_QUORUM"
        } else if self.yes >= 3 && self.yes > self.no {
            "PASSED"
        } else if self.no > self.yes && self.no >= 2 {
            "FAILED"
        } else {
            "NO_QUORUM"
        };

        if deadline_future {
            "EXTENDED"
        } else {
            base
        }
    }
}

/// Parse an ISO-8601 UTC timestamp to Unix seconds.
/// Returns None if parsing fails.
fn parse_iso8601(s: &str) -> Option<i64> {
    // Try a simple pattern: YYYY-MM-DDTHH:MM:SSZ or with +00:00
    // Use chrono for proper parsing.
    use std::str::FromStr;
    // chrono::DateTime<chrono::FixedOffset> can parse RFC 3339.
    if let Ok(dt) = chrono::DateTime::<chrono::FixedOffset>::from_str(s) {
        return Some(dt.timestamp());
    }
    // Try with UTC 'Z' suffix → FixedOffset doesn't always handle bare Z.
    if let Ok(dt) = chrono::DateTime::<chrono::Utc>::from_str(s) {
        return Some(dt.timestamp());
    }
    None
}

/// Parse a duration string like "1h", "24h", "7d" → seconds.
fn parse_duration_secs(s: &str) -> Option<i64> {
    if let Some(n) = s.strip_suffix('h') {
        n.parse::<i64>().ok().map(|h| h * 3600)
    } else if let Some(n) = s.strip_suffix('d') {
        n.parse::<i64>().ok().map(|d| d * 86400)
    } else if let Some(n) = s.strip_suffix('m') {
        n.parse::<i64>().ok().map(|m| m * 60)
    } else {
        s.parse::<i64>().ok() // bare seconds
    }
}

/// Extract a string value from a flat JSON object line.
/// Handles simple `"key":"value"` and `"key":numeric` patterns.
fn json_get_str<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{}\":", key);
    let pos = line.find(needle.as_str())?;
    let rest = &line[pos + needle.len()..];
    if rest.starts_with('"') {
        // String value: find closing quote, accounting for escaped chars.
        let inner = &rest[1..];
        let mut end = 0;
        let mut escaped = false;
        for (i, c) in inner.char_indices() {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                end = i;
                break;
            }
        }
        Some(&inner[..end])
    } else {
        // Numeric or bare value: read until comma/space/brace.
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == ' ')
            .unwrap_or(rest.len());
        Some(rest[..end].trim())
    }
}

/// Parse a vote from a JSON value string: "1", "-1", "0", or unquoted.
fn parse_vote_str(s: &str) -> Option<i32> {
    match s.trim_matches('"') {
        "1" | "+1" => Some(1),
        "-1" => Some(-1),
        "0" => Some(0),
        _ => None,
    }
}

/// Resolve ambient.jsonl path.
fn ambient_path() -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            // Walk up from cwd to find repo root, then .chump-locks/ambient.jsonl
            let root = if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
                PathBuf::from(r)
            } else {
                let mut d = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
                loop {
                    let cargo = d.join("Cargo.toml");
                    if cargo.exists() {
                        if let Ok(c) = std::fs::read_to_string(&cargo) {
                            if c.contains("[workspace]") {
                                break;
                            }
                        }
                    }
                    if !d.pop() {
                        d = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
                        break;
                    }
                }
                d
            };
            root.join(".chump-locks/ambient.jsonl")
        })
}

/// Parse ambient.jsonl into VoteEvents.
fn load_vote_events(
    path: &std::path::Path,
    since_secs: i64,
    now_secs: i64,
    filter_corr_id: Option<&str>,
) -> Vec<VoteEvent> {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };

    let mut events = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Must have event=FEEDBACK and kind=vote
        let ev = json_get_str(line, "event");
        let kind = json_get_str(line, "kind");
        if ev != Some("FEEDBACK") || kind != Some("vote") {
            continue;
        }

        // Time filter
        if since_secs > 0 {
            if let Some(ts_str) = json_get_str(line, "ts") {
                if let Some(ts) = parse_iso8601(ts_str) {
                    if ts < now_secs - since_secs {
                        continue;
                    }
                }
            }
        }

        let corr_id = match json_get_str(line, "corr_id") {
            Some(c) if !c.is_empty() => c.to_string(),
            _ => continue,
        };

        // corr_id filter
        if let Some(f) = filter_corr_id {
            if corr_id != f {
                continue;
            }
        }

        let vote = match json_get_str(line, "vote").and_then(parse_vote_str) {
            Some(v) => v,
            None => continue,
        };

        let deadline = json_get_str(line, "deadline").map(|s| s.to_string());

        // CREDIBLE-082: extract parent_corr_id; treat empty string as None.
        let parent_corr_id = json_get_str(line, "parent_corr_id")
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty());

        events.push(VoteEvent {
            corr_id,
            vote,
            deadline,
            parent_corr_id,
        });
    }
    events
}

/// Aggregate VoteEvents into tallies per corr_id.
///
/// CREDIBLE-082: `react_weight` is the fractional weight for reactions
/// (events whose `parent_corr_id` matches the proposal's corr_id).
/// Originals (no `parent_corr_id`) receive weight 1.0.
/// If no event in the batch carries any `parent_corr_id`, the weighted
/// sum equals the raw count — full backward compatibility.
fn aggregate(events: &[VoteEvent], react_weight: f64) -> HashMap<String, Tally> {
    let mut map: HashMap<String, Tally> = HashMap::new();
    for ev in events {
        let t = map.entry(ev.corr_id.clone()).or_default();
        match ev.vote {
            1 => t.yes += 1,
            -1 => t.no += 1,
            _ => t.abstain += 1,
        }
        // CREDIBLE-082: a reaction has a non-empty parent_corr_id pointing at
        // the proposal being tallied (i.e. matching this event's own corr_id).
        // We check whether the event carries *any* non-empty parent_corr_id;
        // if so it is a reaction regardless of whether it matches exactly
        // (the filter_corr_id guard in load_vote_events already ensures corr_id
        // alignment when --corr-id is specified; for --all mode we weight any
        // event that has a parent_corr_id as a reaction).
        let weight = if ev.parent_corr_id.is_some() {
            react_weight
        } else {
            1.0
        };
        t.weighted += weight;
        // Keep the first non-None deadline.
        if t.deadline.is_none() {
            t.deadline = ev.deadline.clone();
        }
    }
    map
}

pub fn run(args: &[String]) -> i32 {
    // consensus-tally always runs (read-only, no feature flag required).

    // Parse args: [--corr-id X | --all] [--since <dur>] [--echo-warn-threshold <f>]
    let mut filter_corr_id: Option<String> = None;
    let mut _show_all = false;
    let mut since_str: Option<String> = None;
    let mut echo_warn_threshold_str: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--corr-id" => {
                i += 1;
                if i < args.len() {
                    filter_corr_id = Some(args[i].clone());
                }
            }
            "--all" => {
                _show_all = true;
            }
            "--since" => {
                i += 1;
                if i < args.len() {
                    since_str = Some(args[i].clone());
                }
            }
            // CREDIBLE-082: echo-warn threshold flag (default 0.5).
            "--echo-warn-threshold" => {
                i += 1;
                if i < args.len() {
                    echo_warn_threshold_str = Some(args[i].clone());
                }
            }
            _ => {}
        }
        i += 1;
    }

    // Default window: 24h.
    let since_secs = since_str
        .as_deref()
        .and_then(parse_duration_secs)
        .unwrap_or(86400);

    // CREDIBLE-082: reaction weight from env (default 0.3).
    let react_weight: f64 = std::env::var("CHUMP_CONSENSUS_REACT_WEIGHT")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.3);

    // CREDIBLE-082: echo-warn threshold from flag (default 0.5).
    let echo_warn_threshold: f64 = echo_warn_threshold_str
        .as_deref()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.5);

    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let path = ambient_path();
    let events = load_vote_events(&path, since_secs, now_secs, filter_corr_id.as_deref());

    if events.is_empty() {
        println!("no vote events found");
        return 0;
    }

    let tallies = aggregate(&events, react_weight);

    // Print sorted by corr_id for deterministic output.
    let mut keys: Vec<&String> = tallies.keys().collect();
    keys.sort();

    for key in keys {
        let t = &tallies[key];
        let verdict = t.verdict(now_secs);
        let raw = t.total();
        let weighted = t.weighted;

        // CREDIBLE-082: emit echo-warn prefix when weighted/raw is below threshold.
        // Guard against zero-raw (shouldn't happen, but be safe).
        let echo_warn = raw > 0 && (weighted / raw as f64) < echo_warn_threshold;
        let prefix = if echo_warn { "[echo-warn] " } else { "" };

        println!(
            "{prefix}corr_id={key}  yes={yes}  no={no}  abstain={abstain}  total={raw}  weighted={weighted:.2}  verdict={verdict}",
            yes = t.yes,
            no = t.no,
            abstain = t.abstain,
        );
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_tally(
        yes: u32,
        no: u32,
        abstain: u32,
        weighted: f64,
        deadline: Option<String>,
    ) -> Tally {
        Tally {
            yes,
            no,
            abstain,
            weighted,
            deadline,
        }
    }

    #[test]
    fn verdict_passed() {
        let t = make_tally(3, 1, 0, 4.0, None);
        assert_eq!(t.verdict(0), "PASSED");
    }

    #[test]
    fn verdict_failed() {
        let t = make_tally(0, 2, 1, 3.0, None);
        assert_eq!(t.verdict(0), "FAILED");
    }

    #[test]
    fn verdict_no_quorum() {
        let t = make_tally(1, 0, 0, 1.0, None);
        assert_eq!(t.verdict(0), "NO_QUORUM");
    }

    #[test]
    fn verdict_extended_deadline_future() {
        // deadline in the far future → EXTENDED regardless of base verdict
        let t = make_tally(3, 1, 0, 4.0, Some("2099-01-01T00:00:00Z".to_string())); // chump-fmt: time-bomb-ok
        assert_eq!(t.verdict(0), "EXTENDED");
    }

    #[test]
    fn json_get_str_string_value() {
        let line = r#"{"event":"FEEDBACK","kind":"vote","corr_id":"META-999","vote":1}"#;
        assert_eq!(json_get_str(line, "event"), Some("FEEDBACK"));
        assert_eq!(json_get_str(line, "kind"), Some("vote"));
        assert_eq!(json_get_str(line, "corr_id"), Some("META-999"));
    }

    #[test]
    fn json_get_str_numeric_vote() {
        let line = r#"{"event":"FEEDBACK","kind":"vote","corr_id":"X","vote":1}"#;
        let v = json_get_str(line, "vote").and_then(parse_vote_str);
        assert_eq!(v, Some(1));
    }

    #[test]
    fn json_get_str_negative_vote() {
        let line = r#"{"event":"FEEDBACK","kind":"vote","corr_id":"X","vote":-1}"#;
        let v = json_get_str(line, "vote").and_then(parse_vote_str);
        assert_eq!(v, Some(-1));
    }

    #[test]
    fn parse_duration_secs_hours() {
        assert_eq!(parse_duration_secs("24h"), Some(86400));
        assert_eq!(parse_duration_secs("1h"), Some(3600));
    }

    #[test]
    fn parse_duration_secs_days() {
        assert_eq!(parse_duration_secs("7d"), Some(604800));
    }

    // CREDIBLE-082: vote weighting unit tests.

    /// 1 original + 5 reactions @ 0.3 → weighted = 1.0 + 5×0.3 = 2.5
    #[test]
    fn aggregate_weighted_reactions() {
        let react_weight = 0.3_f64;
        let proposal_id = "prop-001".to_string();
        let mut events: Vec<VoteEvent> = Vec::new();

        // 1 original vote (no parent_corr_id)
        events.push(VoteEvent {
            corr_id: proposal_id.clone(),
            vote: 1,
            deadline: None,
            parent_corr_id: None,
        });

        // 5 reactions (parent_corr_id set)
        for _ in 0..5 {
            events.push(VoteEvent {
                corr_id: proposal_id.clone(),
                vote: 1,
                deadline: None,
                parent_corr_id: Some(proposal_id.clone()),
            });
        }

        let tallies = aggregate(&events, react_weight);
        let t = &tallies[&proposal_id];

        assert_eq!(t.total(), 6);
        // weighted = 1.0 + 5 × 0.3 = 2.5 — allow float epsilon
        let expected = 1.0 + 5.0 * react_weight;
        assert!(
            (t.weighted - expected).abs() < 1e-9,
            "expected weighted={expected}, got {}",
            t.weighted
        );
    }

    /// All originals (no parent_corr_id) → weighted equals raw count.
    #[test]
    fn aggregate_all_originals_weighted_equals_raw() {
        let events: Vec<VoteEvent> = (0..4)
            .map(|_| VoteEvent {
                corr_id: "c1".to_string(),
                vote: 1,
                deadline: None,
                parent_corr_id: None,
            })
            .collect();

        let tallies = aggregate(&events, 0.3);
        let t = &tallies["c1"];
        assert_eq!(t.total(), 4);
        assert!((t.weighted - 4.0).abs() < 1e-9);
    }

    /// echo-warn fires when weighted/raw < 0.5 (the default threshold).
    #[test]
    fn echo_warn_fires_when_mostly_reactions() {
        // 1 original + 5 reactions → weighted=2.5, raw=6, ratio≈0.417 < 0.5
        let weighted = 2.5_f64;
        let raw = 6_u32;
        let threshold = 0.5_f64;
        let echo_warn = raw > 0 && (weighted / raw as f64) < threshold;
        assert!(
            echo_warn,
            "echo-warn should fire for ratio {:.3}",
            weighted / raw as f64
        );
    }

    /// echo-warn does NOT fire for pure originals (ratio = 1.0).
    #[test]
    fn echo_warn_silent_for_pure_originals() {
        let weighted = 6.0_f64;
        let raw = 6_u32;
        let threshold = 0.5_f64;
        let echo_warn = raw > 0 && (weighted / raw as f64) < threshold;
        assert!(!echo_warn);
    }

    /// json_get_str extracts parent_corr_id correctly.
    #[test]
    fn json_get_str_parent_corr_id() {
        let line = r#"{"event":"FEEDBACK","kind":"vote","corr_id":"c1","parent_corr_id":"prop-001","vote":1}"#;
        assert_eq!(json_get_str(line, "parent_corr_id"), Some("prop-001"));
    }

    /// Empty parent_corr_id is treated as None (original).
    #[test]
    fn empty_parent_corr_id_is_original() {
        let line =
            r#"{"event":"FEEDBACK","kind":"vote","corr_id":"c1","parent_corr_id":"","vote":1}"#;
        let parent = json_get_str(line, "parent_corr_id")
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty());
        assert!(
            parent.is_none(),
            "empty parent_corr_id should be treated as None"
        );
    }
}
