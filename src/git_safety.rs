//! git_safety.rs — RESILIENT-256 (2026-08-09)
//!
//! On 2026-08-09 an agent ran `git reset --hard origin/main` in the SHARED
//! almanac primary checkout. ~574 insertions across 7 files — a coverage
//! trust-signal for MCP responses, authored ~13 hours earlier and never
//! committed — were destroyed. A second session's in-flight work died in the
//! same reset. Recovery was attempted and is impossible: `git fsck
//! --lost-found` plus `cat-file` over every dangling commit/tree/blob found
//! nothing, because **unstaged changes never enter the object store**. There
//! is no reflog entry, no stash, no dangling blob. The bytes are gone.
//!
//! Three failures stacked, and the reset is the least interesting:
//!
//!   1. Work sat uncommitted for 13 hours. Unstaged changes are the one
//!      class git cannot recover.
//!   2. The agent worked in the PRIMARY checkout other sessions share
//!      instead of its own worktree.
//!   3. `git reset --hard` ran against a dirty tree with no check.
//!
//! Git offers **no pre-reset hook**, so a hook-based fix inside git is
//! impossible. This module therefore ships two organs, weighted the way the
//! failure analysis demands:
//!
//!   * [`snapshot`] (load-bearing) — writes a checkout's dirty state into
//!     the object store under `refs/wip/…` WITHOUT touching the working tree
//!     or the index. Once bytes are in the object store, recovery stays
//!     possible even when the destructive command is entirely legitimate.
//!     This is what makes failure #1 survivable.
//!
//!   * [`guard`] (the seatbelt) — classifies a shell command as
//!     destructive-to-uncommitted-work and refuses it when the target
//!     checkout is dirty, naming every file it would destroy. Also refuses
//!     Edit/Write into a shared PRIMARY checkout (failure #2), because the
//!     primary is read-mostly when another session may hold work there.
//!
//! Pattern follows INFRA-825 (`version::fail_if_stale_for_destructive`):
//! the decision logic is Rust in the binary with unit tests, the wiring is
//! asserted by a shell CI gate
//! (`scripts/ci/test-git-destructive-guard.sh`), and the escape hatch is a
//! named env var whose use is audited into `ambient.jsonl`.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Env hatch: skip the refusal entirely. Audited — every use emits a
/// `kind=destructive_git_override` event into ambient.jsonl.
pub const OVERRIDE_ENV: &str = "CHUMP_ALLOW_DESTRUCTIVE_GIT";

/// Env knob for the shared-primary-checkout write guard: `deny` (default),
/// `warn`, or `off`.
pub const WRITE_GUARD_ENV: &str = "CHUMP_PRIMARY_WRITE_GUARD";

/// Hours a linked worktree may go untouched before we stop treating it as a
/// live sibling session. Override with `CHUMP_SIBLING_WINDOW_H`.
pub const DEFAULT_SIBLING_WINDOW_H: u64 = 6;

/// How many `refs/wip/<branch>/…` snapshots to retain per branch.
///
/// Snapshots are anchored so gc cannot reap them, so without a cap they grow
/// forever: the watchdog re-snapshots whenever work is idle past its
/// threshold, and idle work stays idle, so an untouched dirty checkout
/// produced a fresh ref on EVERY run. At the shipped 30-minute cadence across
/// ~40 checkouts that is ~1,900 refs/day, and the whole point of tightening
/// the cadence is to make it more frequent still. Override with
/// `CHUMP_WIP_RETAIN`; 0 disables pruning.
pub const DEFAULT_WIP_RETAIN: usize = 20;

/// Paths under a primary checkout that are *supposed* to be written there —
/// coordination surfaces that have no meaning inside a linked worktree.
/// Writing these in the primary is never a doctrine violation.
const PRIMARY_WRITE_ALLOWLIST: &[&str] = &[".chump-locks/", ".chump/", "logs/", ".git/"];

// ───────────────────────────── command classification ─────────────────────

/// The class of destruction a command performs. Each class destroys a
/// *different* set of files, which is why the guard classifies instead of
/// pattern-matching a blocklist: naming the wrong files is how a guard
/// trains people to ignore it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DestructiveKind {
    /// `git reset --hard` — discards tracked modifications AND the index.
    /// Leaves untracked files alone.
    ResetHard,
    /// `git checkout -f` / `git checkout -- <paths>` / `git checkout .` —
    /// discards tracked modifications (optionally path-scoped).
    CheckoutDiscard,
    /// `git restore <paths>` targeting the worktree — same loss class.
    RestoreWorktree,
    /// `git clean -f[d][x]` — deletes UNTRACKED files. Disjoint loss class
    /// from the three above.
    CleanForce,
    /// `git worktree remove --force <path>` — deletes another session's
    /// entire checkout, uncommitted work and all.
    WorktreeRemoveForce,
}

impl DestructiveKind {
    pub fn label(self) -> &'static str {
        match self {
            DestructiveKind::ResetHard => "git reset --hard",
            DestructiveKind::CheckoutDiscard => "git checkout (discarding)",
            DestructiveKind::RestoreWorktree => "git restore (worktree)",
            DestructiveKind::CleanForce => "git clean -f",
            DestructiveKind::WorktreeRemoveForce => "git worktree remove --force",
        }
    }

    /// What this class actually destroys — used to pick the at-risk set.
    fn destroys_tracked_modifications(self) -> bool {
        matches!(
            self,
            DestructiveKind::ResetHard
                | DestructiveKind::CheckoutDiscard
                | DestructiveKind::RestoreWorktree
                | DestructiveKind::WorktreeRemoveForce
        )
    }

    fn destroys_untracked(self) -> bool {
        matches!(
            self,
            DestructiveKind::CleanForce | DestructiveKind::WorktreeRemoveForce
        )
    }
}

/// One destructive invocation found inside a (possibly compound) command.
#[derive(Debug, Clone)]
pub struct DestructiveOp {
    pub kind: DestructiveKind,
    /// Reconstructed segment, for the refusal message.
    pub segment: String,
    /// `git -C <dir>` override, if the command named one.
    pub dir_override: Option<String>,
    /// Explicit pathspecs, when the command scoped itself to some files.
    /// Empty means "whole tree".
    pub pathspecs: Vec<String>,
}

