//! The ONE resolver for the Chump gap store path (INFRA-8190, Phase R R4).
//!
//! Before this crate, the `state.db` path was rebuilt ad hoc at ~30 call
//! sites (`repo_root.join(".chump/state.db")`), some honoring
//! `CHUMP_STATE_DB` and some not, none normalizing a linked worktree to its
//! main checkout. The result on cuphead (2026-10-15): the interactive CLI
//! (which sourced `~/.chump/node.env` and so pinned `~/.chump/state.db`, 8,264
//! gaps) and the fleet server + workers (no pin, so `<repo>/.chump/state.db`,
//! 465 gaps) were reading two different databases.
//!
//! Precedence (mirrored exactly by `scripts/coord/lib/state-store.sh`):
//!
//! 1. `CHUMP_STATE_DB` if set and non-empty (leading `~` expands to `$HOME`).
//! 2. The git checkout containing `root` (walking up): the MAIN checkout's
//!    `.chump/state.db`. A linked worktree (`.git` is a file whose gitdir has
//!    a `commondir`) resolves to its main checkout, matching the
//!    `--git-common-dir` convention of `scripts/lib/lease.sh` and the
//!    worktree `state.db` symlinks `chump claim` / `chump dispatch` create.
//! 3. No checkout above `root`: `<root>/.chump/state.db` (an explicit root is
//!    honored, which is what test fixtures rely on). When `root` is `$HOME`
//!    this is the legacy `~/.chump/state.db`; that case prints a one-line
//!    stderr warning once per process.
//!
//! `CHUMP_STATE_DIR` is deliberately NOT consulted: it names the node-state
//! directory (`providers.env`, `node.env`, heartbeats), not the gap store.

#![warn(missing_docs)]

use std::path::{Component, Path, PathBuf};
use std::sync::Once;

/// The single env override for the gap store path.
pub const STATE_DB_ENV: &str = "CHUMP_STATE_DB";

/// Why the resolver picked the path it picked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreSource {
    /// `CHUMP_STATE_DB` was set.
    Env,
    /// The root is inside a main git checkout.
    MainCheckout,
    /// The root is inside a linked worktree; resolved to its main checkout.
    LinkedWorktree,
    /// No git checkout above the root; the explicit root was used.
    NoCheckout,
    /// No git checkout and the root is `$HOME`: legacy `~/.chump/state.db`.
    HomeFallback,
}

impl StoreSource {
    /// Stable machine-readable label (used by `chump gap store-path --json`
    /// and the single-source gate).
    pub fn as_str(&self) -> &'static str {
        match self {
            StoreSource::Env => "env",
            StoreSource::MainCheckout => "main-checkout",
            StoreSource::LinkedWorktree => "linked-worktree",
            StoreSource::NoCheckout => "no-checkout",
            StoreSource::HomeFallback => "home-fallback",
        }
    }
}

/// A resolved store location plus the evidence for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedStore {
    /// Absolute-or-as-given path to `state.db`.
    pub path: PathBuf,
    /// Which precedence rule fired.
    pub source: StoreSource,
    /// The checkout root the store was derived from, when one was found.
    pub checkout: Option<PathBuf>,
}

impl ResolvedStore {
    /// One human-readable line explaining the choice.
    pub fn reason(&self) -> String {
        match self.source {
            StoreSource::Env => format!("{STATE_DB_ENV} is set"),
            StoreSource::MainCheckout => format!(
                "git checkout {}",
                self.checkout.as_deref().unwrap_or(Path::new("?")).display()
            ),
            StoreSource::LinkedWorktree => format!(
                "linked worktree; resolved to main checkout {}",
                self.checkout.as_deref().unwrap_or(Path::new("?")).display()
            ),
            StoreSource::NoCheckout => "no git checkout above the root; using the root".to_string(),
            StoreSource::HomeFallback => {
                "no git checkout; legacy ~/.chump fallback (set CHUMP_STATE_DB or run from the chump checkout)"
                    .to_string()
            }
        }
    }
}

