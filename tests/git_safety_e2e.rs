//! git_safety_e2e.rs — RESILIENT-256 end-to-end acceptance gate.
//!
//! On 2026-08-09 an agent ran `git reset --hard origin/main` in the shared
//! almanac primary checkout. ~574 insertions across 7 files — uncommitted for
//! 13 hours — were destroyed permanently. `git fsck --lost-found` plus
//! cat-file over every dangling object found nothing: unstaged changes never
//! enter the object store, so there was nothing to recover.
//!
//! `src/git_safety.rs` unit tests carry the classification semantics. This
//! file is the acceptance criterion: it drives the REAL `chump` binary
//! against REAL git repositories and asserts
//!
//!   * the destructive command is REFUSED against a dirty tree (exit 2), and
//!     the refusal names every file it would have destroyed;
//!   * the same command is PERMITTED against a clean tree (exit 0);
//!   * loss classes are not conflated (`reset --hard` cannot touch untracked
//!     files; `clean -fd` cannot touch tracked modifications);
//!   * merely mentioning the command is permitted — a guard with false
//!     positives is a guard that gets disabled, which is how you end up back
//!     at 2026-08-09;
//!   * `chump wip-snapshot` puts the bytes somewhere `reset --hard` cannot
//!     reach, WITHOUT touching the working tree or the index;
//!   * the guard is actually wired into the hook path and the installers.
//!
//! Rust rather than `scripts/ci/test-*.sh` on purpose: chump's Rust-first
//! test policy (INFRA-1306) routes new coverage of chump subcommands into
//! `tests/*.rs`, and `scripts/ci/shell-test-allowlist.txt` is deliberately
//! empty. Nothing here needs shell.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const CHUMP: &str = env!("CARGO_BIN_EXE_chump");

// ───────────────────────────── helpers ────────────────────────────────────

fn tmpdir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "chump-r256-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).expect("mktemp");
    d
}

fn git(dir: &Path, args: &[&str]) -> Output {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("git")
}

