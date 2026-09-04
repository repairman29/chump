//! Runtime dispatch-source resolver (CREDIBLE-780, CREDIBLE-237 slice).
//!
//! CI gates that grep a hardcoded source path for a symbol go silently
//! wrong the moment a refactor moves the code: positive assertions
//! false-fail (noisy) and negative assertions false-pass (silent, the
//! dangerous half — see CREDIBLE-237). `resolve_source` fixes this by
//! checking the current expected home first and falling back to the
//! legacy location, so a gate survives either side of a move.

use std::path::{Path, PathBuf};

/// Post-INFRA-1965 home of the `gap` command group's dispatch wiring.
const NEW_GAP_DISPATCH_SOURCE: &str = "src/commands/gap.rs";
/// Pre-INFRA-1965 (legacy) home of the same wiring.
const LEGACY_GAP_DISPATCH_SOURCE: &str = "src/main.rs";

/// Resolve the file that currently contains the `gap` command group's
/// dispatch wiring: the new location if it exists on disk, else the old
/// hard-coded path as a fallback.
pub fn resolve_source(repo_root: &Path) -> PathBuf {
    resolve_from_candidates(repo_root, &[NEW_GAP_DISPATCH_SOURCE, LEGACY_GAP_DISPATCH_SOURCE])
}

/// Generic version of [`resolve_source`]: returns the first candidate
/// (relative to `repo_root`) that exists on disk. If none exist, returns
/// the last candidate anyway so callers still get a deterministic path
/// to report in an error message rather than an `Option`.
fn resolve_from_candidates(repo_root: &Path, candidates: &[&str]) -> PathBuf {
    for candidate in candidates {
        let path = repo_root.join(candidate);
        if path.exists() {
            return path;
        }
    }
    repo_root.join(candidates.last().expect("candidates must not be empty"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn resolves_new_location_when_present() {
        let dir = tempfile::tempdir().unwrap();
        let new_dir = dir.path().join("src/commands");
        fs::create_dir_all(&new_dir).unwrap();
        fs::write(new_dir.join("gap.rs"), "// gap dispatch").unwrap();

        let resolved = resolve_source(dir.path());
        assert_eq!(resolved, dir.path().join(NEW_GAP_DISPATCH_SOURCE));
    }

    #[test]
    fn falls_back_to_legacy_location_when_new_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/main.rs"), "// legacy dispatch").unwrap();

        let resolved = resolve_source(dir.path());
        assert_eq!(resolved, dir.path().join(LEGACY_GAP_DISPATCH_SOURCE));
    }

    #[test]
    fn falls_back_to_last_candidate_when_neither_exists() {
        let dir = tempfile::tempdir().unwrap();
        let resolved = resolve_source(dir.path());
        assert_eq!(resolved, dir.path().join(LEGACY_GAP_DISPATCH_SOURCE));
    }
}
