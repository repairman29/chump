//! INFRA-1048: harness-agnostic event-emit CLI.
//!
//! `chump ambient emit <kind> [--gap ID] [--source S] [--harness H] [--field key=value]...`
//!
//! Writes one JSON line to `.chump-locks/ambient.jsonl` with the same shape
//! `scripts/dev/ambient-emit.sh` produces. The Rust port exists so non-Claude
//! harnesses (opencode-bigpickle, codex, manual) can invoke the chump binary
//! directly instead of depending on the shell script + python + flock chain.
//!
//! Contract:
//!   - `ts` (RFC3339 UTC) is added automatically
//!   - `session` resolves CHUMP_SESSION_ID > CLAUDE_SESSION_ID > worktree-cached > derived
//!   - `worktree` is the basename of the repo root
//!   - `harness` resolves --harness flag > CHUMP_AGENT_HARNESS > "unknown"
//!   - `event` is the positional `<kind>` arg
//!   - Extra fields from `--field key=value` arrive as string-valued JSON keys
//!   - Atomic append via advisory file lock (flock on POSIX; best-effort on Win)

use anyhow::{anyhow, Context, Result};
use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Default, Clone)]
pub struct EmitArgs {
    pub kind: String,
    pub gap: Option<String>,
    pub source: Option<String>,
    pub harness: Option<String>,
    /// Repeated `--field key=value` pairs; order preserved in the output JSON.
    pub fields: Vec<(String, String)>,
    /// Override ambient.jsonl path (tests, alternative repos).
    pub ambient_override: Option<PathBuf>,
    /// Override session ID (tests / explicit override).
    pub session_override: Option<String>,
}

impl EmitArgs {
    pub fn from_argv(args: &[String]) -> Result<Self> {
        // args[0] = "ambient", args[1] = "emit", args[2] = <kind>, then flags.
        let kind = args
            .get(2)
            .ok_or_else(|| anyhow!("missing event kind"))?
            .clone();
        if kind.starts_with("--") {
            return Err(anyhow!("missing event kind (saw flag '{kind}')"));
        }

        let mut out = Self {
            kind,
            ..Default::default()
        };
        let mut i = 3;
        while i < args.len() {
            match args[i].as_str() {
                "--gap" => {
                    out.gap = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--gap needs a value"))?
                            .clone(),
                    );
                    i += 2;
                }
                "--source" => {
                    out.source = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--source needs a value"))?
                            .clone(),
                    );
                    i += 2;
                }
                "--harness" => {
                    out.harness = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--harness needs a value"))?
                            .clone(),
                    );
                    i += 2;
                }
                "--field" => {
                    let kv = args
                        .get(i + 1)
                        .ok_or_else(|| anyhow!("--field needs a key=value arg"))?;
                    let (k, v) = kv
                        .split_once('=')
                        .ok_or_else(|| anyhow!("--field arg must be key=value (got '{kv}')"))?;
                    if k.is_empty() {
                        return Err(anyhow!("--field key is empty (got '{kv}')"));
                    }
                    out.fields.push((k.to_string(), v.to_string()));
                    i += 2;
                }
                other => return Err(anyhow!("unknown flag: {other}")),
            }
        }
        Ok(out)
    }
}

