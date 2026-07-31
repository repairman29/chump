//! ChumpBench runner — DOC-072 / EFFECTIVE-327.
//!
//! Runs a **track** (a repo + a plain-language task + a known-good acceptance check) as one
//! scoreable lap: optionally drive the track's mode engine, grade the acceptance check, tally
//! the human touches during the lap (the CREDIBLE-171 zero-touch metric), and print a scorecard.
//! The scorecard's human-touches-per-lap, trended across the suite, is the readiness number —
//! not CI-green, not a merged PR, but a course completed with no one reaching in.
//!
//! v1 scope: the schema + the grading/scoring harness + `ci-green` grading, proven on the
//! known-good RESCUE/BEAST lap. Engine-drive (`--apply`) shells the mode engine; other
//! acceptance kinds and ambient-event emission are honest follow-ups.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

/// A track: the schema from `e2e/chumpbench/<track>.yaml`.
#[derive(Debug, Deserialize)]
pub struct Track {
    pub id: String,
    pub mode: String,
    pub repo: String,
    #[serde(default)]
    pub stack: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub difficulty: String,
    pub task: String,
    pub acceptance: Acceptance,
    #[serde(default)]
    pub budget: Budget,
}

#[derive(Debug, Deserialize)]
pub struct Acceptance {
    /// ci-green | test-passes | url-live | assertion | comprehension-accuracy
    pub kind: String,
    #[serde(default)]
    pub check: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct Budget {
    #[serde(default)]
    pub max_wall_clock_min: u64,
    #[serde(default)]
    pub max_human_touches: u64,
}

/// The verdict of an acceptance check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Pass,
    Fail,
    Unknown,
}

/// Grade a set of CI check-run conclusions. FAIL if any conclusive run failed; PASS if at least
/// one ran and none failed; UNKNOWN if nothing conclusive ran (e.g. CI is PR-scoped, not on the
/// branch we looked at). Conservative on purpose — a lap only PASSES on real green.
pub fn grade_check_conclusions(conclusions: &[String]) -> Verdict {
    let mut any_ok = false;
    for c in conclusions {
        match c.trim().to_lowercase().as_str() {
            "failure" | "cancelled" | "timed_out" | "action_required" | "startup_failure"
            | "stale" => return Verdict::Fail,
            "success" | "neutral" | "skipped" => any_ok = true,
            _ => {}
        }
    }
    if any_ok {
        Verdict::Pass
    } else {
        Verdict::Unknown
    }
}

/// The overall lap result: FAIL unless acceptance PASSED; then PASS if within the human-touch
/// budget, else PARTIAL (the acceptance was met, but a human had to reach in to get there).
pub fn overall_result(acc: Verdict, human_touches: Option<u64>, max_touches: u64) -> &'static str {
    match acc {
        Verdict::Fail | Verdict::Unknown => "FAIL",
        Verdict::Pass => match human_touches {
            Some(t) if t > max_touches => "PARTIAL",
            _ => "PASS",
        },
    }
}

/// A scored lap.
#[derive(Debug, Serialize)]
pub struct LapScore {
    pub track: String,
    pub mode: String,
    pub repo: String,
    pub acceptance_kind: String,
    pub acceptance_verdict: Verdict,
    pub result: String,
    pub human_touches: Option<u64>,
    pub detail: String,
}

fn gh_bin() -> String {
    std::env::var("CHUMP_BENCH_GH_BIN")
        .or_else(|_| std::env::var("CHUMP_GH_BIN"))
        .unwrap_or_else(|_| "gh".to_string())
}

/// Grade a `ci-green` acceptance: query the repo's default-branch tip check-runs via gh.
fn fetch_ci_verdict(repo: &str) -> (Verdict, String) {
    let branch = Command::new(gh_bin())
        .args([
            "repo",
            "view",
            repo,
            "--json",
            "defaultBranchRef",
            "--jq",
            ".defaultBranchRef.name",
        ])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "main".to_string());
    let out = Command::new(gh_bin())
        .args([
            "api",
            &format!("repos/{repo}/commits/{branch}/check-runs"),
            "--jq",
            ".check_runs[].conclusion",
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let concl: Vec<String> = String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s != "null")
                .collect();
            if concl.is_empty() {
                (
                    Verdict::Unknown,
                    format!("no conclusive CI on {branch} (checks may be PR-scoped)"),
                )
            } else {
                (
                    grade_check_conclusions(&concl),
                    format!("{} check(s) on {branch}: {concl:?}", concl.len()),
                )
            }
        }
        _ => (Verdict::Unknown, "could not query CI via gh".to_string()),
    }
}