fn git_ok(dir: &Path, args: &[&str]) -> String {
    let o = git(dir, args);
    assert!(
        o.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

/// A repository we are allowed to destroy, shaped like the almanac checkout
/// that lost the work.
fn fixture_repo() -> PathBuf {
    let d = tmpdir("fixture");
    git(&d, &["init", "-q", "."]);
    git(&d, &["config", "user.email", "ci@chump.test"]);
    git(&d, &["config", "user.name", "chump ci"]);
    std::fs::create_dir_all(d.join("crates/core")).unwrap();
    std::fs::write(d.join("crates/core/coverage.rs"), "one\n").unwrap();
    std::fs::write(d.join("crates/core/fusion.rs"), "two\n").unwrap();
    std::fs::write(d.join("README.md"), "three\n").unwrap();
    git(&d, &["add", "crates", "README.md"]);
    git(&d, &["commit", "-qm", "init"]);
    d
}

/// Run the guard exactly as the PreToolUse hook would, and return
/// (exit code, combined output).
fn guard(cmd: &str, cwd: &Path) -> (i32, String) {
    let o = Command::new(CHUMP)
        .args(["git-guard", "--check", cmd, "--cwd"])
        .arg(cwd)
        .output()
        .expect("run chump git-guard");
    let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
    s.push_str(&String::from_utf8_lossy(&o.stderr));
    (o.status.code().unwrap_or(-1), s)
}

// ───────────────────── criterion 4: refused dirty / permitted clean ───────

#[test]
fn destructive_command_is_refused_against_a_dirty_tree_and_names_every_file() {
    let repo = fixture_repo();
    std::fs::write(repo.join("crates/core/coverage.rs"), "THE TRUST SIGNAL\n").unwrap();
    std::fs::write(repo.join("crates/core/fusion.rs"), "MODIFIED\n").unwrap();
    std::fs::write(repo.join("README.md"), "MODIFIED\n").unwrap();

    // The 2026-08-09 command, verbatim.
    let (rc, out) = guard("git reset --hard origin/main", &repo);
    assert_eq!(
        rc, 2,
        "reset --hard was NOT refused against a dirty tree:\n{out}"
    );
    for f in [
        "crates/core/coverage.rs",
        "crates/core/fusion.rs",
        "README.md",
    ] {
        assert!(out.contains(f), "refusal did not name {f}:\n{out}");
    }
    assert!(
        out.contains("chump wip-snapshot"),
        "refusal does not tell the agent how to save the work:\n{out}"
    );
    assert!(
        out.contains("CHUMP_ALLOW_DESTRUCTIVE_GIT"),
        "refusal does not name its escape hatch:\n{out}"
    );

    // The forms an agent actually types.
    for cmd in [
        "cd somewhere && git fetch origin && git reset --hard origin/main",
        "git checkout -- .",
        "git restore .",
        "git checkout -f",
    ] {
        let (rc, out) = guard(cmd, &repo);
        assert_eq!(rc, 2, "slipped through: {cmd}\n{out}");
    }

    // `git -C <dirty repo>` retargets the checkout, and the guard follows.
    let elsewhere = tmpdir("elsewhere");
    let (rc, out) = guard(
        &format!("git -C {} reset --hard", repo.display()),
        &elsewhere,
    );
    assert_eq!(rc, 2, "git -C form slipped through:\n{out}");

    // So does `cd <dirty repo> && ...` — the shape agents actually type. The
    // session cwd here is a clean unrelated directory, so a guard that only
    // looked at cwd would confidently permit this.
    let (rc, out) = guard(
        &format!("cd {} && git reset --hard origin/main", repo.display()),
        &elsewhere,
    );
    assert_eq!(rc, 2, "`cd <repo> && reset --hard` slipped through:\n{out}");
    assert!(
        out.contains("crates/core/coverage.rs"),
        "cd-retargeted refusal did not name the files:\n{out}"
    );

    let _ = std::fs::remove_dir_all(&repo);
    let _ = std::fs::remove_dir_all(&elsewhere);
}

#[test]
fn the_same_command_is_permitted_against_a_clean_tree() {
    let repo = fixture_repo();
    assert!(
        git_ok(&repo, &["status", "--porcelain"]).is_empty(),
        "fixture is not clean; this assertion would be meaningless"
    );
    for cmd in [
        "git reset --hard origin/main",
        "git checkout -- .",
        "git clean -fd",
        "git restore .",
        "git checkout -f",
    ] {
        let (rc, out) = guard(cmd, &repo);
        assert_eq!(rc, 0, "clean tree wrongly refused `{cmd}`:\n{out}");
    }
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn loss_classes_are_not_conflated() {
    let repo = fixture_repo();
    std::fs::write(repo.join("scratch.txt"), "untracked\n").unwrap();

    // reset --hard cannot touch untracked files, so refusing here would be
    // a false positive — and false positives are how a guard gets disabled.
    let (rc, out) = guard("git reset --hard", &repo);
    assert_eq!(
        rc, 0,
        "reset --hard wrongly refused over untracked-only:\n{out}"
    );

    // clean -fd destroys exactly those files, and must name them.
    let (rc, out) = guard("git clean -fd", &repo);
    assert_eq!(rc, 2, "clean -fd did not refuse:\n{out}");
    assert!(
        out.contains("scratch.txt"),
        "clean -fd did not name it:\n{out}"
    );

    // ...and conversely, clean -fd over tracked-only modifications is a no-op.
    std::fs::remove_file(repo.join("scratch.txt")).unwrap();
    std::fs::write(repo.join("README.md"), "tracked change\n").unwrap();
    let (rc, out) = guard("git clean -fd", &repo);
    assert_eq!(rc, 0, "clean -fd wrongly refused over tracked-only:\n{out}");

    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn mentioning_the_command_is_not_running_it() {
    let repo = fixture_repo();
    std::fs::write(repo.join("README.md"), "dirty\n").unwrap();
    for cmd in [
        r#"grep -rn "git reset --hard" ."#,
        r#"git commit -m "guard against git reset --hard""#,
        "git status",
        "git stash",
        "git reset --soft HEAD~1",
        "git reset HEAD README.md",
        "git clean -n",
        "git clean --dry-run",
        "git checkout main",
        "git checkout -b feature",
        "git restore --staged README.md",
        "git log --oneline",
        "bash scripts/ci/some-test.sh",
    ] {
        let (rc, out) = guard(cmd, &repo);
        assert_eq!(rc, 0, "FALSE POSITIVE on `{cmd}`:\n{out}");
    }
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn escape_hatch_permits_and_audits() {
    let repo = fixture_repo();
    std::fs::write(repo.join("README.md"), "dirty\n").unwrap();

    let o = Command::new(CHUMP)
        .args(["git-guard", "--check", "git reset --hard", "--cwd"])
        .arg(&repo)
        .env("CHUMP_ALLOW_DESTRUCTIVE_GIT", "1")
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0), "escape hatch did not permit");

    let ambient = std::fs::read_to_string(repo.join(".chump-locks/ambient.jsonl"))
        .expect("escape-hatch use was not audited to ambient.jsonl");
    assert!(
        ambient.contains("destructive_git_override") && ambient.contains("RESILIENT-256"),
        "audit line is missing its kind/gap: {ambient}"
    );
    let _ = std::fs::remove_dir_all(&repo);
}

// ───────────────── criterion 3: bytes reach the object store ──────────────

#[test]
fn wip_snapshot_survives_the_reset_it_exists_to_survive() {
    let repo = fixture_repo();

    // Clean tree → nothing to snapshot, and that is not an error.
    let o = Command::new(CHUMP)
        .args(["wip-snapshot", "--dir"])
        .arg(&repo)
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&o.stdout).contains("clean"));

    std::fs::write(repo.join("crates/core/coverage.rs"), "THE 574 LINES\n").unwrap();
    std::fs::write(repo.join("new-organ.rs"), "untracked too\n").unwrap();

    let o = Command::new(CHUMP)
        .args(["wip-snapshot", "--quiet", "--dir"])
        .arg(&repo)
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0), "wip-snapshot failed");
    let line = String::from_utf8_lossy(&o.stdout).trim().to_string();
    let mut parts = line.split_whitespace();
    let sha = parts.next().expect("snapshot sha").to_string();
    let git_ref = parts.next().expect("snapshot ref").to_string();
    assert!(
        git_ref.starts_with("refs/wip/"),
        "unexpected ref: {git_ref}"
    );

    // Safe against a checkout another session is actively editing: the
    // working tree and the real index must be untouched.
    //
    // Read porcelain WITHOUT trimming: ` M path` carries its status in the
    // first two columns, and trimming the output eats the leading space on
    // the first line — which reads as "staged" and fails the assertion for
    // the wrong reason.
    let st = String::from_utf8_lossy(&git(&repo, &["status", "--porcelain"]).stdout).into_owned();
    assert!(
        st.lines().any(|l| l == " M crates/core/coverage.rs"),
        "worktree changed (expected an unstaged modification): {st:?}"
    );
    assert!(
        st.lines().any(|l| l == "?? new-organ.rs"),
        "worktree changed (expected an untracked file): {st:?}"
    );
    assert!(
        git_ok(&repo, &["diff", "--cached", "--name-only"]).is_empty(),
        "snapshot leaked into the real index"
    );

    // The ref anchors the commit so gc cannot reap it.
    assert_eq!(git_ok(&repo, &["rev-parse", &git_ref]), sha);

    // Now do the thing that destroyed the work on 2026-08-09.
    git(&repo, &["reset", "--hard", "-q", "HEAD"]);
    git(&repo, &["clean", "-fdq"]);
    assert_eq!(
        std::fs::read_to_string(repo.join("crates/core/coverage.rs")).unwrap(),
        "one\n",
        "precondition: the reset really did discard the work on disk"
    );

    // ...and the work is still there.
    assert_eq!(
        git_ok(&repo, &["show", &format!("{sha}:crates/core/coverage.rs")]),
        "THE 574 LINES"
    );
    assert_eq!(
        git_ok(&repo, &["show", &format!("{sha}:new-organ.rs")]),
        "untracked too"
    );

    let _ = std::fs::remove_dir_all(&repo);
}

