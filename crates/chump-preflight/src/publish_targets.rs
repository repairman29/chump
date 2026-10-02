//! EFFECTIVE-1380: artifact_type → publish-target registry (EFFECTIVE-364 slice).
//!
//! EFFECTIVE-364's publication resolver needs to answer "given a shipped
//! gap's artifact_type, which publish destinations does it queue work
//! against" (docs-site refresh, CHANGELOG append, release-notes queue,
//! substack draft, screenshots, ...). This module is that lookup table,
//! mirroring the `artifact_gates` pattern in this same crate: one row per
//! artifact_type, ordered targets, `None`/empty for types that don't
//! publish anywhere (most code-infra gaps).
//!
//! Adding a further artifact_type or target = adding/editing one row here
//! — no other code changes required.

/// One row in the registry: artifact_type → its ordered publish targets.
#[derive(Debug, Clone, Copy)]
pub struct PublishTargetEntry {
    pub artifact_type: &'static str,
    pub targets: &'static [&'static str],
}

/// The production registry. Types absent from this table (or present with
/// an empty `targets` slice) have no publish targets — callers should
/// treat that as a clean no-op, not an error (EFFECTIVE-1380 AC#2).
pub const REGISTRY: &[PublishTargetEntry] = &[
    PublishTargetEntry {
        artifact_type: "release-note",
        targets: &["docs-site", "CHANGELOG", "release-notes", "substack"],
    },
    PublishTargetEntry {
        artifact_type: "product-launch",
        targets: &["docs-site", "substack", "screenshots"],
    },
    PublishTargetEntry {
        artifact_type: "blog-post",
        targets: &["substack", "docs-site"],
    },
    PublishTargetEntry {
        artifact_type: "code",
        targets: &[],
    },
];

/// Look up publish targets for an artifact type against an arbitrary table.
/// Generic over the table (not hardcoded to [`REGISTRY`]) so tests can
/// prove "new type = new registry row" without editing this module.
pub fn resolve_targets<'a>(table: &'a [PublishTargetEntry], artifact_type: &str) -> &'a [&'a str] {
    table
        .iter()
        .find(|e| e.artifact_type == artifact_type)
        .map(|e| e.targets)
        .unwrap_or(&[])
}

/// Look up publish targets for `artifact_type` in the production
/// [`REGISTRY`]. Returns an empty slice for unknown types or types with no
/// configured targets — never panics, never errors.
pub fn targets_for(artifact_type: &str) -> &'static [&'static str] {
    resolve_targets(REGISTRY, artifact_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_note_has_multiple_targets() {
        let targets = targets_for("release-note");
        assert_eq!(
            targets,
            &["docs-site", "CHANGELOG", "release-notes", "substack"]
        );
    }

    #[test]
    fn product_launch_has_multiple_targets() {
        let targets = targets_for("product-launch");
        assert_eq!(targets, &["docs-site", "substack", "screenshots"]);
    }

    #[test]
    fn blog_post_has_multiple_targets() {
        let targets = targets_for("blog-post");
        assert_eq!(targets, &["substack", "docs-site"]);
    }

    #[test]
    fn code_has_no_publish_targets() {
        let targets = targets_for("code");
        assert!(targets.is_empty());
    }

    #[test]
    fn unknown_artifact_type_returns_empty() {
        let targets = targets_for("totally-unregistered-type");
        assert!(targets.is_empty());
    }

    #[test]
    fn fixture_type_dispatch_via_registry_entry_only() {
        // Proves "new type = new registry row" by constructing a fixture
        // table instead of editing the production REGISTRY.
        const FIXTURE: &[PublishTargetEntry] = &[PublishTargetEntry {
            artifact_type: "design-asset",
            targets: &["screenshots"],
        }];
        assert_eq!(resolve_targets(FIXTURE, "design-asset"), &["screenshots"]);
        assert!(resolve_targets(FIXTURE, "code").is_empty());
    }
}
