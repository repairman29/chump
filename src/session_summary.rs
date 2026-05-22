//! INFRA-1437: `chump session-summary` — list merged + armed + filed PRs in
//! the current session window.
//!
//! Surfaced 2026-05-15/16: PM-curator + operator had to manually scrape
//! ambient.jsonl + `gh pr list` + `chump gap list` to compile the per-session
//! summary that gets reported back. ~5 min of manual work at every session
//! end. This subcommand collapses that into one call.
//!
//! Pipeline (shells out to `gh`):
//!
//!   1. Resolve the session start (default: now - 24h; --since=ISO8601 to
//!      override; --window=<dur> for a rolling lookback like 4h, 2d).
//!   2. `gh pr list --author @me --state merged --search "merged:>=<since>"`
//!      → "Merged" section.
//!   3. `gh pr list --author @me --state open --json …` → "Armed" if the PR
//!      has auto-merge enabled, else "Filed".
//!   4. Render plain table by default; `--format json` for machine-readable.
//!
//! Output contract (consumed by the smoke test):
//!
//! ```text
//! Session: <since> (window <dur>)
//! Merged:
//!   #2317 INFRA-1475 feat(...)
//!   ...
//! Armed (auto-merge pending CI):
//!   #2327 INFRA-1656 feat(...)
//! Filed (PR opened, not yet merged):
//!   #2330 INFRA-1700 feat(...)
//! ```
//!
//! Override hook for tests: `CHUMP_SESSION_SUMMARY_GH_STUB=/path/to/script`
//! replaces the `gh` invocation entirely (the stub receives the same argv
//! and prints JSON to stdout). The PATH-shim CI test uses this to avoid
//! relying on PATH resolution order.

use std::process::Command;

/// One PR row as it appears in any of the three sections.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrRow {
    pub number: u64,
    pub title: String,
    /// Extracted gap id (e.g. `INFRA-1437`). Empty if no `<DOMAIN>-<N>` token
    /// in the title.
    pub gap_id: String,
    /// Auto-merge enabled? Only consulted for open PRs.
    pub auto_merge: bool,
}

/// Output format selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Text,
    Json,
}

/// Parsed CLI args for `chump session-summary`.
#[derive(Debug, Clone)]
pub struct Args {
    /// ISO8601-ish "since" timestamp passed to gh's `merged:>=` filter.
    /// Defaults to "now - window" if --since is not set.
    pub since: Option<String>,
    /// Window expression like `24h`, `4h`, `2d`. Default `24h`.
    pub window: String,
    pub format: OutputFormat,
    pub help: bool,
}

impl Default for Args {
    fn default() -> Self {
        Args {
            since: None,
            window: "24h".to_string(),
            format: OutputFormat::Text,
            help: false,
        }
    }
}

/// Parse argv (post-`session-summary`) into `Args`. Returns Err on bad flags.
pub fn parse_args(argv: &[String]) -> Result<Args, String> {
    let mut a = Args::default();
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        match arg.as_str() {
            "-h" | "--help" => {
                a.help = true;
            }
            "--json" => {
                a.format = OutputFormat::Json;
            }
            "--format" => {
                i += 1;
                let v = argv
                    .get(i)
                    .ok_or_else(|| "--format requires a value".to_string())?;
                a.format = match v.as_str() {
                    "text" => OutputFormat::Text,
                    "json" => OutputFormat::Json,
                    other => return Err(format!("--format: unknown value '{}'", other)),
                };
            }
            "--since" => {
                i += 1;
                let v = argv
                    .get(i)
                    .ok_or_else(|| "--since requires a value".to_string())?;
                a.since = Some(v.clone());
            }
            "--window" => {
                i += 1;
                let v = argv
                    .get(i)
                    .ok_or_else(|| "--window requires a value".to_string())?;
                a.window = v.clone();
            }
            other if other.starts_with("--format=") => {
                let v = &other["--format=".len()..];
                a.format = match v {
                    "text" => OutputFormat::Text,
                    "json" => OutputFormat::Json,
                    o => return Err(format!("--format: unknown value '{}'", o)),
                };
            }
            other if other.starts_with("--since=") => {
                a.since = Some(other["--since=".len()..].to_string());
            }
            other if other.starts_with("--window=") => {
                a.window = other["--window=".len()..].to_string();
            }
            other => {
                return Err(format!("unknown argument: {}", other));
            }
        }
        i += 1;
    }
    Ok(a)
}

