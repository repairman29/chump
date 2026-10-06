//! META-1033 (META-270 slice): `chump objective <set|show|progress|done>` — set
//! and track the current fleet objective in a machine-readable file so the
//! orchestrator (and any agent) can read "what are we driving toward" without
//! scraping prose.
//!
//! State file: `.chump-locks/current-objective.json` under the main checkout
//! (override with `CHUMP_OBJECTIVE_FILE`). Fields: `objective_id`, `set_by`,
//! `set_at`, `text`, `success_criteria`, `expected_completion`, `status`
//! (`active` -> `in_progress` -> `done`), plus `progress_log` and
//! `completed_at` once used.
//!
//! ```text
//! chump objective set "<text>" [--criterion "<c>"]... [--expected-completion <ISO8601|YYYY-MM-DD>] [--by <who>]
//! chump objective show [--json]
//! chump objective progress "<note>"
//! chump objective done
//! ```

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Objective {
    pub objective_id: String,
    pub set_by: String,
    pub set_at: String,
    pub text: String,
    pub success_criteria: Vec<String>,
    pub expected_completion: Option<String>,
    pub status: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub progress_log: Vec<ProgressEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProgressEntry {
    pub at: String,
    pub note: String,
}

/// Where the objective lives: `CHUMP_OBJECTIVE_FILE`, else
/// `<main checkout>/.chump-locks/current-objective.json`.
pub fn objective_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_OBJECTIVE_FILE") {
        if !p.trim().is_empty() {
            return PathBuf::from(p);
        }
    }
    crate::repo_path::main_checkout_root()
        .join(".chump-locks")
        .join("current-objective.json")
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Accept an RFC3339 timestamp or a bare `YYYY-MM-DD`.
fn valid_expected_completion(s: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(s).is_ok()
        || chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").is_ok()
}

pub fn load(path: &Path) -> Result<Objective, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|_| format!("no current objective ({} not found)", path.display()))?;
    serde_json::from_str(&raw)
        .map_err(|e| format!("{} is not a valid objective: {e}", path.display()))
}

fn save(path: &Path, o: &Objective) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(o).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body + "\n")
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Create (or replace) the current objective. Rejects empty text and a
/// malformed `expected_completion`.
pub fn set(
    path: &Path,
    text: &str,
    criteria: Vec<String>,
    expected_completion: Option<String>,
    set_by: &str,
) -> Result<Objective, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("objective text must not be empty".into());
    }
    if let Some(ec) = expected_completion.as_deref() {
        if !valid_expected_completion(ec) {
            return Err(format!(
                "--expected-completion must be ISO-8601 (e.g. 2026-10-31 or 2026-10-31T17:00:00Z), got '{ec}'"
            ));
        }
    }
    let criteria: Vec<String> = criteria
        .into_iter()
        .map(|c| c.trim().to_string())
        .filter(|c| !c.is_empty())
        .collect();
    let now = chrono::Utc::now();
    let o = Objective {
        objective_id: format!("OBJ-{}", now.format("%Y%m%d-%H%M%S")),
        set_by: if set_by.trim().is_empty() {
            "unknown".into()
        } else {
            set_by.trim().to_string()
        },
        set_at: now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        text: text.to_string(),
        success_criteria: criteria,
        expected_completion,
        status: "active".into(),
        progress_log: Vec::new(),
        completed_at: None,
    };
    save(path, &o)?;
    Ok(o)
}

/// Append a progress note; moves `active` -> `in_progress`. Refuses a done objective.
pub fn progress(path: &Path, note: &str) -> Result<Objective, String> {
    let note = note.trim();
    if note.is_empty() {
        return Err("progress note must not be empty".into());
    }
    let mut o = load(path)?;
    if o.status == "done" {
        return Err(format!(
            "{} is already done; set a new objective first",
            o.objective_id
        ));
    }
    o.status = "in_progress".into();
    o.progress_log.push(ProgressEntry {
        at: now_rfc3339(),
        note: note.to_string(),
    });
    save(path, &o)?;
    Ok(o)
}

/// Mark the objective done. Refuses if there is none or it is already done.
pub fn done(path: &Path) -> Result<Objective, String> {
    let mut o = load(path)?;
    if o.status == "done" {
        return Err(format!("{} is already done", o.objective_id));
    }
    o.status = "done".into();
    o.completed_at = Some(now_rfc3339());
    save(path, &o)?;
    Ok(o)
}

fn usage() -> &'static str {
    "Usage:\n  chump objective set \"<text>\" [--criterion \"<c>\"]... [--expected-completion <ISO8601|YYYY-MM-DD>] [--by <who>]\n  chump objective show [--json]\n  chump objective progress \"<note>\"\n  chump objective done"
}

fn flag_values(args: &[String], name: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == name {
            if let Some(v) = args.get(i + 1) {
                out.push(v.clone());
            }
            i += 1;
        }
        i += 1;
    }
    out
}

/// First positional (non `--flag`, and not a flag's value) argument.
fn positional(args: &[String], value_flags: &[&str]) -> Option<String> {
    let mut i = 0;
    while i < args.len() {
        if value_flags.contains(&args[i].as_str()) {
            i += 2;
            continue;
        }
        if !args[i].starts_with("--") {
            return Some(args[i].clone());
        }
        i += 1;
    }
    None
}