/// Split a shell command line into command segments, respecting quoting.
///
/// This is deliberately *not* a full shell parser. It exists to answer one
/// question — "is `git` the command being run here, or does the string merely
/// contain the word git?" — so that `grep -rn "git reset --hard" .` is not
/// refused while `cd /repo && git reset --hard` is.
///
/// Known gap: command substitution inside double quotes
/// (`echo "$(git reset --hard)"`) is treated as literal text and not scanned.
pub fn tokenize_segments(cmd: &str) -> Vec<Vec<String>> {
    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut current: Vec<String> = Vec::new();
    let mut token = String::new();
    let mut have_token = false;

    let chars: Vec<char> = cmd.chars().collect();
    let mut i = 0usize;

    macro_rules! flush_token {
        () => {
            if have_token {
                current.push(std::mem::take(&mut token));
                have_token = false;
            }
        };
    }
    macro_rules! flush_segment {
        () => {{
            flush_token!();
            if !current.is_empty() {
                segments.push(std::mem::take(&mut current));
            }
        }};
    }

    while i < chars.len() {
        let c = chars[i];
        match c {
            '\'' => {
                have_token = true;
                i += 1;
                while i < chars.len() && chars[i] != '\'' {
                    token.push(chars[i]);
                    i += 1;
                }
                i += 1; // closing quote (or EOF)
            }
            '"' => {
                have_token = true;
                i += 1;
                while i < chars.len() && chars[i] != '"' {
                    if chars[i] == '\\' && i + 1 < chars.len() {
                        token.push(chars[i + 1]);
                        i += 2;
                        continue;
                    }
                    token.push(chars[i]);
                    i += 1;
                }
                i += 1;
            }
            '\\' if i + 1 < chars.len() => {
                // A backslash-newline is a line continuation, not a token char.
                if chars[i + 1] == '\n' {
                    i += 2;
                } else {
                    have_token = true;
                    token.push(chars[i + 1]);
                    i += 2;
                }
            }
            ' ' | '\t' => {
                flush_token!();
                i += 1;
            }
            ';' | '\n' | '(' | ')' | '{' | '}' => {
                flush_segment!();
                i += 1;
            }
            '&' | '|' => {
                flush_segment!();
                // consume a doubled operator as one
                if i + 1 < chars.len() && chars[i + 1] == c {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            '$' if i + 1 < chars.len() && chars[i + 1] == '(' => {
                // Command substitution: the inside is a real command.
                flush_segment!();
                i += 2;
            }
            '`' => {
                flush_segment!();
                i += 1;
            }
            _ => {
                have_token = true;
                token.push(c);
                i += 1;
            }
        }
    }
    flush_segment!();
    let _ = have_token; // the final flush resets it; nothing reads it after
    segments
}

/// Strip leading `VAR=value` assignments and benign prefixes so
/// `sudo env FOO=1 git reset --hard` still classifies.
fn strip_command_prefix(tokens: &[String]) -> &[String] {
    let mut idx = 0usize;
    while idx < tokens.len() {
        let t = &tokens[idx];
        let is_assignment = t
            .split_once('=')
            .map(|(k, _)| {
                !k.is_empty()
                    && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                    && !k.starts_with(|c: char| c.is_ascii_digit())
            })
            .unwrap_or(false);
        let is_prefix_cmd = matches!(t.as_str(), "sudo" | "env" | "command" | "nice" | "time");
        if is_assignment || is_prefix_cmd {
            idx += 1;
        } else {
            break;
        }
    }
    &tokens[idx..]
}

/// Classify one command segment. Returns `None` for anything that is not a
/// destructive git invocation.
pub fn classify_segment(tokens: &[String]) -> Option<DestructiveOp> {
    let tokens = strip_command_prefix(tokens);
    let first = tokens.first()?;
    // Accept `git`, `/usr/bin/git`, `git.exe`.
    let base = Path::new(first)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(first);
    if base != "git" && base != "git.exe" {
        return None;
    }

    // Consume git's global options, harvesting -C.
    let mut dir_override: Option<String> = None;
    let mut idx = 1usize;
    while idx < tokens.len() {
        match tokens[idx].as_str() {
            "-C" => {
                dir_override = tokens.get(idx + 1).cloned();
                idx += 2;
            }
            "-c" => idx += 2,
            "--no-pager" | "--paginate" | "--bare" | "--literal-pathspecs" => idx += 1,
            t if t.starts_with("--git-dir=") || t.starts_with("--work-tree=") => idx += 1,
            t if t.starts_with('-') => idx += 1,
            _ => break,
        }
    }

    let sub = tokens.get(idx)?.clone();
    let rest: Vec<String> = tokens[(idx + 1).min(tokens.len())..].to_vec();
    let has = |f: &str| rest.iter().any(|a| a == f);
    // Short flag clusters: `-fd`, `-fdx`, `-xdf` all contain force.
    let has_short = |ch: char| {
        rest.iter().any(|a| {
            a.starts_with('-') && !a.starts_with("--") && a.chars().skip(1).any(|c| c == ch)
        })
    };
    let dry_run = has("--dry-run") || has_short('n');

    let segment = tokens.join(" ");
    let mk = |kind: DestructiveKind, pathspecs: Vec<String>| {
        Some(DestructiveOp {
            kind,
            segment: segment.clone(),
            dir_override: dir_override.clone(),
            pathspecs,
        })
    };

    // Positional (non-flag) args after the subcommand, past any `--`.
    let positional = |rest: &[String]| -> Vec<String> {
        let mut out = Vec::new();
        let mut seen_ddash = false;
        for a in rest {
            if a == "--" {
                seen_ddash = true;
                continue;
            }
            if !seen_ddash && a.starts_with('-') {
                continue;
            }
            out.push(a.clone());
        }
        out
    };

    match sub.as_str() {
        "reset" if has("--hard") => mk(DestructiveKind::ResetHard, Vec::new()),
        "checkout" => {
            let forced = has("--force") || has_short('f');
            let path_scoped = has("--") || rest.iter().any(|a| a == "." || a == "./");
            if !forced && !path_scoped {
                // `git checkout <branch>` refuses rather than clobbers.
                return None;
            }
            // `git checkout -- .` names the whole tree; treat as unscoped.
            let mut paths = positional(&rest);
            if paths.iter().any(|p| p == "." || p == "./") {
                paths.clear();
            }
            mk(DestructiveKind::CheckoutDiscard, paths)
        }
        // `git switch` is the modern spelling of the checkout half that
        // changes branches. Plain `switch <branch>` refuses rather than
        // clobbers, exactly like `checkout <branch>`; the force spellings do
        // not.
        "switch" if has("--discard-changes") || has("--force") || has_short('f') => {
            mk(DestructiveKind::CheckoutDiscard, Vec::new())
        }
        "restore" => {
            // `--staged` alone only unstages; content survives in the worktree.
            if has("--staged") && !has("--worktree") && !has("-W") {
                return None;
            }
            if has("--source") || has("-s") {
                // still a worktree overwrite — keep guarding
            }
            let mut paths = positional(&rest);
            if paths.iter().any(|p| p == "." || p == "./") {
                paths.clear();
            }
            mk(DestructiveKind::RestoreWorktree, paths)
        }
        "clean" => {
            if dry_run {
                return None;
            }
            if !(has("--force") || has_short('f')) {
                // Without -f, clean refuses to do anything by default.
                return None;
            }
            mk(DestructiveKind::CleanForce, Vec::new())
        }
        "worktree" => {
            if rest.first().map(String::as_str) != Some("remove") {
                return None;
            }
            if !(has("--force") || has_short('f')) {
                // Plain `worktree remove` already refuses on a dirty tree.
                return None;
            }
            let target = positional(&rest)
                .into_iter()
                .find(|p| p != "remove")
                .map(|p| vec![p])
                .unwrap_or_default();
            mk(DestructiveKind::WorktreeRemoveForce, target)
        }
        _ => None,
    }
}

/// Scan a full (possibly compound) command line for destructive git ops.
pub fn scan_command(cmd: &str) -> Vec<DestructiveOp> {
    tokenize_segments(cmd)
        .iter()
        .filter_map(|seg| classify_segment(seg))
        .collect()
}

/// Same, but tracking `cd` across segments so each op carries the directory
/// it would actually run in.
///
/// `cd /repo && git reset --hard` is the shape agents type constantly. Without
/// this the guard inspects the *session's* cwd, finds it clean, and waves
/// through a reset against a dirty repo somewhere else — which is a guard
/// that reports the wrong answer confidently, the worst kind.
pub fn scan_command_with_cwd(cmd: &str, cwd: &Path) -> Vec<(DestructiveOp, PathBuf)> {
    let mut here = cwd.to_path_buf();
    let mut out = Vec::new();
    for seg in tokenize_segments(cmd) {
        let toks = strip_command_prefix(&seg);
        if let Some(first) = toks.first() {
            if first == "cd" {
                // `cd -` and `cd` (bare, → $HOME) are not worth modelling; both
                // leave `here` alone, which keeps us checking the session cwd
                // rather than inventing a wrong one.
                //
                // Neither is a `cd` that cannot succeed. A shell that fails to
                // cd stays put, so following a nonexistent path would point the
                // guard at a non-repo, `git status` would fail, and the
                // fail-open would wave the reset through — the guard made
                // WEAKER by the feature meant to sharpen it. Caught by
                // tests/git_safety_e2e.rs on `cd somewhere && … reset --hard`.
                if let Some(arg) = toks.get(1) {
                    if arg != "-" && !arg.starts_with('-') {
                        let candidate = resolve(&here, arg);
                        if candidate.is_dir() {
                            here = candidate;
                        }
                    }
                }
                continue;
            }
        }
        if let Some(op) = classify_segment(&seg) {
            out.push((op, here.clone()));
        }
    }
    out
}

// ───────────────────────────── checkout inspection ────────────────────────

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// One entry from `git status --porcelain`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusEntry {
    pub xy: String,
    pub path: String,
}

impl StatusEntry {
    pub fn is_untracked(&self) -> bool {
        self.xy == "??"
    }
    pub fn is_ignored(&self) -> bool {
        self.xy == "!!"
    }
}

/// Parse `git status --porcelain` output. Split out so the classification of
/// "what is at risk" is unit-testable without a real repository.
pub fn parse_porcelain(out: &str) -> Vec<StatusEntry> {
    let mut v = Vec::new();
    for line in out.lines() {
        if line.len() < 4 {
            continue;
        }
        let xy = line[..2].to_string();
        let mut path = line[3..].to_string();
        // Renames are "old -> new"; the new path is the one on disk.
        if let Some((_, new)) = path.split_once(" -> ") {
            path = new.to_string();
        }
        let path = path.trim_matches('"').to_string();
        v.push(StatusEntry { xy, path });
    }
    v
}

/// Which files this op would destroy, given the checkout's status.
///
/// Precision matters: `reset --hard` cannot touch untracked files and
/// `clean -f` cannot touch tracked modifications. A guard that names the
/// wrong files gets ignored, and an ignored guard is worse than none.
pub fn at_risk(entries: &[StatusEntry], op: &DestructiveOp) -> Vec<String> {
    let mut out: BTreeSet<String> = BTreeSet::new();
    for e in entries {
        if e.is_ignored() {
            continue;
        }
        let relevant = if e.is_untracked() {
            op.kind.destroys_untracked()
        } else {
            op.kind.destroys_tracked_modifications()
        };
        if !relevant {
            continue;
        }
        if !op.pathspecs.is_empty() {
            let matches = op.pathspecs.iter().any(|p| {
                let p = p.trim_end_matches('/');
                e.path == p || e.path.starts_with(&format!("{p}/"))
            });
            if !matches {
                continue;
            }
        }
        out.insert(e.path.clone());
    }
    out.into_iter().collect()
}

/// Is `dir` the PRIMARY checkout of its repository (as opposed to a linked
/// worktree)? The primary is the one whose `--git-common-dir` resolves to
/// its own `.git`.
pub fn is_primary_checkout(dir: &Path) -> bool {
    let top = match git(dir, &["rev-parse", "--show-toplevel"]) {
        Some(s) => PathBuf::from(s.trim()),
        None => return false,
    };
    let common = match git(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    ) {
        Some(s) => PathBuf::from(s.trim().to_string()),
        None => return false,
    };
    // Compare canonicalized forms: /tmp vs /private/tmp on macOS.
    let a = common.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let a = std::fs::canonicalize(&a).unwrap_or(a);
    let b = std::fs::canonicalize(&top).unwrap_or(top);
    a == b
}

/// Linked worktrees of this repository, excluding the primary checkout.
pub fn linked_worktrees(dir: &Path) -> Vec<PathBuf> {
    let out = match git(dir, &["worktree", "list", "--porcelain"]) {
        Some(s) => s,
        None => return Vec::new(),
    };
    let mut paths: Vec<PathBuf> = out
        .lines()
        .filter_map(|l| l.strip_prefix("worktree "))
        .map(PathBuf::from)
        .collect();
    if !paths.is_empty() {
        paths.remove(0); // first entry is the primary checkout
    }
    paths
}

/// Linked worktrees whose HEAD or index was touched inside the sibling
/// window — the operational definition of "another session may hold work
/// here right now".
pub fn live_siblings(dir: &Path) -> Vec<PathBuf> {
    let window_h: u64 = std::env::var("CHUMP_SIBLING_WINDOW_H")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_SIBLING_WINDOW_H);
    let cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(window_h * 3600))
        .unwrap_or(std::time::UNIX_EPOCH);
    linked_worktrees(dir)
        .into_iter()
        .filter(|wt| {
            ["", ".git"]
                .iter()
                .any(|suffix| touched_since(&wt.join(suffix), cutoff))
        })
        .collect()
}