/// Resolve the gap store for `root` using the live environment.
pub fn resolve(root: &Path) -> ResolvedStore {
    let env = std::env::var(STATE_DB_ENV).ok();
    let home = home_dir();
    resolve_with(root, env.as_deref(), home.as_deref())
}

/// Resolve the gap store for `root` and return just the path. Prints a
/// one-line stderr warning (once per process) on the `~/.chump` fallback.
/// This is what every Rust call site should use instead of
/// `root.join(".chump/state.db")`.
pub fn state_db_path(root: &Path) -> PathBuf {
    let r = resolve(root);
    if r.source == StoreSource::HomeFallback {
        static WARN: Once = Once::new();
        WARN.call_once(|| {
            eprintln!(
                "chump: warning: not inside a git checkout; gap store falls back to {} (set CHUMP_STATE_DB or run from the chump checkout) [INFRA-8190]",
                r.path.display()
            );
        });
    }
    r.path
}

/// Pure resolver: no env or home lookups, so tests can drive every branch.
pub fn resolve_with(root: &Path, env_state_db: Option<&str>, home: Option<&Path>) -> ResolvedStore {
    if let Some(raw) = env_state_db.map(str::trim).filter(|s| !s.is_empty()) {
        return ResolvedStore {
            path: expand_tilde(raw, home),
            source: StoreSource::Env,
            checkout: None,
        };
    }
    let abs_root = absolutize(root);
    if let Some((checkout, linked)) = find_checkout(&abs_root) {
        return ResolvedStore {
            path: checkout.join(".chump").join("state.db"),
            source: if linked {
                StoreSource::LinkedWorktree
            } else {
                StoreSource::MainCheckout
            },
            checkout: Some(checkout),
        };
    }
    let is_home = home
        .map(|h| same_dir(&absolutize(h), &abs_root))
        .unwrap_or(false);
    ResolvedStore {
        path: root.join(".chump").join("state.db"),
        source: if is_home {
            StoreSource::HomeFallback
        } else {
            StoreSource::NoCheckout
        },
        checkout: None,
    }
}

/// Walk up from `start` to the nearest directory holding `.git`. Returns the
/// MAIN checkout root and whether `start` was inside a linked worktree.
///
/// - `.git` directory: that directory's parent is a main checkout.
/// - `.git` file (`gitdir: <path>`) whose gitdir has a `commondir`: a linked
///   worktree; the main checkout is the parent of the common `.git` dir.
/// - `.git` file without `commondir` (a submodule) or a bare common dir: the
///   directory itself is treated as the checkout.
pub fn find_checkout(start: &Path) -> Option<(PathBuf, bool)> {
    let start = absolutize(start);
    for dir in start.ancestors() {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return Some((dir.to_path_buf(), false));
        }
        if dot_git.is_file() {
            return Some(match linked_worktree_main(dir, &dot_git) {
                Some(main) => (main, true),
                None => (dir.to_path_buf(), false),
            });
        }
    }
    None
}

fn linked_worktree_main(dir: &Path, dot_git_file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(dot_git_file).ok()?;
    let gitdir_raw = text
        .lines()
        .find_map(|l| l.strip_prefix("gitdir:"))
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let gitdir = join_abs(dir, gitdir_raw);
    let commondir_raw = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = join_abs(&gitdir, commondir_raw.trim());
    let common = std::fs::canonicalize(&common).unwrap_or_else(|_| lexical_normalize(&common));
    if common.file_name().map(|n| n == ".git").unwrap_or(false) {
        common.parent().map(Path::to_path_buf)
    } else {
        // Bare common dir: there is no main working tree to share.
        None
    }
}

fn join_abs(base: &Path, p: &str) -> PathBuf {
    let pb = PathBuf::from(p);
    if pb.is_absolute() {
        pb
    } else {
        base.join(pb)
    }
}

fn expand_tilde(raw: &str, home: Option<&Path>) -> PathBuf {
    if raw == "~" {
        if let Some(h) = home {
            return h.to_path_buf();
        }
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(h) = home {
            return h.join(rest);
        }
    }
    PathBuf::from(raw)
}

