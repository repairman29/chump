//! Review-as-Handoff (INFRA-768): ACL trust check for `[handoff:apply]` comments.
//!
//! Only trusted reviewers can issue a `[handoff:apply]` directive.  Three trust paths:
//!
//! 1. **Operator** — always trusted; identified by `CHUMP_OPERATOR_GITHUB_LOGIN` env var
//!    or config field `operator_github_login`.
//! 2. **Reviewer-role session** — an active (non-expired) lease in `.chump-locks/` that
//!    carries both `capabilities: ["reviewer"]` and a `github_login` matching the comment
//!    author.  Set by `chump review --serve` at session start.
//! 3. **Self-handoff** — the comment author is the same GitHub user who authored the PR.
//!    An agent diagnosing its own CI failure may issue a handoff to itself.
//!
//! Any comment from an untrusted source carrying `[handoff:apply]` is silently ignored.
//! Only the **earliest** trusted handoff comment after the last PR HEAD commit is acted on.
//! (INFRA-770, sub-gap 2/6 of Review-as-Handoff)

use std::path::Path;

// ── Comment parsing ───────────────────────────────────────────────────────────

/// A parsed `[handoff:apply]` comment from a PR.
#[derive(Debug, Clone, PartialEq)]
pub struct HandoffComment {
    /// GitHub username of the comment author.
    pub author: String,
    /// The raw `[handoff:apply]` body text.
    pub body: String,
    /// Optional `by=<id>` field from the annotation.
    pub reviewer_id: Option<String>,
    /// Optional `verified=<bool>` field from the annotation.
    pub verified: Option<bool>,
}

/// Parse a PR comment body and return a `HandoffComment` if it contains a valid
/// `[handoff:apply]` annotation, or `None` otherwise.
///
/// Expected annotation format (anywhere in the comment body):
/// ```text
/// [handoff:apply by=<id> verified=<bool>]
/// ```
/// All fields after `handoff:apply` are optional.
pub fn parse_handoff_comment(author: &str, body: &str) -> Option<HandoffComment> {
    // Locate the annotation — case-insensitive, optional trailing content.
    let lower = body.to_lowercase();
    let start = lower.find("[handoff:apply")?;
    let end = body[start..].find(']').map(|e| start + e + 1)?;
    let annotation = &body[start..end];

    let reviewer_id = extract_annotation_field(annotation, "by");
    let verified =
        extract_annotation_field(annotation, "verified").and_then(|v| v.parse::<bool>().ok());

    Some(HandoffComment {
        author: author.to_string(),
        body: body.to_string(),
        reviewer_id,
        verified,
    })
}

fn extract_annotation_field(annotation: &str, key: &str) -> Option<String> {
    let pat = format!("{key}=");
    let start = annotation.find(&pat)? + pat.len();
    let rest = &annotation[start..];
    // Value ends at next space, ']', or end of string.
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ']')
        .unwrap_or(rest.len());
    let val = rest[..end].trim().trim_matches('"');
    if val.is_empty() {
        None
    } else {
        Some(val.to_string())
    }
}

// ── Trust context ─────────────────────────────────────────────────────────────

/// Context used by `is_trusted_handoff` to evaluate trust.
pub struct TrustContext<'a> {
    /// GitHub login of the PR author (always self-trusted).
    pub pr_author: &'a str,
    /// GitHub login of the operator (always trusted).
    pub operator_login: &'a str,
    /// Path to `.chump-locks/` directory for lease-based reviewer lookup.
    pub locks_dir: &'a Path,
}

impl<'a> TrustContext<'a> {
    /// Construct from environment: reads `CHUMP_OPERATOR_GITHUB_LOGIN` for operator_login.
    pub fn from_env(pr_author: &'a str, locks_dir: &'a Path) -> Self {
        let operator_login = Box::leak(
            std::env::var("CHUMP_OPERATOR_GITHUB_LOGIN")
                .unwrap_or_default()
                .into_boxed_str(),
        );
        TrustContext {
            pr_author,
            operator_login,
            locks_dir,
        }
    }
}

// ── Trust check ───────────────────────────────────────────────────────────────

/// Returns `true` if the `HandoffComment` was authored by a trusted reviewer.
///
/// Trust paths (evaluated in order):
/// 1. Operator: `comment.author == context.operator_login` (non-empty check).
/// 2. Reviewer lease: an active lease in `context.locks_dir/` has both
///    `capabilities: ["reviewer"]` and `github_login == comment.author`.
/// 3. Self-handoff: `comment.author == context.pr_author`.
pub fn is_trusted_handoff(comment: &HandoffComment, context: &TrustContext<'_>) -> bool {
    let author = comment.author.as_str();

    // Path 1: operator.
    if !context.operator_login.is_empty() && author == context.operator_login {
        return true;
    }

    // Path 2: reviewer-capability lease.
    if has_reviewer_lease(author, context.locks_dir) {
        return true;
    }

    // Path 3: self-handoff.
    author == context.pr_author
}

