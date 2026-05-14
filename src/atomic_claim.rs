//! INFRA-468 + INFRA-1025: atomic `chump claim <ID>` — single CLI call.
//!
//! Steps (all in Rust, no shell-out to gap-claim.sh — INFRA-1025):
//!   1. fetch origin/main
//!   2. verify gap exists + is open in state.db (seed via import if missing)
//!   3. binary health probe (chump-binary-unwedge.sh, INFRA-275 wedge prevention)
//!   4. derive a unique per-claim session ID
//!   5. git worktree add to ${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap-lower>
//!   6. repair gitdir back-reference (INFRA-779)
//!      6c. remote-branch guard (AC6: --resume resets to remote tip)
//!   7. write lease:
//!      7a. NATS KV dual-write (opt-in)
//!      7b. write JSON lease file to .chump-locks/
//!      7c. write state.db leases row
//!
//! Each step rolls back prior steps on failure (no half-claim state).

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Args to atomic claim.
#[derive(Debug)]
pub struct ClaimArgs {
    pub gap_id: String,
    /// CSV of repo-relative paths to declare lease scope.
    pub paths: Option<String>,
    /// If branch already exists on the remote, reset HEAD to remote tip and continue
    /// instead of aborting. AC6: handles already-pushed-but-unmerged branch.
    pub resume: bool,
    /// Where to create the linked worktree. Default `/tmp`.
    pub worktree_base: PathBuf,
    /// Main repo root (the parent of `--git-common-dir`).
    pub repo_root: PathBuf,
    /// Git remote (default `origin`).
    pub remote: String,
    /// Base branch (default `main`).
    pub base_branch: String,
    /// Override the auto-derived session ID. Same fallback shape as
    /// fleet/INFRA-461: `claim-<gap>-<pid>-<epoch>`.
    pub session_id: Option<String>,
    /// Skip the chump-doctor binary health probe (tests).
    pub skip_doctor: bool,
    /// Skip state.db drift check / import (tests).
    pub skip_import: bool,
}

impl ClaimArgs {
    pub fn from_argv(args: &[String], repo_root: PathBuf) -> Result<Self> {
        // INFRA-1238: trap -h / --help BEFORE positional validation so
        // `chump claim --help` prints usage and exits 0, not "missing GAP-ID".
        for a in args.iter().skip(1) {
            if a == "--help" || a == "-h" {
                println!(
                    "Usage: chump claim <GAP-ID> [--paths CSV] [--session ID] [--no-doctor] [--no-import]\n\n\
                     Atomic claim: fetch + verify + (doctor) + worktree + lease for <GAP-ID>.\n\n\
                     Options:\n  \
                       --paths CSV    Record path scope (comma-separated globs); enables overlap detection\n  \
                       --session ID   Explicit session ID (default derived from env / pid)\n  \
                       --no-doctor    Skip gap-doctor reconciliation (faster, but skips drift repair)\n  \
                       --no-import    Skip yaml->state.db re-import (faster, but assumes registry is fresh)\n  \
                       -h, --help     Show this help"
                );
                std::process::exit(0);
            }
        }
        // args[0] = "claim", args[1] = <GAP-ID>, then optional flags
        let gap_id = args
            .get(1)
            .ok_or_else(|| anyhow!("missing GAP-ID"))?
            .to_string();
        if gap_id.starts_with("--") {
            bail!("missing GAP-ID (saw flag {gap_id})");
        }
        let mut paths: Option<String> = None;
        let mut session_id: Option<String> = None;
        let mut skip_doctor = false;
        let mut skip_import = false;
        let mut resume = false;

        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--paths" => {
                    paths = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--paths needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--session" => {
                    session_id = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--session needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--skip-doctor" => {
                    skip_doctor = true;
                    i += 1;
                }
                "--skip-import" => {
                    skip_import = true;
                    i += 1;
                }
                "--resume" => {
                    resume = true;
                    i += 1;
                }
                other => bail!("unknown flag: {other}"),
            }
        }

        let worktree_base = std::env::var("CHUMP_WORKTREE_BASE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"));
        let remote = std::env::var("CHUMP_REMOTE").unwrap_or_else(|_| "origin".into());
        let base_branch = std::env::var("CHUMP_BASE_BRANCH").unwrap_or_else(|_| "main".into());

        Ok(Self {
            gap_id,
            paths,
            worktree_base,
            repo_root,
            remote,
            base_branch,
            session_id,
            skip_doctor,
            skip_import,
            resume,
        })
    }
}

/// Outcome of a successful claim.
#[derive(Debug)]
pub struct ClaimReport {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch: String,
    pub session_id: String,
    pub paths: Option<String>,
}

/// Print a friendly multi-line summary suitable for a terminal.
pub fn print_report(r: &ClaimReport) {
    println!();
    println!("✓ claimed {} atomically (INFRA-468)", r.gap_id);
    println!("    worktree : {}", r.worktree_path.display());
    println!("    branch   : {}", r.branch);
    println!("    session  : {}", r.session_id);
    if let Some(p) = &r.paths {
        println!("    paths    : {}", p);
    }
    println!();
    println!("    cd {}", r.worktree_path.display());
    println!();
}