fn touched_since(p: &Path, cutoff: std::time::SystemTime) -> bool {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .map(|m| m > cutoff)
        .unwrap_or(false)
}

// ───────────────────────────── the verdict ────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Nothing destructive, or nothing at risk.
    Allow,
    /// Refuse, with a message that names every file.
    Deny(String),
}

/// Decide on a command, given a resolved working directory and the checkout's
/// porcelain status. Split from I/O so the decision is unit-testable.
pub fn decide_with_status(
    cmd: &str,
    dir: &Path,
    entries: &[StatusEntry],
    sibling_count: usize,
) -> Verdict {
    let ops = scan_command(cmd);
    if ops.is_empty() {
        return Verdict::Allow;
    }
    for op in &ops {
        if let d @ Verdict::Deny(_) = verdict_for_op(op, dir, entries, sibling_count) {
            return d;
        }
    }
    Verdict::Allow
}

/// Verdict for one already-classified op.
///
/// Takes the op rather than re-parsing a command string: `git worktree remove
/// --force <path>` carries the worktree path in `pathspecs`, and re-scanning
/// would re-apply it as a *file* filter against paths relative to that same
/// worktree — matching nothing and silently permitting the destruction of a
/// whole dirty checkout.
fn verdict_for_op(
    op: &DestructiveOp,
    dir: &Path,
    entries: &[StatusEntry],
    sibling_count: usize,
) -> Verdict {
    let files = at_risk(entries, op);
    if files.is_empty() {
        return Verdict::Allow;
    }
    let mut m = String::new();
    m.push_str(&format!(
        "REFUSED (RESILIENT-256): `{}` would permanently destroy {} uncommitted file(s) in {}.\n",
        op.kind.label(),
        files.len(),
        dir.display()
    ));
    m.push_str(
        "Unstaged changes are the ONE class git cannot recover: no reflog, no stash, no fsck.\n",
    );
    m.push_str("\nFiles that would be destroyed:\n");
    for f in &files {
        m.push_str(&format!("  {f}\n"));
    }
    if sibling_count > 0 {
        m.push_str(&format!(
            "\nThis checkout is the PRIMARY, shared with {sibling_count} live linked worktree(s).\n\
             Some of those bytes may belong to a session that is not you.\n"
        ));
    }
    m.push_str(&format!(
        "\nGet the bytes into the object store first, then retry:\n  \
         chump wip-snapshot --dir {}\n\
         That writes a refs/wip/… commit WITHOUT touching your working tree or index.\n\
         \nIf you truly mean to destroy them: {OVERRIDE_ENV}=1 <your command>  (audited)\n",
        dir.display()
    ));
    Verdict::Deny(m)
}