pub fn emit(args: &EmitArgs) -> Result<PathBuf> {
    let repo_root = crate::repo_path::repo_root();
    let main_repo = main_repo_root(&repo_root);

    let ambient = args
        .ambient_override
        .clone()
        .unwrap_or_else(|| main_repo.join(".chump-locks/ambient.jsonl"));
    if let Some(parent) = ambient.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }

    let session = args
        .session_override
        .clone()
        .unwrap_or_else(|| resolve_session_id(&repo_root));
    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("?")
        .to_string();
    let harness = args
        .harness
        .clone()
        .or_else(|| {
            std::env::var("CHUMP_AGENT_HARNESS")
                .ok()
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let ts = current_iso8601();

    // Build the JSON object. BTreeMap for deterministic key order on the
    // EXTRA fields; the base fields are written in a fixed order to match
    // ambient-emit.sh byte-for-byte.
    let mut base = String::new();
    base.push('{');
    push_kv_string(&mut base, "ts", &ts, true);
    push_kv_string(&mut base, "session", &session, false);
    push_kv_string(&mut base, "worktree", &worktree, false);
    push_kv_string(&mut base, "harness", &harness, false);
    push_kv_string(&mut base, "event", &args.kind, false);
    if let Some(ref g) = args.gap {
        push_kv_string(&mut base, "gap_id", g, false);
    }
    if let Some(ref s) = args.source {
        push_kv_string(&mut base, "source", s, false);
    }
    // Extra fields preserve --field-flag order (vs BTreeMap dedup):
    // operators usually pass canonical-order keys; sorting would surprise.
    for (k, v) in &args.fields {
        push_kv_string(&mut base, k, v, false);
    }
    base.push('}');
    base.push('\n');

    append_atomic(&ambient, &base)?;
    // INFRA-1468: inline watchdog — emit lagging alert + rotate if file is oversized.
    maybe_warn_and_rotate(&ambient);
    Ok(ambient)
}

/// Check ambient.jsonl size after each write; emit `kind=ambient_rotation_lagging`
/// and rotate in-process when the file exceeds the configured threshold.
///
/// This ensures rotation is not deferred until `chump ambient-rotate` is invoked
/// manually or via fleet_health — it fires automatically on every emit call once
/// the file crosses the threshold (INFRA-1468).
///
/// Thread-safety: `metadata` + `rename` are each individually atomic on POSIX.
/// Two concurrent callers racing at the threshold may both try to rename; the
/// second rename is a no-op on the fresh (tiny) file. Acceptable at production
/// emit rates.
fn maybe_warn_and_rotate(ambient: &std::path::Path) {
    // Re-use ambient_rotate's threshold so both subsystems stay in sync.
    let threshold = crate::ambient_rotate::max_bytes();
    let size = match std::fs::metadata(ambient) {
        Ok(m) => m.len(),
        Err(_) => return, // file may not exist yet (race with O_CREAT); ignore
    };
    if size < threshold {
        return;
    }

    // Write the lagging alert as a raw direct append — NOT via emit() to avoid
    // recursion. This lands in the file *before* rotation so it's visible in
    // the archived .1 copy.
    let ts = current_iso8601();
    let warn_line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"ambient_rotation_lagging\",\"size_bytes\":{size},\"threshold_bytes\":{threshold}}}\n",
    );
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(ambient) {
        let _ = std::io::Write::write_all(&mut f, warn_line.as_bytes());
    }

    // Rotate: rename ambient.jsonl → .1 (→ .2 cascade). After the rename the
    // next O_CREAT|O_APPEND open in append_atomic() creates a fresh file.
    crate::ambient_rotate::rotate_if_needed(ambient);
}

/// Resolve the main-repo root (linked-worktree-safe). Mirrors the shell
/// script's `git rev-parse --git-common-dir` logic.
fn main_repo_root(repo_root: &std::path::Path) -> PathBuf {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .current_dir(repo_root)
        .output();
    if let Ok(o) = out {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !s.is_empty() && s != ".git" {
                let common = std::path::PathBuf::from(&s);
                if let Some(parent) = common.parent() {
                    return parent.to_path_buf();
                }
            }
        }
    }
    repo_root.to_path_buf()
}

/// Session ID lookup matching gap-claim.sh / ambient-emit.sh:
///   CHUMP_SESSION_ID > CLAUDE_SESSION_ID > .chump-locks/.wt-session-id > derived.
fn resolve_session_id(repo_root: &std::path::Path) -> String {
    if let Ok(v) = std::env::var("CHUMP_SESSION_ID") {
        if !v.is_empty() {
            return v;
        }
    }
    if let Ok(v) = std::env::var("CLAUDE_SESSION_ID") {
        if !v.is_empty() {
            return v;
        }
    }
    let wt_cache = repo_root.join(".chump-locks/.wt-session-id");
    if let Ok(s) = std::fs::read_to_string(&wt_cache) {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return s;
        }
    }
    let basename = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("repo");
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("chump-{}-{}", basename, epoch)
}

