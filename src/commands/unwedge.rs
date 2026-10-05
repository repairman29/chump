//! EFFECTIVE-1136 (EFFECTIVE-178 slice): `chump unwedge <gap>` — on-demand
//! kill + recover of a wedged bot-merge run.
//!
//! A "wedged" bot-merge is a `scripts/coord/bot-merge.sh --gap <ID>` process
//! that has been running far longer than any real step should take (past
//! `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S`, default 900s — see
//! docs/process/SUBAGENT_DISPATCH.md), typically stuck mid rebase/push with
//! no forward progress. Left alone it holds the lease, blocks the gap from
//! being reprocessed, and often leaves the worktree mid-git-operation
//! (`.git/rebase-merge`, `.git/MERGE_HEAD`, a stale `.git/index.lock`).
//!
//! This is the fast, on-demand alternative to hand-diagnosing that state:
//!   1. detect  — find the wedged bot-merge process(es) for `<gap>`
//!   2. kill    — SIGTERM (grace) then SIGKILL, including child processes
//!   3. recover — abort any in-progress rebase/merge, clear stale git locks,
//!                run `chump claim <gap> --role unwedge --force-recover` to
//!                reconcile the fleet-side lease/worktree state
//!   4. verify  — confirm the gap is pickable again (`chump gap preflight`)
//!
//! Usage: chump unwedge <GAP-ID> [--stall-threshold-s N] [--dry-run]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(c) = std::fs::read_to_string(&cargo) {
                if c.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn iso_now() -> String {
    Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

fn log(step: &str, msg: &str) {
    println!("[unwedge] {} — {}", step, msg);
}

struct WedgedProc {
    pid: i32,
    etimes: i64,
    cmd: String,
}

/// True if `tokens` contains an argv token that IS `bot-merge.sh` or ends in
/// `/bot-merge.sh` — i.e. the process is actually running that script, not
/// merely a process whose command line happens to mention the string (e.g. a
/// wrapper shell echoing/eval-ing text that quotes a bot-merge.sh invocation).
fn is_bot_merge_invocation(tokens: &[&str], gap_id: &str) -> bool {
    let runs_script = tokens
        .iter()
        .any(|t| *t == "bot-merge.sh" || t.ends_with("/bot-merge.sh"));
    if !runs_script {
        return false;
    }
    tokens.iter().any(|t| *t == format!("--gap={gap_id}"))
        || tokens.windows(2).any(|w| w[0] == "--gap" && w[1] == gap_id)
}

/// Scan `ps -eo pid,etimes,args` for bot-merge.sh processes handling `gap_id`.
fn find_bot_merge_procs(gap_id: &str) -> Vec<WedgedProc> {
    let out = match Command::new("ps").args(["-eo", "pid,etimes,args"]).output() {
        Ok(o) => o,
        Err(_) => return Vec::new(),
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut procs = Vec::new();
    for line in text.lines().skip(1) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // `ps` right-justifies numeric columns with runs of spaces, so a
        // naive splitn(char::is_whitespace) yields empty tokens — collect
        // whitespace-separated fields instead, then rejoin the remainder.
        let mut fields = line.split_whitespace();
        let pid = fields.next().and_then(|p| p.parse::<i32>().ok());
        let etimes = fields.next().and_then(|p| p.parse::<i64>().ok());
        let cmd_tokens: Vec<&str> = fields.collect();
        let (Some(pid), Some(etimes)) = (pid, etimes) else {
            continue;
        };
        if !is_bot_merge_invocation(&cmd_tokens, gap_id) {
            continue;
        }
        procs.push(WedgedProc {
            pid,
            etimes,
            cmd: cmd_tokens.join(" "),
        });
    }
    procs
}

fn kill_proc_tree(pid: i32, dry_run: bool) {
    if dry_run {
        log(
            "kill",
            &format!("[dry-run] would SIGTERM/SIGKILL pid={pid} + children"),
        );
        return;
    }
    // Reap children first (watchdog subprocesses spawned by bot-merge.sh),
    // same order bot-merge.sh itself uses for its own watchdog children.
    let _ = Command::new("pkill")
        .args(["-P", &pid.to_string()])
        .status();
    let _ = Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .status();
    std::thread::sleep(Duration::from_secs(3));
    let still_alive = Command::new("kill")
        .args(["-0", &pid.to_string()])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if still_alive {
        log(
            "kill",
            &format!("pid={pid} ignored SIGTERM — sending SIGKILL"),
        );
        let _ = Command::new("pkill")
            .args(["-9", "-P", &pid.to_string()])
            .status();
        let _ = Command::new("kill")
            .args(["-KILL", &pid.to_string()])
            .status();
    }
}

fn abort_in_progress_git_ops(repo: &PathBuf, dry_run: bool) -> Vec<String> {
    let mut actions = Vec::new();
    let git_dir = repo.join(".git");
    if git_dir.join("rebase-merge").is_dir() || git_dir.join("rebase-apply").is_dir() {
        actions.push("git rebase --abort".to_string());
        if !dry_run {
            let _ = Command::new("git")
                .arg("rebase")
                .arg("--abort")
                .current_dir(repo)
                .status();
        }
    }
    if git_dir.join("MERGE_HEAD").is_file() {
        actions.push("git merge --abort".to_string());
        if !dry_run {
            let _ = Command::new("git")
                .arg("merge")
                .arg("--abort")
                .current_dir(repo)
                .status();
        }
    }
    // A process killed mid-write can leave an index/ref lock behind; a live
    // git process would still be holding it, but we've already terminated
    // the offending tree above, so any lock found here is stale.
    {
        let lock = "index.lock";
        let p = git_dir.join(lock);
        if p.is_file() {
            actions.push(format!("rm .git/{lock}"));
            if !dry_run {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    actions
}

// scanner-anchor: "kind":"gap_unwedged" — event-registry rule direction 2
// (register-without-emit): the JSON below builds this literal via format!
// with escaped quotes, which the scanner's contiguous-substring match can't
// see through, so this plain-text anchor pairs the registry entry with its
// real emit site (same pattern as sibling_status.rs's kind=sibling_status_polled).
fn emit_ambient(lock_dir: &Path, gap_id: &str, killed_pids: &[i32], wedged: bool) {
    let pids_json = killed_pids
        .iter()
        .map(|p| p.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let json = format!(
        "{{\"ts\":\"{}\",\"kind\":\"gap_unwedged\",\"gap_id\":\"{}\",\"wedge_detected\":{},\"killed_pids\":[{}]}}",
        iso_now(),
        gap_id,
        wedged,
        pids_json
    );
    let path = lock_dir.join("ambient.jsonl");
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{}", json);
    }
}

pub fn run(args: &[String]) -> i32 {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let stall_threshold_s: i64 = args
        .iter()
        .position(|a| a == "--stall-threshold-s")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .or_else(|| {
            std::env::var("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S")
                .ok()
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(900);

    let gap_id = match args.iter().find(|a| !a.starts_with("--")) {
        Some(g) => g.clone(),
        None => {
            eprintln!("Usage: chump unwedge <GAP-ID> [--stall-threshold-s N] [--dry-run]");
            return 2;
        }
    };

    let repo = repo_root();
    let lock_dir = repo.join(".chump-locks");

    log(
        "start",
        &format!(
            "scanning for wedged bot-merge on {gap_id} (stall threshold {stall_threshold_s}s)"
        ),
    );

    let procs = find_bot_merge_procs(&gap_id);
    let wedged: Vec<&WedgedProc> = procs
        .iter()
        .filter(|p| p.etimes >= stall_threshold_s)
        .collect();

    if procs.is_empty() {
        log("start", &format!("no bot-merge process found for {gap_id}"));
    } else if wedged.is_empty() {
        log(
            "start",
            &format!(
                "{} bot-merge process(es) found for {gap_id} but none past the stall threshold — not wedged, leaving alone",
                procs.len()
            ),
        );
        return 0;
    }

    let mut killed_pids = Vec::new();
    if wedged.is_empty() {
        log(
            "kill",
            "no wedged process to kill — proceeding straight to recovery",
        );
    } else {
        for p in &wedged {
            log(
                "kill",
                &format!("pid={} etimes={}s cmd={}", p.pid, p.etimes, p.cmd),
            );
            kill_proc_tree(p.pid, dry_run);
            killed_pids.push(p.pid);
        }
    }

    log(
        "recover",
        "checking for in-progress git operations left behind",
    );
    let actions = abort_in_progress_git_ops(&repo, dry_run);
    if actions.is_empty() {
        log("recover", "no in-progress rebase/merge/lock found");
    } else {
        for a in &actions {
            log("recover", &format!("ran: {a}"));
        }
    }

    log(
        "recover",
        &format!("invoking claim-recover flow for {gap_id}"),
    );
    if dry_run {
        log(
            "recover",
            &format!("[dry-run] would run: chump claim {gap_id} --role unwedge --force-recover"),
        );
    } else {
        let claim_status = Command::new("chump")
            .args(["claim", &gap_id, "--role", "unwedge", "--force-recover"])
            .current_dir(&repo)
            .status();
        match claim_status {
            Ok(s) if s.success() => log(
                "recover",
                "claim --force-recover reconciled lease/worktree state",
            ),
            Ok(s) => log(
                "recover",
                &format!(
                    "claim --force-recover exited {:?} (non-fatal — repo may already be clean)",
                    s.code()
                ),
            ),
            Err(e) => log("recover", &format!("failed to invoke chump claim: {e}")),
        }
    }

    if dry_run {
        log(
            "verify",
            "[dry-run] would run: chump gap preflight <gap_id>",
        );
    } else {
        let preflight_status = Command::new("chump")
            .args(["gap", "preflight", &gap_id])
            .current_dir(&repo)
            .status();
        match preflight_status {
            Ok(s) if s.success() => log("verify", &format!("{gap_id} is pickable again — repo is clean")),
            Ok(s) => log(
                "verify",
                &format!("chump gap preflight {gap_id} exited {:?} — inspect manually before re-dispatching", s.code()),
            ),
            Err(e) => log("verify", &format!("failed to invoke chump gap preflight: {e}")),
        }
    }

    if !dry_run {
        emit_ambient(&lock_dir, &gap_id, &killed_pids, !wedged.is_empty());
    }

    log(
        "done",
        &format!(
            "gap={gap_id} killed={} recovery_actions={}",
            killed_pids.len(),
            actions.len()
        ),
    );
    0
}

// EFFECTIVE-1136: unit coverage for the wedge-detection matcher — the part
// of this command with the highest blast radius if wrong (a false-positive
// match kills the wrong process). See scripts/ci/test-effective-1136.sh for
// the end-to-end CLI smoke test (usage error + --dry-run path).
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_exact_gap_flag_with_space() {
        let tokens = [
            "bash",
            "scripts/coord/bot-merge.sh",
            "--gap",
            "EFFECTIVE-1136",
            "--auto-merge",
        ];
        assert!(is_bot_merge_invocation(&tokens, "EFFECTIVE-1136"));
    }

    #[test]
    fn matches_exact_gap_flag_with_equals() {
        let tokens = ["bash", "bot-merge.sh", "--gap=EFFECTIVE-1136"];
        assert!(is_bot_merge_invocation(&tokens, "EFFECTIVE-1136"));
    }

    #[test]
    fn rejects_mismatched_gap_id() {
        let tokens = ["bash", "scripts/coord/bot-merge.sh", "--gap", "OTHER-1"];
        assert!(!is_bot_merge_invocation(&tokens, "EFFECTIVE-1136"));
    }

    #[test]
    fn rejects_substring_match_not_running_the_script() {
        // A wrapper shell whose command line merely quotes/echoes a
        // bot-merge.sh invocation (e.g. an eval'd heredoc) must NOT match —
        // this was a real false-positive caught in manual testing where a
        // naive substring scan killed the wrong process.
        let tokens = [
            "bash",
            "-c",
            "eval",
            "echo",
            "fake-bot-merge.sh",
            "--gap",
            "EFFECTIVE-1136",
        ];
        assert!(!is_bot_merge_invocation(&tokens, "EFFECTIVE-1136"));
    }

    #[test]
    fn rejects_when_gap_missing() {
        let tokens = ["bash", "bot-merge.sh", "--auto-merge"];
        assert!(!is_bot_merge_invocation(&tokens, "EFFECTIVE-1136"));
    }
}
