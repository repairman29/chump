//! ZERO-WASTE-125 AC2: `chump rules audit [--window 30d] [--json]` —
//! reports fires / bypasses per registered rule from
//! `docs/process/RULE_REGISTRY.json` + `.chump-locks/ambient.jsonl`, and
//! ranks delete candidates (rules with zero fires in the window).
//!
//! Honesty note: "catches" (a fire followed by a fix commit on the same PR)
//! and "cost" (CI minutes, agent retries) from the gap's AC2 wishlist are
//! NOT computed here — today's ambient schema has no PR-correlation field
//! on gate-fire events, so faking those numbers would violate the Credible
//! pillar (measurement over vibes). This reports what is actually
//! measurable today (fires, bypasses) and marks the rest `not_instrumented`
//! rather than fabricating. Follow-up: wire PR-correlated catch/cost
//! tracking once gate-fire events carry a `pr_number` field.

use std::collections::HashMap;
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    crate::repo_path::repo_root()
}

struct Rule {
    id: String,
    source: String,
    signal: String,
    protected: bool,
}

fn parse_registry(text: &str) -> Vec<Rule> {
    let Ok(json) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    let Some(rules) = json.get("rules").and_then(|r| r.as_array()) else {
        return Vec::new();
    };
    rules
        .iter()
        .filter_map(|r| {
            Some(Rule {
                id: r.get("id")?.as_str()?.to_string(),
                source: r.get("source")?.as_str().unwrap_or("").to_string(),
                signal: r.get("signal")?.as_str().unwrap_or("").to_string(),
                protected: r
                    .get("protected")
                    .and_then(|p| p.as_bool())
                    .unwrap_or(false),
            })
        })
        .collect()
}

fn parse_window_days(s: &str) -> Option<u64> {
    let s = s.strip_suffix('d')?;
    s.parse().ok()
}

/// Returns (fires, bypasses) for each signal, counted from ambient.jsonl
/// lines within the last `window_days` days. A line counts as a "fire" for
/// a rule if its `kind` field equals the rule's `ci_check=`/`kind=` target,
/// or (for CI gates with no dedicated ambient kind yet) if the rule id
/// appears verbatim in the line. A line counts as a "bypass" if it also
/// contains the substring "bypass" (case-insensitive).
fn count_signals(
    ambient_path: &PathBuf,
    rules: &[Rule],
    window_days: u64,
) -> HashMap<String, (u64, u64)> {
    let mut counts: HashMap<String, (u64, u64)> = HashMap::new();
    for r in rules {
        counts.insert(r.id.clone(), (0, 0));
    }

    let Ok(text) = std::fs::read_to_string(ambient_path) else {
        return counts;
    };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let window_secs = window_days.saturating_mul(86_400);
    let cutoff = now.saturating_sub(window_secs);

    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        // Best-effort timestamp parse: ambient lines carry an ISO8601 "ts"
        // field; fall back to "include it" if unparseable rather than
        // silently dropping real signal.
        if let Some(ts) = v.get("ts").and_then(|t| t.as_str()) {
            if let Ok(parsed) = chrono_parse_unix(ts) {
                if parsed < cutoff {
                    continue;
                }
            }
        }
        let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        let lower_line = line.to_lowercase();
        let is_bypass = lower_line.contains("bypass");

        for r in rules {
            let signal_kind = r.signal.strip_prefix("kind=").unwrap_or("");
            let matched = (!signal_kind.is_empty() && kind == signal_kind)
                || lower_line.contains(&r.id.to_lowercase());
            if matched {
                let entry = counts.entry(r.id.clone()).or_insert((0, 0));
                entry.0 += 1;
                if is_bypass {
                    entry.1 += 1;
                }
            }
        }
    }

    counts
}

/// Minimal ISO8601 UTC -> unix seconds, no chrono dependency pulled in
/// just for this. Returns Err on anything it can't parse; caller treats
/// that as "include the line" (fail open, not closed — we'd rather over-
/// count fires than silently drop real signal due to a format we didn't
/// anticipate).
fn chrono_parse_unix(ts: &str) -> Result<u64, ()> {
    // Expected shape: 2026-09-29T12:34:56Z (or with fractional seconds).
    let ts = ts.trim_end_matches('Z');
    let (date, time) = ts.split_once('T').ok_or(())?;
    let mut d = date.split('-');
    let year: i64 = d.next().ok_or(())?.parse().map_err(|_| ())?;
    let month: i64 = d.next().ok_or(())?.parse().map_err(|_| ())?;
    let day: i64 = d.next().ok_or(())?.parse().map_err(|_| ())?;
    let time = time.split('.').next().ok_or(())?;
    let mut t = time.split(':');
    let hour: i64 = t.next().ok_or(())?.parse().map_err(|_| ())?;
    let min: i64 = t.next().ok_or(())?.parse().map_err(|_| ())?;
    let sec: i64 = t.next().ok_or(())?.parse().map_err(|_| ())?;

    // Days since epoch via a simple civil_from_days-style calc (Howard
    // Hinnant's algorithm), good enough for a reporting tool.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days_since_epoch = era * 146_097 + doe - 719_468;

    let secs = days_since_epoch * 86_400 + hour * 3600 + min * 60 + sec;
    if secs < 0 {
        return Err(());
    }
    Ok(secs as u64)
}