// ───────────── criterion 2: the primary checkout is read-mostly ───────────

#[test]
fn writes_into_a_shared_primary_checkout_are_refused_but_worktrees_are_free() {
    let primary = fixture_repo();
    let sibling = tmpdir("sibling");
    let _ = std::fs::remove_dir_all(&sibling); // git worktree add wants it absent
    let o = git(
        &primary,
        &["worktree", "add", sibling.to_str().unwrap(), "-b", "sib"],
    );
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));

    let check_write = |file: &Path, env: Option<(&str, &str)>| -> i32 {
        let mut c = Command::new(CHUMP);
        c.args(["git-guard", "--check-write"]).arg(file);
        if let Some((k, v)) = env {
            c.env(k, v);
        }
        c.output().unwrap().status.code().unwrap_or(-1)
    };

    // In the shared primary → refused.
    assert_eq!(
        check_write(&primary.join("README.md"), None),
        2,
        "write into a shared PRIMARY checkout was permitted"
    );
    // In your own worktree → the good case, always allowed.
    assert_eq!(
        check_write(&sibling.join("README.md"), None),
        0,
        "write inside a linked worktree was refused"
    );
    // Coordination surfaces only exist in the primary; they must stay writable
    // or every lease and ambient write in the main checkout breaks.
    for rel in [
        ".chump-locks/claim-x.json",
        ".chump/state.sql",
        "logs/run.log",
    ] {
        assert_eq!(
            check_write(&primary.join(rel), None),
            0,
            "coordination surface {rel} was refused in the primary"
        );
    }
    // Escape hatch.
    assert_eq!(
        check_write(
            &primary.join("README.md"),
            Some(("CHUMP_PRIMARY_WRITE_GUARD", "off"))
        ),
        0,
        "CHUMP_PRIMARY_WRITE_GUARD=off did not disable the write guard"
    );
    // Not a git repo at all → never our business.
    assert_eq!(check_write(Path::new("/etc/hosts"), None), 0);

    let _ = git(
        &primary,
        &["worktree", "remove", "--force", sibling.to_str().unwrap()],
    );
    let _ = std::fs::remove_dir_all(&primary);
    let _ = std::fs::remove_dir_all(&sibling);
}