fn print_objective(o: &Objective) {
    println!("{}  [{}]", o.objective_id, o.status);
    println!("  {}", o.text);
    println!("  set by {} at {}", o.set_by, o.set_at);
    if let Some(ec) = &o.expected_completion {
        println!("  expected completion: {ec}");
    }
    for c in &o.success_criteria {
        println!("  - {c}");
    }
    for p in &o.progress_log {
        println!("  progress {}: {}", p.at, p.note);
    }
    if let Some(c) = &o.completed_at {
        println!("  completed at {c}");
    }
}

/// Entry point. `args` are the arguments AFTER `objective`.
pub fn run(args: &[String]) -> i32 {
    let path = objective_path();
    let sub = args.first().map(String::as_str);
    let rest: &[String] = if args.is_empty() { &[] } else { &args[1..] };
    let result = match sub {
        Some("set") => {
            let value_flags = ["--criterion", "--expected-completion", "--by"];
            let Some(text) = positional(rest, &value_flags) else {
                eprintln!("{}", usage());
                return 2;
            };
            let by = flag_values(rest, "--by").pop().unwrap_or_else(|| {
                std::env::var("CHUMP_SESSION_ID")
                    .or_else(|_| std::env::var("USER"))
                    .unwrap_or_else(|_| "unknown".into())
            });
            set(
                &path,
                &text,
                flag_values(rest, "--criterion"),
                flag_values(rest, "--expected-completion").pop(),
                &by,
            )
            .map(|o| println!("objective {} set", o.objective_id))
        }
        Some("show") => load(&path).map(|o| {
            if rest.iter().any(|a| a == "--json") {
                println!("{}", serde_json::to_string_pretty(&o).unwrap_or_default());
            } else {
                print_objective(&o);
            }
        }),
        Some("progress") => {
            let Some(note) = positional(rest, &[]) else {
                eprintln!("{}", usage());
                return 2;
            };
            progress(&path, &note).map(|o| println!("objective {} in progress", o.objective_id))
        }
        Some("done") => done(&path).map(|o| println!("objective {} done", o.objective_id)),
        Some("--help") | Some("-h") | Some("help") => {
            println!("{}", usage());
            return 0;
        }
        _ => {
            eprintln!("{}", usage());
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("chump objective: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn set_then_show_round_trip_with_all_fields() {
        let dir = tempdir().unwrap();
        let p = dir.path().join(".chump-locks/current-objective.json");
        let set_o = set(
            &p,
            "  Ship the picker policy  ",
            vec!["tests green".into(), " ".into(), "docs updated".into()],
            Some("2026-10-31".into()),
            "orchestrator",
        )
        .unwrap();
        let shown = load(&p).unwrap();
        assert_eq!(set_o, shown);
        assert_eq!(shown.text, "Ship the picker policy");
        assert_eq!(shown.success_criteria, vec!["tests green", "docs updated"]);
        assert_eq!(shown.expected_completion.as_deref(), Some("2026-10-31"));
        assert_eq!(shown.set_by, "orchestrator");
        assert_eq!(shown.status, "active");
        assert!(shown.objective_id.starts_with("OBJ-"));
        // The on-disk JSON carries exactly the documented keys.
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        for k in [
            "objective_id",
            "set_by",
            "set_at",
            "text",
            "success_criteria",
            "expected_completion",
            "status",
        ] {
            assert!(v.get(k).is_some(), "missing key {k}");
        }
    }

    #[test]
    fn progress_and_done_lifecycle() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("o.json");
        set(&p, "obj", vec![], None, "me").unwrap();
        let o = progress(&p, "halfway").unwrap();
        assert_eq!(o.status, "in_progress");
        assert_eq!(o.progress_log.len(), 1);
        let o = done(&p).unwrap();
        assert_eq!(o.status, "done");
        assert!(o.completed_at.is_some());
        assert!(done(&p).unwrap_err().contains("already done"));
        assert!(progress(&p, "late").unwrap_err().contains("already done"));
    }

    #[test]
    fn invalid_input_is_rejected_and_writes_nothing() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("o.json");
        assert!(set(&p, "   ", vec![], None, "me")
            .unwrap_err()
            .contains("empty"));
        assert!(set(&p, "x", vec![], Some("next tuesday".into()), "me")
            .unwrap_err()
            .contains("ISO-8601"));
        assert!(!p.exists(), "a rejected set must not create the file");
        // show/progress/done with no objective.
        assert!(load(&p).unwrap_err().contains("no current objective"));
        assert!(progress(&p, "n").is_err());
        assert!(done(&p).is_err());
        // empty progress note.
        set(&p, "x", vec![], None, "me").unwrap();
        assert!(progress(&p, " ").unwrap_err().contains("empty"));
        // corrupt file.
        std::fs::write(&p, "{not json").unwrap();
        assert!(load(&p).unwrap_err().contains("not a valid objective"));
    }

    #[test]
    fn arg_parsing_picks_text_and_flags() {
        let a: Vec<String> = [
            "ship it",
            "--criterion",
            "a",
            "--criterion",
            "b",
            "--by",
            "me",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(
            positional(&a, &["--criterion", "--expected-completion", "--by"]).as_deref(),
            Some("ship it")
        );
        assert_eq!(flag_values(&a, "--criterion"), vec!["a", "b"]);
        assert_eq!(flag_values(&a, "--by"), vec!["me"]);
        let flags_first: Vec<String> = ["--by", "me", "text here"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(
            positional(
                &flags_first,
                &["--criterion", "--expected-completion", "--by"]
            )
            .as_deref(),
            Some("text here")
        );
    }
}