fn absolutize(p: &Path) -> PathBuf {
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|c| c.join(p))
            .unwrap_or_else(|_| p.to_path_buf())
    }
}

fn same_dir(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => lexical_normalize(a) == lexical_normalize(b),
    }
}

fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
}

/// Marker file placed beside a `state.db` to declare that store an
/// expected non-canonical replica (RESILIENT-1650, Phase R R4).
pub const NONCANONICAL_MARKER: &str = "NONCANONICAL";

/// Marker file placed beside a retired/archived `state.db` (CREDIBLE-1602).
pub const ARCHIVED_MARKER: &str = "CHUMP_STORE_ARCHIVED";

/// Classification of a discovered `state.db` on a node (RESILIENT-1650).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GapStoreStatus {
    /// The canonical store resolved for this node.
    Canonical,
    /// A non-canonical copy explicitly marked with a `NONCANONICAL` file
    /// beside `state.db` (expected; not a warning).
    NonCanonicalMarked,
    /// A non-canonical copy without a `NONCANONICAL` marker beside it
    /// (unexpected; emits a warning with its path).
    Unmarked,
}

impl GapStoreStatus {
    /// Stable label required by RESILIENT-1650 AC1:
    /// `"canonical"`, `"non-canonical"`, or `"UNMARKED"`.
    pub fn as_str(&self) -> &'static str {
        match self {
            GapStoreStatus::Canonical => "canonical",
            GapStoreStatus::NonCanonicalMarked => "non-canonical",
            GapStoreStatus::Unmarked => "UNMARKED",
        }
    }
}

/// One `state.db` discovered on the node (RESILIENT-1650).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredGapStore {
    /// Path to `state.db`.
    pub path: PathBuf,
    /// Where this candidate was found (`"CHUMP_STATE_DB"`, `"repo"`, `"home"`, `"scan"`).
    pub origin: String,
    /// Classification (`Canonical`, `NonCanonicalMarked`, `Unmarked`).
    pub status: GapStoreStatus,
}

impl DiscoveredGapStore {
    /// Human-readable one-line description for `chump health` / `chump fleet doctor`.
    pub fn summary_line(&self) -> String {
        match self.status {
            GapStoreStatus::Canonical => {
                format!("{} [canonical ({})]", self.path.display(), self.origin)
            }
            GapStoreStatus::NonCanonicalMarked => {
                format!(
                    "{} [non-canonical: {} marker beside store — expected ({})]",
                    self.path.display(),
                    NONCANONICAL_MARKER,
                    self.origin
                )
            }
            GapStoreStatus::Unmarked => {
                format!(
                    "WARN: {} [UNMARKED non-canonical gap store ({})]",
                    self.path.display(),
                    self.origin
                )
            }
        }
    }
}

/// Full node gap-store audit report (RESILIENT-1650).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NodeGapStoreReport {
    /// Path resolved as the node's canonical store.
    pub canonical_path: PathBuf,
    /// Every `state.db` found on the node, classified.
    pub stores: Vec<DiscoveredGapStore>,
    /// Warnings for any `UNMARKED` non-canonical stores (each includes the path).
    pub warnings: Vec<String>,
}

/// Return true if `db_path` sits in a directory carrying a `NONCANONICAL`
/// marker file (`<dir>/NONCANONICAL`).
pub fn has_noncanonical_marker(db_path: &Path) -> bool {
    db_path
        .parent()
        .map(|d| d.join(NONCANONICAL_MARKER).exists())
        .unwrap_or(false)
}

/// Return true if `db_path` sits in a directory carrying a
/// `CHUMP_STORE_ARCHIVED` marker file (`<dir>/CHUMP_STORE_ARCHIVED`).
pub fn has_archived_marker(db_path: &Path) -> bool {
    db_path
        .parent()
        .map(|d| d.join(ARCHIVED_MARKER).exists())
        .unwrap_or(false)
}