/// Run the atomic claim. Each step is a separate function so the unit
/// tests can exercise individual pieces in isolation.
pub fn run_claim(args: ClaimArgs) -> Result<ClaimReport> {
    // 1. Fetch latest base branch — best-effort; the worktree-add will
    //    fail loudly if origin is unreachable AND no local ref exists.
    let _ = run_git(
        &args.repo_root,
        &["fetch", &args.remote, &args.base_branch, "--quiet"],
    );

    // 2. Verify gap is openable (or seed state.db if drifted).
    if !args.skip_import {
        verify_or_seed_gap(&args.repo_root, &args.gap_id)?;
    }

    // 3. Binary health probe (INFRA-275 wedge prevention).
    if !args.skip_doctor {
        run_doctor_probe(&args.repo_root)?;
    }

    // 4. Session ID — explicit --session flag > derived.
    //
    // Deliberately do NOT honor CHUMP_SESSION_ID env: each `chump claim`
    // is meant to be a fresh isolated session. Operators who want a
    // specific session ID pass --session explicitly. This avoids the
    // surprise where a parent shell's CHUMP_SESSION_ID (e.g. set by
    // bot-merge.sh, or another claim earlier in the same shell) bleeds
    // into the lease and breaks the "one claim = one session" model.
    let session_id = args
        .session_id
        .clone()
        .unwrap_or_else(|| derive_session_id(&args.gap_id));

    // 5. Worktree path + branch name.
    let gap_lower = args.gap_id.to_lowercase();
    let worktree_path = args.worktree_base.join(format!("chump-{}", gap_lower));
    let branch = format!("chump/{}-claim", gap_lower);

    if worktree_path.exists() {
        bail!(
            "worktree path already exists: {}\n  Remove it first with: git worktree remove --force {}",
            worktree_path.display(),
            worktree_path.display()
        );
    }

    // PathBuf-to-str: macOS/Linux paths are normally UTF-8, but
    // CHUMP_WORKTREE_BASE could be set to a non-UTF-8 path. Fail loudly
    // rather than panic with unwrap().
    let worktree_path_str = worktree_path.to_str().ok_or_else(|| {
        anyhow!(
            "worktree path contains non-UTF-8 bytes (likely from CHUMP_WORKTREE_BASE): {}",
            worktree_path.display()
        )
    })?;

    // 6. git worktree add -b <branch> <path> <remote>/<base>
    run_git(
        &args.repo_root,
        &[
            "worktree",
            "add",
            "-b",
            &branch,
            worktree_path_str,
            &format!("{}/{}", args.remote, args.base_branch),
        ],
    )
    .with_context(|| {
        format!(
            "git worktree add failed for {} -> {}",
            branch,
            worktree_path.display()
        )
    })?;

    // 6b. Verify (and repair if needed) the gitdir back-reference.
    // Concurrent `git worktree add` calls from sibling agents can clobber
    // .git/worktrees/<name>/gitdir, causing the new worktree to resolve to
    // the wrong repo root (INFRA-779). Repair is safe: git computes this
    // value deterministically as the canonicalized path of <worktree>/.git.
    verify_and_repair_gitdir(&args.repo_root, &branch, &worktree_path)?;

    // Rollback helper: undo worktree + branch on failure.
    let rollback_wt = |extra: &str| {
        let _ = run_git(
            &args.repo_root,
            &["worktree", "remove", "--force", worktree_path_str],
        );
        let _ = run_git(&args.repo_root, &["branch", "-D", &branch]);
        if !extra.is_empty() {
            eprintln!("[claim] rolled back worktree: {}", extra);
        }
    };

    // 6c. INFRA-1025 AC6: detect existing remote branch. If --resume, reset
    // HEAD to the remote tip and continue; otherwise abort with guidance.
    let remote_has_branch = remote_branch_exists(&args.repo_root, &args.remote, &branch);
    if remote_has_branch {
        if args.resume {
            // Reset the new local branch to match the remote tip so we pick up
            // prior work (e.g. an aborted session that already pushed commits).
            if let Err(e) = run_git(
                &worktree_path,
                &["reset", "--hard", &format!("{}/{}", args.remote, branch)],
            ) {
                rollback_wt(&format!("reset --hard failed: {e}"));
                bail!(
                    "--resume: reset --hard to {}/{} failed: {}",
                    args.remote,
                    branch,
                    e
                );
            }
            eprintln!(
                "[claim] --resume: reset HEAD to {}/{} (existing remote branch)",
                args.remote, branch
            );
        } else {
            rollback_wt("");
            bail!(
                "branch {} already exists on {}.\n  \
                 Pass --resume to reset HEAD to the remote tip and continue from that work.\n  \
                 Or delete the remote branch: gh api repos/OWNER/REPO/git/refs/heads/{} -X DELETE",
                branch,
                args.remote,
                branch
            );
        }
    }

    // 7. INFRA-1025: Write lease atomically in Rust — no shell-out to gap-claim.sh.
    // Order: NATS (cross-machine serialization) → JSON lease file → state.db row.
    // Each step rolls back all prior steps on failure.

    // 7a. NATS KV dual-write (opt-in: CHUMP_NATS_URL must be set).
    let lock_dir = args.repo_root.join(".chump-locks");
    let ambient_log = lock_dir.join("ambient.jsonl");
    let nats_result = nats_dual_write(&args.gap_id, &session_id, Some(&ambient_log))?;
    if nats_result == NatsClaimOutcome::Conflict {
        rollback_wt("");
        bail!(
            "NATS KV conflict: another session holds the atomic claim for {}. \
             Check `chump-coord claim` output.",
            args.gap_id
        );
    }

    // 7b. Write JSON lease file to .chump-locks/<session>.json.
    let lease_file = match write_or_merge_lease(
        &lock_dir,
        &session_id,
        &args.gap_id,
        args.paths.as_deref(),
        14_400, // 4h TTL
        false,
    ) {
        Ok(p) => p,
        Err(e) => {
            rollback_wt(&format!("JSON lease write failed: {e}"));
            return Err(e.context("writing JSON lease file (.chump-locks/)"));
        }
    };

    // 7c. Write state.db leases row.
    if let Err(e) = write_db_claim(
        &args.repo_root,
        &args.gap_id,
        &session_id,
        worktree_path_str,
        14_400,
    ) {
        let _ = std::fs::remove_file(&lease_file);
        rollback_wt(&format!("state.db claim failed: {e}"));
        return Err(e.context("writing state.db leases row"));
    }

    // INFRA-1240: emit gap_claimed ambient event for observability (silent_agent debugging)
    let _ = emit_gap_claimed_event(&args.repo_root, &args.gap_id, &session_id);

    Ok(ClaimReport {
        gap_id: args.gap_id,
        worktree_path,
        branch,
        session_id,
        paths: args.paths,
    })
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// INFRA-1025 AC6: check whether <remote>/<branch> exists on the remote.
/// Uses `git ls-remote --exit-code` which exits 2 when the ref is absent.
/// Best-effort — on network error we assume absent (don't block the claim).
fn remote_branch_exists(repo_root: &Path, remote: &str, branch: &str) -> bool {
    let refspec = format!("refs/heads/{}", branch);
    let out = Command::new("git")
        .args(["ls-remote", "--exit-code", remote, &refspec])
        .current_dir(repo_root)
        .output();
    match out {
        Ok(o) => o.status.success(),
        Err(_) => false,
    }
}

/// INFRA-1025: write the leases row to state.db. Mirrors GapStore::claim()
/// but without requiring a GapStore reference in this module.
/// Best-effort when DB absent (fresh clone has no state.db yet).
fn write_db_claim(
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    worktree: &str,
    ttl_secs: i64,
) -> Result<()> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Ok(());
    }
    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {} for lease write", db_path.display()))?;
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let expires_at = now_secs + ttl_secs;
    conn.execute(
        "INSERT INTO leases(session_id, gap_id, worktree, expires_at)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(session_id) DO UPDATE SET gap_id=excluded.gap_id,
             worktree=excluded.worktree, expires_at=excluded.expires_at",
        rusqlite::params![session_id, gap_id, worktree, expires_at],
    )
    .with_context(|| format!("inserting lease for {} into leases table", gap_id))?;
    Ok(())
}