/// The clone's base branch name — the remote default the lap branched FROM. Mirrors
/// `improve.rs::detect_default_branch` (symbolic-ref origin/HEAD, then main/master), kept
/// self-contained so the bench runner compiles independently of the improve engine.
fn base_branch(clone: &Path) -> String {
    let cd = clone.to_string_lossy().to_string();
    if let Ok(out) = Command::new("git")
        .args([
            "-C",
            &cd,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_start_matches("origin/")
                .to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    for cand in ["main", "master"] {
        for r in [format!("origin/{cand}"), cand.to_string()] {
            let ok = Command::new("git")
                .args(["-C", &cd, "rev-parse", "--verify", "--quiet", &r])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                return cand.to_string();
            }
        }
    }
    "main".to_string()
}

/// Resolve a rev to a form `git log` accepts, preferring the remote ref over the local branch of
/// the same name (`origin/main` before `main`). Returns None if neither exists.
fn resolve_rev(clone: &Path, name: &str) -> Option<String> {
    let cd = clone.to_string_lossy().to_string();
    for r in [format!("origin/{name}"), name.to_string()] {
        let ok = Command::new("git")
            .args(["-C", &cd, "rev-parse", "--verify", "--quiet", &r])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return Some(r);
        }
    }
    None
}

/// INFRA-3523: the range of commits the LAP itself produced, as a `base..tip` spec for `git log`.
///
/// The improve/rescue engine branches `chump/improve-<key>` off `origin/<default>` and commits the
/// lap's work there (the OS commit carries the `Chump-Agent:` trailer); the shared clone keeps that
/// branch after ship. So the lap's commits are exactly `base..<lap-branch>` — NOT the clone's whole
/// history. Counting `git log origin/HEAD -n50` (the old behavior) tallied the external repo's
/// entire pre-existing default-branch history as human touches (~50), which is the bug this fixes.
///
/// tip = the newest local `chump/*` lap branch if one exists, else HEAD. base = the remote default
/// branch. Returns None when the base can't be resolved (can't scope → caller reports "can't read").
fn lap_commit_range(clone: &Path) -> Option<String> {
    let cd = clone.to_string_lossy().to_string();
    let base = resolve_rev(clone, &base_branch(clone))?;

    // Prefer the lap's own branch (chump/*), newest first; the improve engine names it
    // chump/improve-<key> and leaves it in the clone after ship.
    let tip = Command::new("git")
        .args([
            "-C",
            &cd,
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads/chump/",
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|s| s.trim().to_string())
                .find(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "HEAD".to_string());

    Some(format!("{base}..{tip}"))
}

/// Trailer-based provenance count over the commits in `range` (a `git log` revision range) of a
/// local clone: (human, zero_touch, scanned). A commit carrying `Chump-Agent:` is the OS's; one
/// lacking it (and not a bot) is a human touch (COTG-3.2). The range is scoped to the LAP's own
/// commits (INFRA-3523, see `lap_commit_range`) so the count is the lap's touches, not the clone's
/// entire history. Kept self-contained so the runner compiles independently of the CREDIBLE-171
/// metric; both share the same trailer rule and can be deduped once both land.
fn count_provenance(clone: &Path, range: &str) -> Option<(u64, u64, u64)> {
    let out = Command::new("git")
        .args([
            "-C",
            &clone.to_string_lossy(),
            "log",
            range,
            "-n50",
            "--format=%an%x1f%ae%x1f%b%x1e",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (mut human, mut zt, mut scanned) = (0u64, 0u64, 0u64);
    for rec in text.split('\u{1e}') {
        let rec = rec.trim_matches(|c| c == '\n' || c == '\r');
        if rec.is_empty() {
            continue;
        }
        let f: Vec<&str> = rec.split('\u{1f}').collect();
        if f.len() < 3 {
            continue;
        }
        scanned += 1;
        if f[2].to_lowercase().contains("chump-agent:") {
            zt += 1;
        } else {
            let idl = format!("{} {}", f[0], f[1]).to_lowercase();
            if !(idl.contains("bot") || idl.contains("github-actions")) {
                human += 1;
            }
        }
    }
    Some((human, zt, scanned))
}

/// The local clone the external-improve flow leaves on disk for a repo (if any).
fn local_clone_dir(repo: &str) -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    let slug = repo.replace('/', "_");
    Path::new(&home)
        .join(".chump/external")
        .join(&slug)
        .join("clone")
}

/// Map a process exit code to a verdict: 0 → PASS, non-zero → FAIL, no code (killed / spawn
/// failure) → UNKNOWN. Pure + testable — the core of the `command` acceptance grader.
pub fn verdict_from_exit(code: Option<i32>) -> Verdict {
    match code {
        Some(0) => Verdict::Pass,
        Some(_) => Verdict::Fail,
        None => Verdict::Unknown,
    }
}

/// Grade a `command` acceptance: run the track's `check` as a shell command in `cwd` (the repo's
/// local clone). PASS iff it exits 0. These commands come from OUR own in-repo track YAMLs — a
/// test harness, not untrusted input. UNKNOWN if there's no clone to run in (drive a lap first).
fn grade_command(check: &str, cwd: Option<&Path>) -> (Verdict, String) {
    let Some(dir) = cwd else {
        return (
            Verdict::Unknown,
            "no local clone to run the acceptance command in (drive an --apply lap first)"
                .to_string(),
        );
    };
    if check.trim().is_empty() {
        return (
            Verdict::Unknown,
            "track has no acceptance command".to_string(),
        );
    }
    match Command::new("sh")
        .arg("-c")
        .arg(check)
        .current_dir(dir)
        .output()
    {
        Ok(o) => {
            let v = verdict_from_exit(o.status.code());
            let tail: String = String::from_utf8_lossy(&o.stderr)
                .lines()
                .last()
                .unwrap_or("")
                .chars()
                .take(80)
                .collect();
            let cmd: String = check.chars().take(60).collect();
            let suffix = if tail.is_empty() {
                String::new()
            } else {
                format!(" — {tail}")
            };
            (v, format!("`{cmd}` exit {:?}{suffix}", o.status.code()))
        }
        Err(e) => (
            Verdict::Unknown,
            format!("could not run acceptance command: {e}"),
        ),
    }
}

/// Best-effort human-touch tally for `repo` from a local clone the improve flow left on disk;
/// otherwise None (a driven `--apply` lap produces the count).
fn tally_human_touches(repo: &str) -> (Option<u64>, String) {
    let clone = local_clone_dir(repo);
    if !clone.join(".git").exists() {
        return (
            None,
            "n/a — no local clone (a driven --apply lap produces the touch count)".to_string(),
        );
    }
    // CREDIBLE-183: a CREATE lap (bootstrap:*) is a FRESH repo — there's no base
    // branch to diff against; the whole history IS the lap (the scaffold + the
    // implement commit, both OS-authored, Chump-Agent-trailed). Count over full
    // history. For IMPROVE/RESCUE clones keep the INFRA-3523 base..lap-branch
    // scoping so we don't count the clone's entire upstream history.
    let range = if repo.starts_with("bootstrap:") {
        "HEAD".to_string()
    } else {
        match lap_commit_range(&clone) {
            Some(r) => r,
            None => {
                return (
                    None,
                    "n/a — could not resolve the lap's commit range in local clone".to_string(),
                );
            }
        }
    };
    match count_provenance(&clone, &range) {
        Some((human, zt, scanned)) if scanned > 0 => {
            let ratio = zt as f64 / scanned as f64 * 100.0;
            (
                Some(human),
                format!("{human} human / {zt} zero-touch of {scanned} lap commit(s) ({ratio:.0}% zero-touch) in local clone"),
            )
        }
        Some(_) => (
            None,
            "n/a — no lap commits in local clone (base..lap-branch is empty)".to_string(),
        ),
        None => (
            None,
            "n/a — could not read local clone provenance".to_string(),
        ),
    }
}

/// Load a track from a YAML file.
pub fn load_track(path: &Path) -> Result<Track> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading track {}", path.display()))?;
    serde_yaml::from_str(&text).with_context(|| format!("parsing track {}", path.display()))
}

/// EFFECTIVE-345: task-directed execution for an EXISTING repo. Clone the repo
/// into the dir the scorer runs acceptance in, run `agent-run --slim` with the
/// TRACK's task — so the agent does the *specific* task, not the repo's own gaps
/// (which is what generic `chump improve` would work) — then commit its output
/// with a Chump-Agent trailer so the touch tally proves zero-touch. This is the
/// CREATE `--implement` pattern, but on an existing repo; it's what lets the
/// IMPROVE/FINISH/COMPREHEND tracks satisfy their task-specific acceptance.
fn drive_task_directed(chump: &str, track: &Track) -> Result<()> {
    let dir = local_clone_dir(&track.repo);
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    // Fresh clone each lap.
    let _ = std::fs::remove_dir_all(&dir);
    let dir_str = dir.to_string_lossy().into_owned();
    eprintln!("[bench] cloning {} for a task-directed lap …", track.repo);
    // `gh repo clone` so private repos authenticate; shallow for speed.
    let clone = Command::new("gh")
        .args(["repo", "clone", &track.repo, &dir_str, "--", "--depth", "1"])
        .status()
        .with_context(|| "spawn gh repo clone")?;
    if !clone.success() {
        anyhow::bail!("gh repo clone {} failed", track.repo);
    }
    // The agent gets the TASK (not the acceptance command) and works in the clone.
    let prompt = format!(
        "{}\n\nYou are working in an existing repository (your current directory). \
         Make the change directly — edit or create the necessary files so the task \
         is complete. Do not ask questions; implement fully.",
        track.task
    );
    // Prompt lives OUTSIDE the clone so the agent doesn't treat it as a repo file.
    let prompt_path = dir
        .parent()
        .unwrap_or(dir.as_path())
        .join(".bench-task-prompt.txt");
    std::fs::write(&prompt_path, &prompt).with_context(|| "write task prompt")?;
    let prompt_str = prompt_path.to_string_lossy().into_owned();
    eprintln!(
        "[bench] task-directed agent-run on {} (can take minutes) …",
        track.repo
    );
    let status = Command::new(chump)
        .args([
            "agent-run",
            "--slim",
            "--cwd",
            &dir_str,
            "--prompt-file",
            &prompt_str,
        ])
        // CREATE builds new files; existing-repo tasks may too — re-admit
        // write_file (with its shrink guard) so the agent can create files.
        .env("CHUMP_FREE_TIER_WRITE_FILE", "1")
        .status();
    let _ = std::fs::remove_file(&prompt_path);
    match status {
        Ok(s) if s.success() => eprintln!("[bench] task-directed step completed"),
        Ok(s) => eprintln!(
            "[bench] task-directed step exited non-zero ({:?}) — scoring current state",
            s.code()
        ),
        Err(e) => {
            eprintln!("[bench] task-directed step failed to spawn: {e} — scoring current state")
        }
    }
    // Capture the agent's output as an OS-authored commit (CREDIBLE-183) so the
    // touch tally can prove zero-touch.
    let _ = Command::new("git")
        .args(["-C", &dir_str, "add", "-A"])
        .status();
    let has_changes = Command::new("git")
        .args(["-C", &dir_str, "diff", "--cached", "--quiet"])
        .status()
        .map(|s| !s.success())
        .unwrap_or(false);
    if has_changes {
        let _ = Command::new("git")
            .args([
                "-C",
                &dir_str,
                "-c",
                "gpg.sign=false",
                "commit",
                "-m",
                "feat: implement track task\n\nChump-Agent: bench-implement",
                "--no-verify",
            ])
            .status();
    }
    Ok(())
}

/// Drive the track's mode engine (only on `--apply`). Wires RESCUE/IMPROVE/FINISH →
/// `chump improve` (or, on `--implement`, task-directed `agent-run`, EFFECTIVE-345),
/// CREATE → `chump bootstrap`, COMPREHEND → the `comprehend` engine (or task-directed
/// on `--implement`). On `implement` (EFFECTIVE-341/345), drives `chump agent-run` so
/// the lap does the track's actual task, not just a scaffold or a generic gap.
fn drive_engine(track: &Track, implement: bool) -> Result<()> {
    let chump = std::env::var("CHUMP_BENCH_CHUMP_BIN")
        .or_else(|_| std::env::var("CHUMP_BIN"))
        .unwrap_or_else(|_| "chump".to_string());
    match track.mode.to_uppercase().as_str() {
        // FINISH (complete a half-built repo) shares the improve engine: pointing
        // `chump improve` at an existing clone drives the agent to work the repo
        // toward green — which is exactly "wire the stubbed endpoint + make its
        // test pass" (EFFECTIVE-340). RESCUE (fix broken CI) and IMPROVE (add a
        // feature) are the same operation with different intent.
        "RESCUE" | "IMPROVE" | "FINISH" => {
            // EFFECTIVE-345: --implement runs the TRACK's task on a fresh clone
            // via agent-run (so the acceptance can actually be satisfied). Plain
            // --apply keeps the generic improve engine (works the repo's own gaps).
            if implement {
                return drive_task_directed(&chump, track);
            }
            let status = Command::new(&chump)
                .args(["improve", &track.repo, "--apply"])
                .status()
                .with_context(|| "spawn chump improve")?;
            if !status.success() {
                anyhow::bail!("engine `chump improve {}` exited non-zero", track.repo);
            }
            Ok(())
        }
        "CREATE" => {
            // CREATE tracks carry a `bootstrap:<name>` pseudo-repo — the lap
            // creates the project from the plain-language `task`. Drive the
            // create engine: `chump bootstrap` scaffolds the project (git init +
            // manifest + first commit; the bench passes --no-umbrella-gap) into
            // the same dir the scorer runs the acceptance command in.
            //
            // EFFECTIVE-335 v1: bootstrap SCAFFOLDS but does not IMPLEMENT the
            // tool, so a track whose acceptance runs the generated program will
            // honestly score FAIL post-scaffold — surfacing "implement-after-
            // bootstrap" as the next CREATE layer (a follow-up wires
            // bootstrap → implement so acceptance can pass zero-touch).
            let dir = local_clone_dir(&track.repo);
            if let Some(parent) = dir.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("mkdir {}", parent.display()))?;
            }
            // Bootstrap wants a fresh dir — clear any prior lap's output.
            let _ = std::fs::remove_dir_all(&dir);
            let dir_str = dir.to_string_lossy().into_owned();
            // EFFECTIVE-339: honor the track's stack so the scaffold language
            // matches the acceptance command (e.g. stack: python → a python
            // scaffold, not the Rust default). Unknown/empty stacks fall through
            // to bootstrap's Rust default.
            let template = match track.stack.to_lowercase().as_str() {
                "python" | "py" => Some("python"),
                "node" | "javascript" | "typescript" | "js" | "ts" => Some("node"),
                "rust" | "rs" => Some("rust"),
                _ => None,
            };
            let mut args: Vec<&str> = vec!["bootstrap", track.task.as_str(), "--dir", &dir_str];
            if let Some(t) = template {
                args.push("--template");
                args.push(t);
            }
            // Bench harness flags: no LLM arch decision, and --no-umbrella-gap so
            // repeated laps don't flood the canonical registry with one
            // `Bootstrap: <task>` gap each (EFFECTIVE-339).
            args.push("--skip-arch-decision");
            args.push("--no-umbrella-gap");
            let status = Command::new(&chump)
                .args(&args)
                .status()
                .with_context(|| "spawn chump bootstrap")?;
            if !status.success() {
                anyhow::bail!(
                    "engine `chump bootstrap` exited non-zero for {}",
                    track.repo
                );
            }
            // EFFECTIVE-341: implement-after-bootstrap. Bootstrap only scaffolds;
            // on --implement, drive the coding agent to actually BUILD the tool
            // from the vision so a CREATE lap can pass zero-touch. The agent gets
            // the TASK, NOT the acceptance command — feeding it the grader would
            // be teaching to the test. `agent-run` roots its file tools at --cwd,
            // so edits land in the same scaffold dir the scorer runs acceptance
            // in. A failed/soft implement must NOT fail the drive — we score
            // whatever state the agent left (honest partial).
            if implement {
                let prompt = format!(
                    "{}\n\nThe project is scaffolded in this directory. Implement it \
                     fully so it works end to end: write all necessary source files \
                     and make it runnable from this directory. Do not ask questions — \
                     implement completely.",
                    track.task
                );
                // Write the prompt OUTSIDE the scored clone dir so the agent does
                // not treat it as a project file.
                let prompt_path = dir
                    .parent()
                    .unwrap_or(dir.as_path())
                    .join(".bench-implement-prompt.txt");
                if let Err(e) = std::fs::write(&prompt_path, &prompt) {
                    eprintln!(
                        "[bench] implement: could not write prompt file: {e} — skipping implement"
                    );
                } else {
                    eprintln!(
                        "[bench] implementing {} via agent-run (can take minutes) …",
                        track.repo
                    );
                    let prompt_str = prompt_path.to_string_lossy().into_owned();
                    match Command::new(&chump)
                        // --slim: the free-tier writer profile (EFFECTIVE-342) so
                        // the agent actually WRITES the tool instead of returning
                        // it as text.
                        .args([
                            "agent-run",
                            "--slim",
                            "--cwd",
                            &dir_str,
                            "--prompt-file",
                            &prompt_str,
                        ])
                        // CREATE builds NEW files from scratch. The slim profile
                        // ships patch_file (edit existing) but not write_file, which
                        // patch_file can't substitute for — patching a nonexistent
                        // file fails and the model storms. Re-admit write_file (with
                        // its >50%-shrink guard) so the agent can CREATE the tool.
                        .env("CHUMP_FREE_TIER_WRITE_FILE", "1")
                        .status()
                    {
                        Ok(s) if s.success() => eprintln!("[bench] implement step completed"),
                        Ok(s) => eprintln!(
                            "[bench] implement step exited non-zero ({:?}) — scoring current state",
                            s.code()
                        ),
                        Err(e) => eprintln!(
                            "[bench] implement step failed to spawn: {e} — scoring current state"
                        ),
                    }
                    let _ = std::fs::remove_file(&prompt_path);
                }
                // CREDIBLE-183: capture the agent's working-tree output as an
                // OS-authored commit. The implement agent often leaves files
                // uncommitted (write_file without git_commit); without this its
                // work is invisible to count_provenance and the zero-touch tally
                // reports n/a instead of a provable 0.
                let cd = dir.to_string_lossy().to_string();
                let _ = Command::new("git").args(["-C", &cd, "add", "-A"]).status();
                let has_changes = Command::new("git")
                    .args(["-C", &cd, "diff", "--cached", "--quiet"])
                    .status()
                    .map(|s| !s.success()) // non-zero exit ⇒ staged differences exist
                    .unwrap_or(false);
                if has_changes {
                    let _ = Command::new("git")
                        .args([
                            "-C",
                            &cd,
                            "-c",
                            "gpg.sign=false",
                            "commit",
                            "-m",
                            "feat: implement from vision\n\nChump-Agent: bench-implement",
                            "--no-verify",
                        ])
                        .status();
                }
            }
            Ok(())
        }
        "COMPREHEND" => {
            // EFFECTIVE-345: --implement runs the TRACK's task on a fresh clone
            // (e.g. "produce docs/ONBOARDING_MAP.md") so the agent WRITES the
            // deliverable the acceptance checks for. Plain --apply keeps the
            // read-only comprehend engine (reports, doesn't write).
            if implement {
                return drive_task_directed(&chump, track);
            }
            // COMPREHEND tracks point at an existing repo — the lap *understands*
            // it (no mutation). Drive the comprehension engine: the `comprehend`
            // binary (almanac-organs) runs the wiring/gates/config organs over the
            // clone and prints a report. We point it at the same dir the scorer
            // runs the acceptance command in (`local_clone_dir`) — read-only, so
            // unlike CREATE we must NOT wipe the dir first.
            //
            // EFFECTIVE-336 v1: comprehend REPORTS but does not WRITE the
            // onboarding map, so a track whose acceptance checks for that file
            // will honestly score FAIL post-comprehend — surfacing "write-the-map-
            // after-comprehend" as the next COMPREHEND layer (a follow-up wires
            // comprehend → emit docs/ONBOARDING_MAP.md so acceptance can pass
            // zero-touch). Mirrors the CREATE arm's honest-partial posture.
            let bin = crate::comprehend_tool::comprehend_bin().ok_or_else(|| {
                anyhow::anyhow!("comprehend binary not found (set CHUMP_COMPREHEND_BIN)")
            })?;
            let dir = local_clone_dir(&track.repo);
            let status = Command::new(&bin)
                .arg("--repo")
                .arg(&dir)
                .status()
                .with_context(|| "spawn comprehend")?;
            if !status.success() {
                anyhow::bail!(
                    "engine `comprehend --repo` exited non-zero for {}",
                    track.repo
                );
            }
            Ok(())
        }
        other => {
            anyhow::bail!(
                "unknown bench mode {other} (wired: RESCUE/IMPROVE/CREATE/COMPREHEND/FINISH)"
            )
        }
    }
}

