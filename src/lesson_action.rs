//! COG-043: lesson action-telemetry — record whether agents actually
//! ACT ON the lessons surfaced to them.
//!
//! Two events written to `.chump-locks/ambient.jsonl`:
//!
//! 1. `lessons_shown` (emitted from `briefing.rs` when a briefing is
//!    rendered): records which directives were surfaced for `gap_id` at
//!    time `ts`, plus the ranking mode (`semantic` vs `recency`).
//!
//! 2. `lesson_applied` / `lesson_not_applied` (emitted from
//!    `chump lesson-grade <GAP-ID> --pr <N>` post-ship): for each
//!    `lessons_shown` event matching the gap, score the directive
//!    against the PR's diff + body. If >=50% of the directive's
//!    distinctive (high-IDF) tokens appear in the PR text, count as
//!    applied. Else, not_applied.
//!
//! Aggregation (downstream, separate gap):
//!   META-040 (lesson-effectiveness audit) reads these events nightly
//!   and grades each directive by adoption rate.
//!   EVAL-099 (COG-041 quality eval) reads them to compare lesson-applied
//!   rate between semantic and recency-frequency modes.
//!
//! Design constraints:
//! - Best-effort everywhere — never blocks shipping or briefing if the
//!   write fails. Telemetry is for measurement, not gating.
//! - No new tables yet (defer to META-040 if aggregation needs them).
//!   ambient.jsonl is the durable log; consumers parse it.

use std::collections::HashSet;
use std::path::Path;

/// Stop list reused from COG-041 tokenize semantics. Kept in sync
/// manually rather than imported to avoid cross-module coupling that
/// shifts the IDF distribution if either side changes.
const STOPWORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "is", "are", "was", "were", "be", "been", "being", "to",
    "of", "in", "on", "at", "for", "with", "by", "from", "as", "this", "that", "these", "those",
    "it", "its", "if", "then", "else", "do", "does", "did", "have", "has", "had", "i", "you", "we",
    "they", "he", "she", "will", "would", "should", "could", "can", "may", "might", "not", "no",
    "yes", "so", "up", "down", "out", "into", "than", "vs", "via", "per", "via",
];

/// Tokenize text → lowercase alphanumeric tokens, len>=4 (slightly
/// stricter than COG-041's len>=3 because we want distinctive tokens
/// for matching, not bag-of-words signal). Drops stopwords and pure-
/// numeric tokens.
pub fn extract_keywords(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            cur.push(ch.to_ascii_lowercase());
        } else if !cur.is_empty() {
            push_kw(&mut out, std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        push_kw(&mut out, cur);
    }
    out
}

fn push_kw(out: &mut Vec<String>, t: String) {
    if t.len() < 4 {
        return;
    }
    if t.chars().all(|c| c.is_ascii_digit()) {
        return;
    }
    if STOPWORDS.contains(&t.as_str()) {
        return;
    }
    out.push(t);
}

/// Score how strongly a directive's keywords appear in the PR text.
///
/// Strategy:
/// - Extract keywords from `directive`.
/// - Take the most distinctive (here: just the unique set; we don't have
///   per-corpus IDF available without the briefing/db pool, and the
///   simple unique-token approach is good-enough signal at this scale).
/// - For each keyword, check whether it appears as a substring (case-
///   insensitive) of `pr_text`. The substring approach catches
///   "cascade" matching "cascading" and similar morphology.
/// - Return (matched, total): caller decides threshold.
pub fn score_directive_against_pr(directive: &str, pr_text: &str) -> (usize, usize) {
    let kws: HashSet<String> = extract_keywords(directive).into_iter().collect();
    if kws.is_empty() {
        return (0, 0);
    }
    let pr_lower = pr_text.to_lowercase();
    let matched = kws.iter().filter(|k| pr_lower.contains(k.as_str())).count();
    (matched, kws.len())
}

/// Decide whether a directive counts as APPLIED to the PR.
///
/// Threshold: >=50% of distinctive tokens present, AND at least 2
/// tokens matched in absolute terms. The absolute-2 floor avoids
/// false-positive "applied" decisions on directives with very few
/// distinctive tokens (a 1/1 match would otherwise be 100%).
pub fn directive_applied(directive: &str, pr_text: &str) -> bool {
    let (matched, total) = score_directive_against_pr(directive, pr_text);
    if total == 0 {
        return false;
    }
    matched >= 2 && (matched as f64) / (total as f64) >= 0.5
}