/// Verify that .git/worktrees/<branch-slug>/gitdir points at <worktree_path>/.git.
/// Repairs the file if wrong (INFRA-779: concurrent sibling claims can clobber it).
///
/// INFRA-1056 hardening:
///   - Retry up to 3 times with short backoff if the back-ref is wrong AFTER
///     repair (i.e. a sibling claim re-clobbered it between our write and read).
///   - Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl so operators
///     can see if/when the race is still happening in the wild.
fn verify_and_repair_gitdir(repo_root: &Path, _branch: &str, worktree_path: &Path) -> Result<()> {
    // The worktrees entry name is the last component of the branch slug
    // (git uses the worktree directory name, not the branch name).
    let wt_name = worktree_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if wt_name.is_empty() {
        return Ok(());
    }

    let gitdir_file = repo_root
        .join(".git")
        .join("worktrees")
        .join(wt_name)
        .join("gitdir");
    if !gitdir_file.exists() {
        return Ok(());
    }

    // git stores the canonical (realpath) value of <worktree>/.git
    let dot_git = worktree_path.join(".git");
    let canonical = std::fs::canonicalize(&dot_git).unwrap_or(dot_git.clone());
    let expected = canonical.to_str().unwrap_or("").to_string();
    if expected.is_empty() {
        return Ok(());
    }

    // Retry loop: INFRA-1056. The race window is the time between our read-
    // back-ref and any concurrent sibling claim's write. 3 attempts × 50ms
    // covers the realistic worst case without blocking the claim path.
    const MAX_ATTEMPTS: usize = 3;
    let mut last_recorded = String::new();
    for attempt in 1..=MAX_ATTEMPTS {
        let recorded = std::fs::read_to_string(&gitdir_file)
            .unwrap_or_default()
            .trim()
            .to_string();
        last_recorded = recorded.clone();

        if recorded == expected {
            if attempt > 1 {
                eprintln!(
                    "[claim] INFRA-1056: gitdir back-ref converged on attempt {attempt} for {wt_name}"
                );
            }
            return Ok(());
        }

        eprintln!(
            "[claim] INFRA-1056 (attempt {attempt}/{MAX_ATTEMPTS}): gitdir mismatch for {wt_name} — repairing\n  was: {recorded}\n  now: {expected}"
        );
        std::fs::write(&gitdir_file, format!("{expected}\n"))
            .with_context(|| format!("repairing gitdir file {}", gitdir_file.display()))?;
        emit_gitdir_repair_event(repo_root, wt_name, &recorded, &expected, attempt);
        emit_gitdir_repaired_event(repo_root, wt_name, &recorded, &expected);

        if attempt < MAX_ATTEMPTS {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    // We attempted 3 repairs and the back-ref still doesn't match. Concurrent
    // sibling activity is overwhelming the repair path. Surface this loudly
    // — the operator needs to know the race is unresolved for this claim.
    bail!(
        "INFRA-1056: gitdir back-ref for {wt_name} did not converge after {MAX_ATTEMPTS} repair attempts\n  expected: {expected}\n  last seen: {last_recorded}\n  Concurrent sibling claims are overwhelming the repair path; release leases and retry."
    );
}

/// Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl. Best-effort —
/// silently no-ops if the file isn't writable. Lets operators measure
/// whether the INFRA-779 race is still firing in production.
fn emit_gitdir_repair_event(repo_root: &Path, wt_name: &str, was: &str, now: &str, attempt: usize) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = format!(
        r#"{{"ts":"{ts}","kind":"worktree_gitdir_repair_fired","worktree":"{wt_name}","was":"{}","now":"{}","attempt":{attempt}}}"#,
        json_escape(was),
        json_escape(now),
    );
    let path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }
}