/// Print the help banner to stdout.
pub fn print_help() {
    print!(
        "chump session-summary — list merged + armed + filed PRs in current session window\n\
         \n\
         Usage:\n\
           chump session-summary [--window <dur>] [--since <ts>] [--json|--format json]\n\
         \n\
         Flags:\n\
           --window <dur>     Rolling lookback (24h, 4h, 2d). Default 24h.\n\
           --since <ts>       Explicit ISO8601 cutoff. Overrides --window.\n\
           --format text|json Output format (default text).\n\
           --json             Shorthand for --format json.\n\
           -h, --help         This help.\n\
         \n\
         Environment overrides (testing):\n\
           CHUMP_SESSION_SUMMARY_GH_STUB=<path>   Replace `gh` with the script at <path>.\n"
    );
}

/// Compute the `since` value (`merged:>=<since>`) from the args. When
/// `args.since` is set, returns it verbatim. Otherwise renders a GitHub
/// search expression like `2026-05-21` (UTC date) based on the window.
///
/// We use a coarse-grained "N days ago" date — gh's search API treats
/// `merged:>=YYYY-MM-DD` as midnight UTC of that day, which is exactly what
/// we want for a 24h-style window. Sub-day windows widen to "today".
pub fn resolve_since(args: &Args, now_unix: i64) -> String {
    if let Some(s) = &args.since {
        return s.clone();
    }
    let seconds = parse_window_to_seconds(&args.window).unwrap_or(24 * 3600);
    let cutoff_unix = now_unix - seconds;
    unix_to_iso_date(cutoff_unix)
}

/// Parse "24h" / "4h" / "2d" / "30m" into seconds. Returns None on bad input.
pub fn parse_window_to_seconds(window: &str) -> Option<i64> {
    if window.is_empty() {
        return None;
    }
    let (num_part, unit) = window.split_at(window.len() - 1);
    let n: i64 = num_part.parse().ok()?;
    let multiplier = match unit {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86_400,
        _ => return None,
    };
    Some(n * multiplier)
}

/// Convert a unix timestamp to a `YYYY-MM-DD` UTC date string. Hand-rolled
/// so we don't drag chrono into this module — INFRA-1437 is small.
fn unix_to_iso_date(unix: i64) -> String {
    // Days since 1970-01-01 (UTC). Negative inputs floor toward -∞.
    let days = if unix >= 0 {
        unix / 86_400
    } else {
        // round toward negative infinity
        -((-unix + 86_399) / 86_400)
    };
    // Civil-from-days algorithm (Howard Hinnant, public domain).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02}", y, m, d)
}

/// Extract a gap id (e.g. `INFRA-1437`) from a PR title. Returns empty
/// string if no `<DOMAIN>-<NUMBER>` token appears.
pub fn extract_gap_id(title: &str) -> String {
    // We accept any uppercase alphabetic stretch followed by '-' and digits,
    // possibly nested in parens. Matches what reviewers actually write.
    let bytes = title.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_uppercase() {
                i += 1;
            }
            // Need at least 2 letters to avoid matching `A-1` style noise.
            if i - start >= 2 && i < bytes.len() && bytes[i] == b'-' {
                let dash = i;
                i += 1;
                let digit_start = i;
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                if i > digit_start {
                    return title[start..i].to_string();
                }
                // back up; the dash wasn't followed by digits
                i = dash + 1;
            }
        } else {
            i += 1;
        }
    }
    String::new()
}

/// Decide which section an open PR belongs to.
pub fn classify_open(row: &PrRow) -> OpenSection {
    if row.auto_merge {
        OpenSection::Armed
    } else {
        OpenSection::Filed
    }
}

/// Section label for an open PR (merged PRs always go to Merged).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenSection {
    Armed,
    Filed,
}