/// Full decision including reading the checkout. `cwd` is the directory the
/// command would run in.
pub fn decide(cmd: &str, cwd: &Path) -> Verdict {
    for (op, effective_cwd) in scan_command_with_cwd(cmd, cwd) {
        // `git -C <dir>` and `worktree remove <path>` retarget the checkout.
        let target: PathBuf = match (&op.dir_override, op.kind) {
            (Some(d), _) => resolve(&effective_cwd, d),
            (None, DestructiveKind::WorktreeRemoveForce) => match op.pathspecs.first() {
                Some(p) => resolve(&effective_cwd, p),
                None => effective_cwd.clone(),
            },
            _ => effective_cwd.clone(),
        };
        let porcelain = match git(&target, &["status", "--porcelain"]) {
            Some(s) => s,
            // Not a git repo / git unavailable — fail open. A seatbelt that
            // jams the door shut is worse than no seatbelt.
            None => continue,
        };
        let entries = parse_porcelain(&porcelain);
        // For worktree-remove the pathspec names the WORKTREE, not a file
        // filter inside it — everything dirty in there dies.
        let mut op2 = op.clone();
        if op2.kind == DestructiveKind::WorktreeRemoveForce {
            op2.pathspecs.clear();
        }
        // Cheap first pass with no sibling lookup: on the overwhelmingly
        // common Allow path this hook must not spend two extra `git`
        // invocations per Bash call.
        if verdict_for_op(&op2, &target, &entries, 0) == Verdict::Allow {
            continue;
        }
        let siblings = if is_primary_checkout(&target) {
            live_siblings(&target).len()
        } else {
            0
        };
        return verdict_for_op(&op2, &target, &entries, siblings);
    }
    Verdict::Allow
}

fn resolve(cwd: &Path, p: &str) -> PathBuf {
    let pb = PathBuf::from(p);
    if pb.is_absolute() {
        pb
    } else {
        cwd.join(pb)
    }
}

// ───────────────────── criterion 2: primary is read-mostly ────────────────

/// Path of `file` relative to checkout root `top`.
///
/// Both sides are canonicalized first. macOS hands the tool `/tmp/...` while
/// git reports `/private/tmp/...`, and a naive `strip_prefix` silently fails
/// — which made the allowlist below miss and would have blocked every
/// `.chump-locks/` lease write in the main checkout. Handles files that do
/// not exist yet (a Write creating one) by canonicalizing the deepest
/// existing ancestor and re-attaching the remainder. If even that fails the
/// original path comes back unchanged, and the caller's allowlist simply
/// does not match — a fail-toward-refuse this narrow is acceptable because
/// the refusal names its own escape hatch.
pub fn repo_relative(file: &Path, top: &Path) -> String {
    let cf = std::fs::canonicalize(file).unwrap_or_else(|_| {
        // The file may not exist yet (a Write creating it). Canonicalize the
        // deepest existing ancestor and re-attach the remainder.
        let mut tail: Vec<std::ffi::OsString> = Vec::new();
        let mut cur = file.to_path_buf();
        loop {
            match std::fs::canonicalize(&cur) {
                Ok(c) => {
                    let mut out = c;
                    for part in tail.iter().rev() {
                        out.push(part);
                    }
                    return out;
                }
                Err(_) => match (cur.file_name().map(|s| s.to_os_string()), cur.parent()) {
                    (Some(name), Some(parent)) => {
                        tail.push(name);
                        cur = parent.to_path_buf();
                    }
                    _ => return file.to_path_buf(),
                },
            }
        }
    });
    let ct = std::fs::canonicalize(top).unwrap_or_else(|_| top.to_path_buf());
    cf.strip_prefix(&ct)
        .unwrap_or(file)
        .to_string_lossy()
        .to_string()
}

/// Decide whether an Edit/Write to `file` should be refused because it lands
/// in a PRIMARY checkout that a live sibling session may also be holding.
///
/// Returns `Allow` outside git repos, inside linked worktrees, for
/// coordination surfaces that only exist in the primary, and when no sibling
/// worktree has been touched inside the window.
pub fn decide_write(file: &Path) -> Verdict {
    let mode = std::env::var(WRITE_GUARD_ENV).unwrap_or_else(|_| "deny".into());
    if mode == "off" {
        return Verdict::Allow;
    }
    let dir = match file.parent() {
        Some(p) if p.exists() => p.to_path_buf(),
        // New file in a not-yet-created dir: walk up to something real.
        _ => {
            let mut cur = file.parent().map(|p| p.to_path_buf());
            loop {
                match cur {
                    Some(ref p) if p.exists() => break p.clone(),
                    Some(ref p) => cur = p.parent().map(|q| q.to_path_buf()),
                    None => return Verdict::Allow,
                }
            }
        }
    };
    let top = match git(&dir, &["rev-parse", "--show-toplevel"]) {
        Some(s) => PathBuf::from(s.trim()),
        None => return Verdict::Allow, // not a git repo
    };
    if !is_primary_checkout(&dir) {
        return Verdict::Allow; // already in your own worktree — the good case
    }
    let rel = repo_relative(file, &top);
    if PRIMARY_WRITE_ALLOWLIST.iter().any(|p| rel.starts_with(p)) {
        return Verdict::Allow; // coordination surfaces belong in the primary
    }
    let siblings = live_siblings(&top);
    if siblings.is_empty() {
        return Verdict::Allow; // nobody else here
    }
    let slug = std::env::var("CHUMP_GAP_ID")
        .ok()
        .map(|s| s.to_lowercase())
        .unwrap_or_else(|| "my-work".into());
    let msg = format!(
        "REFUSED (RESILIENT-256): {rel} is inside the PRIMARY checkout {}, which {} live \
         linked worktree(s) share.\n\
         The primary is read-mostly: an agent that edits it puts another session's uncommitted \
         work one `git reset --hard` away from permanent loss (2026-08-09, ~574 lines, \
         unrecoverable).\n\
         \nTake your own worktree — one command:\n  \
         scripts/dev/own-worktree.sh {slug}\n\
         \nEscape hatch (audited): {WRITE_GUARD_ENV}=off\n",
        top.display(),
        siblings.len()
    );
    if mode == "warn" {
        eprintln!("{msg}");
        return Verdict::Allow;
    }
    Verdict::Deny(msg)
}

// ───────────────────────────── snapshot (load-bearing) ────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotResult {
    pub commit: String,
    pub git_ref: String,
    pub files: usize,
}