/// Score a track: grade the acceptance check + tally touches. (Does not drive the engine.)
pub fn score_track(track: &Track) -> LapScore {
    let (acc, detail) = match track.acceptance.kind.to_lowercase().as_str() {
        "ci-green" => fetch_ci_verdict(&track.repo),
        // The universal gradeable primitive: run the acceptance command in the repo's clone,
        // PASS iff exit 0. Covers test-passes (cargo/npm test), url-live (curl), the CREATE
        // tool-runs check, and comprehension-accuracy (a validator that the map's paths exist).
        "command" => {
            let d = local_clone_dir(&track.repo);
            let cwd = if d.exists() { Some(d) } else { None };
            grade_command(&track.acceptance.check, cwd.as_deref())
        }
        other => (
            Verdict::Unknown,
            format!("acceptance kind '{other}' not graded yet (v1: ci-green | command)"),
        ),
    };
    let (touches, touch_detail) = tally_human_touches(&track.repo);
    let result = overall_result(acc, touches, track.budget.max_human_touches).to_string();
    LapScore {
        track: track.id.clone(),
        mode: track.mode.clone(),
        repo: track.repo.clone(),
        acceptance_kind: track.acceptance.kind.clone(),
        acceptance_verdict: acc,
        result,
        human_touches: touches,
        detail: format!("{detail}; touches: {touch_detail}"),
    }
}