/// Emit kind=worktree_gitdir_repaired to ambient.jsonl (INFRA-1033).
fn emit_gitdir_repaired_event(repo_root: &Path, wt_name: &str, was: &str, now: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let ts = {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Format as ISO-8601 UTC
        let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
        format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
    };

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"worktree_gitdir_repaired\",\"wt_name\":\"{wt_name}\",\"was\":\"{was}\",\"now\":\"{now}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1240: Emit gap_claimed ambient event for observability.
/// Used to debug silent_agent and lease-race issues.
fn emit_gap_claimed_event(repo_root: &Path, gap_id: &str, session_id: &str) -> Result<()> {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claimed\",\"gap_id\":\"{gap_id}\",\"session_id\":\"{session_id}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
    Ok(())
}

/// Decompose Unix epoch seconds into (year, month, day, hour, min, sec) UTC.
/// Minimal implementation — no external date crate dependency.
fn secs_to_ymdhms(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = secs % 60;
    let mi = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Gregorian calendar from day count since 1970-01-01.
    let mut y = 1970u32;
    let mut rem = days;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let days_in_year = if leap { 366u64 } else { 365u64 };
        if rem < days_in_year {
            break;
        }
        rem -= days_in_year;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31u64,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut mo = 1u32;
    for &md in &month_days {
        if rem < md {
            break;
        }
        rem -= md;
        mo += 1;
    }
    (y, mo, rem as u32 + 1, h as u32, mi as u32, s as u32)
}

fn run_git(cwd: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .with_context(|| format!("spawning git {:?}", args))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("git {} failed: {}", args.join(" "), stderr);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Derive a unique session ID for an atomic claim. Same shape as the
/// INFRA-461 fleet pattern but with a `claim-` prefix so logs / leases
/// distinguish operator-claims from fleet-claims.
fn derive_session_id(gap_id: &str) -> String {
    let pid = std::process::id();
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("claim-{}-{}-{}", gap_id.to_lowercase(), pid, epoch)
}

/// INFRA-965 slice 1 (INFRA-984): port the new-lease-file write from
/// scripts/coord/gap-claim.sh into Rust. Matches the JSON schema used by
/// gap-preflight.sh's reader exactly — session_id, paths, taken_at,
/// expires_at, heartbeat_at, purpose, gap_id. Returns the path of the
/// lease file written.
///
/// This is the simple-case write (no existing lease, no speculative
/// flag). INFRA-985 ports the merge-existing-lease + speculative cases;
/// INFRA-986 ports the NATS KV dual-write. Once all three land, gap-claim.sh
/// can be deleted (INFRA-987).
pub fn write_basic_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    std::fs::create_dir_all(lock_dir)
        .with_context(|| format!("create lock dir {}", lock_dir.display()))?;

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let now_iso = unix_to_iso8601(now_secs);
    let expires_iso = unix_to_iso8601(now_secs.saturating_add(ttl_secs));

    let paths_list: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // Hand-roll the JSON to match gap-claim.sh's output byte-for-byte:
    // two-space indent, trailing newline, key order session_id → paths →
    // taken_at → expires_at → heartbeat_at → purpose → gap_id. Using
    // serde_json::to_string_pretty would change key order (it's BTreeMap
    // for serde_json::Map under that path) and add subtle diffs that
    // would break callers diffing against the existing format.
    let mut json = String::new();
    json.push_str("{\n");
    json.push_str(&format!(
        "  \"session_id\": \"{}\",\n",
        json_escape(session_id)
    ));
    json.push_str("  \"paths\": [");
    if !paths_list.is_empty() {
        json.push('\n');
        for (i, p) in paths_list.iter().enumerate() {
            json.push_str(&format!("    \"{}\"", json_escape(p)));
            if i + 1 < paths_list.len() {
                json.push(',');
            }
            json.push('\n');
        }
        json.push_str("  ");
    }
    json.push_str("],\n");
    json.push_str(&format!("  \"taken_at\": \"{}\",\n", now_iso));
    json.push_str(&format!("  \"expires_at\": \"{}\",\n", expires_iso));
    json.push_str(&format!("  \"heartbeat_at\": \"{}\",\n", now_iso));
    json.push_str(&format!(
        "  \"purpose\": \"gap:{}\",\n",
        json_escape(gap_id)
    ));
    json.push_str(&format!("  \"gap_id\": \"{}\"\n", json_escape(gap_id)));
    json.push_str("}\n");

    let lease_path = lock_dir.join(format!("{}.json", session_id));
    std::fs::write(&lease_path, json)
        .with_context(|| format!("write lease {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-965 slice 2 (INFRA-985): merge-or-write public entrypoint.
///
/// If a lease file already exists at `<lock_dir>/<session_id>.json` (the
/// session already holds a lease — typically from a prior claim earlier
/// in the same shell), update it in place:
///   - set `gap_id` to the new value
///   - merge `paths_csv` into the existing `paths` array, preserving
///     dedup order
///   - preserve the existing `speculative` flag if present (caller can
///     promote via the `speculative` arg here)
///   - clear `pending_new_gap` if it referenced this gap_id
///   - leave taken_at / expires_at / heartbeat_at untouched (the lease
///     keeps its original lifetime; that's why we merge instead of
///     overwriting)
///
/// If no lease file exists, falls through to `write_basic_lease` (slice 1)
/// or its speculative variant when `speculative=true`.
///
/// Returns the path of the lease file.
pub fn write_or_merge_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
    speculative: bool,
) -> Result<PathBuf> {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    if lease_path.exists() {
        return merge_existing_lease(&lease_path, gap_id, paths_csv, speculative);
    }
    if speculative {
        write_speculative_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    } else {
        write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    }
}

/// INFRA-985: speculative lease variant — same shape as basic but with
/// `"speculative": true` appended. `gap-preflight.sh` reads this field to
/// allow concurrent claims from other speculative-mode sessions on the
/// same gap (first-to-land wins).
pub fn write_speculative_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    // Re-use the basic write then rewrite with the extra key. Simpler than
    // duplicating 60 lines of JSON-emit for one extra field.
    let lease_path = write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)?;
    let body = std::fs::read_to_string(&lease_path).with_context(|| {
        format!(
            "read lease for speculative annotation: {}",
            lease_path.display()
        )
    })?;
    // Insert "speculative": true before the closing brace. Body ends with
    // `  "gap_id": "..."\n}\n` — we add a comma to the gap_id line and a
    // new speculative line.
    let trimmed = body.trim_end_matches('\n');
    let with_spec = trimmed
        .strip_suffix('}')
        .map(|s| {
            format!(
                "{},\n  \"speculative\": true\n}}\n",
                s.trim_end_matches(['\n', ' '])
            )
        })
        .ok_or_else(|| anyhow!("unexpected lease body shape: missing closing brace"))?;
    std::fs::write(&lease_path, with_spec)
        .with_context(|| format!("rewrite speculative lease: {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-985: merge new gap_id + paths into an existing lease file in
/// place. Preserves session_id, taken_at, expires_at, heartbeat_at,
/// speculative-flag (with optional promotion), and any extra unknown
/// keys (forward-compat with future schema additions).
fn merge_existing_lease(
    lease_path: &Path,
    gap_id: &str,
    paths_csv: Option<&str>,
    promote_speculative: bool,
) -> Result<PathBuf> {
    let body = std::fs::read_to_string(lease_path)
        .with_context(|| format!("read existing lease {}", lease_path.display()))?;
    let mut val: serde_json::Value = serde_json::from_str(&body)
        .with_context(|| format!("parse existing lease {}", lease_path.display()))?;

    let obj = val.as_object_mut().ok_or_else(|| {
        anyhow!(
            "lease {} is not a JSON object: {}",
            lease_path.display(),
            body
        )
    })?;

    obj.insert(
        "gap_id".to_string(),
        serde_json::Value::String(gap_id.to_string()),
    );

    if promote_speculative {
        obj.insert("speculative".to_string(), serde_json::Value::Bool(true));
    }

    // pending_new_gap cleanup: if it's an object whose "id" matches the
    // gap we're now claiming, drop the pending pointer.
    if let Some(pending) = obj.get("pending_new_gap") {
        if let Some(pid) = pending.get("id").and_then(|v| v.as_str()) {
            if pid == gap_id {
                obj.remove("pending_new_gap");
            }
        }
    }

    // Merge paths.
    let new_paths: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut merged: Vec<String> = obj
        .get("paths")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|p| p.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    for p in new_paths {
        if !merged.contains(&p) {
            merged.push(p);
        }
    }

    obj.insert(
        "paths".to_string(),
        serde_json::Value::Array(merged.into_iter().map(serde_json::Value::String).collect()),
    );

    // Re-serialize with pretty 2-space indent + trailing newline to match
    // the basic-write convention.
    let mut out = serde_json::to_string_pretty(&val).with_context(|| "serialize merged lease")?;
    out.push('\n');
    std::fs::write(lease_path, out)
        .with_context(|| format!("write merged lease {}", lease_path.display()))?;
    Ok(lease_path.to_path_buf())
}

/// INFRA-985: scan a lock dir for OTHER sessions' lease files that claim
/// the same gap_id. Returns (session_id, is_speculative) tuples. Excludes
/// `own_session_id`. Used by the speculative-mode banner to show siblings.
pub fn sibling_lease_holders(
    lock_dir: &Path,
    gap_id: &str,
    own_session_id: &str,
) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        let sid = val
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        if sid == own_session_id {
            continue;
        }
        let gid = val.get("gap_id").and_then(|v| v.as_str()).unwrap_or("");
        if gid != gap_id {
            continue;
        }
        let speculative = val
            .get("speculative")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        out.push((sid, speculative));
    }
    out.sort();
    out
}

fn unix_to_iso8601(unix: u64) -> String {
    // Minimal RFC3339 formatter — no chrono dep required at this seam.
    // Days-since-epoch -> Y/M/D via simple civil_from_days algorithm
    // (Howard Hinnant). Seconds-of-day -> H:M:S directly.
    let days = (unix / 86_400) as i64;
    let sod = (unix % 86_400) as u32;
    let h = sod / 3600;
    let m = (sod % 3600) / 60;
    let s = sod % 60;
    let (y, mo, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, m, s)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    // Hinnant's civil_from_days, adapted from
    // https://howardhinnant.github.io/date_algorithms.html
    let z = z + 719_468;
    let era = if z >= 0 {
        z / 146_097
    } else {
        (z - 146_096) / 146_097
    };
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
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
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Step 2: ensure the gap is in state.db. If missing, attempt to seed
/// via `chump gap import` (uses the per-file YAML mirrors as source of
/// truth — INFRA-470 / INFRA-460 territory).
fn verify_or_seed_gap(repo_root: &Path, gap_id: &str) -> Result<()> {
    // Quick sqlite read.
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        // No DB yet — bootstrap by running `chump gap import`. Caller
        // is presumably trying to seed too, so this is fine.
        return run_chump_gap_import(repo_root);
    }

    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {}", db_path.display()))?;
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .unwrap_or(0);

    if count == 0 {
        // Gap not in DB but YAML may have it — seed.
        run_chump_gap_import(repo_root)?;

        // Re-check.
        let count_after: i64 = conn
            .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
                r.get(0)
            })
            .unwrap_or(0);
        if count_after == 0 {
            bail!(
                "gap {} not found in state.db or docs/gaps/ — reserve it first with `chump gap reserve --domain D --title T`",
                gap_id
            );
        }
    }

    // Reject if already done.
    let status: String = conn
        .query_row("SELECT status FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .unwrap_or_else(|_| "unknown".into());
    if status == "done" {
        bail!(
            "gap {} is already status=done; pick a different gap or reopen it",
            gap_id
        );
    }
    Ok(())
}

fn run_chump_gap_import(repo_root: &Path) -> Result<()> {
    // Use the same binary that's running this code so we're consistent
    // with the build that may have local edits. argv[0] resolves to it.
    let exe = std::env::current_exe().context("locating current chump exe")?;
    let out = Command::new(&exe)
        .args(["gap", "import"])
        .current_dir(repo_root)
        .output()
        .context("spawning chump gap import")?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("chump gap import failed: {}", stderr);
    }
    Ok(())
}

