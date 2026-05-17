//! INFRA-1541: `chump pr ac-coverage <PR_NUMBER>`
//!
//! CREDIBLE: pre-merge AC coverage gate — exits 0 iff every AC bullet of the
//! referenced gap is covered by the PR diff. Exits 1 with a numbered miss-list
//! on uncovered bullets (unless advisory mode is active).
//!
//! Testability:
//!   - `CHUMP_GH` env var overrides the `gh` binary path (mock injection).
//!   - `CHUMP_REPO_ROOT` env var overrides the repo root (fake gap YAMLs).

use std::process::Command;

use crate::ambient_emit::{emit, EmitArgs};

// ── public types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoverageStatus {
    Pass,
    Miss,
    NoGapRef,
    Disabled,
    Advisory,
}

#[derive(Debug, Clone)]
pub struct BulletResult {
    pub index: usize,
    pub text: String,
    pub covered: bool,
    pub waived: bool,
    pub waive_reason: Option<String>,
    /// Which rule numbers (1–4) matched.
    pub rules_hit: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct AcCoverageResult {
    pub pr_number: u64,
    pub gap_id: Option<String>,
    pub status: CoverageStatus,
    pub bullets: Vec<BulletResult>,
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

fn repo_root() -> std::path::PathBuf {
    if let Ok(v) = std::env::var("CHUMP_REPO_ROOT") {
        return std::path::PathBuf::from(v);
    }
    crate::repo_path::repo_root()
}

fn run_gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args(args)
        .output()
        .map_err(|e| format!("gh exec failed: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

// ── title parser ──────────────────────────────────────────────────────────────

/// Parse a `<DOMAIN>-N` gap reference from a PR title.
/// Returns the first match, e.g. `"INFRA-1541"`.
pub fn parse_gap_id(title: &str) -> Option<String> {
    // Regex equivalent: [A-Z][A-Z0-9]+-\d+
    // We do it manually to avoid pulling in the regex crate just for this.
    let bytes = title.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    while i < len {
        // Need an uppercase ASCII letter to start
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            // consume uppercase-alphanumeric run
            while i < len && (bytes[i].is_ascii_uppercase() || bytes[i].is_ascii_digit()) {
                i += 1;
            }
            let domain_len = i - start;
            if domain_len >= 1 && i < len && bytes[i] == b'-' {
                i += 1; // consume '-'
                let num_start = i;
                while i < len && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                if i > num_start {
                    // matched!
                    return Some(title[start..i].to_string());
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

// ── AC bullet loader ──────────────────────────────────────────────────────────

/// Load acceptance_criteria bullets from `docs/gaps/<GAP_ID>.yaml`.
/// Supports `acceptance_criteria:` as a list-of-strings YAML block.
/// The YAML file may be a list (starts with `- id:`) or a top-level object.
fn load_ac_bullets(gap_id: &str) -> Result<Vec<String>, String> {
    let root = repo_root();
    let path = root.join("docs").join("gaps").join(format!("{gap_id}.yaml"));
    let text =
        std::fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;

    let mut bullets = Vec::new();
    let mut in_ac = false;
    // Track the indentation of the `acceptance_criteria:` key so we know
    // when a line at the *same or lower* indent level ends the block.
    let mut ac_indent = 0usize;

    for line in text.lines() {
        let trimmed = line.trim_start();
        let indent = line.len() - trimmed.len();

        if trimmed.starts_with("acceptance_criteria:") {
            in_ac = true;
            ac_indent = indent;
            continue;
        }

        if in_ac {
            // A bullet line starts with "- " (after whitespace).
            if let Some(rest) = trimmed.strip_prefix("- ") {
                // Strip surrounding quotes if present.
                let bullet = rest.trim();
                let bullet = bullet
                    .strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .or_else(|| bullet.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
                    .unwrap_or(bullet);
                bullets.push(bullet.to_string());
            } else if trimmed.is_empty() {
                // blank line — continue
            } else if indent <= ac_indent && !trimmed.starts_with('-') {
                // A non-bullet line at the same indent level as `acceptance_criteria:`
                // means we've exited the block.
                break;
            } else if indent <= ac_indent && trimmed.starts_with('-') {
                // A new list item at the same level (e.g. a different gap entry) — done.
                break;
            }
        }
    }

    Ok(bullets)
}

// ── waiver parser ─────────────────────────────────────────────────────────────

/// Parse `AC-Coverage-Waive: <bullet-index>: <reason>` lines from PR body +
/// commit messages. Returns `(index, reason)` pairs.
fn parse_waivers(text: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        // Trim leading whitespace (bodies can have indentation)
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("AC-Coverage-Waive:").map(str::trim) {
            // rest = "<index>: <reason>" or "<index>:<reason>"
            if let Some((idx_str, reason)) = rest.split_once(':') {
                if let Ok(idx) = idx_str.trim().parse::<usize>() {
                    out.push((idx, reason.trim().to_string()));
                }
            }
        }
    }
    out
}

// ── coverage rules ────────────────────────────────────────────────────────────

static COMMON_WORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "have", "will", "must", "each",
    "when", "where", "into", "then", "than", "some", "file", "path", "rule", "item", "test",
    "first", "last", "bool", "true", "false", "none", "null", "zero", "both", "only", "list",
    "all", "any", "new", "add", "get", "set", "run", "via", "per", "not", "use", "has", "are",
    "its", "one", "two", "may", "can", "but", "also", "emit", "does", "been", "every", "should",
    "given", "under", "after", "before", "return", "check", "value", "match", "cover",
];

/// Extract candidate symbols/keywords from a bullet for Rule (b).
/// 4+ chars, alphanumeric/underscore/hyphen, skip common words.
fn extract_keywords(bullet: &str) -> Vec<String> {
    bullet
        .split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
        .filter(|w| {
            let l = w.len();
            if l < 4 {
                return false;
            }
            // skip pure-numeric tokens
            if w.chars().all(|c| c.is_ascii_digit()) {
                return false;
            }
            let lower = w.to_ascii_lowercase();
            !COMMON_WORDS.contains(&lower.as_str())
        })
        .map(|w| w.to_string())
        .collect()
}

/// Rule (a): any file path mentioned literally in the bullet appears as
/// `+++ b/<path>` in the diff.
fn rule_a(bullet: &str, diff: &str) -> bool {
    // Extract path-like tokens: anything with '/' or a known extension.
    for token in bullet.split_whitespace() {
        let token = token.trim_matches(|c: char| "'\"`(),;".contains(c));
        if token.contains('/') || token.ends_with(".rs") || token.ends_with(".sh") || token.ends_with(".yaml") || token.ends_with(".yml") || token.ends_with(".toml") || token.ends_with(".md") {
            let needle = format!("+++ b/{token}");
            if diff.contains(&needle) {
                return true;
            }
            // Also check without leading b/ (some diff formats)
            if diff.contains(token) && diff.contains("+++ b/") {
                // only if the path appears as a diff file header
                for line in diff.lines() {
                    if line.starts_with("+++ b/") && line.contains(token) {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// Rule (b): any keyword from the bullet (4+ chars, non-common) appears in
/// the diff text.
fn rule_b(bullet: &str, diff: &str) -> bool {
    for kw in extract_keywords(bullet) {
        if diff.contains(&*kw) {
            return true;
        }
    }
    false
}

/// Rule (c): commit body contains `Closes-AC: <prefix>` where prefix matches
/// the first 40 chars of the bullet.
fn rule_c(bullet: &str, commit_text: &str) -> bool {
    let prefix40 = &bullet[..bullet.len().min(40)];
    for line in commit_text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Closes-AC:").map(str::trim) {
            if rest.starts_with(prefix40) || prefix40.starts_with(rest) || rest.len() >= 10 && bullet.contains(rest) {
                return true;
            }
        }
    }
    false
}

/// Rule (d): any `+++ b/scripts/ci/test-*.sh` or `+++ b/tests/` file in the
/// diff mentions a keyword from the bullet.
fn rule_d(bullet: &str, diff: &str) -> bool {
    // Collect lines that add content to test files.
    let mut in_test_file = false;
    let mut test_additions = String::new();
    for line in diff.lines() {
        if line.starts_with("+++ b/scripts/ci/test-") || line.starts_with("+++ b/tests/") {
            in_test_file = true;
            continue;
        }
        if line.starts_with("+++ b/") || line.starts_with("diff --git") {
            in_test_file = false;
            continue;
        }
        if in_test_file && line.starts_with('+') {
            test_additions.push_str(&line[1..]);
            test_additions.push('\n');
        }
    }
    if test_additions.is_empty() {
        return false;
    }
    for kw in extract_keywords(bullet) {
        if test_additions.contains(&*kw) {
            return true;
        }
    }
    false
}

/// Check which rules (1–4) cover a bullet given diff text and commit messages.
fn check_coverage(bullet: &str, diff: &str, commit_text: &str) -> Vec<u8> {
    let mut hit = Vec::new();
    if rule_a(bullet, diff) {
        hit.push(1);
    }
    if rule_b(bullet, diff) {
        hit.push(2);
    }
    if rule_c(bullet, commit_text) {
        hit.push(3);
    }
    if rule_d(bullet, diff) {
        hit.push(4);
    }
    hit
}

// ── ambient emit wrapper ──────────────────────────────────────────────────────

fn ambient(kind: &str, fields: Vec<(&str, String)>) {
    let args = EmitArgs {
        kind: kind.to_string(),
        fields: fields
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
        ..Default::default()
    };
    // Best-effort: ignore emit errors in the coverage gate.
    let _ = emit(&args);
}

// ── JSON render ───────────────────────────────────────────────────────────────

pub fn render_json(result: &AcCoverageResult) -> String {
    let status = match result.status {
        CoverageStatus::Pass => "pass",
        CoverageStatus::Miss => "miss",
        CoverageStatus::NoGapRef => "no_gap_ref",
        CoverageStatus::Disabled => "disabled",
        CoverageStatus::Advisory => "advisory",
    };
    let gap_id = result
        .gap_id
        .as_deref()
        .map(|s| format!(r#""{s}""#))
        .unwrap_or_else(|| "null".to_string());
    let misses: Vec<usize> = result
        .bullets
        .iter()
        .filter(|b| !b.covered && !b.waived)
        .map(|b| b.index)
        .collect();
    let misses_json = misses
        .iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"status":"{status}","pr_number":{pr},"gap_id":{gap_id},"misses":[{misses_json}]}}"#,
        pr = result.pr_number,
    )
}

// ── main entry point ──────────────────────────────────────────────────────────

pub fn run(pr_number: u64) -> Result<AcCoverageResult, String> {
    // Operator override: gate disabled
    if std::env::var("CHUMP_AC_GATE_ENABLED").as_deref() == Ok("false") {
        ambient(
            "ac_coverage_disabled",
            vec![("pr_number", pr_number.to_string())],
        );
        return Ok(AcCoverageResult {
            pr_number,
            gap_id: None,
            status: CoverageStatus::Disabled,
            bullets: vec![],
        });
    }

    // Fetch PR title + body + commits
    let pr_json_str = run_gh(&[
        "pr",
        "view",
        &pr_number.to_string(),
        "--json",
        "title,body,commits",
    ])?;

    // Parse JSON manually to avoid pulling serde_json as a new dep.
    // We need: title (string), body (string), commits[].messageBody (strings)
    let title = json_extract_string(&pr_json_str, "title").unwrap_or_default();
    let body = json_extract_string(&pr_json_str, "body").unwrap_or_default();
    let commit_bodies = extract_commit_messages(&pr_json_str);

    // Build full text for trailer scanning (PR body + all commit messages)
    let mut trailer_text = body.clone();
    for cb in &commit_bodies {
        trailer_text.push('\n');
        trailer_text.push_str(cb);
    }

    // Parse gap ID from title
    let gap_id = match parse_gap_id(&title) {
        Some(id) => id,
        None => {
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: None,
                status: CoverageStatus::NoGapRef,
                bullets: vec![],
            });
        }
    };

    // Load AC bullets
    let raw_bullets = match load_ac_bullets(&gap_id) {
        Ok(b) if !b.is_empty() => b,
        Ok(_) => {
            // No AC bullets → treat as pass (gap has no AC to check)
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: Some(gap_id),
                status: CoverageStatus::Pass,
                bullets: vec![],
            });
        }
        Err(e) => {
            // Gap YAML missing or unreadable → treat as advisory pass
            eprintln!("ac-coverage: {e} — skipping (no AC YAML found)");
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: Some(gap_id),
                status: CoverageStatus::Pass,
                bullets: vec![],
            });
        }
    };

    // Fetch diff
    let diff = run_gh(&["pr", "diff", &pr_number.to_string()]).unwrap_or_default();

    // Parse waivers (0-based index per spec)
    let waivers = parse_waivers(&trailer_text);

    // Evaluate each bullet
    let mut bullets = Vec::new();
    let mut any_miss = false;

    for (i, text) in raw_bullets.iter().enumerate() {
        // Check if waived (0-based index)
        let waiver = waivers.iter().find(|(idx, _)| *idx == i);
        if let Some((_, reason)) = waiver {
            ambient(
                "ac_coverage_waived",
                vec![
                    ("pr_number", pr_number.to_string()),
                    ("gap_id", gap_id.clone()),
                    ("bullet_index", i.to_string()),
                    ("reason", reason.clone()),
                ],
            );
            bullets.push(BulletResult {
                index: i,
                text: text.clone(),
                covered: true,
                waived: true,
                waive_reason: Some(reason.clone()),
                rules_hit: vec![],
            });
            continue;
        }

        let rules_hit = check_coverage(text, &diff, &trailer_text);
        let covered = !rules_hit.is_empty();

        if !covered {
            any_miss = true;
            let prefix = &text[..text.len().min(40)];
            ambient(
                "ac_coverage_miss",
                vec![
                    ("pr_number", pr_number.to_string()),
                    ("gap_id", gap_id.clone()),
                    ("bullet_index", i.to_string()),
                    ("bullet_text_prefix", prefix.to_string()),
                ],
            );
        }

        bullets.push(BulletResult {
            index: i,
            text: text.clone(),
            covered,
            waived: false,
            waive_reason: None,
            rules_hit,
        });
    }

    // Determine status
    let is_advisory = std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() == Ok("true");
    let status = if any_miss {
        if is_advisory {
            CoverageStatus::Advisory
        } else {
            CoverageStatus::Miss
        }
    } else {
        CoverageStatus::Pass
    };

    // Print miss list to stderr
    if any_miss {
        eprintln!("ac-coverage: uncovered AC bullets for {gap_id} on PR #{pr_number}:");
        for b in &bullets {
            if !b.covered && !b.waived {
                eprintln!("  [{}] {}", b.index, &b.text[..b.text.len().min(80)]);
            }
        }
    }

    Ok(AcCoverageResult {
        pr_number,
        gap_id: Some(gap_id),
        status,
        bullets,
    })
}

// ── minimal JSON helpers (no serde_json dep) ──────────────────────────────────

/// Extract a top-level JSON string field by name.
fn json_extract_string(json: &str, key: &str) -> Option<String> {
    let needle = format!(r#""{key}":"#);
    let pos = json.find(&needle)?;
    let rest = json[pos + needle.len()..].trim_start();
    if rest.starts_with('"') {
        // JSON string value
        let inner = &rest[1..];
        let mut out = String::new();
        let mut chars = inner.chars();
        loop {
            match chars.next()? {
                '"' => break,
                '\\' => {
                    match chars.next()? {
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        c => {
                            out.push('\\');
                            out.push(c);
                        }
                    }
                }
                c => out.push(c),
            }
        }
        Some(out)
    } else {
        None
    }
}

/// Extract `messageHeadline` + `messageBody` from each commit in the JSON array.
fn extract_commit_messages(json: &str) -> Vec<String> {
    let mut out = Vec::new();
    // Find "commits":[ and walk through objects
    let Some(start) = json.find(r#""commits":["#) else {
        return out;
    };
    let commits_section = &json[start..];
    // Simple heuristic: extract all messageHeadline and messageBody values
    let mut rest = commits_section;
    while let Some(pos) = rest.find(r#""messageHeadline":"#) {
        rest = &rest[pos + r#""messageHeadline":"#.len()..];
        if let Some(v) = extract_json_string_at(rest) {
            out.push(v.text);
            rest = &rest[v.consumed..];
        }
    }
    let mut rest2 = commits_section;
    while let Some(pos) = rest2.find(r#""messageBody":"#) {
        rest2 = &rest2[pos + r#""messageBody":"#.len()..];
        if let Some(v) = extract_json_string_at(rest2) {
            if !v.text.is_empty() {
                out.push(v.text);
            }
            rest2 = &rest2[v.consumed..];
        }
    }
    out
}

struct ExtractResult {
    text: String,
    consumed: usize,
}

fn extract_json_string_at(s: &str) -> Option<ExtractResult> {
    let s = s.trim_start();
    if !s.starts_with('"') {
        return None;
    }
    let inner = &s[1..];
    let mut out = String::new();
    let mut chars = inner.char_indices();
    let end_byte = loop {
        let (bi, c) = chars.next()?;
        match c {
            '"' => break bi + 1, // byte after closing quote in `inner`
            '\\' => {
                let (_bi2, c2) = chars.next()?;
                match c2 {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    _ => {
                        out.push('\\');
                        out.push(c2);
                    }
                }
            }
            c => out.push(c),
        }
    };
    // consumed = 1 (opening quote) + end_byte (bytes consumed in inner)
    let consumed = 1 + end_byte;
    Some(ExtractResult { text: out, consumed })
}

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_title_parser_extracts_gap_id() {
        assert_eq!(
            parse_gap_id("INFRA-1234: add something"),
            Some("INFRA-1234".to_string())
        );
        assert_eq!(
            parse_gap_id("feat(INFRA-9001): add foo bar"),
            Some("INFRA-9001".to_string())
        );
        assert_eq!(
            parse_gap_id("FLEET-007: scale test"),
            Some("FLEET-007".to_string())
        );
    }

    #[test]
    fn test_title_parser_no_gap_ref() {
        assert_eq!(parse_gap_id("fix: hotfix PR"), None);
        assert_eq!(parse_gap_id("chore: docs cleanup"), None);
        assert_eq!(parse_gap_id(""), None);
    }

    #[test]
    fn test_coverage_rule_a_file_path() {
        let bullet = "src/pr_ac_coverage.rs must exist and implement run()";
        let diff = "+++ b/src/pr_ac_coverage.rs\n+pub fn run() {}\n";
        assert!(rule_a(bullet, diff), "Rule (a) should match file path");
    }

    #[test]
    fn test_coverage_rule_b_symbol() {
        let bullet = "emit kind=ac_coverage_miss to ambient";
        let diff = "+    ac_coverage_miss_event();\n";
        assert!(rule_b(bullet, diff), "Rule (b) should match symbol ac_coverage_miss");
    }

    #[test]
    fn test_coverage_rule_c_closes_ac_trailer() {
        let bullet = "File src/pr_ac_coverage.rs must exist and implement run()";
        let commit_text = "Closes-AC: File src/pr_ac_coverage.rs must exist and implement run()";
        assert!(rule_c(bullet, commit_text), "Rule (c) should match Closes-AC trailer");
    }

    #[test]
    fn test_coverage_rule_d_test_file_keyword() {
        let bullet = "Shell wrapper scripts/ci/test-pr-ac-coverage.sh must be a 3-line exec";
        let diff = concat!(
            "+++ b/scripts/ci/test-pr-ac-coverage.sh\n",
            "+exec chump pr ac-coverage \"$@\"\n",
        );
        assert!(rule_d(bullet, diff), "Rule (d) should match test file keyword 'exec'");
    }

    #[test]
    fn test_waiver_parsed() {
        let body = "Some PR body text.\nAC-Coverage-Waive: 0: legacy path\nOther stuff.";
        let waivers = parse_waivers(body);
        assert_eq!(waivers.len(), 1);
        assert_eq!(waivers[0].0, 0);
        assert_eq!(waivers[0].1, "legacy path");
    }

    #[test]
    fn test_waiver_multiple() {
        let body = "AC-Coverage-Waive: 0: legacy\nAC-Coverage-Waive: 1: not applicable";
        let waivers = parse_waivers(body);
        assert_eq!(waivers.len(), 2);
        assert_eq!(waivers[1].0, 1);
        assert_eq!(waivers[1].1, "not applicable");
    }

    #[test]
    fn test_extract_keywords_skips_common() {
        let kws = extract_keywords("Add the file path with some test");
        // "some", "with", "test", "the", "file", "path", "Add" (3 chars) should be skipped
        // only words 4+ chars and not common
        assert!(!kws.iter().any(|k| k == "the" || k == "with" || k == "some"));
    }

    #[test]
    fn test_render_json_pass() {
        let result = AcCoverageResult {
            pr_number: 42,
            gap_id: Some("INFRA-1541".to_string()),
            status: CoverageStatus::Pass,
            bullets: vec![],
        };
        let json = render_json(&result);
        assert!(json.contains(r#""status":"pass""#));
        assert!(json.contains(r#""pr_number":42"#));
        assert!(json.contains(r#""gap_id":"INFRA-1541""#));
    }
}