pub fn run(args: &[String]) -> i32 {
    let mut window_days: u64 = 30;
    let mut json_out = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--window" => {
                let Some(v) = args.get(i + 1) else {
                    eprintln!("chump rules audit: --window requires a value, e.g. --window 30d");
                    return 2;
                };
                match parse_window_days(v) {
                    Some(d) => window_days = d,
                    None => {
                        eprintln!("chump rules audit: invalid --window '{v}', expected e.g. '30d'");
                        return 2;
                    }
                }
                i += 2;
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            "help" | "--help" | "-h" => {
                println!("chump rules audit [--window 30d] [--json]");
                println!("Reports fires/bypasses per registered rule over the trailing window,");
                println!("ranking zero-fire rules as delete candidates. Reads:");
                println!("  docs/process/RULE_REGISTRY.json");
                println!("  .chump-locks/ambient.jsonl");
                return 0;
            }
            other => {
                eprintln!("chump rules audit: unknown argument '{other}'");
                return 2;
            }
        }
    }

    let root = repo_root();
    let registry_path = root.join("docs/process/RULE_REGISTRY.json");
    let Ok(registry_text) = std::fs::read_to_string(&registry_path) else {
        eprintln!(
            "chump rules audit: registry missing at {} — run scripts/coord/rules-registry-gen.sh",
            registry_path.display()
        );
        return 3;
    };
    let rules = parse_registry(&registry_text);
    if rules.is_empty() {
        eprintln!(
            "chump rules audit: registry at {} has no rules",
            registry_path.display()
        );
        return 3;
    }

    let ambient_path = root.join(".chump-locks/ambient.jsonl");
    let counts = count_signals(&ambient_path, &rules, window_days);

    let mut rows: Vec<serde_json::Value> = Vec::new();
    for r in &rules {
        let (fires, bypasses) = counts.get(&r.id).copied().unwrap_or((0, 0));
        let bypass_rate = if fires > 0 {
            bypasses as f64 / fires as f64
        } else {
            0.0
        };
        let delete_candidate = !r.protected && fires == 0;
        rows.push(serde_json::json!({
            "id": r.id,
            "source": r.source,
            "signal": r.signal,
            "protected": r.protected,
            "window_days": window_days,
            "fires": fires,
            "bypasses": bypasses,
            "bypass_rate": bypass_rate,
            "catches": "not_instrumented",
            "cost": "not_instrumented",
            "delete_candidate": delete_candidate,
        }));
    }
    // Delete candidates first, then by fewest fires.
    rows.sort_by(|a, b| {
        let ac = a["delete_candidate"].as_bool().unwrap_or(false);
        let bc = b["delete_candidate"].as_bool().unwrap_or(false);
        bc.cmp(&ac).then(
            a["fires"]
                .as_u64()
                .unwrap_or(0)
                .cmp(&b["fires"].as_u64().unwrap_or(0)),
        )
    });

    let candidate_count = rows
        .iter()
        .filter(|r| r["delete_candidate"].as_bool().unwrap_or(false))
        .count();

    if json_out {
        println!(
            "{}",
            serde_json::json!({
                "window_days": window_days,
                "total_rules": rules.len(),
                "delete_candidates": candidate_count,
                "rules": rows,
            })
        );
        return 0;
    }

    println!(
        "chump rules audit — {} rules, window={}d, {} delete candidate(s) (0 fires, not protected)",
        rules.len(),
        window_days,
        candidate_count
    );
    println!(
        "{:<45} {:>8} {:>10} {:>10}  note",
        "id", "fires", "bypasses", "protected"
    );
    for row in rows.iter().take(40) {
        println!(
            "{:<45} {:>8} {:>10} {:>10}  {}",
            row["id"].as_str().unwrap_or(""),
            row["fires"].as_u64().unwrap_or(0),
            row["bypasses"].as_u64().unwrap_or(0),
            row["protected"].as_bool().unwrap_or(false),
            if row["delete_candidate"].as_bool().unwrap_or(false) {
                "DELETE CANDIDATE"
            } else {
                ""
            }
        );
    }
    if rows.len() > 40 {
        println!(
            "... and {} more (use --json for the full list)",
            rows.len() - 40
        );
    }
    println!();
    println!(
        "catches/cost: not_instrumented (ambient has no PR-correlation field yet — see module doc)"
    );

    0
}