fn usage() -> i32 {
    eprintln!(
        "chump bench — ChumpBench: run a track as a scoreable lap (DOC-072)\n\n\
USAGE:\n  chump bench run --track <path.yaml> [--apply] [--implement] [--json]\n\n\
FLAGS:\n  \
--track <path>   Path to a track YAML (e2e/chumpbench/<id>.yaml)\n  \
--apply          Drive the track's mode engine first, THEN score (default: score current state)\n  \
--implement      CREATE only: after scaffolding, drive the coding agent to build the tool (implies --apply; slow)\n  \
--json           Machine-readable scorecard"
    );
    2
}

/// CLI entry — dispatched from `main.rs` on `chump bench`.
pub fn run(args: &[String]) -> i32 {
    // CREDIBLE-184: `chump bench heat` runs the whole track suite and prints one
    // aggregated V1 scorecard (the green/red board we drive to green).
    if args.first().map(String::as_str) == Some("heat") {
        return run_heat(&args[1..]);
    }
    // args[0] is the subcommand ("run"); tolerate its absence.
    let mut track_path: Option<String> = None;
    let mut apply = false;
    let mut implement = false;
    let mut json = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "run" => {}
            "--track" => {
                i += 1;
                match args.get(i) {
                    Some(p) => track_path = Some(p.clone()),
                    None => {
                        eprintln!("--track needs a path");
                        return usage();
                    }
                }
            }
            "--apply" => apply = true,
            // --implement drives the coding agent to BUILD the tool after
            // scaffolding (CREATE only, EFFECTIVE-341). Implies --apply.
            "--implement" => {
                apply = true;
                implement = true;
            }
            "--json" => json = true,
            "-h" | "--help" => return usage(),
            other => {
                eprintln!("unknown arg: {other}");
                return usage();
            }
        }
        i += 1;
    }
    let Some(tp) = track_path else {
        eprintln!("a --track <path.yaml> is required");
        return usage();
    };
    let track = match load_track(Path::new(&tp)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("could not load track: {e:#}");
            return 1;
        }
    };

    if apply {
        eprintln!("[bench] driving {} engine on {} …", track.mode, track.repo);
        if let Err(e) = drive_engine(&track, implement) {
            eprintln!("[bench] engine drive failed: {e:#} — scoring current state anyway");
        }
    }

    let score = score_track(&track);
    if json {
        println!(
            "{}",
            serde_json::to_string(&score).unwrap_or_else(|_| "{}".into())
        );
        return 0;
    }
    println!("── ChumpBench lap: {} ──", score.track);
    println!("  mode:       {}  repo: {}", score.mode, score.repo);
    println!("  task:       {}", track.task);
    println!(
        "  acceptance: {} → {:?}",
        score.acceptance_kind, score.acceptance_verdict
    );
    println!(
        "  human touches: {}",
        score
            .human_touches
            .map(|t| t.to_string())
            .unwrap_or_else(|| "n/a".into())
    );
    println!("  RESULT:     {}", score.result);
    println!("  detail:     {}", score.detail);
    0
}