/// Inspect all gap stores discoverable on this node using the live environment
/// (`CHUMP_STATE_DB`, repo `.chump/state.db`, `~/.chump/state.db`, and a shallow
/// scan of `$HOME` / `CHUMP_STORE_SCAN_DIRS`). Strictly read-only: never opens,
/// syncs, restores, or copies any database file (RESILIENT-1650 AC1-AC3).
pub fn inspect_node_stores(root: &Path) -> NodeGapStoreReport {
    let env_db = std::env::var(STATE_DB_ENV).ok();
    let home = home_dir();
    let extra_dirs: Vec<PathBuf> = std::env::var("CHUMP_STORE_SCAN_DIRS")
        .ok()
        .map(|raw| {
            raw.split(':')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .collect()
        })
        .unwrap_or_default();
    inspect_node_stores_with(root, env_db.as_deref(), home.as_deref(), &extra_dirs)
}

/// Pure/testable node gap-store inspector (RESILIENT-1650).
/// Lists every existing `state.db` it can find across `env_state_db`, `root`,
/// `home`, and `extra_scan_dirs`, classifying each as `canonical`,
/// `non-canonical` (`NONCANONICAL` marker beside it — expected), or `UNMARKED`
/// (warning with path).
pub fn inspect_node_stores_with(
    root: &Path,
    env_state_db: Option<&str>,
    home: Option<&Path>,
    extra_scan_dirs: &[PathBuf],
) -> NodeGapStoreReport {
    let resolved = resolve_with(root, env_state_db, home);
    let canonical_path = resolved.path.clone();

    let mut candidates: Vec<(PathBuf, String)> = Vec::new();
    if let Some(raw) = env_state_db.map(str::trim).filter(|s| !s.is_empty()) {
        candidates.push((expand_tilde(raw, home), "CHUMP_STATE_DB".to_string()));
    }
    let abs_root = absolutize(root);
    if let Some((checkout, _)) = find_checkout(&abs_root) {
        candidates.push((checkout.join(".chump").join("state.db"), "repo".to_string()));
    }
    candidates.push((root.join(".chump").join("state.db"), "repo".to_string()));
    if let Some(h) = home {
        candidates.push((h.join(".chump").join("state.db"), "home".to_string()));
        scan_for_state_dbs(h, 0, 3, &mut candidates);
    }
    for dir in extra_scan_dirs {
        candidates.push((dir.join(".chump").join("state.db"), "scan".to_string()));
        scan_for_state_dbs(dir, 0, 3, &mut candidates);
    }

    let mut seen_keys: Vec<PathBuf> = Vec::new();
    let mut stores: Vec<DiscoveredGapStore> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    for (cand, origin) in candidates {
        // Ignore non-existent paths and symlinks (a worktree symlink into the
        // canonical store is not a separate store).
        let Ok(sym_meta) = std::fs::symlink_metadata(&cand) else {
            continue;
        };
        if !sym_meta.file_type().is_file() {
            continue;
        }
        if has_archived_marker(&cand) {
            continue;
        }
        let dedup_key =
            std::fs::canonicalize(&cand).unwrap_or_else(|_| lexical_normalize(&absolutize(&cand)));
        if seen_keys.contains(&dedup_key) {
            continue;
        }
        seen_keys.push(dedup_key);

        let status = if has_noncanonical_marker(&cand) {
            GapStoreStatus::NonCanonicalMarked
        } else if same_file_or_path(&cand, &canonical_path) {
            GapStoreStatus::Canonical
        } else {
            GapStoreStatus::Unmarked
        };

        if status == GapStoreStatus::Unmarked {
            warnings.push(format!(
                "WARN: unmarked non-canonical gap store at {} (mark with {} beside it if expected, or archive with scripts/coord/archive-stale-gap-store.sh)",
                cand.display(),
                NONCANONICAL_MARKER
            ));
        }

        stores.push(DiscoveredGapStore {
            path: cand,
            origin,
            status,
        });
    }

    NodeGapStoreReport {
        canonical_path,
        stores,
        warnings,
    }
}