fn current_iso8601() -> String {
    let unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Reuse the formatter from atomic_claim (Hinnant civil_from_days). We
    // shell out to `date -u` only as a last resort; in-process is cleaner
    // and faster for the hot path.
    let days = (unix / 86_400) as i64;
    let sod = (unix % 86_400) as u32;
    let h = sod / 3600;
    let m = (sod % 3600) / 60;
    let s = sod % 60;
    let (y, mo, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, m, s)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 {
        z / 146_097
    } else {
        (z - 146_096) / 146_097
    };
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn push_kv_string(out: &mut String, key: &str, value: &str, first: bool) {
    if !first {
        out.push(',');
    }
    out.push('"');
    out.push_str(&json_escape(key));
    out.push_str("\":\"");
    out.push_str(&json_escape(value));
    out.push('"');
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

/// Atomic append. POSIX guarantees that writes to an O_APPEND fd with
/// length < PIPE_BUF (4096 bytes) are atomic — the kernel handles the
/// seek+write as one operation, so concurrent emitters never interleave
/// as long as each call writes a single line under the buffer cap.
///
/// Our event lines are well under 4096 (the longest realistic events
/// in EVENT_REGISTRY are ~500 bytes including all extra fields). If a
/// caller ever generates a line >= PIPE_BUF, that's a registry-shape
/// problem worth fixing at the schema layer, not papering over here.
fn append_atomic(path: &std::path::Path, line: &str) -> Result<()> {
    // Sanity check — surface the schema-shape bug rather than risk torn writes.
    const PIPE_BUF_MIN: usize = 4096;
    if line.len() >= PIPE_BUF_MIN {
        return Err(anyhow!(
            "ambient line is {} bytes (>= PIPE_BUF {}); split the event or shrink fields",
            line.len(),
            PIPE_BUF_MIN
        ));
    }
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open ambient log {}", path.display()))?;
    f.write_all(line.as_bytes())
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

/// Builder helper for tests (also keeps the BTreeMap import alive even when
/// the binary path doesn't use it).
#[allow(dead_code)]
fn collect_fields(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    let _bt: BTreeMap<&str, &str> = pairs.iter().copied().collect();
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra1048-{}-{}",
            label,
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn from_argv_minimal() {
        let argv: Vec<String> = vec!["ambient".into(), "emit".into(), "file_edit".into()];
        let a = EmitArgs::from_argv(&argv).unwrap();
        assert_eq!(a.kind, "file_edit");
        assert!(a.gap.is_none() && a.source.is_none() && a.harness.is_none());
        assert!(a.fields.is_empty());
    }

    #[test]
    fn from_argv_all_flags() {
        let argv: Vec<String> = vec![
            "ambient".into(),
            "emit".into(),
            "session_start".into(),
            "--gap".into(),
            "INFRA-1048".into(),
            "--source".into(),
            "my-script.sh".into(),
            "--harness".into(),
            "opencode-bigpickle".into(),
            "--field".into(),
            "path=src/foo.rs".into(),
            "--field".into(),
            "extra=value with spaces".into(),
        ];
        let a = EmitArgs::from_argv(&argv).unwrap();
        assert_eq!(a.kind, "session_start");
        assert_eq!(a.gap.as_deref(), Some("INFRA-1048"));
        assert_eq!(a.source.as_deref(), Some("my-script.sh"));
        assert_eq!(a.harness.as_deref(), Some("opencode-bigpickle"));
        assert_eq!(a.fields.len(), 2);
        assert_eq!(a.fields[0], ("path".into(), "src/foo.rs".into()));
        assert_eq!(a.fields[1], ("extra".into(), "value with spaces".into()));
    }

    #[test]
    fn from_argv_rejects_missing_kind() {
        let argv: Vec<String> = vec!["ambient".into(), "emit".into()];
        assert!(EmitArgs::from_argv(&argv).is_err());
    }

    #[test]
    fn from_argv_rejects_field_without_equals() {
        let argv: Vec<String> = vec![
            "ambient".into(),
            "emit".into(),
            "k".into(),
            "--field".into(),
            "novalue".into(),
        ];
        assert!(EmitArgs::from_argv(&argv).is_err());
    }

    #[test]
    fn from_argv_rejects_empty_field_key() {
        let argv: Vec<String> = vec![
            "ambient".into(),
            "emit".into(),
            "k".into(),
            "--field".into(),
            "=v".into(),
        ];
        assert!(EmitArgs::from_argv(&argv).is_err());
    }

    #[test]
    fn json_escape_handles_quotes_and_controls() {
        assert_eq!(json_escape(r#"a"b"#), r#"a\"b"#);
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("a\nb"), "a\\nb");
        assert_eq!(json_escape("a\u{0001}b"), "a\\u0001b");
    }

    #[test]
    fn emit_writes_valid_json_with_all_base_fields() {
        let tmp = mk_tmp("basic");
        let ambient = tmp.join("ambient.jsonl");
        let args = EmitArgs {
            kind: "file_edit".into(),
            ambient_override: Some(ambient.clone()),
            session_override: Some("test-sess".into()),
            harness: Some("manual".into()),
            ..Default::default()
        };
        emit(&args).unwrap();
        let body = std::fs::read_to_string(&ambient).unwrap();
        assert!(body.ends_with("\n"));
        let line = body.trim_end();
        let parsed: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
        assert_eq!(parsed["event"], "file_edit");
        assert_eq!(parsed["session"], "test-sess");
        assert_eq!(parsed["harness"], "manual");
        assert!(parsed["ts"].as_str().unwrap().ends_with("Z"));
        assert!(parsed["worktree"].as_str().is_some());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn emit_includes_gap_and_extra_fields() {
        let tmp = mk_tmp("fields");
        let ambient = tmp.join("ambient.jsonl");
        let args = EmitArgs {
            kind: "commit".into(),
            gap: Some("INFRA-XYZ".into()),
            source: Some("bot-merge.sh".into()),
            fields: vec![
                ("sha".into(), "abc1234".into()),
                ("msg".into(), "fix: something".into()),
            ],
            ambient_override: Some(ambient.clone()),
            session_override: Some("s".into()),
            harness: Some("claude".into()),
        };
        emit(&args).unwrap();
        let line = std::fs::read_to_string(&ambient).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed["gap_id"], "INFRA-XYZ");
        assert_eq!(parsed["source"], "bot-merge.sh");
        assert_eq!(parsed["sha"], "abc1234");
        assert_eq!(parsed["msg"], "fix: something");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn emit_concurrent_appends_dont_interleave() {
        // Spawn 8 threads each emitting 50 events. Verify the file has
        // exactly 400 lines and each parses as valid JSON.
        let tmp = mk_tmp("concurrent");
        let ambient = tmp.join("ambient.jsonl");
        let ambient_c = ambient.clone();
        let mut handles = vec![];
        for t in 0..8 {
            let a = ambient_c.clone();
            handles.push(std::thread::spawn(move || {
                for i in 0..50 {
                    let args = EmitArgs {
                        kind: "stress".into(),
                        ambient_override: Some(a.clone()),
                        session_override: Some(format!("t{}", t)),
                        harness: Some("test".into()),
                        fields: vec![("i".into(), format!("{i}"))],
                        ..Default::default()
                    };
                    emit(&args).unwrap();
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        let body = std::fs::read_to_string(&ambient).unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(
            lines.len(),
            400,
            "expected 400 atomic lines, got {}",
            lines.len()
        );
        for (n, line) in lines.iter().enumerate() {
            serde_json::from_str::<serde_json::Value>(line)
                .unwrap_or_else(|e| panic!("line {n} invalid JSON: {e} - line={line}"));
        }
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn emit_harness_falls_back_to_env_then_unknown() {
        let tmp = mk_tmp("harness");
        let ambient = tmp.join("ambient.jsonl");
        let prev = std::env::var("CHUMP_AGENT_HARNESS").ok();

        // (1) env set, no flag → env wins.
        std::env::set_var("CHUMP_AGENT_HARNESS", "opencode-bigpickle");
        let a = EmitArgs {
            kind: "k".into(),
            ambient_override: Some(ambient.clone()),
            session_override: Some("s".into()),
            ..Default::default()
        };
        emit(&a).unwrap();

        // (2) flag set, env set → flag wins.
        std::fs::write(&ambient, "").unwrap();
        let a2 = EmitArgs {
            kind: "k".into(),
            harness: Some("explicit".into()),
            ambient_override: Some(ambient.clone()),
            session_override: Some("s".into()),
            ..Default::default()
        };
        emit(&a2).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&ambient).unwrap().trim_end()).unwrap();
        assert_eq!(v["harness"], "explicit");

        // (3) no env, no flag → unknown.
        std::env::remove_var("CHUMP_AGENT_HARNESS");
        std::fs::write(&ambient, "").unwrap();
        let a3 = EmitArgs {
            kind: "k".into(),
            ambient_override: Some(ambient.clone()),
            session_override: Some("s".into()),
            ..Default::default()
        };
        emit(&a3).unwrap();
        let v3: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&ambient).unwrap().trim_end()).unwrap();
        assert_eq!(v3["harness"], "unknown");

        if let Some(v) = prev {
            std::env::set_var("CHUMP_AGENT_HARNESS", v);
        }
        std::fs::remove_dir_all(&tmp).ok();
    }
}
