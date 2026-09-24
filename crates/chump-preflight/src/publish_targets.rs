//! EFFECTIVE-1380: artifact_type → publish-target registry (EFFECTIVE-364
//! slice, sibling of EFFECTIVE-363's `artifact_gates` module).
//!
//! Where `artifact_gates` answers "what must this artifact pass before it
//! ships", this module answers "where does it go once it has". A table
//! mapping `artifact_type` (the same column `artifact_gates` keys off of) to
//! an ordered list of publish destinations — docs-site, CHANGELOG,
//! release-notes, substack, screenshots, etc. Adding a further destination
//! for an existing type, or a further type, is a registry row, nothing more.

/// One row in the registry: artifact_type → its ordered publish targets.
#[derive(Debug, Clone, Copy)]
pub struct PublishTargetEntry {
    pub artifact_type: &'static str,
    pub targets: &'static [&'static str],
}

/// The production registry. Types with no publish destination (e.g. "code",
/// which ships via the normal PR/merge pipeline, not a publish step) are
/// deliberately absent — [`targets_for`] returns an empty list for them.
pub const REGISTRY: &[PublishTargetEntry] = &[
    PublishTargetEntry {
        artifact_type: "release-note",
        targets: &["CHANGELOG", "release-notes", "docs-site"],
    },
    PublishTargetEntry {
        artifact_type: "blog-post",
        targets: &["docs-site", "substack"],
    },
    PublishTargetEntry {
        artifact_type: "demo-recording",
        targets: &["screenshots", "docs-site"],
    },
];

/// Look up publish targets for an artifact type against an arbitrary table.
/// Generic over the table (not hardcoded to [`REGISTRY`]) so tests can prove
/// "new type = new registry row" with a local table, mirroring
/// `artifact_gates::resolve_gates`.
pub fn resolve_targets<'a>(
    table: &'a [PublishTargetEntry],
    artifact_type: &str,
) -> &'a [&'static str] {
    table
        .iter()
        .find(|e| e.artifact_type == artifact_type)
        .map(|e| e.targets)
        .unwrap_or(&[])
}

/// Look up publish targets for `artifact_type` in the production
/// [`REGISTRY`]. Artifact types with no registry entry (or entries with an
/// empty `targets` list) return an empty slice — never an error — since "no
/// publish destination" is a valid, expected answer (e.g. "code").
pub fn targets_for(artifact_type: &str) -> &'static [&'static str] {
    resolve_targets(REGISTRY, artifact_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AC#1 + AC#3 (three types, multiple targets each): the registry
    /// returns an ordered, non-empty target list for each registered type.
    #[test]
    fn returns_ordered_targets_for_registered_types() {
        assert_eq!(
            targets_for("release-note"),
            &["CHANGELOG", "release-notes", "docs-site"]
        );
        assert_eq!(targets_for("blog-post"), &["docs-site", "substack"]);
        assert_eq!(targets_for("demo-recording"), &["screenshots", "docs-site"]);
    }

    /// AC#2 + AC#3 (one type with no targets): an unregistered artifact_type
    /// — including "code", which ships via the PR pipeline, not a publish
    /// step — returns an empty list rather than erroring.
    #[test]
    fn returns_empty_for_types_with_no_publish_targets() {
        assert!(targets_for("code").is_empty());
        assert!(targets_for("totally-unregistered-type").is_empty());
    }

    /// AC#1: adding a further artifact type requires only a registry entry,
    /// proven the same way `artifact_gates` proves it — via a local table
    /// rather than editing production `REGISTRY`.
    #[test]
    fn fixture_type_resolves_via_registry_entry_only() {
        const FIXTURE_TABLE: &[PublishTargetEntry] = &[
            PublishTargetEntry {
                artifact_type: "release-note",
                targets: &["CHANGELOG", "release-notes", "docs-site"],
            },
            PublishTargetEntry {
                artifact_type: "fixture-widget",
                targets: &["fixture-dest"],
            },
        ];

        assert_eq!(
            resolve_targets(FIXTURE_TABLE, "fixture-widget"),
            &["fixture-dest"]
        );
        assert!(resolve_targets(FIXTURE_TABLE, "not-in-table").is_empty());
    }
}
