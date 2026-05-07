//! COG-042: differential reflection — record "what I did differently
//! than last time on this gap class."
//!
//! Pairs with COG-043 (action-telemetry):
//! - COG-043 measures whether shown lessons WERE applied.
//! - COG-042 measures whether the agent's APPROACH changed across
//!   similar gaps. Both feed META-040 (lesson-effectiveness audit).
//!
//! Minimum viable shape — pure additive, no schema migration:
//! - `chump reflect-delta <GAP-ID> "<text>"` emits a `delta_recorded`
//!   event to `.chump-locks/ambient.jsonl` with ts + session + gap + text.
//! - Briefing surfaces recent `delta_recorded` events for similar gaps
//!   so the next agent on a related gap sees how the last attempt
//!   differed from the time before that.
//!
//! Population mechanism is deferred:
//! - For now, agents call the CLI explicitly when they have something
//!   concrete to record. A follow-up gap (COG-052+) will wire the
//!   bot-merge ship path to prompt for delta on close, similar to
//!   COG-050 deferring COG-043's bot-merge hook.

use std::path::Path;

/// Emit a `delta_recorded` event to ambient.jsonl. Best-effort —
/// silently no-ops on any I/O failure (the CLI exits 0 anyway because
/// recording is observation, not gating).
pub fn emit_delta_recorded(repo_root: &Path, session_id: &str, gap_id: &str, text: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    let truncated: String = text.chars().take(2000).collect();

    // Hand-rolled escape — keep this module dependency-light.
    let json = format!(
        r#"{{"event":"delta_recorded","kind":"delta_recorded","ts":"{ts}","session_id":"{}","gap_id":"{}","delta":"{}"}}"#,
        json_escape_inline(session_id),
        json_escape_inline(gap_id),
        json_escape_inline(&truncated)
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

/// Read the most-recent N `delta_recorded` events for a given gap
/// domain (e.g. "INFRA", "COG"). Used by briefing.rs to surface what
/// past sessions did differently on similar gaps.
///
/// Matches by domain prefix on `gap_id` rather than exact-gap-id so
/// agents see deltas across the broader class. Returns oldest-first.
pub fn recent_deltas_for_domain(repo_root: &Path, domain: &str, limit: usize) -> Vec<DeltaRecord> {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let domain_prefix = format!("{}-", domain.to_uppercase());

    let mut hits: Vec<DeltaRecord> = Vec::new();
    for line in contents.lines() {
        if !line.contains(r#""kind":"delta_recorded""#)
            && !line.contains(r#""kind": "delta_recorded""#)
        {
            continue;
        }
        // Cheap field extraction without pulling serde_json.
        let gap = extract_field(line, "gap_id").unwrap_or_default();
        if !gap.starts_with(&domain_prefix) {
            continue;
        }
        let ts = extract_field(line, "ts").unwrap_or_default();
        let session = extract_field(line, "session_id").unwrap_or_default();
        let delta = extract_field(line, "delta").unwrap_or_default();
        hits.push(DeltaRecord {
            ts,
            session_id: session,
            gap_id: gap,
            delta,
        });
    }
    if hits.len() > limit {
        let drop = hits.len() - limit;
        hits.drain(0..drop);
    }
    hits
}

#[derive(Debug, Clone)]
pub struct DeltaRecord {
    pub ts: String,
    pub session_id: String,
    pub gap_id: String,
    pub delta: String,
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

/// Extract a string field from a single-line JSON object. Permissive —
/// finds `"<field>":"<value>"` and unescapes the standard sequences.
/// Returns None if the field isn't present or the format is malformed.
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
                    // Skip the 4 hex digits — we don't decode unicode
                    // escapes in this minimal parser.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-cog042-test-{}-{}",
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
    fn cog042_emit_writes_jsonl() {
        let tmp = tempdir();
        emit_delta_recorded(
            &tmp,
            "test-session",
            "INFRA-100",
            "tried foo instead of bar",
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl exists");
        assert!(log.contains(r#""kind":"delta_recorded""#));
        assert!(log.contains("INFRA-100"));
        assert!(log.contains("tried foo instead of bar"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cog042_recent_deltas_filters_by_domain() {
        let tmp = tempdir();
        emit_delta_recorded(&tmp, "s1", "INFRA-1", "delta-A");
        emit_delta_recorded(&tmp, "s2", "COG-1", "delta-B");
        emit_delta_recorded(&tmp, "s3", "INFRA-2", "delta-C");
        let infra = recent_deltas_for_domain(&tmp, "INFRA", 10);
        assert_eq!(infra.len(), 2);
        assert!(infra.iter().any(|r| r.delta == "delta-A"));
        assert!(infra.iter().any(|r| r.delta == "delta-C"));
        let cog = recent_deltas_for_domain(&tmp, "COG", 10);
        assert_eq!(cog.len(), 1);
        assert_eq!(cog[0].delta, "delta-B");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cog042_recent_deltas_limit() {
        let tmp = tempdir();
        for i in 0..10 {
            emit_delta_recorded(&tmp, "s", &format!("INFRA-{}", i), &format!("d{}", i));
        }
        let got = recent_deltas_for_domain(&tmp, "INFRA", 3);
        assert_eq!(got.len(), 3);
        // Most-recent-last (oldest-first per docstring); the last 3
        // by file order are INFRA-7, 8, 9.
        assert_eq!(got[2].delta, "d9");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cog042_extract_field_handles_escapes() {
        // Test unescape for JSON escape sequences embedded in delta text.
        let line = r#"{"event":"delta_recorded","kind":"delta_recorded","ts":"x","session_id":"s","gap_id":"COG-1","delta":"line one\nline two with \"quotes\""}"#;
        let v = extract_field(line, "delta").expect("delta field");
        assert_eq!(v, "line one\nline two with \"quotes\"");
    }

    #[test]
    fn cog042_extract_field_returns_none_for_missing() {
        let line = r#"{"event":"other","ts":"x"}"#;
        assert!(extract_field(line, "delta").is_none());
    }

    #[test]
    fn cog042_emit_truncates_long_text() {
        let tmp = tempdir();
        let long: String = "x".repeat(5000);
        emit_delta_recorded(&tmp, "s", "INFRA-1", &long);
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl exists");
        // We truncate to 2000 chars; the resulting line should be < 5000 chars.
        // (JSON envelope adds ~100 chars; budget leaves headroom for both.)
        let line = log.lines().last().unwrap();
        assert!(
            line.len() < 3000,
            "expected truncation, line len={}",
            line.len()
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
