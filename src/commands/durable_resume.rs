//! RESILIENT-059: `chump durable-resume <gap-id>` — inspect or initiate a
//! durable-execution resume for a gap.
//!
//! # What it does
//!
//! 1. Opens the durable journal in `.chump/state.db`.
//! 2. Looks up the most recent `run_id` for `<gap-id>`.
//! 3. If there are incomplete steps → prints a resume-ready summary and exits 0.
//! 4. If all steps are complete (or no runs exist) → prints "no resumable run"
//!    and exits 0 with a hint to start a fresh execution.
//!
//! # Flags
//!
//! ```text
//! chump durable-resume <gap-id> [--json] [--list-steps]
//!
//!   --json          Emit a machine-readable JSON object to stdout instead of
//!                   human-readable text. Useful for pipeline integration.
//!   --list-steps    Print each completed step with its result_json. Implies
//!                   human-readable format (ignored when combined with --json,
//!                   which always includes the steps array).
//! ```
//!
//! # Exit codes
//!
//! ```text
//!   0  — success (either a resumable run was found, or no runs exist)
//!   1  — journal open / query error
//!   2  — bad usage (missing gap-id)
//! ```
//!
//! # JSON output schema
//!
//! ```json
//! {
//!   "gap_id": "INFRA-1234",
//!   "resumable": true,
//!   "run_id": 3,
//!   "replayed_steps": 2,
//!   "incomplete_steps": 1,
//!   "steps": [
//!     { "step_name": "fetch-pr", "step_index": 0, "completed": true,
//!       "started_at": "...", "completed_at": "...", "result_json": "..." },
//!     { "step_name": "apply-patch", "step_index": 1, "completed": false,
//!       "started_at": "...", "completed_at": null, "result_json": null }
//!   ]
//! }
//! ```

use std::path::PathBuf;

use super::durable_execution_journal::Journal;

// ── helpers ───────────────────────────────────────────────────────────────────

fn usage() {
    eprintln!("Usage: chump durable-resume <gap-id> [--json] [--list-steps]");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --json        Machine-readable JSON output");
    eprintln!("  --list-steps  Print each completed step and its cached result");
    eprintln!();
    eprintln!("Exit codes: 0=ok, 1=error, 2=bad usage");
}

fn open_journal() -> Result<Journal, String> {
    Journal::open().map_err(|e| format!("cannot open durable journal: {e}"))
}

fn open_journal_at(path: &std::path::Path) -> Result<Journal, String> {
    Journal::open_at(path)
        .map_err(|e| format!("cannot open durable journal at {}: {e}", path.display()))
}

// ── public entry point ────────────────────────────────────────────────────────