/// Write the dirty state of `dir` into the object store as a commit under
/// `refs/wip/<branch>/<epoch>`, WITHOUT touching the working tree or the
/// real index.
///
/// Mechanism: a throwaway `GIT_INDEX_FILE` is seeded from HEAD, everything
/// non-ignored is added to *that* index, and `write-tree` + `commit-tree`
/// produce a real commit object. `update-ref` anchors it so gc cannot reap
/// it. The caller's index and working tree are never opened for writing —
/// which is what makes it safe to run against a checkout some other session
/// is actively typing into.
///
/// Returns `Ok(None)` when the tree is clean (nothing to snapshot).
pub fn snapshot(dir: &Path) -> Result<Option<SnapshotResult>, String> {
    let porcelain = git(dir, &["status", "--porcelain"])
        .ok_or_else(|| format!("{} is not a git checkout", dir.display()))?;
    let entries = parse_porcelain(&porcelain);
    let dirty: Vec<&StatusEntry> = entries.iter().filter(|e| !e.is_ignored()).collect();
    if dirty.is_empty() {
        return Ok(None);
    }

    let head = git(dir, &["rev-parse", "HEAD"])
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let branch = git(dir, &["rev-parse", "--abbrev-ref", "HEAD"])
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "detached".into());
    let branch_slug: String = branch
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();

    let tmp_index = std::env::temp_dir().join(format!(
        "chump-wip-index-{}-{}",
        std::process::id(),
        now_epoch()
    ));
    let run = |args: &[&str]| -> Result<String, String> {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_INDEX_FILE", &tmp_index)
            .output()
            .map_err(|e| format!("git {args:?}: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    };

    let cleanup = || {
        let _ = std::fs::remove_file(&tmp_index);
    };

    if !head.is_empty() {
        if let Err(e) = run(&["read-tree", "HEAD"]) {
            cleanup();
            return Err(e);
        }
    }
    // `--all` against a THROWAWAY index. It never reaches the real index,
    // so this cannot stage anything in the session that owns the checkout.
    if let Err(e) = run(&["add", "--all", "."]) {
        cleanup();
        return Err(e);
    }
    let tree = match run(&["write-tree"]) {
        Ok(t) => t,
        Err(e) => {
            cleanup();
            return Err(e);
        }
    };
    let msg = format!(
        "wip-snapshot: {} dirty path(s) on {branch}\n\n\
         Written by chump wip-snapshot (RESILIENT-256). The working tree and index\n\
         were NOT modified. Recover with:\n  \
         git -C {} restore --source=<this-sha> -- <path>\n  \
         git -C {} diff HEAD <this-sha>\n",
        dirty.len(),
        dir.display(),
        dir.display()
    );
    let mut ct_args: Vec<String> = vec!["commit-tree".into(), tree.clone()];
    if !head.is_empty() {
        ct_args.push("-p".into());
        ct_args.push(head.clone());
    }
    ct_args.push("-m".into());
    ct_args.push(msg);
    let ct_refs: Vec<&str> = ct_args.iter().map(String::as_str).collect();
    let commit = match run(&ct_refs) {
        Ok(c) => c,
        Err(e) => {
            cleanup();
            return Err(e);
        }
    };
    cleanup();

    // Dedup by TREE, not by commit. commit-tree stamps a timestamp, so an
    // unchanged working tree still yields a brand-new commit hash every run —
    // which is exactly how idle work minted a ref per cycle forever. The tree
    // hash is content-addressed: identical content, identical tree, nothing
    // new to record.
    if let Some(prev) = newest_wip_tree(dir, &branch_slug) {
        if prev == tree {
            return Ok(None);
        }
    }

    // Epoch SECONDS alone is not unique: two snapshots inside the same second
    // produce the same ref name and update-ref silently overwrites the first.
    // Found by the retention test — 12 rapid snapshots yielded 3 refs, not 12,
    // so a burst of real edits would have quietly lost checkpoints. The commit
    // hash disambiguates, and it cannot collide here because identical trees
    // are already deduped above.
    // MILLISECONDS, zero-padded to 13 digits. Seconds were not enough: two
    // snapshots in the same second collided on the ref name and update-ref
    // silently overwrote the first, and `--sort=-committerdate` tied among
    // them so pruning could discard the NEWEST work while keeping older
    // siblings. Millisecond precision makes the name unique and, because the
    // width is fixed, lexical order on refname IS chronological order — which
    // is what both the dedup lookup and the prune rely on.
    let git_ref = format!("refs/wip/{branch_slug}/{:013}", now_epoch_ms());
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["update-ref", &git_ref, &commit])
        .output()
        .map_err(|e| format!("update-ref: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "update-ref failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    prune_wip_refs(dir, &branch_slug);

    Ok(Some(SnapshotResult {
        commit,
        git_ref,
        files: dirty.len(),
    }))
}

/// Tree hash of the most recent snapshot for this branch, if any.
///
/// Sorted by committerdate rather than by the epoch in the ref name: the name
/// is generated from our own clock and a backwards step (NTP correction,
/// sleep/wake) would otherwise make an older snapshot sort newest and defeat
/// the dedup silently.
fn newest_wip_tree(dir: &Path, branch_slug: &str) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "for-each-ref",
            "--sort=-refname",
            "--count=1",
            "--format=%(objectname)",
            &format!("refs/wip/{branch_slug}/"),
        ])
        .output()
        .ok()?;
    let commit = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if commit.is_empty() {
        return None;
    }
    let tree = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", &format!("{commit}^{{tree}}")])
        .output()
        .ok()?;
    let tree = String::from_utf8_lossy(&tree.stdout).trim().to_string();
    (!tree.is_empty()).then_some(tree)
}

/// Keep the newest `CHUMP_WIP_RETAIN` snapshots for this branch, delete the rest.
///
/// Best-effort and deliberately silent on failure: losing a prune is a slow
/// leak, but a prune that aborts the caller would mean a failed cleanup costs
/// you the snapshot itself — the opposite of the point.
fn prune_wip_refs(dir: &Path, branch_slug: &str) {
    let retain = std::env::var("CHUMP_WIP_RETAIN")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(DEFAULT_WIP_RETAIN);
    if retain == 0 {
        return;
    }
    let Ok(out) = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "for-each-ref",
            "--sort=-refname",
            "--format=%(refname)",
            &format!("refs/wip/{branch_slug}/"),
        ])
        .output()
    else {
        return;
    };
    let refs: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();
    for old in refs.into_iter().skip(retain) {
        let _ = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["update-ref", "-d", &old])
            .output();
    }
}

fn now_epoch_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ───────────────────────────── audit trail ────────────────────────────────

fn emit_ambient(repo_root: &Path, json_line: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let path = lock_dir.join("ambient.jsonl");
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{json_line}");
    }
}

/// ISO-8601 UTC, matching the `ts` format every other ambient emitter uses.
/// chrono is already a dependency of this binary; an earlier hand-rolled
/// days-to-civil conversion here bought nothing and shipped an off-by-one.
fn ts_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

// ───────────────────────────── CLI entry points ───────────────────────────

fn read_stdin() -> String {
    let mut s = String::new();
    let _ = std::io::stdin().read_to_string(&mut s);
    s
}