fn same_file_or_path(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => lexical_normalize(&absolutize(a)) == lexical_normalize(&absolutize(b)),
    }
}

fn scan_for_state_dbs(
    dir: &Path,
    depth: usize,
    max_depth: usize,
    out: &mut Vec<(PathBuf, String)>,
) {
    if depth > max_depth {
        return;
    }
    let candidate = dir.join(".chump").join("state.db");
    if let Ok(meta) = std::fs::symlink_metadata(&candidate) {
        if meta.file_type().is_file() {
            out.push((candidate, "scan".to_string()));
        }
    }
    if depth == max_depth {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if !ft.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if matches!(
            name_str.as_ref(),
            ".chump" | ".git" | "tmp" | ".cache" | "node_modules" | ".cargo" | ".rustup" | "target"
        ) || name_str.ends_with("-backup")
        {
            continue;
        }
        scan_for_state_dbs(&entry.path(), depth + 1, max_depth, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .expect("git runs");
        assert!(st.success(), "git {args:?} failed");
    }

    fn canon(p: &Path) -> PathBuf {
        std::fs::canonicalize(p).unwrap()
    }

    #[test]
    fn env_override_wins_over_everything() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let r = resolve_with(d.path(), Some("/x/y/state.db"), None);
        assert_eq!(r.source, StoreSource::Env);
        assert_eq!(r.path, PathBuf::from("/x/y/state.db"));
    }

    #[test]
    fn env_override_expands_tilde_and_ignores_blank() {
        let home = Path::new("/fixture-home/op");
        let r = resolve_with(Path::new("/nowhere"), Some("~/s/state.db"), Some(home));
        assert_eq!(r.path, PathBuf::from("/fixture-home/op/s/state.db"));
        let d = tempfile::tempdir().unwrap();
        let r = resolve_with(d.path(), Some("   "), None);
        assert_ne!(r.source, StoreSource::Env, "blank CHUMP_STATE_DB is unset");
    }

    #[test]
    fn main_checkout_resolves_repo_local_even_from_a_subdir() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let sub = d.path().join("crates/x");
        std::fs::create_dir_all(&sub).unwrap();
        let r = resolve_with(&sub, None, None);
        assert_eq!(r.source, StoreSource::MainCheckout);
        assert_eq!(r.path, d.path().join(".chump/state.db"));
    }

    #[test]
    fn explicit_non_git_root_is_honored() {
        let d = tempfile::tempdir().unwrap();
        let r = resolve_with(d.path(), None, Some(Path::new("/definitely/not/home")));
        assert_eq!(r.source, StoreSource::NoCheckout);
        assert_eq!(r.path, d.path().join(".chump/state.db"));
    }

    #[test]
    fn home_without_checkout_is_the_legacy_fallback() {
        let home = tempfile::tempdir().unwrap();
        let r = resolve_with(home.path(), None, Some(home.path()));
        assert_eq!(r.source, StoreSource::HomeFallback);
        assert_eq!(r.path, home.path().join(".chump/state.db"));
    }

    #[test]
    fn linked_worktree_resolves_to_its_main_checkouts_store() {
        let d = tempfile::tempdir().unwrap();
        let main = d.path().join("main");
        std::fs::create_dir(&main).unwrap();
        git(&main, &["init", "-q", "-b", "main"]);
        std::fs::write(main.join("f"), "x").unwrap();
        git(&main, &["add", "f"]);
        git(&main, &["commit", "-q", "-m", "init"]);
        let wt = d.path().join("wt");
        git(
            &main,
            &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "w"],
        );
        assert!(wt.join(".git").is_file(), "worktree .git must be a file");

        let from_main = resolve_with(&main, None, None);
        let from_wt = resolve_with(&wt, None, None);
        let from_wt_sub = resolve_with(&wt.join("."), None, None);
        assert_eq!(from_main.source, StoreSource::MainCheckout);
        assert_eq!(from_wt.source, StoreSource::LinkedWorktree);
        assert_eq!(from_wt_sub.source, StoreSource::LinkedWorktree);
        assert_eq!(
            canon(from_wt.checkout.as_deref().unwrap()),
            canon(&main),
            "worktree must resolve to the MAIN checkout"
        );
        // Same store, compared through the (existing) checkout dir.
        assert_eq!(
            canon(from_wt.path.parent().unwrap().parent().unwrap()),
            canon(from_main.path.parent().unwrap().parent().unwrap())
        );
    }

    #[test]
    fn submodule_style_gitfile_without_commondir_stays_local() {
        let d = tempfile::tempdir().unwrap();
        let fake_gitdir = d.path().join("modules/sub");
        std::fs::create_dir_all(&fake_gitdir).unwrap();
        let sub = d.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(
            sub.join(".git"),
            format!("gitdir: {}\n", fake_gitdir.display()),
        )
        .unwrap();
        let r = resolve_with(&sub, None, None);
        assert_eq!(r.source, StoreSource::MainCheckout);
        assert_eq!(r.path, sub.join(".chump/state.db"));
    }

    #[test]
    fn source_labels_are_stable() {
        assert_eq!(StoreSource::Env.as_str(), "env");
        assert_eq!(StoreSource::LinkedWorktree.as_str(), "linked-worktree");
        assert_eq!(StoreSource::HomeFallback.as_str(), "home-fallback");
    }

    #[test]
    fn resilient_1650_inspect_node_stores_classifies_canonical_marked_and_unmarked() {
        let d = tempfile::tempdir().unwrap();
        let repo = d.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join(".chump")).unwrap();
        let canonical_db = repo.join(".chump/state.db");
        std::fs::write(&canonical_db, b"canonical-bytes").unwrap();

        let home = d.path().join("home");
        // Unmarked store in ~/.chump/state.db
        std::fs::create_dir_all(home.join(".chump")).unwrap();
        let unmarked_db = home.join(".chump/state.db");
        std::fs::write(&unmarked_db, b"unmarked-bytes").unwrap();

        // Marked non-canonical replica in ~/replica/.chump/state.db with NONCANONICAL beside it
        let replica_dir = home.join("replica/.chump");
        std::fs::create_dir_all(&replica_dir).unwrap();
        let marked_db = replica_dir.join("state.db");
        std::fs::write(&marked_db, b"marked-replica-bytes").unwrap();
        std::fs::write(replica_dir.join(NONCANONICAL_MARKER), b"expected replica\n").unwrap();

        let report = inspect_node_stores_with(&repo, None, Some(&home), &[]);
        assert_eq!(
            report.stores.len(),
            3,
            "expected 3 stores: {:?}",
            report.stores
        );

        let by_status = |st: GapStoreStatus| -> Vec<&DiscoveredGapStore> {
            report.stores.iter().filter(|s| s.status == st).collect()
        };
        assert_eq!(by_status(GapStoreStatus::Canonical).len(), 1);
        assert_eq!(by_status(GapStoreStatus::Canonical)[0].path, canonical_db);

        assert_eq!(by_status(GapStoreStatus::NonCanonicalMarked).len(), 1);
        assert_eq!(
            by_status(GapStoreStatus::NonCanonicalMarked)[0].path,
            marked_db
        );
        assert!(
            by_status(GapStoreStatus::NonCanonicalMarked)[0]
                .summary_line()
                .contains("expected"),
            "marked copy must be reported as expected"
        );

        assert_eq!(by_status(GapStoreStatus::Unmarked).len(), 1);
        assert_eq!(by_status(GapStoreStatus::Unmarked)[0].path, unmarked_db);
        assert_eq!(report.warnings.len(), 1);
        assert!(
            report.warnings[0].contains(&unmarked_db.display().to_string()),
            "warning must include unmarked store path: {:?}",
            report.warnings
        );

        // AC3: strictly read-only — canonical and marked stores are byte-unchanged.
        assert_eq!(std::fs::read(&canonical_db).unwrap(), b"canonical-bytes");
        assert_eq!(std::fs::read(&marked_db).unwrap(), b"marked-replica-bytes");
    }
}