/// Aggregate a heat's per-track scores: (green, total, zero_touch_passes).
/// A green track has `result == "PASS"`; a zero-touch pass additionally proved
/// `human_touches == Some(0)` — the V1 bar is not just green, it's green with a
/// receipt that no one reached in.
fn heat_summary(scores: &[LapScore]) -> (usize, usize, usize) {
    let total = scores.len();
    let green = scores.iter().filter(|s| s.result == "PASS").count();
    let zt = scores
        .iter()
        .filter(|s| s.result == "PASS" && s.human_touches == Some(0))
        .count();
    (green, total, zt)
}

/// CREDIBLE-184: run every track in the suite and print one aggregated V1
/// scorecard — the single green/red board we drive to green. Score-only by
/// default (fast, current state); `--apply`/`--implement` drive each engine
/// first. Exits non-zero unless every track is green, so the loop/CI can gate
/// on "fully green".
fn run_heat(args: &[String]) -> i32 {
    let mut apply = false;
    let mut implement = false;
    let mut json = false;
    let mut dir = "e2e/chumpbench".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--apply" => apply = true,
            "--implement" => {
                apply = true;
                implement = true;
            }
            "--json" => json = true,
            "--dir" => {
                i += 1;
                if let Some(d) = args.get(i) {
                    dir = d.clone();
                }
            }
            "-h" | "--help" => {
                eprintln!(
                    "usage: chump bench heat [--apply] [--implement] [--json] [--dir <path>]"
                );
                return 2;
            }
            other => {
                eprintln!("unknown arg: {other}");
                return 2;
            }
        }
        i += 1;
    }

    let mut paths: Vec<std::path::PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.extension()
                    .map(|x| x == "yaml" || x == "yml")
                    .unwrap_or(false)
            })
            .collect(),
        Err(e) => {
            eprintln!("bench heat: cannot read {dir}: {e}");
            return 1;
        }
    };
    paths.sort();
    if paths.is_empty() {
        eprintln!("bench heat: no tracks in {dir}");
        return 1;
    }

    let mut scores: Vec<LapScore> = Vec::new();
    for p in &paths {
        let track = match load_track(p) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("[heat] skip {}: {e:#}", p.display());
                continue;
            }
        };
        if apply {
            eprintln!("[heat] driving {} on {} …", track.mode, track.repo);
            if let Err(e) = drive_engine(&track, implement) {
                eprintln!(
                    "[heat] {} drive failed: {e:#} — scoring current state",
                    track.id
                );
            }
        }
        scores.push(score_track(&track));
    }

    if json {
        println!(
            "{}",
            serde_json::to_string(&scores).unwrap_or_else(|_| "[]".into())
        );
        let (green, total, _) = heat_summary(&scores);
        return if green == total { 0 } else { 1 };
    }

    let (green, total, zt) = heat_summary(&scores);
    println!("── ChumpBench V1 scorecard — {green}/{total} green ──");
    println!(
        "  {:<32} {:<10} {:<8} {:<6} ACCEPTANCE",
        "TRACK", "MODE", "RESULT", "TOUCH"
    );
    for s in &scores {
        let touch = s
            .human_touches
            .map(|t| t.to_string())
            .unwrap_or_else(|| "n/a".into());
        println!(
            "  {:<32} {:<10} {:<8} {:<6} {} → {:?}",
            s.track, s.mode, s.result, touch, s.acceptance_kind, s.acceptance_verdict
        );
    }
    println!("  ─────");
    println!("  GREEN: {green}/{total}   zero-touch passes: {zt}/{green}");
    if green == total && total > 0 {
        println!("  ✅ V1 scorecard fully green");
        0
    } else {
        println!("  ⛳ {} track(s) still red", total - green);
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lap(result: &str, touches: Option<u64>) -> LapScore {
        LapScore {
            track: "t".into(),
            mode: "CREATE".into(),
            repo: "r".into(),
            acceptance_kind: "command".into(),
            acceptance_verdict: Verdict::Pass,
            result: result.into(),
            human_touches: touches,
            detail: String::new(),
        }
    }

    #[test]
    fn heat_summary_counts_green_and_zero_touch() {
        // green = PASS; zero-touch pass = PASS with a proven touches==0 receipt
        // (a PASS with touches n/a is green but NOT a proven zero-touch pass).
        let scores = vec![lap("PASS", Some(0)), lap("PASS", None), lap("FAIL", None)];
        assert_eq!(heat_summary(&scores), (2, 3, 1));
    }

    #[test]
    fn ci_grading_is_conservative() {
        assert_eq!(
            grade_check_conclusions(&["success".into(), "skipped".into()]),
            Verdict::Pass
        );
        // any failure dominates
        assert_eq!(
            grade_check_conclusions(&["success".into(), "failure".into()]),
            Verdict::Fail
        );
        // nothing conclusive → unknown, never a false pass
        assert_eq!(grade_check_conclusions(&[]), Verdict::Unknown);
        assert_eq!(
            grade_check_conclusions(&["".into(), "null".into()]),
            Verdict::Unknown
        );
    }

    #[test]
    fn overall_result_maps_verdict_and_touch_budget() {
        // acceptance fail → FAIL regardless of touches
        assert_eq!(overall_result(Verdict::Fail, Some(0), 0), "FAIL");
        assert_eq!(overall_result(Verdict::Unknown, Some(0), 0), "FAIL");
        // acceptance pass + within touch budget → PASS
        assert_eq!(overall_result(Verdict::Pass, Some(0), 0), "PASS");
        assert_eq!(overall_result(Verdict::Pass, None, 0), "PASS");
        // acceptance pass but a human had to reach in → PARTIAL (the honest distinction)
        assert_eq!(overall_result(Verdict::Pass, Some(3), 0), "PARTIAL");
    }

    #[test]
    fn track_yaml_round_trips() {
        let y = r#"
id: rescue-beast-ci
mode: RESCUE
repo: repairman29/BEAST-MODE
stack: javascript
state: red-ci
difficulty: medium
task: "CI is red, fix it."
acceptance:
  kind: ci-green
  check: "all checks pass"
budget:
  max_wall_clock_min: 30
  max_human_touches: 0
"#;
        let t: Track = serde_yaml::from_str(y).unwrap();
        assert_eq!(t.id, "rescue-beast-ci");
        assert_eq!(t.mode, "RESCUE");
        assert_eq!(t.acceptance.kind, "ci-green");
        assert_eq!(t.budget.max_human_touches, 0);
    }

    /// INFRA-3523: the touch counter must tally only the LAP's own commits, not the external
    /// clone's entire pre-existing history. Fixture: a repo with N human commits on the base
    /// branch + 1 zero-touch lap commit on a `chump/*` branch → scanned == 1 (the lap commit),
    /// human == 0, zt == 1 — NOT N+1.
    #[test]
    fn touch_count_is_scoped_to_the_lap_not_the_whole_clone() {
        let tmp = std::env::temp_dir().join(format!("chump-bench-inf3523-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let cd = tmp.to_string_lossy().to_string();
        let git = |args: &[&str]| {
            let ok = Command::new("git")
                .args(["-C", &cd])
                .args(args)
                .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00")
                .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00")
                .output()
                .unwrap();
            assert!(
                ok.status.success(),
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&ok.stderr)
            );
        };
        git(&["init", "-q", "-b", "main"]);
        // A distinct HUMAN identity with no trailer — these must NOT be counted.
        git(&["config", "user.name", "Jane Human"]);
        git(&["config", "user.email", "jane@example.com"]);
        // N = 5 pre-existing human commits on the base branch (the clone's inherited history).
        let n = 5;
        for i in 0..n {
            std::fs::write(tmp.join(format!("f{i}.txt")), format!("{i}")).unwrap();
            git(&["add", "-A"]);
            git(&[
                "commit",
                "-q",
                "-m",
                &format!("pre-existing human commit {i}"),
            ]);
        }
        // The lap branches off base and adds ONE commit carrying the zero-touch trailer.
        git(&["checkout", "-q", "-b", "chump/improve-p999"]);
        std::fs::write(tmp.join("lap.txt"), "lap").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "lap work\n\nChump-Agent: chump/v1"]);

        // The scoped range must be base..lap-branch and yield exactly the 1 lap commit.
        let range = lap_commit_range(&tmp).expect("range resolves");
        assert_eq!(
            range, "main..chump/improve-p999",
            "scoped to base..lap-branch"
        );
        let (human, zt, scanned) = count_provenance(&tmp, &range).expect("counts");
        assert_eq!(
            scanned, 1,
            "scanned only the lap's commit, not the {} pre-existing",
            n
        );
        assert_eq!(zt, 1, "the lap commit is zero-touch (carries the trailer)");
        assert_eq!(human, 0, "no human touches in the lap itself");

        // Guard against regression: the OLD full-history count would have scanned N+1.
        let (_, _, full) = count_provenance(&tmp, "chump/improve-p999").expect("full counts");
        assert_eq!(
            full,
            (n + 1) as u64,
            "sanity: unscoped counts every commit (the old bug)"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn command_acceptance_grades_by_exit_code() {
        // pure exit-code mapping
        assert_eq!(verdict_from_exit(Some(0)), Verdict::Pass);
        assert_eq!(verdict_from_exit(Some(1)), Verdict::Fail);
        assert_eq!(verdict_from_exit(Some(127)), Verdict::Fail);
        assert_eq!(verdict_from_exit(None), Verdict::Unknown);
        // live: a real command in a tempdir — exit 0 → PASS, exit 1 → FAIL
        let tmp = std::env::temp_dir();
        assert_eq!(grade_command("true", Some(&tmp)).0, Verdict::Pass);
        assert_eq!(grade_command("false", Some(&tmp)).0, Verdict::Fail);
        // no clone to run in → UNKNOWN, never a false pass
        assert_eq!(grade_command("true", None).0, Verdict::Unknown);
        // empty check → UNKNOWN
        assert_eq!(grade_command("   ", Some(&tmp)).0, Verdict::Unknown);
    }
}