/// Emit a `lessons_shown` event to ambient.jsonl.
/// Called from briefing.rs after rendering.
///
/// `mode` is "semantic" or "recency" — the ranking algorithm that
/// produced the shown set. Distinguishes COG-041 traffic from
/// recency-frequency traffic so EVAL-099 can split outcomes.
pub fn emit_lessons_shown(
    repo_root: &Path,
    session_id: &str,
    gap_id: &str,
    mode: &str,
    directives: &[String],
) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();

    // Truncate each directive to 200 chars to keep the JSONL log lean.
    let truncated: Vec<String> = directives
        .iter()
        .map(|d| {
            if d.chars().count() > 200 {
                d.chars().take(200).collect()
            } else {
                d.clone()
            }
        })
        .collect();

    let json = if let Some(j) = build_json_via_python(
        &[
            ("event", "lessons_shown"),
            ("kind", "lessons_shown"),
            ("ts", &ts),
            ("session_id", session_id),
            ("gap_id", gap_id),
            ("mode", mode),
        ],
        Some(("directives", &truncated)),
    ) {
        j
    } else {
        // Fallback hand-rolled emitter if python3 isn't available.
        let dirs_json = truncated
            .iter()
            .map(|d| json_escape(d))
            .collect::<Vec<_>>()
            .join(",");
        format!(
            r#"{{"event":"lessons_shown","kind":"lessons_shown","ts":"{ts}","session_id":"{}","gap_id":"{}","mode":"{}","directives":[{}]}}"#,
            json_escape_inline(session_id),
            json_escape_inline(gap_id),
            json_escape_inline(mode),
            dirs_json
        )
    };

    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

/// Emit `lesson_applied` or `lesson_not_applied`.
/// Called from `chump lesson-grade <GAP-ID> --pr <N>`.
///
/// 8 args is over clippy's default of 7, but each is a distinct
/// primitive (session+gap+pr+directive+applied+matched+total) that
/// doesn't naturally cluster into a struct without bloating the
/// caller. Telemetry path stays flat.
#[allow(clippy::too_many_arguments)]
pub fn emit_lesson_grade(
    repo_root: &Path,
    session_id: &str,
    gap_id: &str,
    pr_number: u64,
    directive: &str,
    applied: bool,
    matched: usize,
    total_keywords: usize,
) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    let kind = if applied {
        "lesson_applied"
    } else {
        "lesson_not_applied"
    };
    let directive_short: String = directive.chars().take(200).collect();
    let pr_str = pr_number.to_string();
    let matched_str = matched.to_string();
    let total_str = total_keywords.to_string();

    let json = if let Some(j) = build_json_via_python(
        &[
            ("event", "ALERT"),
            ("kind", kind),
            ("ts", &ts),
            ("session_id", session_id),
            ("gap_id", gap_id),
            ("pr", &pr_str),
            ("directive", &directive_short),
            ("matched_keywords", &matched_str),
            ("total_keywords", &total_str),
        ],
        None,
    ) {
        j
    } else {
        format!(
            r#"{{"event":"ALERT","kind":"{kind}","ts":"{ts}","session_id":"{}","gap_id":"{}","pr":{pr_number},"directive":"{}","matched_keywords":{matched},"total_keywords":{total_keywords}}}"#,
            json_escape_inline(session_id),
            json_escape_inline(gap_id),
            json_escape_inline(&directive_short),
        )
    };

    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