/// Step 3: chump-doctor binary health probe. Skips silently if the
/// script isn't present (e.g. partial checkouts in tests).
fn run_doctor_probe(repo_root: &Path) -> Result<()> {
    let doctor = repo_root.join("scripts/dev/chump-binary-unwedge.sh");
    if !doctor.exists() {
        return Ok(()); // best-effort
    }
    // Use QUIET mode if supported by the script (it greps args for
    // CHUMP_DOCTOR_QUIET=1).
    let out = Command::new("bash")
        .arg(&doctor)
        .env("CHUMP_DOCTOR_QUIET", "1")
        .current_dir(repo_root)
        .output()
        .context("spawning chump-binary-unwedge.sh")?;
    if !out.status.success() {
        // Don't abort — the doctor itself may exit non-zero on
        // fresh-binary "no heal needed" paths in some versions. Log
        // stderr as a warning for visibility.
        let stderr = String::from_utf8_lossy(&out.stderr);
        if !stderr.is_empty() {
            eprintln!("[chump claim] chump-doctor stderr: {}", stderr.trim());
        }
    }
    Ok(())
}

/// INFRA-986: outcome of an attempted NATS KV dual-write.
#[derive(Debug, PartialEq, Eq)]
pub enum NatsClaimOutcome {
    /// CHUMP_NATS_URL unset OR chump-coord binary missing — no NATS attempt.
    /// File-based lease should proceed as the only mechanism.
    Skipped,
    /// chump-coord exit 0 — atomic CAS won (or NATS reachable + key absent).
    Claimed,
    /// chump-coord exit 1 — another session holds the claim. Caller MUST
    /// abort: do not write the file-based lease, do not create the worktree.
    Conflict,
}