/// Pull a string field out of a flat-ish JSON blob without a JSON dependency
/// in the hot path. Handles `"key": "value"` with escaped quotes.
pub fn json_str_field(blob: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let mut from = 0usize;
    while let Some(pos) = blob[from..].find(&needle) {
        let start = from + pos + needle.len();
        let rest = &blob[start..];
        let rest = rest.trim_start();
        let rest = rest.strip_prefix(':')?.trim_start();
        if !rest.starts_with('"') {
            from = start;
            continue;
        }
        let body = &rest[1..];
        let mut out = String::new();
        let mut it = body.chars();
        while let Some(c) = it.next() {
            match c {
                '\\' => match it.next() {
                    Some('n') => out.push('\n'),
                    Some('t') => out.push('\t'),
                    Some('r') => out.push('\r'),
                    Some(other) => out.push(other),
                    None => break,
                },
                '"' => return Some(out),
                _ => out.push(c),
            }
        }
        return Some(out);
    }
    None
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
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

fn deny_and_exit(reason: &str) -> i32 {
    // Emit both shapes so the refusal lands on every Claude Code version:
    // structured JSON for the permission-decision protocol, stderr + exit 2
    // for the older blocking-hook contract.
    println!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\
         \"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"{}\"}}}}",
        json_escape(reason)
    );
    eprintln!("{reason}");
    2
}

// ── EVENT_REGISTRY coverage scanner-anchor (INFRA-1237 / INFRA-1287) ─────────
// audit_override() below is a REAL emit, but it writes through a `format!`
// whose braces and quotes are escaped (`{{\"kind\":\"…\"`), which the coverage
// regex (scripts/ci/test-event-registry-coverage.sh) cannot see through.
// Anchor the literal here in the scanner's detectable JSON form so the
// register-without-emit (orphan) gate stays green:
//   "kind":"destructive_git_override"
fn audit_override(repo_root: &Path, cmd: &str) {
    emit_ambient(
        repo_root,
        &format!(
            "{{\"event\":\"ALERT\",\"kind\":\"destructive_git_override\",\"gap\":\"RESILIENT-256\",\
             \"ts\":\"{}\",\"cmd\":\"{}\",\"reason\":\"{OVERRIDE_ENV}=1 bypassed the \
             destructive-git guard\"}}",
            ts_now(),
            json_escape(&cmd.chars().take(200).collect::<String>())
        ),
    );
}

/// `chump git-guard …`
pub fn run_cli(args: &[String]) -> i32 {
    let mut mode = "";
    let mut cmd_arg: Option<String> = None;
    let mut file_arg: Option<String> = None;
    let mut cwd_arg: Option<String> = None;
    let mut i = 2usize;
    while i < args.len() {
        match args[i].as_str() {
            "--hook" => {
                mode = "hook";
                i += 1;
            }
            "--hook-write" => {
                mode = "hook-write";
                i += 1;
            }
            "--check" => {
                mode = "check";
                cmd_arg = args.get(i + 1).cloned();
                i += 2;
            }
            "--check-write" => {
                mode = "check-write";
                file_arg = args.get(i + 1).cloned();
                i += 2;
            }
            "--cwd" => {
                cwd_arg = args.get(i + 1).cloned();
                i += 2;
            }
            "-h" | "--help" => {
                print_guard_help();
                return 0;
            }
            _ => i += 1,
        }
    }
    if mode.is_empty() {
        print_guard_help();
        return 2;
    }

    let payload = if mode.starts_with("hook") {
        read_stdin()
    } else {
        String::new()
    };

    let cwd = cwd_arg
        .map(PathBuf::from)
        .or_else(|| json_str_field(&payload, "cwd").map(PathBuf::from))
        .or_else(|| std::env::var("CLAUDE_PROJECT_DIR").ok().map(PathBuf::from))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));

    match mode {
        "hook" | "check" => {
            let cmd = cmd_arg
                .or_else(|| json_str_field(&payload, "command"))
                .unwrap_or_default();
            if cmd.is_empty() {
                return 0;
            }
            if std::env::var(OVERRIDE_ENV)
                .map(|v| v == "1")
                .unwrap_or(false)
            {
                audit_override(&cwd, &cmd);
                return 0;
            }
            match decide(&cmd, &cwd) {
                Verdict::Allow => 0,
                Verdict::Deny(reason) => {
                    if mode == "hook" {
                        deny_and_exit(&reason)
                    } else {
                        eprintln!("{reason}");
                        2
                    }
                }
            }
        }
        "hook-write" | "check-write" => {
            let f = file_arg
                .or_else(|| json_str_field(&payload, "file_path"))
                .or_else(|| json_str_field(&payload, "path"))
                .unwrap_or_default();
            if f.is_empty() {
                return 0;
            }
            match decide_write(Path::new(&f)) {
                Verdict::Allow => 0,
                Verdict::Deny(reason) => {
                    if mode == "hook-write" {
                        deny_and_exit(&reason)
                    } else {
                        eprintln!("{reason}");
                        2
                    }
                }
            }
        }
        _ => 2,
    }
}

fn print_guard_help() {
    println!("chump git-guard — RESILIENT-256 destructive-git guard");
    println!();
    println!("USAGE");
    println!(
        "  chump git-guard --hook                 # PreToolUse Bash hook (reads JSON on stdin)"
    );
    println!("  chump git-guard --hook-write           # PreToolUse Edit|Write hook (stdin JSON)");
    println!("  chump git-guard --check '<command>' [--cwd DIR]");
    println!("  chump git-guard --check-write <file>");
    println!();
    println!("EXIT CODES");
    println!("  0   permitted");
    println!("  2   REFUSED — the command would destroy uncommitted work");
    println!();
    println!("ENV");
    println!("  {OVERRIDE_ENV}=1     bypass the refusal (audited to ambient.jsonl)");
    println!("  {WRITE_GUARD_ENV}=warn|off   soften the shared-primary write guard");
    println!("  CHUMP_SIBLING_WINDOW_H=N            live-sibling window (default {DEFAULT_SIBLING_WINDOW_H}h)");
}

/// `chump wip-snapshot [--dir D] [--quiet]`
pub fn run_snapshot_cli(args: &[String]) -> i32 {
    let mut dir: Option<String> = None;
    let mut quiet = false;
    let mut i = 2usize;
    while i < args.len() {
        match args[i].as_str() {
            "--dir" => {
                dir = args.get(i + 1).cloned();
                i += 2;
            }
            "--quiet" | "-q" => {
                quiet = true;
                i += 1;
            }
            "-h" | "--help" => {
                println!("chump wip-snapshot — RESILIENT-256");
                println!();
                println!("Write a checkout's dirty state into the object store as a");
                println!("refs/wip/<branch>/<epoch> commit, WITHOUT touching the working");
                println!("tree or the index. Safe to run against a checkout another");
                println!("session is actively editing.");
                println!();
                println!("USAGE");
                println!("  chump wip-snapshot [--dir DIR] [--quiet]");
                println!();
                println!("EXIT CODES");
                println!("  0   snapshot written, or tree already clean");
                println!("  1   snapshot failed");
                return 0;
            }
            _ => i += 1,
        }
    }
    let d = dir
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    match snapshot(&d) {
        Ok(None) => {
            if !quiet {
                println!("clean: nothing to snapshot in {}", d.display());
            }
            0
        }
        Ok(Some(r)) => {
            if !quiet {
                println!(
                    "snapshot {} ({} path(s)) -> {}\n  recover: git -C {} diff HEAD {}",
                    &r.commit[..12.min(r.commit.len())],
                    r.files,
                    r.git_ref,
                    d.display(),
                    &r.commit[..12.min(r.commit.len())]
                );
            } else {
                println!("{} {}", r.commit, r.git_ref);
            }
            0
        }
        Err(e) => {
            eprintln!("wip-snapshot: {e}");
            1
        }
    }
}

