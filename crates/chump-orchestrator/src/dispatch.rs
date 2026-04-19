//! Subprocess spawn for dispatched subagents — AUTO-013 MVP step 2.
//!
//! `dispatch_gap` creates a linked worktree for a gap, claims the lease in
//! that worktree, and spawns a `claude` CLI subprocess with a focused prompt.
//! The spawned agent follows `docs/TEAM_OF_AGENTS.md`: read CLAUDE.md, do the
//! work, ship via `scripts/bot-merge.sh`, reply only with the PR number.
//!
//! Monitor loop + reflection writes land in steps 3-4. This module only
//! returns a `DispatchHandle` — the caller owns tracking.
//!
//! ## Depth-1 enforcement (design doc §2, Q5)
//!
//! Dispatched subagents MUST NOT spawn further subagents. We set
//! `CHUMP_DISPATCH_DEPTH=1` in the subprocess env; a future guard in
//! `dispatch_gap` will refuse when that env var is already set.
//!
//! ## Why `std::process::Command`, not `tokio::process`
//!
//! Step 2 only needs to *start* the subprocess and return a handle. The
//! monitor loop (step 3) is where async polling matters. Keeping this
//! synchronous avoids pulling tokio into the crate for no gain.

use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::Gap;

/// Default cap on lines retained in [`DispatchHandle::stderr_tail`].
/// Anything past this is dropped — PRODUCT-006 only needs a representative
/// sample of WARN/ERROR lines, not the whole transcript.
pub const STDERR_TAIL_CAP: usize = 64;

/// Shared, lock-protected ring of WARN/ERROR lines tailed off a subagent's
/// stderr. Held by both the spawning thread and the [`DispatchHandle`].
pub type StderrTail = Arc<Mutex<Vec<String>>>;

/// Result of [`Spawner::spawn_claude`]: an optional child handle plus the
/// optional stderr-tail buffer the spawner attached.
pub type SpawnResult = (Option<Child>, Option<StderrTail>);

/// Handle returned after a successful spawn. The monitor loop (step 3) will
/// consume these to track outcomes.
///
/// `child` is `Some` for real spawns and `None` for tests / injection-mode
/// runs that skip the actual process fork.
#[derive(Debug)]
pub struct DispatchHandle {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch_name: String,
    pub child_pid: Option<u32>,
    pub started_at_unix: u64,
    /// Held so the child isn't reaped as a zombie before the monitor loop
    /// exists. In step 3 the monitor takes ownership.
    pub child: Option<Child>,
    /// Bounded ring of WARN/ERROR lines captured from the subagent's
    /// stderr. Populated by a background thread spawned in
    /// [`RealSpawner::spawn_claude`]; the monitor reads it when the
    /// subprocess reaches a terminal outcome and feeds the snapshot into
    /// the dispatch reflection (AUTO-013 step 4 — see
    /// [`crate::reflect::DispatchReflection`]).
    ///
    /// `None` for test spawners that don't fork a real process.
    pub stderr_tail: Option<StderrTail>,
}

impl DispatchHandle {
    /// Snapshot the captured stderr tail as a single newline-joined string
    /// (empty when no buffer was attached or no lines matched). Cheap —
    /// holds the mutex only long enough to clone the `Vec`.
    pub fn stderr_tail_snapshot(&self) -> String {
        match &self.stderr_tail {
            Some(buf) => match buf.lock() {
                Ok(g) => g.join("\n"),
                Err(_) => String::new(),
            },
            None => String::new(),
        }
    }
}

/// How to create worktrees + claim leases + spawn the claude CLI. Injecting
/// this makes `dispatch_gap` unit-testable without forking real processes
/// (which would burn budget and require a live `claude` binary).
pub trait Spawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()>;
    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()>;
    /// Returns `(child, stderr_tail)` — the child handle and an optional
    /// shared buffer the spawner attached to a stderr-tailing thread.
    /// Test spawners that don't fork a real process return `(None, None)`.
    fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult>;
}

/// Production spawner: shells out to git, gap-claim.sh, and the `claude` CLI.
pub struct RealSpawner;