/// INFRA-986: port of the FLEET-032 NATS KV dual-write block from
/// scripts/coord/gap-claim.sh. Shells out to the `chump-coord` binary
/// (transitional: future iterations will call the chump-coord crate
/// directly once gap_claim is a stable library entry point — see
/// INFRA-478). Returns the outcome so the caller can decide what to do.
///
/// Discovery:
///   * `CHUMP_NATS_URL` must be set, otherwise skip (single-machine mode).
///   * `chump-coord` must be on PATH (or pointed at by `CHUMP_COORD_BIN`).
///     Both gates skip cleanly — NATS is opt-in.
///
/// On `Conflict`, emits a `gap_claim_nats_conflict` event to
/// `ambient_log_path` (or `.chump-locks/ambient.jsonl` if None). The
/// emitter is intentionally a one-line append: keep the ambient stream
/// the source of truth for cross-machine visibility, no other side
/// effect.
pub fn nats_dual_write(
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_default();
    if nats_url.is_empty() {
        return Ok(NatsClaimOutcome::Skipped);
    }
    let coord_bin = match resolve_coord_bin() {
        Some(p) => p,
        None => return Ok(NatsClaimOutcome::Skipped),
    };
    nats_dual_write_with_bin(&coord_bin, gap_id, session_id, ambient_log_path)
}

/// Test seam: caller-supplied chump-coord path. Production callers go
/// through `nats_dual_write` (above) which honors `CHUMP_NATS_URL` +
/// PATH discovery.
pub(crate) fn nats_dual_write_with_bin(
    coord_bin: &Path,
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    let out = Command::new(coord_bin)
        .args(["claim", gap_id])
        .env("CHUMP_SESSION_ID", session_id)
        .output()
        .with_context(|| format!("spawning {} claim {}", coord_bin.display(), gap_id))?;

    if out.status.success() {
        return Ok(NatsClaimOutcome::Claimed);
    }
    let code = out.status.code().unwrap_or(-1);
    if code == 1 {
        emit_nats_conflict_event(ambient_log_path, gap_id, session_id);
        return Ok(NatsClaimOutcome::Conflict);
    }
    // Any other exit (NATS server unreachable, network blip, transient
    // chump-coord error) is treated like Skipped: do NOT block the claim
    // on infrastructure that's opt-in. Mirrors the shell behavior — the
    // `if !chump-coord claim …` branch only fires on rc=1 conflict; any
    // other failure (rc=2+, signal, no stdout) is silently tolerated.
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !stderr.trim().is_empty() {
        eprintln!(
            "[atomic_claim] chump-coord returned rc={} for gap {}: {}",
            code,
            gap_id,
            stderr.trim()
        );
    }
    Ok(NatsClaimOutcome::Skipped)
}

fn resolve_coord_bin() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("CHUMP_COORD_BIN") {
        if !explicit.is_empty() {
            let p = PathBuf::from(explicit);
            if p.exists() {
                return Some(p);
            }
        }
    }
    // Walk PATH.
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let cand = dir.join("chump-coord");
        if cand.is_file() {
            return Some(cand);
        }
    }
    None
}

