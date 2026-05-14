//! INFRA-537: per-agent ship-quality grade.
//!
//! For each `ship_grade` event emitted by `bot-merge.sh`, records three
//! binary quality signals:
//! - `clippy_ok`    — did local `cargo clippy` pass? (null when --fast skipped it)
//! - `test_added`   — does the PR diff contain at least one test addition?
//! - `rebase_clean` — did `git rebase` complete without conflicts? (null when up-to-date)
//!
//! Events are tagged with `model` (FLEET_MODEL env) and `agent_id`
//! (AGENT_ID env) so the aggregation can surface empirical numbers like
//! "sonnet-shipped PRs land clean 88% of the time, haiku 60%".
//!
//! ## Event format (appended to .chump-locks/ambient.jsonl)
//!
//! ```json
//! {"event":"ship_grade","kind":"ship_grade","ts":"...","gap_id":"INFRA-123",
//!  "model":"sonnet","agent_id":"2",
//!  "clippy_ok":true,"test_added":false,"rebase_clean":true}
//! ```
//!
//! ## Aggregation
//!
//! `chump ship-quality [--since 24h] [--json]` reads ambient.jsonl,
//! groups events by model and agent_id, and prints a table with the
//! pass rate for each signal.

use std::collections::BTreeMap;
use std::path::Path;

// ── Emission ─────────────────────────────────────────────────────────────────

/// Grade signals captured at bot-merge.sh ship time.
#[derive(Debug, Clone, Default)]
pub struct ShipGrade {
    pub gap_id: String,
    /// FLEET_MODEL value (haiku / sonnet / opus / unknown).
    pub model: String,
    /// AGENT_ID value from the fleet worker, or "unknown" for manual ships.
    pub agent_id: String,
    /// CHUMP_AGENT_HARNESS value (claude / opencode / manual / unknown). INFRA-1049.
    pub harness: String,
    /// None = skipped (--fast mode).
    pub clippy_ok: Option<bool>,
    /// None = diff check not available.
    pub test_added: Option<bool>,
    /// None = was already up-to-date (no rebase needed).
    pub rebase_clean: Option<bool>,
}