fn current_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Avoid pulling chrono just for this. Use the `date` shell as a
    // last-resort + a hand-rolled formatter using the secs-since-epoch.
    if let Ok(out) = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
    {
        if out.status.success() {
            return String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
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

fn json_escape(s: &str) -> String {
    format!(r#""{}""#, json_escape_inline(s))
}

/// Build a JSON object via python3 (more reliable than hand-rolled
/// for unicode + nested arrays). Returns None if python3 is unavailable
/// or fails — caller should fall back to hand-rolled emitter.
///
/// `kvs` is flat string-string pairs; `array_field` is an optional
/// `(field_name, &[String])` for one array field.
fn build_json_via_python(
    kvs: &[(&str, &str)],
    array_field: Option<(&str, &[String])>,
) -> Option<String> {
    let mut script = String::from("import json,sys; o={}");
    let mut argv: Vec<String> = Vec::new();
    for (i, (k, _v)) in kvs.iter().enumerate() {
        argv.push((*k).to_string());
        script.push_str(&format!(
            "; o[sys.argv[{}]]=sys.argv[{}]",
            i * 2 + 1,
            i * 2 + 2
        ));
    }
    // Re-shape so each key/value is appended in pairs argv[1],argv[2] ...
    let mut paired_argv: Vec<String> = Vec::new();
    for (k, v) in kvs.iter() {
        paired_argv.push((*k).to_string());
        paired_argv.push((*v).to_string());
    }
    if let Some((name, arr)) = array_field {
        // Append the array elements as pipe-joined argv at the tail; the
        // python script splits them.
        let arr_marker = format!("__ARR__{}", paired_argv.len());
        let arr_payload = arr.join("\u{1f}"); // ASCII unit-separator delim
        paired_argv.push(format!("__ARRNAME__{}", name));
        paired_argv.push(arr_payload);
        let _ = arr_marker; // unused; we use string sentinels instead
    }
    // Rewrite the script: simpler to just take pairs from sys.argv[1:]
    // until a sentinel, then handle the array.
    let script = r#"
import json, sys
argv = sys.argv[1:]
o = {}
i = 0
while i < len(argv):
    if argv[i].startswith('__ARRNAME__'):
        name = argv[i][len('__ARRNAME__'):]
        payload = argv[i+1]
        o[name] = payload.split('\x1f') if payload else []
        i += 2
    else:
        # Try numeric coercion for known int-y fields
        k, v = argv[i], argv[i+1]
        if k in ('pr', 'matched_keywords', 'total_keywords'):
            try:
                o[k] = int(v)
            except ValueError:
                o[k] = v
        else:
            o[k] = v
        i += 2
print(json.dumps(o))
"#;
    let out = std::process::Command::new("python3")
        .arg("-c")
        .arg(script)
        .args(paired_argv)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cog043_extract_keywords_basic() {
        let kw = extract_keywords("Use scripts/coord/bot-merge.sh as the canonical ship pipeline");
        // "as", "the" are stopwords; "use" is len 3 (< 4) → dropped
        // even though not in stoplist. "scripts", "coord", "merge",
        // "canonical", "ship", "pipeline" survive.
        assert!(kw.contains(&"scripts".to_string()));
        assert!(kw.contains(&"canonical".to_string()));
        assert!(kw.contains(&"pipeline".to_string()));
        assert!(!kw.contains(&"the".to_string()));
        assert!(!kw.contains(&"use".to_string())); // len 3
    }

    #[test]
    fn cog043_extract_keywords_drops_pure_numbers() {
        let kw = extract_keywords("INFRA-468 fixes 2026 bugs");
        assert!(kw.contains(&"infra".to_string()));
        assert!(!kw.contains(&"468".to_string()));
        assert!(!kw.contains(&"2026".to_string()));
        assert!(kw.contains(&"fixes".to_string()));
    }

    #[test]
    fn cog043_directive_applied_high_overlap() {
        let directive =
            "Always use scripts/coord/bot-merge.sh for shipping pull requests with auto-merge";
        let pr_text = "This PR runs scripts/coord/bot-merge.sh --gap INFRA-X --auto-merge to ship the change.";
        // Both share "scripts", "coord", "merge", "auto", "ship" etc.
        assert!(directive_applied(directive, pr_text));
    }

    #[test]
    fn cog043_directive_applied_low_overlap_rejects() {
        let directive = "Always use scripts/coord/bot-merge.sh for shipping pull requests";
        let pr_text = "This PR refactors the database connection pool implementation.";
        // Almost no shared distinctive tokens.
        assert!(!directive_applied(directive, pr_text));
    }

    #[test]
    fn cog043_score_directive_returns_zero_total_for_empty_directive() {
        let (m, t) = score_directive_against_pr("a the of", "anything");
        assert_eq!(m, 0);
        assert_eq!(t, 0);
    }

    #[test]
    fn cog043_emit_lessons_shown_writes_jsonl() {
        let tmp = tempdir();
        emit_lessons_shown(
            &tmp,
            "test-session",
            "INFRA-XXX",
            "semantic",
            &[
                "Always use bot-merge.sh".to_string(),
                "Reserve gap IDs via chump gap reserve".to_string(),
            ],
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl should exist");
        assert!(
            log.contains(r#""kind":"lessons_shown""#) || log.contains(r#""kind": "lessons_shown""#)
        );
        assert!(log.contains(r#""mode":"semantic""#) || log.contains(r#""mode": "semantic""#));
        assert!(log.contains("INFRA-XXX"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cog043_emit_lesson_grade_writes_jsonl() {
        let tmp = tempdir();
        emit_lesson_grade(
            &tmp,
            "test-session",
            "INFRA-YYY",
            999,
            "Use bot-merge.sh for shipping",
            true,
            3,
            5,
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient.jsonl should exist");
        assert!(
            log.contains(r#""kind":"lesson_applied""#)
                || log.contains(r#""kind": "lesson_applied""#)
        );
        assert!(
            log.contains(r#""matched_keywords":3"#) || log.contains(r#""matched_keywords": 3"#)
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-cog043-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