fn emit_nats_conflict_event(ambient_log_path: Option<&Path>, gap_id: &str, session_id: &str) {
    let target = ambient_log_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".chump-locks/ambient.jsonl"));
    // Best-effort: ambient append must never break the claim flow.
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claim_nats_conflict\",\"gap_id\":\"{gid}\",\"session_id\":\"{sid}\"}}\n",
        ts = unix_to_iso8601(now),
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&target)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_session_id_shape() {
        let s = derive_session_id("INFRA-123");
        assert!(s.starts_with("claim-infra-123-"));
        // claim-infra-123-<pid>-<epoch> = 4 dash-separated segments
        assert_eq!(s.matches('-').count(), 4);
    }

    #[test]
    fn unix_to_iso8601_matches_known_values() {
        // 2026-05-13T22:00:00Z = 1778709600
        assert_eq!(unix_to_iso8601(1_778_709_600), "2026-05-13T22:00:00Z");
        // Unix epoch
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
        // 2000-01-01T00:00:00Z = 946684800 (post-leap-day-2000 reference)
        assert_eq!(unix_to_iso8601(946_684_800), "2000-01-01T00:00:00Z");
        // Day after leap day 2024 (leap-year math sanity)
        // 2024-03-01T00:00:00Z = 1709251200
        assert_eq!(unix_to_iso8601(1_709_251_200), "2024-03-01T00:00:00Z");
    }

    #[test]
    fn json_escape_handles_metachars() {
        assert_eq!(json_escape(r#"a"b"#), r#"a\"b"#);
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("a\nb"), "a\\nb");
        assert_eq!(json_escape("normal"), "normal");
        assert_eq!(json_escape("with\u{0001}control"), "with\\u0001control");
    }

    #[test]
    fn write_basic_lease_minimal() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-min-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease =
            write_basic_lease(&tmp, "test-session-abc", "INFRA-999", None, 14_400).expect("write");

        // File path is <lock_dir>/<session>.json
        assert!(lease.exists());
        assert_eq!(
            lease.file_name().unwrap().to_str().unwrap(),
            "test-session-abc.json"
        );

        let body = std::fs::read_to_string(&lease).unwrap();
        // Schema key order matches gap-claim.sh — first key is session_id
        assert!(
            body.starts_with("{\n  \"session_id\": \"test-session-abc\","),
            "header mismatch: {body}"
        );
        assert!(body.contains("\"gap_id\": \"INFRA-999\""));
        assert!(body.contains("\"purpose\": \"gap:INFRA-999\""));
        // Empty paths array, inline form
        assert!(body.contains("\"paths\": [],"));
        // Trailing newline
        assert!(body.ends_with("}\n"));
        // taken_at / expires_at / heartbeat_at all present and Z-suffixed
        for key in ["taken_at", "expires_at", "heartbeat_at"] {
            let needle = format!("\"{key}\":");
            assert!(body.contains(&needle), "missing {key} in: {body}");
        }
        assert!(body.contains("Z\""));

        // expires_at is 14400 seconds (4h) after taken_at
        let taken = body
            .split("\"taken_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        let expires = body
            .split("\"expires_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        assert_ne!(taken, expires);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_with_paths() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-paths-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(
            &tmp,
            "s2",
            "INFRA-1",
            Some("src/foo.rs, src/bar.rs,, ,src/baz.rs"), // empty + whitespace entries dropped
            3_600,
        )
        .unwrap();

        let body = std::fs::read_to_string(&lease).unwrap();
        // Multi-line paths array
        assert!(body.contains(
            "\"paths\": [\n    \"src/foo.rs\",\n    \"src/bar.rs\",\n    \"src/baz.rs\"\n  ],"
        ));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_json_parses_roundtrip() {
        // Sanity check that the hand-rolled JSON is actually valid JSON
        // — gap-preflight.sh's reader is python json.load(), so this
        // must round-trip cleanly.
        let tmp = std::env::temp_dir().join(format!(
            "infra984-rt-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(&tmp, "s3", "INFRA-2", Some("a.rs,b.rs"), 7_200).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&body).expect("valid JSON for gap-preflight reader");
        assert_eq!(parsed["session_id"], "s3");
        assert_eq!(parsed["gap_id"], "INFRA-2");
        assert_eq!(parsed["purpose"], "gap:INFRA-2");
        assert_eq!(parsed["paths"], serde_json::json!(["a.rs", "b.rs"]));

        std::fs::remove_dir_all(&tmp).ok();
    }

    // ── INFRA-985 slice 2 tests ─────────────────────────────────────────────

    fn mk_test_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra985-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn write_speculative_lease_appends_flag() {
        let tmp = mk_test_tmp("spec");
        let lease = write_speculative_lease(&tmp, "spec-sess", "INFRA-10", None, 3_600).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["session_id"], "spec-sess");
        assert_eq!(parsed["gap_id"], "INFRA-10");
        // Format check: trailing newline, JSON-parses cleanly (the comma-
        // splice into the basic-write output is fragile if wrong).
        assert!(body.ends_with("}\n"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_existing_lease_dedups_paths() {
        let tmp = mk_test_tmp("merge");
        // Seed: existing lease with paths [a.rs, b.rs] for an old gap_id.
        write_basic_lease(&tmp, "shared-sess", "INFRA-OLD", Some("a.rs,b.rs"), 7_200).unwrap();

        // Now claim a NEW gap on the same session, with overlapping paths.
        let lease = write_or_merge_lease(
            &tmp,
            "shared-sess",
            "INFRA-NEW",
            Some("b.rs, c.rs, a.rs"), // duplicates a.rs+b.rs; adds c.rs
            7_200,
            false,
        )
        .unwrap();

        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        // gap_id rewritten to new
        assert_eq!(parsed["gap_id"], "INFRA-NEW");
        // paths union'd, order preserved (existing first, new at end)
        assert_eq!(
            parsed["paths"],
            serde_json::json!(["a.rs", "b.rs", "c.rs"]),
            "expected union-merge dedup, got: {}",
            parsed["paths"]
        );
        // session_id unchanged
        assert_eq!(parsed["session_id"], "shared-sess");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_promotes_speculative_flag() {
        let tmp = mk_test_tmp("promote");
        // Seed with non-speculative basic lease.
        write_basic_lease(&tmp, "sess-p", "INFRA-A", Some("a.rs"), 7_200).unwrap();

        // Merge with speculative=true should add the flag.
        let lease = write_or_merge_lease(&tmp, "sess-p", "INFRA-B", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["gap_id"], "INFRA-B");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_writes_new_when_no_existing() {
        let tmp = mk_test_tmp("new");
        // No existing lease — falls through to write_basic_lease.
        let lease = write_or_merge_lease(&tmp, "sess-fresh", "INFRA-X", Some("x.rs"), 7_200, false)
            .unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["session_id"], "sess-fresh");
        assert_eq!(parsed["gap_id"], "INFRA-X");
        // No speculative key on the basic path
        assert!(parsed.get("speculative").is_none());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_speculative_falls_through_to_speculative_write() {
        let tmp = mk_test_tmp("new-spec");
        let lease = write_or_merge_lease(&tmp, "sess-spec", "INFRA-Y", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn merge_clears_pending_new_gap_when_id_matches() {
        let tmp = mk_test_tmp("pending");
        let lease_path = tmp.join("sess-pending.json");
        // Hand-craft a lease with pending_new_gap pointing at the gap
        // we're about to claim. gap-claim.sh writes this shape when a
        // session is awaiting reserve completion.
        std::fs::write(
            &lease_path,
            r#"{
  "session_id": "sess-pending",
  "paths": [],
  "taken_at": "2026-05-13T00:00:00Z",
  "expires_at": "2026-05-13T04:00:00Z",
  "heartbeat_at": "2026-05-13T00:00:00Z",
  "purpose": "reserve",
  "gap_id": "",
  "pending_new_gap": {"id": "INFRA-Z", "title": "tbd"}
}
"#,
        )
        .unwrap();

        write_or_merge_lease(&tmp, "sess-pending", "INFRA-Z", None, 7_200, false).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease_path).unwrap()).unwrap();
        assert!(
            parsed.get("pending_new_gap").is_none(),
            "pending_new_gap should be cleared when its id matches the new claim; got: {}",
            parsed
        );
        assert_eq!(parsed["gap_id"], "INFRA-Z");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_finds_others_on_same_gap() {
        let tmp = mk_test_tmp("siblings");
        // Three leases: two claim INFRA-Q (one speculative), one claims a
        // different gap, plus our own.
        write_basic_lease(&tmp, "sib1", "INFRA-Q", None, 7_200).unwrap();
        write_speculative_lease(&tmp, "sib2", "INFRA-Q", None, 7_200).unwrap();
        write_basic_lease(&tmp, "sib3", "INFRA-OTHER", None, 7_200).unwrap();
        write_basic_lease(&tmp, "me", "INFRA-Q", None, 7_200).unwrap();

        let siblings = sibling_lease_holders(&tmp, "INFRA-Q", "me");
        assert_eq!(
            siblings.len(),
            2,
            "expected sib1 + sib2 only; got {siblings:?}"
        );
        let spec_map: std::collections::HashMap<_, _> = siblings.into_iter().collect();
        assert_eq!(spec_map.get("sib1"), Some(&false));
        assert_eq!(spec_map.get("sib2"), Some(&true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_empty_when_no_siblings() {
        let tmp = mk_test_tmp("alone");
        write_basic_lease(&tmp, "me", "INFRA-SOLO", None, 7_200).unwrap();
        assert!(sibling_lease_holders(&tmp, "INFRA-SOLO", "me").is_empty());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn from_argv_minimal() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-123".into()];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-123");
        assert!(args.paths.is_none());
        assert!(!args.skip_doctor);
        assert!(!args.resume);
    }

    #[test]
    fn from_argv_with_flags() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-200".into(),
            "--paths".into(),
            "src/,scripts/".into(),
            "--session".into(),
            "test-session".into(),
            "--skip-doctor".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-200");
        assert_eq!(args.paths.as_deref(), Some("src/,scripts/"));
        assert_eq!(args.session_id.as_deref(), Some("test-session"));
        assert!(args.skip_doctor);
        assert!(!args.resume);
    }

    #[test]
    fn from_argv_resume_flag() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-300".into(), "--resume".into()];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-300");
        assert!(args.resume);
    }

    #[test]
    fn from_argv_missing_gap_id() {
        let argv: Vec<String> = vec!["claim".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }

    #[test]
    fn from_argv_flag_in_gap_id_position() {
        let argv: Vec<String> = vec!["claim".into(), "--paths".into(), "x".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }

    // INFRA-779: verify_and_repair_gitdir repairs a clobbered gitdir file
    #[test]
    fn infra779_repairs_clobbered_gitdir() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-999");
        std::fs::create_dir_all(&wt_path).unwrap();

        // Simulate the worktree .git file and the worktrees entry.
        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-999");
        std::fs::create_dir_all(&wt_entry).unwrap();

        // Write a WRONG gitdir (simulates concurrent clobber).
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, "/private/tmp/chump-OTHER/.git\n").unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-999-claim", &wt_path).unwrap();

        let repaired = std::fs::read_to_string(&gitdir_file).unwrap();
        let repaired = repaired.trim();
        // After repair it must point at the worktree's .git (canonical form).
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        assert_eq!(repaired, canonical.to_str().unwrap());
    }

    #[test]
    fn infra779_noop_when_gitdir_already_correct() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-998");
        std::fs::create_dir_all(&wt_path).unwrap();

        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        let canonical_str = canonical.to_str().unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-998");
        std::fs::create_dir_all(&wt_entry).unwrap();
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, format!("{canonical_str}\n")).unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-998-claim", &wt_path).unwrap();

        // Must remain unchanged.
        let after = std::fs::read_to_string(&gitdir_file).unwrap();
        assert_eq!(after.trim(), canonical_str);
    }

    // ── INFRA-986 NATS dual-write tests ─────────────────────────────────────

    /// Write an executable bash shim at `path` that exits with `rc` and
    /// writes `stderr_msg` to stderr.
    fn write_coord_shim(path: &Path, rc: i32, stderr_msg: &str) {
        use std::os::unix::fs::PermissionsExt;
        let body = format!(
            "#!/usr/bin/env bash\n>&2 printf '%s\\n' \"{}\"\nexit {}\n",
            stderr_msg.replace('"', "\\\""),
            rc
        );
        std::fs::write(path, body).unwrap();
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[test]
    fn nats_dual_write_skipped_when_nats_url_unset() {
        // Belt-and-braces: temporarily clear CHUMP_NATS_URL.
        let saved = std::env::var("CHUMP_NATS_URL").ok();
        std::env::remove_var("CHUMP_NATS_URL");

        let outcome = nats_dual_write("INFRA-986", "test-sess", None).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);

        if let Some(v) = saved {
            std::env::set_var("CHUMP_NATS_URL", v);
        }
    }

    #[test]
    fn nats_dual_write_conflict_emits_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 1, "CONFLICT: another session holds claim");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Conflict);

        let body = std::fs::read_to_string(&amb).expect("ambient must exist after conflict");
        assert!(
            body.contains("\"kind\":\"gap_claim_nats_conflict\""),
            "missing kind in: {body}"
        );
        assert!(body.contains("\"gap_id\":\"INFRA-986\""));
        assert!(body.contains("\"session_id\":\"test-sess\""));
        // Must be valid JSON (one event per line)
        for line in body.lines() {
            let _: serde_json::Value =
                serde_json::from_str(line).unwrap_or_else(|e| panic!("bad json '{line}': {e}"));
        }
    }

    #[test]
    fn nats_dual_write_success_no_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 0, "");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Claimed);
        // On success we must NOT pollute ambient.
        assert!(!amb.exists(), "ambient should not be written on success");
    }

    #[test]
    fn nats_dual_write_transient_error_treated_as_skipped() {
        // Mirrors shell behavior: any rc != 0 && rc != 1 is "infra hiccup,
        // not a conflict" — file lease should proceed.
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 42, "transient NATS error");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);
        assert!(
            !amb.exists(),
            "transient error must not look like a conflict"
        );
    }

    #[test]
    fn resolve_coord_bin_honors_explicit_env() {
        let tmp = tempfile::tempdir().unwrap();
        let fake = tmp.path().join("chump-coord");
        std::fs::write(&fake, b"#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mut p = std::fs::metadata(&fake).unwrap().permissions();
        p.set_mode(0o755);
        std::fs::set_permissions(&fake, p).unwrap();

        let saved = std::env::var("CHUMP_COORD_BIN").ok();
        std::env::set_var("CHUMP_COORD_BIN", &fake);
        let resolved = resolve_coord_bin();
        assert_eq!(resolved.as_deref(), Some(fake.as_path()));
        match saved {
            Some(v) => std::env::set_var("CHUMP_COORD_BIN", v),
            None => std::env::remove_var("CHUMP_COORD_BIN"),
        }
    }
}