impl Spawner for RealSpawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
        let status = Command::new("git")
            .args([
                "worktree",
                "add",
                worktree.to_str().context("worktree path not utf-8")?,
                "-b",
                branch,
                base,
            ])
            .status()
            .context("spawning git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed for {}", worktree.display());
        }
        Ok(())
    }

    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
        // gap-claim.sh refuses from the main worktree root, so cwd MUST be the
        // new linked worktree. That's the caller's contract.
        let script = worktree.join("scripts").join("gap-claim.sh");
        let status = Command::new("bash")
            .arg(script)
            .arg(gap_id)
            .current_dir(worktree)
            .status()
            .context("spawning gap-claim.sh")?;
        if !status.success() {
            bail!("gap-claim.sh failed for {gap_id} in {}", worktree.display());
        }
        Ok(())
    }

    fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // `claude -p <prompt>` is non-interactive. CWD is the worktree.
        // CHUMP_DISPATCH_DEPTH=1 prevents recursive dispatch in the child.
        //
        // stderr is piped + tailed in a background thread so the AUTO-013
        // step-4 dispatch reflection can include WARN/ERROR lines without
        // buffering the whole transcript. The buffer is bounded by
        // [`STDERR_TAIL_CAP`].
        let mut child = Command::new("claude")
            .arg("-p")
            .arg(prompt)
            .current_dir(worktree)
            .env("CHUMP_DISPATCH_DEPTH", "1")
            .stderr(Stdio::piped())
            .spawn()
            .context("spawning claude CLI")?;

        let buf: StderrTail = Arc::new(Mutex::new(Vec::new()));
        if let Some(stderr) = child.stderr.take() {
            let buf_thread = Arc::clone(&buf);
            std::thread::Builder::new()
                .name("orchestrator-stderr-tail".into())
                .spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        // Cheap filter — only retain lines that look like
                        // diagnostic noise. PRODUCT-006 wants signals,
                        // not the full info-stream.
                        let upper = line.to_uppercase();
                        if upper.contains("ERROR")
                            || upper.contains("WARN")
                            || upper.contains("FAIL")
                            || upper.contains("PANIC")
                        {
                            if let Ok(mut g) = buf_thread.lock() {
                                if g.len() >= STDERR_TAIL_CAP {
                                    // Drop oldest; keep the most-recent
                                    // window (terminal failures cluster
                                    // near the end of the transcript).
                                    g.remove(0);
                                }
                                g.push(line);
                            }
                        }
                    }
                })
                .ok(); // best-effort — failing to spawn the tailer must
                       // not abort dispatch.
        }

        Ok((Some(child), Some(buf)))
    }
}

/// Build the prompt handed to the dispatched subagent. See
/// `docs/TEAM_OF_AGENTS.md` — the contract every dispatched subagent follows.
pub fn build_prompt(gap_id: &str) -> String {
    format!(
        "You are a Chump dispatched agent working on gap {gap}. Read CLAUDE.md \
mandatory pre-flight first. The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps.yaml for full acceptance criteria. Do \
the work, then ship via:\n  scripts/bot-merge.sh --gap {gap} --auto-merge\n\
Do not push to the branch after bot-merge.sh runs (atomic-PR \
discipline). After ship, exit. Reply ONLY with the PR number.",
        gap = gap_id
    )
}

/// Derive the worktree path + branch name for a gap. Lowercased, underscores
/// rewritten to hyphens (matching the conventions in musher.sh and the
/// existing `.claude/worktrees/<name>/` tree).
pub fn dispatch_paths(repo_root: &Path, gap_id: &str) -> (PathBuf, String) {
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let worktree = repo_root.join(".claude").join("worktrees").join(&slug);
    let branch = format!("claude/{slug}");
    (worktree, branch)
}

/// Dispatch a single gap. Creates the worktree, claims the lease, spawns
/// `claude -p <prompt>`, returns a handle for the monitor loop.
///
/// `repo_root` is the top-level git repo. `base_ref` is the git ref the new
/// worktree branches off (caller typically passes `"origin/main"`).
pub fn dispatch_gap_with<S: Spawner>(
    spawner: &S,
    gap: &Gap,
    repo_root: &Path,
    base_ref: &str,
) -> Result<DispatchHandle> {
    let (worktree, branch) = dispatch_paths(repo_root, &gap.id);

    spawner
        .create_worktree(&worktree, &branch, base_ref)
        .with_context(|| format!("creating worktree {} for {}", worktree.display(), gap.id))?;

    spawner
        .claim_gap(&worktree, &gap.id)
        .with_context(|| format!("claiming lease for {} in {}", gap.id, worktree.display()))?;

    let prompt = build_prompt(&gap.id);
    let (child, stderr_tail) = spawner
        .spawn_claude(&worktree, &prompt)
        .with_context(|| format!("spawning claude for {}", gap.id))?;

    let pid = child.as_ref().map(|c| c.id());
    let started_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before UNIX epoch")?
        .as_secs();

    Ok(DispatchHandle {
        gap_id: gap.id.clone(),
        worktree_path: worktree,
        branch_name: branch,
        child_pid: pid,
        started_at_unix,
        child,
        stderr_tail,
    })
}