/// Check `.chump-locks/*.json` for an active (non-expired) lease that names `github_login`
/// and includes `"reviewer"` in its `capabilities` array.
fn has_reviewer_lease(github_login: &str, locks_dir: &Path) -> bool {
    let now_epoch = {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    };

    let entries = match std::fs::read_dir(locks_dir) {
        Ok(e) => e,
        Err(_) => return false,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if is_reviewer_lease_json(&content, github_login, now_epoch) {
            return true;
        }
    }
    false
}

/// Parse a lease JSON blob and return true if it is:
/// - Not expired (`expires_at` > now), AND
/// - Has `capabilities` containing `"reviewer"`, AND
/// - Has `github_login` matching the given login.
fn is_reviewer_lease_json(json: &str, github_login: &str, now_epoch: u64) -> bool {
    // Quick string scan before heavier parsing — skip most leases fast.
    if !json.contains("reviewer") || !json.contains(github_login) {
        return false;
    }

    // Check expiry: parse expires_at ISO-8601 field.
    let expires_at = match extract_json_string(json, "expires_at") {
        Some(v) => v,
        None => return false,
    };
    let expires_epoch = parse_iso8601_to_unix(&expires_at).unwrap_or(0);
    if expires_epoch <= now_epoch {
        return false;
    }

    // Check github_login field.
    let login = match extract_json_string(json, "github_login") {
        Some(v) => v,
        None => return false,
    };
    if login != github_login {
        return false;
    }

    // Check capabilities array contains "reviewer".
    json.contains(r#""reviewer""#)
}

/// Minimal JSON string field extractor — avoids a serde dependency here.
fn extract_json_string(json: &str, key: &str) -> Option<String> {
    let pat = format!(r#""{key}":"#);
    let start = json.find(&pat)? + pat.len();
    let rest = json[start..].trim_start();
    if !rest.starts_with('"') {
        return None;
    }
    let inner = &rest[1..];
    let end = inner.find('"')?;
    Some(inner[..end].to_string())
}

/// Parse an ISO-8601 UTC timestamp ("2026-05-11T17:10:28Z") to Unix seconds.
/// Returns `None` if the string is not parseable.
fn parse_iso8601_to_unix(ts: &str) -> Option<u64> {
    // Accepted format: YYYY-MM-DDTHH:MM:SSZ (UTC, no sub-seconds)
    let ts = ts.trim_end_matches('Z');
    let parts: Vec<&str> = ts.split('T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<u32> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<u32> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() != 3 || time_parts.len() != 3 {
        return None;
    }
    // Simple epoch computation (Gregorian calendar, UTC only).
    let (y, m, d) = (
        date_parts[0] as i64,
        date_parts[1] as i64,
        date_parts[2] as i64,
    );
    let (h, min, s) = (
        time_parts[0] as i64,
        time_parts[1] as i64,
        time_parts[2] as i64,
    );
    // Days from epoch (1970-01-01) to year-month-day.
    let days = days_from_epoch(y, m, d)?;
    Some((days * 86400 + h * 3600 + min * 60 + s) as u64)
}

fn days_from_epoch(y: i64, m: i64, d: i64) -> Option<i64> {
    // Convert y-m-d to Julian Day Number, then subtract JDN of 1970-01-01.
    // JDN formula: https://en.wikipedia.org/wiki/Julian_day#Converting_Gregorian_calendar_date_to_Julian_Day_Number
    let a = (14 - m) / 12;
    let yy = y + 4800 - a;
    let mm = m + 12 * a - 3;
    let jdn = d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045;
    let jdn_epoch = 2440588i64; // JDN of 1970-01-01
    Some(jdn - jdn_epoch)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ── parse_handoff_comment ─────────────────────────────────────────────────

    #[test]
    fn parse_bare_annotation() {
        let c = parse_handoff_comment("alice", "Some text\n[handoff:apply]\nMore text").unwrap();
        assert_eq!(c.author, "alice");
        assert_eq!(c.reviewer_id, None);
        assert_eq!(c.verified, None);
    }

    #[test]
    fn parse_annotation_with_by_and_verified() {
        let c = parse_handoff_comment(
            "bob",
            "[handoff:apply by=session-42 verified=true] — apply this diff",
        )
        .unwrap();
        assert_eq!(c.reviewer_id.as_deref(), Some("session-42"));
        assert_eq!(c.verified, Some(true));
    }

    #[test]
    fn parse_annotation_case_insensitive() {
        assert!(parse_handoff_comment("x", "[HANDOFF:APPLY]").is_some());
    }

    #[test]
    fn parse_returns_none_when_no_annotation() {
        assert!(parse_handoff_comment("alice", "Just a normal comment, no annotation").is_none());
    }

    #[test]
    fn parse_returns_none_when_annotation_unclosed() {
        assert!(parse_handoff_comment("alice", "[handoff:apply no closing bracket").is_none());
    }

    // ── is_trusted_handoff — operator path ───────────────────────────────────

    #[test]
    fn operator_is_always_trusted() {
        let tmp = TempDir::new().unwrap();
        let comment = HandoffComment {
            author: "operator-gh".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "someone-else",
            operator_login: "operator-gh",
            locks_dir: tmp.path(),
        };
        assert!(is_trusted_handoff(&comment, &ctx));
    }

    #[test]
    fn empty_operator_login_does_not_match() {
        let tmp = TempDir::new().unwrap();
        let comment = HandoffComment {
            author: "".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "",
            locks_dir: tmp.path(),
        };
        // Empty operator_login should not match any author (even empty string).
        assert!(!is_trusted_handoff(&comment, &ctx));
    }

    // ── is_trusted_handoff — self-handoff path ────────────────────────────────

    #[test]
    fn pr_author_self_handoff_trusted() {
        let tmp = TempDir::new().unwrap();
        let comment = HandoffComment {
            author: "alice".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(is_trusted_handoff(&comment, &ctx));
    }

    #[test]
    fn different_user_not_trusted_without_lease() {
        let tmp = TempDir::new().unwrap();
        let comment = HandoffComment {
            author: "mallory".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(!is_trusted_handoff(&comment, &ctx));
    }

    // ── is_trusted_handoff — reviewer lease path ──────────────────────────────

    fn write_lease(dir: &std::path::Path, filename: &str, content: &str) {
        fs::write(dir.join(filename), content).unwrap();
    }

    fn future_ts() -> String {
        "2099-12-31T23:59:59Z".to_string()
    }

    #[test]
    fn reviewer_lease_grants_trust() {
        let tmp = TempDir::new().unwrap();
        let expires = future_ts();
        write_lease(
            tmp.path(),
            "review-session.json",
            &format!(
                r#"{{"session_id":"review-session","github_login":"reviewer-bot","capabilities":["reviewer"],"expires_at":"{expires}"}}"#
            ),
        );
        let comment = HandoffComment {
            author: "reviewer-bot".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(is_trusted_handoff(&comment, &ctx));
    }

    #[test]
    fn expired_reviewer_lease_not_trusted() {
        let tmp = TempDir::new().unwrap();
        write_lease(
            tmp.path(),
            "old-session.json",
            r#"{"session_id":"old","github_login":"reviewer-bot","capabilities":["reviewer"],"expires_at":"2020-01-01T00:00:00Z"}"#,
        );
        let comment = HandoffComment {
            author: "reviewer-bot".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(!is_trusted_handoff(&comment, &ctx));
    }

    #[test]
    fn lease_without_reviewer_capability_not_trusted() {
        let tmp = TempDir::new().unwrap();
        let expires = future_ts();
        write_lease(
            tmp.path(),
            "worker-session.json",
            &format!(
                r#"{{"session_id":"worker","github_login":"worker-bot","capabilities":[],"expires_at":"{expires}"}}"#
            ),
        );
        let comment = HandoffComment {
            author: "worker-bot".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(!is_trusted_handoff(&comment, &ctx));
    }

    #[test]
    fn lease_wrong_github_login_not_trusted() {
        let tmp = TempDir::new().unwrap();
        let expires = future_ts();
        write_lease(
            tmp.path(),
            "reviewer-session.json",
            &format!(
                r#"{{"session_id":"rev","github_login":"other-reviewer","capabilities":["reviewer"],"expires_at":"{expires}"}}"#
            ),
        );
        let comment = HandoffComment {
            author: "mallory".to_string(),
            body: "[handoff:apply]".to_string(),
            reviewer_id: None,
            verified: None,
        };
        let ctx = TrustContext {
            pr_author: "alice",
            operator_login: "op",
            locks_dir: tmp.path(),
        };
        assert!(!is_trusted_handoff(&comment, &ctx));
    }

    // ── parse_iso8601_to_unix ────────────────────────────────────────────────

    #[test]
    fn epoch_parses_to_zero() {
        assert_eq!(parse_iso8601_to_unix("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn known_timestamp_parses_correctly() {
        // 2026-05-11T17:00:00Z → days from epoch
        let secs = parse_iso8601_to_unix("2026-05-11T17:00:00Z").unwrap();
        // Rough sanity: should be ~56 years * 365.25 days * 86400 ≈ 1.77e9
        assert!(secs > 1_700_000_000 && secs < 1_800_000_000);
    }

    #[test]
    fn malformed_timestamp_returns_none() {
        assert_eq!(parse_iso8601_to_unix("not-a-date"), None);
    }
}