// ───────────────────────────── tests ──────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(cmd: &str) -> Vec<Vec<String>> {
        tokenize_segments(cmd)
    }

    #[test]
    fn tokenizer_splits_on_operators_and_respects_quotes() {
        let s = seg("cd /repo && git reset --hard origin/main");
        assert_eq!(s.len(), 2);
        assert_eq!(s[1], vec!["git", "reset", "--hard", "origin/main"]);
        let q = seg("git commit -m \"git reset --hard\"");
        assert_eq!(q.len(), 1);
        assert_eq!(q[0][3], "git reset --hard");
    }

    /// The 2026-08-09 command, verbatim.
    #[test]
    fn resilient_256_replay_classifies_the_reset() {
        let ops = scan_command("git reset --hard origin/main");
        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].kind, DestructiveKind::ResetHard);
    }

    #[test]
    fn mentions_of_the_command_are_not_the_command() {
        // A guard that fires on `grep` is a guard people disable.
        assert!(scan_command("grep -rn \"git reset --hard\" .").is_empty());
        assert!(scan_command("git commit -m 'do not git reset --hard here'").is_empty());
        assert!(scan_command("echo 'git clean -fd'").is_empty());
        assert!(scan_command("bash scripts/ci/test-git-destructive-guard.sh").is_empty());
    }

    #[test]
    fn compound_and_substituted_commands_are_reached() {
        assert_eq!(scan_command("cd /x; git clean -fdx").len(), 1);
        assert_eq!(scan_command("foo || git checkout -- .").len(), 1);
        assert_eq!(scan_command("$(git reset --hard)").len(), 1);
        assert_eq!(
            scan_command("git fetch && git reset --hard @{u} && echo done").len(),
            1
        );
    }

    #[test]
    fn non_destructive_git_is_left_alone() {
        for cmd in [
            "git status",
            "git reset --soft HEAD~1",
            "git reset HEAD file.txt",
            "git checkout main",
            "git checkout -b feature",
            "git clean -n",
            "git clean --dry-run",
            "git restore --staged file.txt",
            "git stash",
            "git worktree remove /tmp/wt",
            "git switch main",
            "git switch -c feature",
        ] {
            assert!(scan_command(cmd).is_empty(), "false positive on: {cmd}");
        }
    }

    #[test]
    fn every_destructive_class_is_caught() {
        let cases = [
            ("git reset --hard", DestructiveKind::ResetHard),
            ("git checkout -f", DestructiveKind::CheckoutDiscard),
            ("git checkout -- src/", DestructiveKind::CheckoutDiscard),
            ("git checkout .", DestructiveKind::CheckoutDiscard),
            ("git restore src/main.rs", DestructiveKind::RestoreWorktree),
            (
                "git restore --staged --worktree .",
                DestructiveKind::RestoreWorktree,
            ),
            ("git clean -fd", DestructiveKind::CleanForce),
            ("git clean --force", DestructiveKind::CleanForce),
            (
                "git worktree remove --force /tmp/wt",
                DestructiveKind::WorktreeRemoveForce,
            ),
            (
                "git switch --discard-changes main",
                DestructiveKind::CheckoutDiscard,
            ),
            ("git switch -f main", DestructiveKind::CheckoutDiscard),
        ];
        for (cmd, kind) in cases {
            let ops = scan_command(cmd);
            assert_eq!(ops.len(), 1, "missed: {cmd}");
            assert_eq!(ops[0].kind, kind, "wrong class for: {cmd}");
        }
    }

    #[test]
    fn env_prefixes_and_absolute_git_still_classify() {
        assert_eq!(scan_command("GIT_PAGER=cat git reset --hard").len(), 1);
        assert_eq!(scan_command("/usr/bin/git reset --hard").len(), 1);
        assert_eq!(scan_command("sudo git clean -fdx").len(), 1);
    }

    #[test]
    fn dir_override_is_harvested() {
        let ops = scan_command("git -C /tmp/other reset --hard");
        assert_eq!(ops[0].dir_override.as_deref(), Some("/tmp/other"));
    }

    /// `cd /repo && git reset --hard` is the shape agents actually type. If
    /// the guard checks the session cwd instead of /repo it reports a clean
    /// tree and permits the reset — confidently wrong.
    #[test]
    fn cd_retargets_the_checkout_the_guard_inspects() {
        let base = std::env::temp_dir().join(format!("chump-cd-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("sub/dir")).unwrap();
        std::fs::create_dir_all(base.join("a/b")).unwrap();

        // Absolute cd retargets.
        let target = base.join("sub");
        let got = scan_command_with_cwd(
            &format!("cd {} && git reset --hard origin/main", target.display()),
            &base,
        );
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].1, target);

        // Relative cd resolves against the session cwd.
        let got = scan_command_with_cwd("cd sub/dir; git clean -fd", &base);
        assert_eq!(got[0].1, base.join("sub/dir"));

        // Multiple cds compose.
        let got = scan_command_with_cwd("cd a && cd b && git checkout -f", &base);
        assert_eq!(got[0].1, base.join("a/b"));

        // No cd → the session cwd, unchanged.
        let got = scan_command_with_cwd("git reset --hard", &base);
        assert_eq!(got[0].1, base);

        // A cd that cannot succeed leaves the shell — and the guard — where it
        // was. Following it would point at a non-repo and fail open.
        let got = scan_command_with_cwd("cd nowhere-at-all && git reset --hard", &base);
        assert_eq!(got[0].1, base);

        // `git -C` still wins over the cd (resolved in decide(), but the op
        // must carry both pieces of information to get there).
        let got = scan_command_with_cwd("cd a && git -C /b reset --hard", &base);
        assert_eq!(got[0].0.dir_override.as_deref(), Some("/b"));
        assert_eq!(got[0].1, base.join("a"));

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn porcelain_parses_untracked_renames_and_staged() {
        let e =
            parse_porcelain(" M src/a.rs\n?? new.txt\nA  added.rs\nR  old.rs -> new.rs\n!! ig\n");
        assert_eq!(e.len(), 5);
        assert_eq!(e[0].path, "src/a.rs");
        assert!(e[1].is_untracked());
        assert_eq!(e[3].path, "new.rs");
        assert!(e[4].is_ignored());
    }

    #[test]
    fn at_risk_respects_the_loss_class() {
        let entries = parse_porcelain(" M tracked.rs\n?? untracked.txt\n!! ignored.log\n");
        let reset = &scan_command("git reset --hard")[0];
        // reset --hard cannot touch untracked files.
        assert_eq!(at_risk(&entries, reset), vec!["tracked.rs".to_string()]);
        let clean = &scan_command("git clean -fd")[0];
        // clean -fd cannot touch tracked modifications.
        assert_eq!(at_risk(&entries, clean), vec!["untracked.txt".to_string()]);
    }

    #[test]
    fn at_risk_honours_pathspec_scope() {
        let entries = parse_porcelain(" M src/a.rs\n M docs/b.md\n");
        let op = &scan_command("git checkout -- src/")[0];
        assert_eq!(at_risk(&entries, op), vec!["src/a.rs".to_string()]);
    }

    #[test]
    fn dirty_tree_is_refused_and_every_file_is_named() {
        let entries = parse_porcelain(" M crates/a.rs\n M crates/b.rs\nM  crates/c.rs\n");
        let v = decide_with_status(
            "git reset --hard origin/main",
            Path::new("/repo"),
            &entries,
            0,
        );
        match v {
            Verdict::Deny(m) => {
                assert!(m.contains("REFUSED"), "{m}");
                for f in ["crates/a.rs", "crates/b.rs", "crates/c.rs"] {
                    assert!(m.contains(f), "message did not name {f}:\n{m}");
                }
                assert!(m.contains("chump wip-snapshot"), "no recovery path:\n{m}");
                assert!(m.contains(OVERRIDE_ENV), "no escape hatch named:\n{m}");
            }
            Verdict::Allow => panic!("dirty tree was permitted"),
        }
    }

    #[test]
    fn clean_tree_is_permitted() {
        let entries = parse_porcelain("");
        assert_eq!(
            decide_with_status(
                "git reset --hard origin/main",
                Path::new("/repo"),
                &entries,
                0
            ),
            Verdict::Allow
        );
        // Untracked-only tree: reset --hard destroys nothing, so permit it.
        let untracked = parse_porcelain("?? scratch.txt\n");
        assert_eq!(
            decide_with_status("git reset --hard", Path::new("/repo"), &untracked, 0),
            Verdict::Allow
        );
    }

    /// Regression: `worktree remove --force <path>` carries the worktree path
    /// in `pathspecs`. An earlier version re-parsed the segment inside the
    /// verdict, re-applying that path as a FILE filter against paths relative
    /// to that same worktree — it matched nothing, and destroying a whole
    /// dirty checkout was silently permitted.
    #[test]
    fn worktree_remove_force_does_not_filter_itself_into_allow() {
        let entries = parse_porcelain(" M live-work.rs\n?? scratch.txt\n");
        let mut op = scan_command("git worktree remove --force /tmp/sibling-wt")[0].clone();
        assert_eq!(op.pathspecs, vec!["/tmp/sibling-wt".to_string()]);
        op.pathspecs.clear(); // what decide() does before asking for a verdict
        match verdict_for_op(&op, Path::new("/tmp/sibling-wt"), &entries, 0) {
            Verdict::Deny(m) => {
                assert!(m.contains("live-work.rs"), "{m}");
                // remove --force takes untracked files with it too.
                assert!(m.contains("scratch.txt"), "{m}");
            }
            Verdict::Allow => panic!("destroying a dirty sibling worktree was permitted"),
        }
    }

    #[test]
    fn shared_primary_is_named_in_the_refusal() {
        let entries = parse_porcelain(" M a.rs\n");
        match decide_with_status("git reset --hard", Path::new("/repo"), &entries, 3) {
            Verdict::Deny(m) => assert!(m.contains("3 live linked worktree"), "{m}"),
            Verdict::Allow => panic!("expected refusal"),
        }
    }

    #[test]
    fn hook_payload_fields_are_extracted() {
        let p = r#"{"tool_name":"Bash","cwd":"/Users/j/almanac","tool_input":{"command":"git reset --hard origin/main"}}"#;
        assert_eq!(
            json_str_field(p, "command").as_deref(),
            Some("git reset --hard origin/main")
        );
        assert_eq!(
            json_str_field(p, "cwd").as_deref(),
            Some("/Users/j/almanac")
        );
        let esc = r#"{"command":"echo \"hi\" && git clean -fd"}"#;
        assert_eq!(
            json_str_field(esc, "command").as_deref(),
            Some("echo \"hi\" && git clean -fd")
        );
    }

    /// Regression: macOS hands the hook `/tmp/...` while git reports
    /// `/private/tmp/...`. A naive strip_prefix left `rel` as an absolute
    /// path, the `.chump-locks/` allowlist missed, and the write guard would
    /// have refused every lease write in the main checkout.
    #[test]
    fn repo_relative_survives_the_tmp_symlink() {
        let root = std::env::temp_dir().join(format!("chump-relpath-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".chump-locks")).unwrap();
        std::fs::write(root.join(".chump-locks/lease.json"), "{}").unwrap();

        // /tmp/... (as the tool sees it) vs the canonical /private/tmp/...
        let canonical_root = std::fs::canonicalize(&root).unwrap();
        let as_tool_sees_it = root.join(".chump-locks/lease.json");
        assert_eq!(
            repo_relative(&as_tool_sees_it, &canonical_root),
            ".chump-locks/lease.json"
        );
        // A file that does not exist yet (Write creating it) still resolves.
        assert_eq!(
            repo_relative(&root.join(".chump-locks/not-yet.json"), &canonical_root),
            ".chump-locks/not-yet.json"
        );
        assert!(PRIMARY_WRITE_ALLOWLIST.iter().any(|p| repo_relative(
            &as_tool_sees_it,
            &canonical_root
        )
        .starts_with(p)));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ts_now_matches_the_ambient_timestamp_format() {
        let t = ts_now();
        assert_eq!(t.len(), 20, "{t}");
        assert!(t.ends_with('Z'), "{t}");
        // Must round-trip through the same parse the watchdogs use.
        assert!(
            chrono::DateTime::parse_from_rfc3339(&t.replace('Z', "+00:00")).is_ok(),
            "not parseable as RFC3339: {t}"
        );
    }

    #[test]
    fn snapshot_writes_objects_without_touching_the_worktree() {
        let dir = std::env::temp_dir().join(format!("chump-snap-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let g = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .unwrap()
        };
        g(&["init", "-q", "."]);
        g(&["config", "user.email", "t@t.t"]);
        g(&["config", "user.name", "t"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        g(&["add", "a.txt"]);
        g(&["commit", "-qm", "init"]);

        // Clean tree → nothing to snapshot.
        assert_eq!(snapshot(&dir).unwrap(), None);

        std::fs::write(dir.join("a.txt"), "TWO\n").unwrap();
        std::fs::write(dir.join("untracked.txt"), "new\n").unwrap();
        let r = snapshot(&dir).unwrap().expect("expected a snapshot");
        assert_eq!(r.files, 2);

        // The bytes are in the object store...
        let show = g(&["show", &format!("{}:a.txt", r.commit)]);
        assert_eq!(String::from_utf8_lossy(&show.stdout), "TWO\n");
        let show_u = g(&["show", &format!("{}:untracked.txt", r.commit)]);
        assert_eq!(String::from_utf8_lossy(&show_u.stdout), "new\n");

        // ...and the working tree and index were NOT touched.
        let st = g(&["status", "--porcelain"]);
        let st = String::from_utf8_lossy(&st.stdout);
        assert!(st.contains(" M a.txt"), "worktree changed: {st}");
        assert!(st.contains("?? untracked.txt"), "worktree changed: {st}");
        let staged = g(&["diff", "--cached", "--name-only"]);
        assert!(
            String::from_utf8_lossy(&staged.stdout).trim().is_empty(),
            "snapshot leaked into the real index"
        );

        // The ref anchors it against gc.
        let rp = g(&["rev-parse", &r.git_ref]);
        assert_eq!(String::from_utf8_lossy(&rp.stdout).trim(), r.commit);

        // And the whole point: after a reset --hard, the work survives.
        g(&["reset", "--hard", "HEAD"]);
        let after = g(&["show", &format!("{}:a.txt", r.commit)]);
        assert_eq!(
            String::from_utf8_lossy(&after.stdout),
            "TWO\n",
            "snapshot did not survive the reset it exists to survive"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
