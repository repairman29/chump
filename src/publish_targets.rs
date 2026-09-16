//! EFFECTIVE-1713: artifact_type -> publish-target registry (EFFECTIVE-364 slice).
//!
//! `publish_targets.yml` (repo root) maps each `artifact_type` (chump-gap-store,
//! EFFECTIVE-363) to an ordered array of publish-target identifiers
//! (docs-site refresh, CHANGELOG append, release-notes queue, substack draft,
//! screenshots, ...). The EFFECTIVE-364 publication resolver reads this
//! registry after a gap ships to decide which publish-work gaps to reserve.
//! An `artifact_type` with no entry (or the file missing) resolves to an
//! empty target list — a no-op, not an error, per EFFECTIVE-364 part (d).

use std::collections::HashMap;
use std::path::Path;

/// artifact_type -> ordered publish-target identifiers.
pub type PublishTargetRegistry = HashMap<String, Vec<String>>;

/// Default location of the registry file, relative to the repo root.
pub const DEFAULT_REGISTRY_PATH: &str = "publish_targets.yml";

/// Parse a `publish_targets.yml` registry from its raw YAML contents.
pub fn parse_registry(yaml: &str) -> anyhow::Result<PublishTargetRegistry> {
    let registry: PublishTargetRegistry = serde_yaml::from_str(yaml)?;
    Ok(registry)
}

/// Load the publish-target registry from `repo_root/publish_targets.yml`.
/// A missing file resolves to an empty registry (every artifact_type then
/// looks up to an empty target list) rather than an error, matching the
/// "no-op cleanly when a type has no targets" requirement.
pub fn load_registry(repo_root: &Path) -> anyhow::Result<PublishTargetRegistry> {
    let path = repo_root.join(DEFAULT_REGISTRY_PATH);
    match std::fs::read_to_string(&path) {
        Ok(contents) => parse_registry(&contents),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(PublishTargetRegistry::new()),
        Err(e) => Err(e.into()),
    }
}

/// Query the registry for `artifact_type`'s publish targets. An unknown
/// type returns an empty slice, never an error.
pub fn targets_for<'a>(registry: &'a PublishTargetRegistry, artifact_type: &str) -> &'a [String] {
    registry
        .get(artifact_type)
        .map(|v| v.as_slice())
        .unwrap_or(&[])
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_YAML: &str = "\
release-note:
  - changelog-append
  - docs-site-refresh
doc:
  - docs-site-refresh
";

    /// AC#2 (known type): querying the registry with a known artifact_type
    /// returns the correct target list, in order.
    #[test]
    fn known_artifact_type_returns_correct_targets() {
        let registry = parse_registry(FIXTURE_YAML).unwrap();
        assert_eq!(
            targets_for(&registry, "release-note"),
            &[
                "changelog-append".to_string(),
                "docs-site-refresh".to_string()
            ]
        );
        assert_eq!(
            targets_for(&registry, "doc"),
            &["docs-site-refresh".to_string()]
        );
    }

    /// AC#2 (unknown type): querying with an unknown artifact_type returns
    /// an empty list, not an error.
    #[test]
    fn unknown_artifact_type_returns_empty_list() {
        let registry = parse_registry(FIXTURE_YAML).unwrap();
        assert!(targets_for(&registry, "totally-unregistered-type").is_empty());
    }

    /// A missing registry file resolves to an empty registry rather than
    /// erroring — EFFECTIVE-364 part (d), "no-op cleanly when a type has no
    /// targets."
    #[test]
    fn missing_registry_file_loads_empty_registry() {
        let tmp = tempfile::tempdir().unwrap();
        let registry = load_registry(tmp.path()).unwrap();
        assert!(targets_for(&registry, "release-note").is_empty());
    }

    /// The real `publish_targets.yml` at the repo root parses cleanly and
    /// contains the release-note row this module documents.
    #[test]
    fn production_registry_file_parses_and_resolves_release_note() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let registry = load_registry(repo_root).unwrap();
        assert!(!targets_for(&registry, "release-note").is_empty());
        assert!(targets_for(&registry, "not-a-real-artifact-type").is_empty());
    }
}