/// Production entry point: dispatch a gap using the real `RealSpawner`.
pub fn dispatch_gap(gap: &Gap, repo_root: &Path, base_ref: &str) -> Result<DispatchHandle> {
    dispatch_gap_with(&RealSpawner, gap, repo_root, base_ref)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Test spawner that records every call and never touches the real
    /// filesystem or forks a process. This is the contract enforcement: the
    /// dispatch flow must call create_worktree → claim_gap → spawn_claude in
    /// order, with the correctly-derived paths.
    #[derive(Default)]
    struct RecordingSpawner {
        calls: RefCell<Vec<String>>,
    }

    impl Spawner for RecordingSpawner {
        fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!(
                "worktree:{}:{}:{}",
                worktree.display(),
                branch,
                base
            ));
            Ok(())
        }
        fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
            self.calls
                .borrow_mut()
                .push(format!("claim:{}:{}", worktree.display(), gap_id));
            Ok(())
        }
        fn spawn_claude(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
            self.calls
                .borrow_mut()
                .push(format!("spawn:{}:{}", worktree.display(), prompt.len()));
            Ok((None, None))
        }
    }

    fn fake_gap(id: &str) -> Gap {
        Gap {
            id: id.into(),
            title: "t".into(),
            priority: "P1".into(),
            effort: "m".into(),
            status: "open".into(),
            depends_on: None,
        }
    }

    #[test]
    fn dispatch_paths_lowercases_and_replaces_underscores() {
        let (wt, branch) = dispatch_paths(Path::new("/repo"), "AUTO_013");
        assert_eq!(wt, PathBuf::from("/repo/.claude/worktrees/auto-013"));
        assert_eq!(branch, "claude/auto-013");
    }

    #[test]
    fn dispatch_calls_steps_in_order() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("AUTO-013");
        let handle = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();

        let calls = spawner.calls.borrow();
        assert_eq!(calls.len(), 3);
        assert!(calls[0].starts_with("worktree:"), "first call = worktree");
        assert!(calls[1].starts_with("claim:"), "second call = claim");
        assert!(calls[2].starts_with("spawn:"), "third call = spawn");

        assert_eq!(handle.gap_id, "AUTO-013");
        assert_eq!(handle.branch_name, "claude/auto-013");
        assert_eq!(
            handle.worktree_path,
            PathBuf::from("/repo/.claude/worktrees/auto-013")
        );
        assert!(handle.child_pid.is_none(), "recording spawner = no pid");
        assert!(handle.started_at_unix > 0);
    }

    #[test]
    fn claim_receives_exact_gap_id() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("EVAL-031");
        let _ = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
        let calls = spawner.calls.borrow();
        assert!(
            calls[1].ends_with(":EVAL-031"),
            "claim must pass exact gap id, got {}",
            calls[1]
        );
    }

    #[test]
    fn build_prompt_contains_gap_id_and_ship_command() {
        let prompt = build_prompt("AUTO-013");
        assert!(prompt.contains("AUTO-013"));
        assert!(prompt.contains("scripts/bot-merge.sh --gap AUTO-013 --auto-merge"));
        assert!(prompt.contains("CLAUDE.md"));
        assert!(prompt.contains("PR number"));
    }

    #[test]
    fn stderr_tail_snapshot_returns_empty_when_no_buffer() {
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: None,
        };
        assert_eq!(h.stderr_tail_snapshot(), "");
    }

    #[test]
    fn stderr_tail_snapshot_joins_lines_with_newlines() {
        let buf = Arc::new(Mutex::new(vec![
            "ERROR: foo".to_string(),
            "WARN: bar".to_string(),
        ]));
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: Some(buf),
        };
        assert_eq!(h.stderr_tail_snapshot(), "ERROR: foo\nWARN: bar");
    }

    #[test]
    fn worktree_create_failure_aborts_claim_and_spawn() {
        struct FailingWorktree;
        impl Spawner for FailingWorktree {
            fn create_worktree(&self, _w: &Path, _b: &str, _r: &str) -> Result<()> {
                bail!("worktree add failed");
            }
            fn claim_gap(&self, _w: &Path, _g: &str) -> Result<()> {
                panic!("must not be called");
            }
            fn spawn_claude(&self, _w: &Path, _p: &str) -> Result<SpawnResult> {
                panic!("must not be called");
            }
        }
        let gap = fake_gap("AUTO-013");
        let err = dispatch_gap_with(&FailingWorktree, &gap, Path::new("/repo"), "origin/main")
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("worktree add failed"), "got: {msg}");
    }
}