/// Render the full summary in text form. Pure function — fed by callers
/// that bring their own row data (real gh output in `run`, synthetic data
/// in unit tests).
pub fn render_text(since: &str, window: &str, merged: &[PrRow], open: &[PrRow]) -> String {
    let mut out = String::new();
    out.push_str(&format!("Session: {} (window {})\n", since, window));

    out.push_str("Merged:\n");
    if merged.is_empty() {
        out.push_str("  (none)\n");
    } else {
        for r in merged {
            push_row(&mut out, r);
        }
    }

    let armed: Vec<&PrRow> = open
        .iter()
        .filter(|r| classify_open(r) == OpenSection::Armed)
        .collect();
    let filed: Vec<&PrRow> = open
        .iter()
        .filter(|r| classify_open(r) == OpenSection::Filed)
        .collect();

    out.push_str("Armed (auto-merge pending CI):\n");
    if armed.is_empty() {
        out.push_str("  (none)\n");
    } else {
        for r in &armed {
            push_row(&mut out, r);
        }
    }

    out.push_str("Filed (PR opened, not yet merged):\n");
    if filed.is_empty() {
        out.push_str("  (none)\n");
    } else {
        for r in &filed {
            push_row(&mut out, r);
        }
    }
    out
}

fn push_row(out: &mut String, r: &PrRow) {
    if r.gap_id.is_empty() {
        out.push_str(&format!("  #{} {}\n", r.number, r.title));
    } else {
        // Strip the gap id from the title if present at the front to avoid
        // duplication; otherwise just print both.
        let trimmed = r.title.strip_prefix(&r.gap_id).unwrap_or(&r.title);
        let trimmed = trimmed.trim_start_matches(['(', ')', ':', ' ']);
        out.push_str(&format!("  #{} {} {}\n", r.number, r.gap_id, trimmed));
    }
}

/// JSON output for machine consumption. Hand-rolled (no serde dep churn).
pub fn render_json(since: &str, window: &str, merged: &[PrRow], open: &[PrRow]) -> String {
    let armed: Vec<&PrRow> = open.iter().filter(|r| r.auto_merge).collect();
    let filed: Vec<&PrRow> = open.iter().filter(|r| !r.auto_merge).collect();
    let mut s = String::new();
    s.push('{');
    s.push_str(&format!("\"since\":{},", json_str(since)));
    s.push_str(&format!("\"window\":{},", json_str(window)));
    s.push_str("\"merged\":");
    push_rows_json(&mut s, merged.iter());
    s.push_str(",\"armed\":");
    push_rows_json(&mut s, armed.into_iter());
    s.push_str(",\"filed\":");
    push_rows_json(&mut s, filed.into_iter());
    s.push('}');
    s.push('\n');
    s
}

fn push_rows_json<'a, I: Iterator<Item = &'a PrRow>>(out: &mut String, iter: I) {
    out.push('[');
    let mut first = true;
    for r in iter {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(&format!(
            "{{\"number\":{},\"title\":{},\"gap_id\":{},\"auto_merge\":{}}}",
            r.number,
            json_str(&r.title),
            json_str(&r.gap_id),
            r.auto_merge
        ));
    }
    out.push(']');
}

fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Run a `gh` command (or the stub override) and capture stdout.
fn run_gh(args: &[&str]) -> Result<String, String> {
    let stub = std::env::var("CHUMP_SESSION_SUMMARY_GH_STUB").ok();
    let (program, gh_args): (String, Vec<String>) = if let Some(p) = stub {
        (p, args.iter().map(|s| s.to_string()).collect())
    } else {
        (
            "gh".to_string(),
            args.iter().map(|s| s.to_string()).collect(),
        )
    };
    let out = Command::new(&program)
        .args(&gh_args)
        .output()
        .map_err(|e| format!("failed to spawn {}: {}", program, e))?;
    if !out.status.success() {
        return Err(format!(
            "{} {:?} exited {}: {}",
            program,
            gh_args,
            out.status,
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Parse `gh pr list --json number,title[,autoMergeRequest]` output into rows.
pub fn parse_gh_json(blob: &str, expect_auto_merge: bool) -> Result<Vec<PrRow>, String> {
    let blob = blob.trim();
    if blob.is_empty() || blob == "[]" {
        return Ok(Vec::new());
    }
    // Minimal hand parser — we know gh's shape exactly. Splits on `},{` after
    // trimming the outer `[` and `]`.
    let inner = blob
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .ok_or_else(|| format!("expected JSON array, got: {}", &blob[..blob.len().min(80)]))?
        .trim();
    if inner.is_empty() {
        return Ok(Vec::new());
    }
    let mut rows = Vec::new();
    for obj in split_top_level_objects(inner) {
        let number = extract_json_number(&obj, "number")
            .ok_or_else(|| format!("missing 'number' in {}", obj))?;
        let title = extract_json_string(&obj, "title")
            .ok_or_else(|| format!("missing 'title' in {}", obj))?;
        let auto_merge = if expect_auto_merge {
            // gh emits "autoMergeRequest": null when off, or an object when on.
            extract_json_field_raw(&obj, "autoMergeRequest")
                .map(|v| !v.trim().is_empty() && v.trim() != "null")
                .unwrap_or(false)
        } else {
            false
        };
        let gap_id = extract_gap_id(&title);
        rows.push(PrRow {
            number,
            title,
            gap_id,
            auto_merge,
        });
    }
    Ok(rows)
}

/// Split the comma-delimited list of top-level `{...}` objects inside the
/// outer JSON array, respecting nested braces and strings.
fn split_top_level_objects(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0;
    let mut start = None;
    let mut in_str = false;
    let mut escape = false;
    for (i, c) in s.char_indices() {
        if in_str {
            if escape {
                escape = false;
            } else if c == '\\' {
                escape = true;
            } else if c == '"' {
                in_str = false;
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '{' => {
                if depth == 0 {
                    start = Some(i);
                }
                depth += 1;
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    if let Some(st) = start.take() {
                        out.push(s[st..=i].to_string());
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn extract_json_number(obj: &str, key: &str) -> Option<u64> {
    let raw = extract_json_field_raw(obj, key)?;
    raw.trim().parse().ok()
}

fn extract_json_string(obj: &str, key: &str) -> Option<String> {
    let raw = extract_json_field_raw(obj, key)?;
    let raw = raw.trim();
    let raw = raw.strip_prefix('"')?.strip_suffix('"')?;
    // Minimal unescape — gh JSON strings only use \", \\, and \n in practice.
    let mut out = String::with_capacity(raw.len());
    let mut esc = false;
    for c in raw.chars() {
        if esc {
            match c {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                c => out.push(c),
            }
            esc = false;
        } else if c == '\\' {
            esc = true;
        } else {
            out.push(c);
        }
    }
    Some(out)
}

/// Return the raw value text for `"key": <value>` inside `obj`. The caller
/// is responsible for parsing it. Handles strings, numbers, null, and
/// nested objects (returns the matched-brace span).
fn extract_json_field_raw(obj: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\"", key);
    let mut i = obj.find(&needle)?;
    i += needle.len();
    // skip whitespace + colon
    let bytes = obj.as_bytes();
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    if i >= bytes.len() || bytes[i] != b':' {
        return None;
    }
    i += 1;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    if i >= bytes.len() {
        return None;
    }
    let start = i;
    match bytes[i] {
        b'"' => {
            // string — scan to closing quote, honoring escapes
            i += 1;
            let mut esc = false;
            while i < bytes.len() {
                let c = bytes[i];
                if esc {
                    esc = false;
                } else if c == b'\\' {
                    esc = true;
                } else if c == b'"' {
                    return Some(obj[start..=i].to_string());
                }
                i += 1;
            }
            None
        }
        b'{' => {
            // nested object — match braces
            let mut depth = 0;
            let mut in_str = false;
            let mut esc = false;
            while i < bytes.len() {
                let c = bytes[i];
                if in_str {
                    if esc {
                        esc = false;
                    } else if c == b'\\' {
                        esc = true;
                    } else if c == b'"' {
                        in_str = false;
                    }
                } else {
                    match c {
                        b'"' => in_str = true,
                        b'{' => depth += 1,
                        b'}' => {
                            depth -= 1;
                            if depth == 0 {
                                return Some(obj[start..=i].to_string());
                            }
                        }
                        _ => {}
                    }
                }
                i += 1;
            }
            None
        }
        _ => {
            // number, true/false/null — scan to , or }
            while i < bytes.len() && bytes[i] != b',' && bytes[i] != b'}' {
                i += 1;
            }
            Some(obj[start..i].trim().to_string())
        }
    }
}

/// Entry point — wired from main.rs.
pub fn run(argv: &[String]) -> i32 {
    let args = match parse_args(argv) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("chump session-summary: {}", e);
            eprintln!("Try `chump session-summary --help`.");
            return 2;
        }
    };
    if args.help {
        print_help();
        return 0;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let since = resolve_since(&args, now);

    let merged_blob = match run_gh(&[
        "pr",
        "list",
        "--author",
        "@me",
        "--state",
        "merged",
        "--search",
        &format!("merged:>={}", since),
        "--json",
        "number,title",
        "--limit",
        "100",
    ]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("chump session-summary: gh (merged) failed: {}", e);
            return 1;
        }
    };
    let merged = match parse_gh_json(&merged_blob, false) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump session-summary: parse merged: {}", e);
            return 1;
        }
    };

    let open_blob = match run_gh(&[
        "pr",
        "list",
        "--author",
        "@me",
        "--state",
        "open",
        "--json",
        "number,title,autoMergeRequest",
        "--limit",
        "100",
    ]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("chump session-summary: gh (open) failed: {}", e);
            return 1;
        }
    };
    let open = match parse_gh_json(&open_blob, true) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump session-summary: parse open: {}", e);
            return 1;
        }
    };

    let rendered = match args.format {
        OutputFormat::Text => render_text(&since, &args.window, &merged, &open),
        OutputFormat::Json => render_json(&since, &args.window, &merged, &open),
    };
    print!("{}", rendered);
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(n: u64, t: &str, am: bool) -> PrRow {
        PrRow {
            number: n,
            title: t.to_string(),
            gap_id: extract_gap_id(t),
            auto_merge: am,
        }
    }

    #[test]
    fn parse_args_defaults() {
        let a = parse_args(&[]).unwrap();
        assert_eq!(a.window, "24h");
        assert_eq!(a.format, OutputFormat::Text);
        assert_eq!(a.since, None);
        assert!(!a.help);
    }

    #[test]
    fn parse_args_flags() {
        let a = parse_args(&[
            "--window".to_string(),
            "4h".to_string(),
            "--since".to_string(),
            "2026-05-22".to_string(),
            "--json".to_string(),
        ])
        .unwrap();
        assert_eq!(a.window, "4h");
        assert_eq!(a.since.as_deref(), Some("2026-05-22"));
        assert_eq!(a.format, OutputFormat::Json);
    }

    #[test]
    fn parse_args_equals_form() {
        let a = parse_args(&[
            "--window=2d".to_string(),
            "--since=2026-01-01".to_string(),
            "--format=json".to_string(),
        ])
        .unwrap();
        assert_eq!(a.window, "2d");
        assert_eq!(a.since.as_deref(), Some("2026-01-01"));
        assert_eq!(a.format, OutputFormat::Json);
    }

    #[test]
    fn parse_args_rejects_bad_flag() {
        assert!(parse_args(&["--nope".to_string()]).is_err());
        assert!(parse_args(&["--format".to_string(), "yaml".to_string()]).is_err());
    }

    #[test]
    fn window_to_seconds() {
        assert_eq!(parse_window_to_seconds("24h"), Some(86_400));
        assert_eq!(parse_window_to_seconds("4h"), Some(14_400));
        assert_eq!(parse_window_to_seconds("2d"), Some(172_800));
        assert_eq!(parse_window_to_seconds("30m"), Some(1_800));
        assert_eq!(parse_window_to_seconds("90s"), Some(90));
        assert_eq!(parse_window_to_seconds("nope"), None);
        assert_eq!(parse_window_to_seconds(""), None);
    }

    #[test]
    fn resolve_since_honors_explicit() {
        let a = Args {
            since: Some("2026-01-01".to_string()),
            ..Args::default()
        };
        assert_eq!(resolve_since(&a, 0), "2026-01-01");
    }

    #[test]
    fn resolve_since_computes_window() {
        // 2026-05-22 00:00:00 UTC = 1779_X (we just check the shape)
        let now = 1_779_580_800_i64; // 2026-05-22 00:00:00 UTC approx
        let a = Args {
            window: "24h".to_string(),
            ..Args::default()
        };
        let since = resolve_since(&a, now);
        assert_eq!(since.len(), 10); // YYYY-MM-DD
        assert!(since.starts_with("2026-"));
    }

    #[test]
    fn extract_gap_id_basic() {
        assert_eq!(
            extract_gap_id("feat(INFRA-1437): session-summary"),
            "INFRA-1437"
        );
        assert_eq!(
            extract_gap_id("INFRA-1437 add session summary"),
            "INFRA-1437"
        );
        assert_eq!(
            extract_gap_id("[CREDIBLE-073] bump scoreboard"),
            "CREDIBLE-073"
        );
        assert_eq!(extract_gap_id("chore: no gap here"), "");
        // Single-letter prefix is noise, not a gap id.
        assert_eq!(extract_gap_id("A-1 not a gap"), "");
    }

    #[test]
    fn classify_open_picks_section() {
        assert_eq!(
            classify_open(&row(1, "INFRA-1 t", true)),
            OpenSection::Armed
        );
        assert_eq!(
            classify_open(&row(1, "INFRA-1 t", false)),
            OpenSection::Filed
        );
    }

    #[test]
    fn render_text_layout() {
        let merged = vec![row(2317, "feat(INFRA-1475): fleet queue impl", false)];
        let open = vec![
            row(2327, "feat(INFRA-1656): main-health watchdog", true),
            row(2328, "feat(INFRA-1700): scoreboard sparklines", false),
        ];
        let out = render_text("2026-05-21", "24h", &merged, &open);
        assert!(out.contains("Session: 2026-05-21 (window 24h)"));
        assert!(out.contains("Merged:\n  #2317 INFRA-1475"));
        assert!(out.contains("Armed (auto-merge pending CI):\n  #2327 INFRA-1656"));
        assert!(out.contains("Filed (PR opened, not yet merged):\n  #2328 INFRA-1700"));
    }

    #[test]
    fn render_text_empty_sections() {
        let out = render_text("2026-05-21", "24h", &[], &[]);
        assert!(out.contains("Merged:\n  (none)"));
        assert!(out.contains("Armed (auto-merge pending CI):\n  (none)"));
        assert!(out.contains("Filed (PR opened, not yet merged):\n  (none)"));
    }

    #[test]
    fn render_json_shape() {
        let merged = vec![row(2317, "feat(INFRA-1475): x", false)];
        let open = vec![
            row(2327, "feat(INFRA-1656): y", true),
            row(2328, "feat(INFRA-1700): z", false),
        ];
        let out = render_json("2026-05-21", "24h", &merged, &open);
        assert!(out.contains("\"since\":\"2026-05-21\""));
        assert!(out.contains("\"window\":\"24h\""));
        assert!(out.contains("\"merged\":[{\"number\":2317"));
        assert!(out.contains("\"armed\":[{\"number\":2327"));
        assert!(out.contains("\"filed\":[{\"number\":2328"));
        // Filed PR must NOT show up in armed.
        let armed_idx = out.find("\"armed\":").unwrap();
        let filed_idx = out.find("\"filed\":").unwrap();
        let armed_slice = &out[armed_idx..filed_idx];
        assert!(!armed_slice.contains("2328"));
    }

    #[test]
    fn parse_gh_json_empty() {
        assert_eq!(parse_gh_json("", false).unwrap().len(), 0);
        assert_eq!(parse_gh_json("[]", false).unwrap().len(), 0);
    }

    #[test]
    fn parse_gh_json_merged_rows() {
        let blob = r#"[{"number":2317,"title":"feat(INFRA-1475): impl"},{"number":2318,"title":"chore: bump"}]"#;
        let rows = parse_gh_json(blob, false).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].number, 2317);
        assert_eq!(rows[0].gap_id, "INFRA-1475");
        assert!(!rows[0].auto_merge);
        assert_eq!(rows[1].gap_id, "");
    }

    #[test]
    fn parse_gh_json_open_rows_with_auto_merge() {
        let blob = r#"[{"number":2327,"title":"feat(INFRA-1656): watchdog","autoMergeRequest":{"mergeMethod":"SQUASH"}},{"number":2328,"title":"feat(INFRA-1700): sparkles","autoMergeRequest":null}]"#;
        let rows = parse_gh_json(blob, true).unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows[0].auto_merge);
        assert!(!rows[1].auto_merge);
    }

    #[test]
    fn unix_to_iso_date_known_value() {
        // 1970-01-01
        assert_eq!(unix_to_iso_date(0), "1970-01-01");
        // 2026-05-22 00:00:00 UTC = 1779408000 (calendar.timegm cross-check).
        assert_eq!(unix_to_iso_date(1_779_408_000), "2026-05-22");
        // One day later.
        assert_eq!(unix_to_iso_date(1_779_408_000 + 86_400), "2026-05-23");
    }
}