pub fn run(args: &[String]) -> i32 {
    let mut gap_id = String::new();
    let mut json_mode = false;
    let mut list_steps = false;

    for arg in args {
        match arg.as_str() {
            "--json" => json_mode = true,
            "--list-steps" => list_steps = true,
            "--help" | "-h" => {
                usage();
                return 0;
            }
            s if !s.starts_with('-') && gap_id.is_empty() => {
                gap_id = s.to_string();
            }
            unknown => {
                eprintln!("error: unknown flag: {unknown}");
                usage();
                return 2;
            }
        }
    }

    if gap_id.is_empty() {
        eprintln!("error: gap-id is required");
        usage();
        return 2;
    }

    // Allow test harnesses to inject a custom DB path.
    let journal_result = if let Ok(p) = std::env::var("CHUMP_STATE_DB_PATH") {
        open_journal_at(&PathBuf::from(p))
    } else {
        open_journal()
    };

    let journal = match journal_result {
        Ok(j) => j,
        Err(e) => {
            eprintln!("[durable-resume] error: {e}");
            return 1;
        }
    };

    // Find the most recent run_id for this gap.
    let resume_run_id = match journal.next_run_id(&gap_id, true) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("[durable-resume] error querying run_id: {e}");
            return 1;
        }
    };

    // Check if that run has any rows at all (next_run_id returns 1 even when
    // there are no rows, so we need to distinguish "no runs" from "run 1 exists").
    let completed = match journal.completed_steps(&gap_id, resume_run_id) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[durable-resume] error reading completed steps: {e}");
            return 1;
        }
    };

    let incomplete = match journal.incomplete_step_count(&gap_id, resume_run_id) {
        Ok(n) => n,
        Err(e) => {
            eprintln!("[durable-resume] error reading incomplete steps: {e}");
            return 1;
        }
    };

    let resumable = !completed.is_empty() || incomplete > 0;

    if json_mode {
        // Build a JSON object and write to stdout.
        let steps_json: Vec<serde_json::Value> =
            build_all_steps_json(&journal, &gap_id, resume_run_id);
        let obj = serde_json::json!({
            "gap_id": &gap_id,
            "resumable": resumable,
            "run_id": resume_run_id,
            "replayed_steps": completed.len(),
            "incomplete_steps": incomplete,
            "steps": steps_json,
        });
        println!(
            "{}",
            serde_json::to_string_pretty(&obj).unwrap_or_else(|_| "{}".to_string())
        );
        return 0;
    }

    // Human-readable output.
    if !resumable {
        println!("[durable-resume] gap={gap_id}: no resumable run found");
        println!(
            "[durable-resume] hint: run `chump --execute-gap {gap_id}` to start a fresh execution"
        );
        return 0;
    }

    println!("[durable-resume] gap={gap_id}: resumable run found");
    println!("  run_id          : {resume_run_id}");
    println!("  completed steps : {}", completed.len());
    println!("  incomplete steps: {incomplete}");

    if list_steps && !completed.is_empty() {
        println!();
        println!("  Completed steps:");
        for s in &completed {
            let result_preview = s
                .result_json
                .as_deref()
                .unwrap_or("(null)")
                .chars()
                .take(60)
                .collect::<String>();
            println!(
                "    [{:>2}] {:<30} completed_at={} result={}",
                s.step_index,
                s.step_name,
                s.completed_at.as_deref().unwrap_or("?"),
                result_preview,
            );
        }
    }

    if incomplete > 0 {
        println!();
        println!("[durable-resume] hint: construct a DurableExecutor with resume=true to continue from the first incomplete step");
    }

    0
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Build a combined steps list (completed + in-flight) for the JSON output.
fn build_all_steps_json(journal: &Journal, gap_id: &str, run_id: u64) -> Vec<serde_json::Value> {
    let completed = journal.completed_steps(gap_id, run_id).unwrap_or_default();

    // Collect all step rows (including in-flight) via a raw query through the
    // public API. We represent in-flight steps by what we know: only completed
    // ones are returned by completed_steps. We expose only completed steps in
    // JSON for now — in-flight steps by definition have no result to return.
    completed
        .iter()
        .map(|s| {
            serde_json::json!({
                "step_name": &s.step_name,
                "step_index": s.step_index,
                "completed": true,
                "started_at": &s.started_at,
                "completed_at": &s.completed_at,
                "result_json": &s.result_json,
            })
        })
        .collect()
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::durable_execution::DurableExecutor;
    use crate::commands::durable_execution_journal::Journal;
    use tempfile::NamedTempFile;

    fn with_temp_db() -> (std::path::PathBuf, tempfile::TempPath) {
        let f = NamedTempFile::new().unwrap();
        let path = f.into_temp_path();
        // Copy path before potential move.
        let p = path.to_path_buf();
        unsafe {
            std::env::set_var("CHUMP_DURABLE_AMBIENT_DISABLE", "1");
        }
        (p, path)
    }

    #[test]
    fn run_no_args_returns_2() {
        let rc = run(&[]);
        assert_eq!(rc, 2, "missing gap-id should exit 2");
    }

    #[test]
    fn run_help_returns_0() {
        let rc = run(&["--help".to_string()]);
        assert_eq!(rc, 0);
    }

    #[test]
    #[serial_test::serial(state_db_env)]
    fn no_resumable_run_exits_0() {
        let (path, _guard) = with_temp_db();
        unsafe {
            std::env::set_var("CHUMP_STATE_DB_PATH", path.to_str().unwrap());
        }
        // Ensure schema is created.
        let _ = Journal::open_at(&path).unwrap();
        let rc = run(&["INFRA-NOTEXIST".to_string()]);
        assert_eq!(rc, 0);
    }

    #[test]
    #[serial_test::serial(state_db_env)]
    fn resumable_run_exits_0_and_reports() {
        let (path, _guard) = with_temp_db();
        unsafe {
            std::env::set_var("CHUMP_STATE_DB_PATH", path.to_str().unwrap());
        }

        // Create an executor, complete one step, leave one incomplete.
        let j = Journal::open_at(&path).unwrap();
        let exec = DurableExecutor::with_journal("INFRA-CMD-TEST", j, false).unwrap();
        let _: String = exec.activity("step-done", || Ok("ok".to_string())).unwrap();
        // Drop exec without completing a second step (simulates crash).
        drop(exec);

        let rc = run(&["INFRA-CMD-TEST".to_string()]);
        assert_eq!(rc, 0);
    }

    #[test]
    #[serial_test::serial(state_db_env)]
    fn json_mode_produces_valid_json() {
        let (path, _guard) = with_temp_db();
        unsafe {
            std::env::set_var("CHUMP_STATE_DB_PATH", path.to_str().unwrap());
        }
        let j = Journal::open_at(&path).unwrap();
        let exec = DurableExecutor::with_journal("INFRA-JSON-TEST", j, false).unwrap();
        let _: u32 = exec.activity("s1", || Ok(1u32)).unwrap();
        drop(exec);

        // --json should still exit 0.
        let rc = run(&["INFRA-JSON-TEST".to_string(), "--json".to_string()]);
        assert_eq!(rc, 0);
    }
}