/// Append a `ship_grade` event to `.chump-locks/ambient.jsonl`. Best-effort.
pub fn emit_ship_grade(repo_root: &Path, grade: &ShipGrade) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();

    fn opt_bool_field(name: &str, v: Option<bool>) -> String {
        match v {
            Some(true) => format!(r#","{}":true"#, name),
            Some(false) => format!(r#","{}":false"#, name),
            None => format!(r#","{}":null"#, name),
        }
    }

    let json = format!(
        r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{ts}","gap_id":"{gap}","model":"{model}","agent_id":"{agent}","harness":"{harness}"{clippy}{test}{rebase}}}"#,
        ts = ts,
        gap = json_escape(&grade.gap_id),
        model = json_escape(&grade.model),
        agent = json_escape(&grade.agent_id),
        harness = json_escape(&grade.harness),
        clippy = opt_bool_field("clippy_ok", grade.clippy_ok),
        test = opt_bool_field("test_added", grade.test_added),
        rebase = opt_bool_field("rebase_clean", grade.rebase_clean),
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

// ── Aggregation ──────────────────────────────────────────────────────────────

/// Per-key (model or agent_id) quality aggregate.
#[derive(Debug, Clone, Default)]
pub struct GradeStats {
    pub total: u64,
    pub clippy_ok: u64,
    pub clippy_n: u64,
    pub test_added: u64,
    pub test_n: u64,
    pub rebase_clean: u64,
    pub rebase_n: u64,
}

impl GradeStats {
    fn accum(&mut self, clippy: Option<bool>, test: Option<bool>, rebase: Option<bool>) {
        self.total += 1;
        if let Some(v) = clippy {
            self.clippy_n += 1;
            if v {
                self.clippy_ok += 1;
            }
        }
        if let Some(v) = test {
            self.test_n += 1;
            if v {
                self.test_added += 1;
            }
        }
        if let Some(v) = rebase {
            self.rebase_n += 1;
            if v {
                self.rebase_clean += 1;
            }
        }
    }

    fn pct(num: u64, den: u64) -> String {
        if den == 0 {
            "n/a".to_string()
        } else {
            format!("{:.0}%", 100.0 * num as f64 / den as f64)
        }
    }

    pub fn clippy_pct(&self) -> String {
        Self::pct(self.clippy_ok, self.clippy_n)
    }
    pub fn test_pct(&self) -> String {
        Self::pct(self.test_added, self.test_n)
    }
    pub fn rebase_pct(&self) -> String {
        Self::pct(self.rebase_clean, self.rebase_n)
    }
}

pub struct ShipQualityReport {
    pub since_seconds: u64,
    pub total_grades: u64,
    pub by_model: BTreeMap<String, GradeStats>,
    pub by_agent: BTreeMap<String, GradeStats>,
    /// INFRA-1049: per-harness aggregation.
    pub by_harness: BTreeMap<String, GradeStats>,
}

/// Build a ship-quality report from ambient.jsonl for the given lookback window.
pub fn build_report(repo_root: &Path, since_secs: u64) -> ShipQualityReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let cutoff = current_unix().saturating_sub(since_secs);

    let mut by_model: BTreeMap<String, GradeStats> = BTreeMap::new();
    let mut by_agent: BTreeMap<String, GradeStats> = BTreeMap::new();
    let mut by_harness: BTreeMap<String, GradeStats> = BTreeMap::new();
    let mut total = 0u64;

    for line in contents.lines() {
        if !line.contains(r#""kind":"ship_grade""#) {
            continue;
        }
        if let Some(ts_str) = extract_field(line, "ts") {
            if let Some(unix_ts) = parse_iso8601_to_unix(&ts_str) {
                if unix_ts < cutoff {
                    continue;
                }
            }
        }
        let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
        let agent = extract_field(line, "agent_id").unwrap_or_else(|| "unknown".to_string());
        // INFRA-1049: harness field; pre-fix events default to "claude" (fleet default).
        let harness = extract_field(line, "harness").unwrap_or_else(|| "claude".to_string());
        let clippy = extract_opt_bool(line, "clippy_ok");
        let test = extract_opt_bool(line, "test_added");
        let rebase = extract_opt_bool(line, "rebase_clean");

        total += 1;
        by_model
            .entry(model)
            .or_default()
            .accum(clippy, test, rebase);
        by_agent
            .entry(agent)
            .or_default()
            .accum(clippy, test, rebase);
        by_harness
            .entry(harness)
            .or_default()
            .accum(clippy, test, rebase);
    }

    ShipQualityReport {
        since_seconds: since_secs,
        total_grades: total,
        by_model,
        by_agent,
        by_harness,
    }
}

impl ShipQualityReport {
    pub fn render_text(&self) -> String {
        if self.total_grades == 0 {
            let h = self.since_seconds / 3600;
            return format!(
                "No ship_grade events in the last {}h.\n\
                 (Events are emitted by bot-merge.sh when a PR ships.)\n",
                h
            );
        }

        let h = self.since_seconds / 3600;
        let mut out = format!(
            "Ship quality — last {}h ({} grades)\n\n",
            h, self.total_grades
        );

        fn table_block(title: &str, map: &BTreeMap<String, GradeStats>) -> String {
            let mut s = format!("{}:\n", title);
            s.push_str(&format!(
                "  {:<18}  {:>6}  {:>9}  {:>10}  {:>12}\n",
                "key", "ships", "clippy_ok", "test_added", "rebase_clean"
            ));
            s.push_str(&format!(
                "  {:<18}  {:>6}  {:>9}  {:>10}  {:>12}\n",
                "──────────────────", "──────", "─────────", "──────────", "────────────"
            ));
            for (key, g) in map {
                s.push_str(&format!(
                    "  {:<18}  {:>6}  {:>9}  {:>10}  {:>12}\n",
                    key,
                    g.total,
                    g.clippy_pct(),
                    g.test_pct(),
                    g.rebase_pct()
                ));
            }
            s.push('\n');
            s
        }

        out.push_str(&table_block("By model", &self.by_model));
        out.push_str(&table_block("By agent", &self.by_agent));
        out.push_str(&table_block("By harness", &self.by_harness));
        out
    }

    pub fn render_json(&self) -> String {
        fn entry_json(key: &str, g: &GradeStats) -> String {
            format!(
                r#"{{"key":"{key}","total":{total},"clippy_ok_pct":"{cp}","test_added_pct":"{tp}","rebase_clean_pct":"{rp}","clippy_n":{cn},"test_n":{tn},"rebase_n":{rn}}}"#,
                key = json_escape(key),
                total = g.total,
                cp = g.clippy_pct(),
                tp = g.test_pct(),
                rp = g.rebase_pct(),
                cn = g.clippy_n,
                tn = g.test_n,
                rn = g.rebase_n,
            )
        }

        let models: Vec<_> = self
            .by_model
            .iter()
            .map(|(k, v)| entry_json(k, v))
            .collect();
        let agents: Vec<_> = self
            .by_agent
            .iter()
            .map(|(k, v)| entry_json(k, v))
            .collect();
        let harnesses: Vec<_> = self
            .by_harness
            .iter()
            .map(|(k, v)| entry_json(k, v))
            .collect();

        format!(
            r#"{{"since_seconds":{since},"total_grades":{total},"by_model":[{models}],"by_agent":[{agents}],"by_harness":[{harnesses}]}}"#,
            since = self.since_seconds,
            total = self.total_grades,
            models = models.join(","),
            agents = agents.join(","),
            harnesses = harnesses.join(","),
        )
    }
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn current_iso8601() -> String {
    if let Ok(out) = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
    {
        if out.status.success() {
            return String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    use std::time::{SystemTime, UNIX_EPOCH};
    let s = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}Z", s)
}

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if out2.status.success() {
        return String::from_utf8_lossy(&out2.stdout).trim().parse().ok();
    }
    None
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

/// Extract a JSON boolean or null field: `"field":true`, `"field":false`, `"field":null`.
fn extract_opt_bool(line: &str, field: &str) -> Option<bool> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start_matches(' ');
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        // null or missing → None
        None
    }
}

fn json_escape(s: &str) -> String {
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

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra537-{}-{}",
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
    fn infra537_emit_ship_grade_writes_jsonl() {
        let tmp = tmpdir();
        emit_ship_grade(
            &tmp,
            &ShipGrade {
                gap_id: "INFRA-537".to_string(),
                model: "sonnet".to_string(),
                agent_id: "2".to_string(),
                harness: "claude".to_string(),
                clippy_ok: Some(true),
                test_added: Some(false),
                rebase_clean: Some(true),
            },
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient exists");
        assert!(log.contains(r#""kind":"ship_grade""#));
        assert!(log.contains(r#""gap_id":"INFRA-537""#));
        assert!(log.contains(r#""model":"sonnet""#));
        assert!(log.contains(r#""agent_id":"2""#));
        assert!(log.contains(r#""harness":"claude""#));
        assert!(log.contains(r#""clippy_ok":true"#));
        assert!(log.contains(r#""test_added":false"#));
        assert!(log.contains(r#""rebase_clean":true"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra537_emit_ship_grade_null_fields() {
        let tmp = tmpdir();
        emit_ship_grade(
            &tmp,
            &ShipGrade {
                gap_id: "INFRA-100".to_string(),
                model: "haiku".to_string(),
                agent_id: "1".to_string(),
                harness: "opencode".to_string(),
                clippy_ok: None,
                test_added: None,
                rebase_clean: None,
            },
        );
        let log = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl"))
            .expect("ambient exists");
        assert!(log.contains(r#""clippy_ok":null"#));
        assert!(log.contains(r#""test_added":null"#));
        assert!(log.contains(r#""rebase_clean":null"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra537_extract_opt_bool_parses_true_false_null() {
        assert_eq!(
            extract_opt_bool(r#"{"clippy_ok":true,"x":1}"#, "clippy_ok"),
            Some(true)
        );
        assert_eq!(
            extract_opt_bool(r#"{"clippy_ok":false}"#, "clippy_ok"),
            Some(false)
        );
        assert_eq!(extract_opt_bool(r#"{"clippy_ok":null}"#, "clippy_ok"), None);
        assert_eq!(extract_opt_bool(r#"{"other":"x"}"#, "clippy_ok"), None);
    }

    /// Build a fresh ISO8601 timestamp at `now - offset_secs`. Tests use dynamic
    /// stamps so the 7-day filter window in build_report keeps the fixtures in
    /// scope regardless of when CI runs. (Hardcoded 2026-05-06 stamps caused
    /// 3 tests to start failing on 2026-05-13 once the rolling window passed.)
    fn recent_iso(offset_secs: u64) -> String {
        let unix = current_unix().saturating_sub(offset_secs);
        let out = std::process::Command::new("date")
            .args(["-u", "-r", &unix.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .ok();
        if let Some(o) = out {
            if o.status.success() {
                return String::from_utf8_lossy(&o.stdout).trim().to_string();
            }
        }
        // GNU date fallback
        let out2 = std::process::Command::new("date")
            .args(["-u", "-d", &format!("@{}", unix), "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .expect("date command must work");
        String::from_utf8_lossy(&out2.stdout).trim().to_string()
    }

    #[test]
    fn infra537_build_report_aggregates_by_model_and_agent() {
        let tmp = tmpdir();
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();

        let t1 = recent_iso(3600);
        let t2 = recent_iso(3540);
        let t3 = recent_iso(3480);
        // Two sonnet ships (both clippy ok, 1 test added) + one haiku ship (clippy ok, no test)
        let lines = [
            format!(
                r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{t1}","gap_id":"INFRA-1","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#
            ),
            format!(
                r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{t2}","gap_id":"INFRA-2","model":"sonnet","agent_id":"2","clippy_ok":true,"test_added":false,"rebase_clean":null}}"#
            ),
            format!(
                r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{t3}","gap_id":"INFRA-3","model":"haiku","agent_id":"1","clippy_ok":false,"test_added":false,"rebase_clean":true}}"#
            ),
        ];
        std::fs::write(&amb, lines.join("\n") + "\n").unwrap();

        let report = build_report(&tmp, 86400 * 7); // 7-day window
        assert_eq!(report.total_grades, 3);

        let sonnet = &report.by_model["sonnet"];
        assert_eq!(sonnet.total, 2);
        assert_eq!(sonnet.clippy_ok, 2);
        assert_eq!(sonnet.clippy_n, 2);
        assert_eq!(sonnet.test_added, 1);
        assert_eq!(sonnet.test_n, 2);
        // rebase_clean: one true, one null — only 1 checked
        assert_eq!(sonnet.rebase_n, 1);
        assert_eq!(sonnet.rebase_clean, 1);

        let haiku = &report.by_model["haiku"];
        assert_eq!(haiku.total, 1);
        assert_eq!(haiku.clippy_ok, 0);
        assert_eq!(haiku.clippy_n, 1);

        // INFRA-1049: events without harness field default to "claude"
        let claude = &report.by_harness["claude"];
        assert_eq!(claude.total, 3);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra1049_mixed_harness_fixture() {
        let tmp = tmpdir();
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();

        let t1 = recent_iso(100);
        let t2 = recent_iso(60);
        let t3 = recent_iso(20);
        let lines = [
            format!(
                r#"{{"kind":"ship_grade","ts":"{t1}","gap_id":"A","model":"sonnet","agent_id":"1","harness":"claude","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#
            ),
            format!(
                r#"{{"kind":"ship_grade","ts":"{t2}","gap_id":"B","model":"sonnet","agent_id":"2","harness":"opencode","clippy_ok":false,"test_added":false,"rebase_clean":null}}"#
            ),
            format!(
                r#"{{"kind":"ship_grade","ts":"{t3}","gap_id":"C","model":"haiku","agent_id":"3","harness":"claude","clippy_ok":true,"test_added":false,"rebase_clean":true}}"#
            ),
        ];
        std::fs::write(&amb, lines.join("\n") + "\n").unwrap();

        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_grades, 3);
        assert_eq!(report.by_harness.len(), 2);
        let claude = &report.by_harness["claude"];
        assert_eq!(claude.total, 2);
        let opencode = &report.by_harness["opencode"];
        assert_eq!(opencode.total, 1);
        assert_eq!(opencode.clippy_ok, 0);

        let text = report.render_text();
        assert!(text.contains("By harness"));
        assert!(text.contains("opencode"));

        let json = report.render_json();
        assert!(json.contains(r#""by_harness""#));
        assert!(json.contains("opencode"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra537_build_report_empty_window() {
        let tmp = tmpdir();
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_grades, 0);
        let text = report.render_text();
        assert!(text.contains("No ship_grade events"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra537_render_text_shows_per_model_table() {
        let tmp = tmpdir();
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();
        let t1 = recent_iso(3600);
        let lines = [format!(
            r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{t1}","gap_id":"INFRA-1","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#
        )];
        std::fs::write(&amb, lines.join("\n") + "\n").unwrap();
        let report = build_report(&tmp, 86400 * 7);
        let text = report.render_text();
        assert!(text.contains("By model"));
        assert!(text.contains("By agent"));
        assert!(text.contains("By harness"));
        assert!(text.contains("sonnet"));
        assert!(text.contains("100%")); // clippy 1/1
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra537_render_json_is_valid_structure() {
        let tmp = tmpdir();
        let amb = tmp.join(".chump-locks/ambient.jsonl");
        std::fs::create_dir_all(amb.parent().unwrap()).unwrap();
        let t1 = recent_iso(3600);
        let line = format!(
            r#"{{"event":"ship_grade","kind":"ship_grade","ts":"{t1}","gap_id":"INFRA-1","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":false,"rebase_clean":true}}"#
        );
        std::fs::write(&amb, line + "\n").unwrap();
        let report = build_report(&tmp, 86400 * 7);
        let json = report.render_json();
        assert!(json.contains(r#""total_grades":1"#));
        assert!(json.contains(r#""by_model""#));
        assert!(json.contains(r#""by_agent""#));
        assert!(json.contains(r#""by_harness""#));
        assert!(json.contains("sonnet"));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