// ───────────────────────── criterion 1: it is WIRED ───────────────────────

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn the_hook_path_denies_with_a_real_payload() {
    let repo = fixture_repo();
    std::fs::write(repo.join("README.md"), "uncommitted\n").unwrap();

    // Exactly what Claude Code pipes into a PreToolUse hook.
    let payload = format!(
        r#"{{"tool_name":"Bash","cwd":"{}","tool_input":{{"command":"git reset --hard origin/main"}}}}"#,
        repo.display()
    );
    let mut child = Command::new(CHUMP)
        .args(["git-guard", "--hook"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    {
        use std::io::Write;
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(payload.as_bytes())
            .unwrap();
    }
    let o = child.wait_with_output().unwrap();
    assert_eq!(o.status.code(), Some(2), "hook did not block");
    let stdout = String::from_utf8_lossy(&o.stdout);
    assert!(
        stdout.contains("\"permissionDecision\":\"deny\""),
        "hook did not emit the structured deny: {stdout}"
    );
    assert!(
        stdout.contains("README.md"),
        "structured deny did not name the file: {stdout}"
    );
    assert!(
        String::from_utf8_lossy(&o.stderr).contains("REFUSED"),
        "hook did not emit the stderr form older Claude Code versions read"
    );
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn the_fleet_wide_installer_wires_both_hooks_idempotently() {
    let installer = repo_root().join("scripts/setup/install-git-guard-hook.sh");
    assert!(
        installer.is_file(),
        "installer missing: {}",
        installer.display()
    );
    if Command::new("jq").arg("--version").output().is_err() {
        eprintln!("SKIP: jq not installed");
        return;
    }

    let dir = tmpdir("settings");
    let settings = dir.join("settings.json");
    std::fs::write(
        &settings,
        r#"{"hooks":{"PreToolUse":[{"label":"unrelated-existing-hook"}]}}"#,
    )
    .unwrap();

    let run = |args: &[&str]| {
        let o = Command::new("bash")
            .arg(&installer)
            .arg("--user-settings-path")
            .arg(&settings)
            .args(args)
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "installer failed: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    };
    let read = || -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(&settings).unwrap()).unwrap()
    };
    let entries = |v: &serde_json::Value| -> Vec<serde_json::Value> {
        v["hooks"]["PreToolUse"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    };

    run(&[]);
    let v = read();
    let ours: Vec<_> = entries(&v)
        .into_iter()
        .filter(|e| e["_chump_tag"] == "resilient-256-git-guard")
        .collect();
    assert_eq!(ours.len(), 2, "expected a Bash hook and an Edit|Write hook");
    assert!(
        ours.iter().any(|e| e["matcher"] == "Bash"
            && e["hooks"][0]["command"]
                .as_str()
                .unwrap_or("")
                .contains("git-guard --hook")),
        "Bash PreToolUse hook not wired: {ours:?}"
    );
    assert!(
        ours.iter()
            .any(|e| e["matcher"].as_str().unwrap_or("").contains("Edit")
                && e["hooks"][0]["command"]
                    .as_str()
                    .unwrap_or("")
                    .contains("git-guard --hook-write")),
        "Edit|Write PreToolUse hook not wired: {ours:?}"
    );
    // Fail-open: a machine without the binary must not have every Bash call
    // error out.
    assert!(
        ours.iter().all(|e| e["hooks"][0]["command"]
            .as_str()
            .unwrap_or("")
            .contains("command -v chump")),
        "hooks are not fail-open when chump is absent"
    );
    assert!(
        entries(&v)
            .iter()
            .any(|e| e["label"] == "unrelated-existing-hook"),
        "installer clobbered an unrelated hook"
    );

    run(&[]); // idempotence
    assert_eq!(
        entries(&read())
            .iter()
            .filter(|e| e["_chump_tag"] == "resilient-256-git-guard")
            .count(),
        2,
        "installer duplicated entries on re-run"
    );

    run(&["--uninstall"]);
    assert_eq!(
        entries(&read())
            .iter()
            .filter(|e| e["_chump_tag"] == "resilient-256-git-guard")
            .count(),
        0,
        "--uninstall left our entries behind"
    );
    assert!(
        entries(&read())
            .iter()
            .any(|e| e["label"] == "unrelated-existing-hook"),
        "--uninstall removed someone else's hook"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_guard_and_the_watchdog_are_reachable_from_the_repo() {
    let root = repo_root();

    // main.rs dispatch — without it the subcommand does not exist.
    let main_rs = std::fs::read_to_string(root.join("src/main.rs")).unwrap();
    assert!(
        main_rs.contains("git_safety::run_cli"),
        "src/main.rs does not dispatch `chump git-guard`"
    );
    assert!(
        main_rs.contains("git_safety::run_snapshot_cli"),
        "src/main.rs does not dispatch `chump wip-snapshot`"
    );

    // Repo-local wiring: chump's own agents get the guard with no install step.
    let local: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(root.join(".claude/settings.json")).unwrap())
            .unwrap();
    let wired = local["hooks"]["PreToolUse"]
        .as_array()
        .map(|a| {
            a.iter().any(|e| {
                e["hooks"][0]["command"]
                    .as_str()
                    .unwrap_or("")
                    .contains("git-guard")
            })
        })
        .unwrap_or(false);
    assert!(wired, ".claude/settings.json does not wire the guard");

    // Criterion 3's operational surface.
    for rel in [
        "scripts/ops/uncommitted-wip-watchdog.sh",
        "scripts/setup/install-wip-watchdog-launchd.sh",
        "scripts/setup/install-git-guard-hook.sh",
        "scripts/dev/own-worktree.sh",
    ] {
        let p = root.join(rel);
        assert!(p.is_file(), "missing {rel}");
        let o = Command::new("bash").arg("-n").arg(&p).output().unwrap();
        assert!(
            o.status.success(),
            "{rel} is not valid bash: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    }

    // A watchdog nothing grades is a watchdog that dies quietly.
    let hb =
        std::fs::read_to_string(root.join("scripts/ops/reaper-heartbeat-watchdog.sh")).unwrap();
    assert!(
        hb.contains("wip)"),
        "the wip watchdog has no threshold in reaper-heartbeat-watchdog.sh"
    );
    assert!(
        hb.contains("distill wip") || hb.contains(" wip)"),
        "the wip watchdog is not in the heartbeat watchdog's default TARGETS"
    );

    // Every event kind the new organs emit must be registered (INFRA-754).
    let registry =
        std::fs::read_to_string(root.join("docs/observability/EVENT_REGISTRY.yaml")).unwrap();
    for kind in [
        "wip_unprotected",
        "wip_snapshotted",
        "destructive_git_override",
    ] {
        assert!(
            registry.contains(&format!("kind: {kind}")),
            "event kind {kind} is not registered"
        );
    }
}

// ───────────────── snapshot dedup + retention (RESILIENT-256 follow-up) ────
//
// The watchdog snapshots whenever dirty work is idle past its threshold, and
// idle work stays idle — so before dedup, an untouched dirty checkout minted a
// fresh ANCHORED ref on every single run. At the original 30-minute cadence
// across ~40 checkouts that is roughly 1,900 refs/day, and the point of the
// follow-up was to run FAR more often than that. Without these two properties
// the tighter cadence is unaffordable.

fn snap(dir: &Path, retain: Option<&str>) -> String {
    let mut c = Command::new(CHUMP);
    c.args(["wip-snapshot", "--dir"]).arg(dir).arg("--quiet");
    if let Some(r) = retain {
        c.env("CHUMP_WIP_RETAIN", r);
    }
    let o = c.output().expect("run chump wip-snapshot");
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

fn wip_ref_count(dir: &Path) -> usize {
    git_ok(dir, &["for-each-ref", "--format=%(refname)", "refs/wip/"])
        .lines()
        .filter(|l| !l.trim().is_empty())
        .count()
}

#[test]
fn an_unchanged_dirty_tree_is_snapshotted_once_not_once_per_run() {
    let d = fixture_repo();
    std::fs::write(d.join("README.md"), "dirty\n").unwrap();

    let first = snap(&d, None);
    assert!(!first.is_empty(), "the first snapshot must be recorded");
    // Two more runs with byte-identical content. commit-tree stamps a
    // timestamp, so without tree-level dedup each of these mints a new commit
    // and a new ref even though nothing changed.
    assert!(
        snap(&d, None).is_empty(),
        "an unchanged tree must not re-snapshot"
    );
    assert!(
        snap(&d, None).is_empty(),
        "still unchanged, still nothing new"
    );
    assert_eq!(wip_ref_count(&d), 1, "three runs, one ref");
}

#[test]
fn changed_content_still_produces_a_new_snapshot() {
    // The dedup must not be so eager that it stops protecting real edits —
    // that would turn a safety net into a silent no-op, which is worse than
    // having none.
    let d = fixture_repo();
    std::fs::write(d.join("README.md"), "first\n").unwrap();
    assert!(!snap(&d, None).is_empty());
    std::fs::write(d.join("README.md"), "second\n").unwrap();
    assert!(!snap(&d, None).is_empty(), "an edit MUST be captured");
    assert_eq!(wip_ref_count(&d), 2);
}

#[test]
fn retention_caps_the_refs_and_keeps_the_newest() {
    let d = fixture_repo();
    for i in 0..12 {
        std::fs::write(d.join("README.md"), format!("v{i}\n")).unwrap();
        snap(&d, Some("4"));
    }
    assert_eq!(wip_ref_count(&d), 4, "retention must cap the ref set");

    // Capping is only useful if it keeps the RIGHT ones. The newest snapshot
    // is the one an operator reaches for after a destructive command.
    let newest = git_ok(
        &d,
        &[
            "for-each-ref",
            "--sort=-refname",
            "--count=1",
            "--format=%(objectname)",
            "refs/wip/",
        ],
    );
    let body = git_ok(&d, &["show", &format!("{}:README.md", newest.trim())]);
    assert_eq!(
        body.trim(),
        "v11",
        "the most recent work must survive pruning"
    );
}

#[test]
fn retention_can_be_disabled() {
    // 0 = keep everything, for anyone who would rather pay the refs than risk
    // losing a checkpoint.
    let d = fixture_repo();
    for i in 0..6 {
        std::fs::write(d.join("README.md"), format!("v{i}\n")).unwrap();
        snap(&d, Some("0"));
    }
    assert_eq!(wip_ref_count(&d), 6, "retain=0 must keep every snapshot");
}
