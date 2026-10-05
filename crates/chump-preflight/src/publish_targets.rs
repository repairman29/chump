//! EFFECTIVE-1380 (EFFECTIVE-1255 / EFFECTIVE-364 slice): artifact_type →
//! publish-target registry.
//!
//! EFFECTIVE-364 (publication stage after ship) needs to answer "where does
//! this artifact_type get published" before it can reserve publish-work
//! gaps. This module is that lookup: a table mapping `artifact_type` (the
//! column from [`crate::artifact_gates`], EFFECTIVE-363) to an ordered list
//! of publish targets (docs-site, CHANGELOG, release-notes, substack,
//! screenshots, ...). It mirrors `artifact_gates`'s registry shape on
//! purpose — same lookup pattern, same "no entry = empty, not an error"
//! contract — so EFFECTIVE-364's resolver can compose both without two
//! different APIs.
//!
//! This module does not reserve gaps, route to the approval queue, or post
//! anywhere — it only answers "what are the targets", which is the slice
//! EFFECTIVE-364 depends on.

/// One row in the registry: artifact_type → its ordered publish targets.
#[derive(Debug, Clone, Copy)]
pub struct PublishTargetEntry {
    pub artifact_type: &'static str,
    pub targets: &'static [&'static str],
}

/// The production registry. Adding a further artifact type = adding one row
/// here. Types with no publish destination (mostly code/infra gaps) are
/// deliberately absent — `targets_for` returns an empty list for them, not
/// an error.
pub const REGISTRY: &[PublishTargetEntry] = &[
    PublishTargetEntry {
        artifact_type: "release-note",
        targets: &["CHANGELOG", "release-notes", "docs-site"],
    },
    PublishTargetEntry {
        artifact_type: "doc",
        targets: &["docs-site"],
    },
    PublishTargetEntry {
        artifact_type: "copy",
        targets: &["substack", "docs-site"],
    },
    PublishTargetEntry {
        artifact_type: "design",
        targets: &["screenshots", "docs-site"],
    },
];

/// Look up publish targets for an artifact type against an arbitrary table.
/// Generic over the table (not hardcoded to [`REGISTRY`]) so tests — and
/// later, EFFECTIVE-364's resolver — can prove "new type = new registry
/// row" without editing this module.
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
/// [`REGISTRY`]. Always returns a list — empty, never `None` — because "no
/// publish targets" is a valid, expected answer (e.g. `code`), not a lookup
/// failure.
pub fn targets_for(artifact_type: &str) -> &'static [&'static str] {
    resolve_targets(REGISTRY, artifact_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AC#1/#3: multiple registered types each return their ordered targets.
    #[test]
    fn registered_types_return_ordered_targets() {
        assert_eq!(
            targets_for("release-note"),
            &["CHANGELOG", "release-notes", "docs-site"]
        );
        assert_eq!(targets_for("doc"), &["docs-site"]);
        assert_eq!(targets_for("copy"), &["substack", "docs-site"]);
        assert_eq!(targets_for("design"), &["screenshots", "docs-site"]);
    }

    /// AC#2: an artifact_type with no registry entry returns an empty list,
    /// not an error — "code" is the real-world case (most code/infra gaps
    /// have nothing to publish).
    #[test]
    fn unregistered_type_returns_empty_list() {
        assert!(targets_for("code").is_empty());
        assert!(targets_for("totally-unregistered-type").is_empty());
    }

    /// Proves the table is generic: a local fixture table with one extra
    /// row dispatches correctly without touching REGISTRY/production code,
    /// the same mechanism a real new-type PR would exercise.
    #[test]
    fn fixture_table_resolves_independently_of_production_registry() {
        const FIXTURE_TABLE: &[PublishTargetEntry] = &[PublishTargetEntry {
            artifact_type: "fixture-widget",
            targets: &["fixture-target"],
        }];

        assert_eq!(
            resolve_targets(FIXTURE_TABLE, "fixture-widget"),
            &["fixture-target"]
        );
        assert!(resolve_targets(FIXTURE_TABLE, "not-in-table").is_empty());
    }
}
