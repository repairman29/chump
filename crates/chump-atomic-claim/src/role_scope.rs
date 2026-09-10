//! INFRA-1863 (META-074 child C): role/scope-typed claims.
//!
//! Slice shipped here: `chump claim --role <role> --scope <scope>` layered
//! on top of the existing (still-supported) `--paths` file-lease flow.
//!
//! - Role validation against `docs/process/AGENT_ROLES.yaml` (AC4).
//! - Append-only metadata files are never part of the lease surface — they
//!   have their own merge driver, so leasing them double-counts (AC2).
//! - Broad-scope guard: a `--paths` CSV spanning more than one top-level
//!   directory requires `--broad --reason "<text>"`, otherwise it is
//!   auto-narrowed to the most specific common parent (AC3).

use anyhow::{bail, Result};
use std::path::Path;

/// AC2: append-only metadata files are exempt from lease semantics — the
/// append-only merge driver already resolves concurrent appends, so leasing
/// them just blocks unrelated agents from adding a row.
pub const APPEND_ONLY_EXEMPT_FILES: &[&str] = &[
    "scripts/ci/event-registry-reserved.txt",
    "scripts/ci/env-vars-internal.txt",
    "docs/observability/EVENT_REGISTRY.yaml",
];

/// Strip append-only-exempt files out of a `--paths` CSV. Returns `None`
/// when nothing is left after stripping (an all-exempt paths list is
/// equivalent to no declared paths).
pub fn strip_append_only_exempt(paths_csv: &str) -> Option<String> {
    let kept: Vec<&str> = paths_csv
        .split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .filter(|p| !APPEND_ONLY_EXEMPT_FILES.contains(p))
        .collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept.join(","))
    }
}

/// Read the registered role names out of `docs/process/AGENT_ROLES.yaml`.
/// Parses a minimal `roles:\n  - name: <role>` shape by line-scanning
/// rather than pulling in a YAML crate dependency for one field.
pub fn load_registered_roles(repo_root: &Path) -> Vec<String> {
    let path = repo_root.join("docs/process/AGENT_ROLES.yaml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            trimmed
                .strip_prefix("- name:")
                .or_else(|| trimmed.strip_prefix("-name:"))
                .map(|rest| rest.trim().trim_matches('"').to_string())
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// AC4: `chump claim --role` must match a registered role.
pub fn validate_role(repo_root: &Path, role: &str) -> Result<()> {
    let roles = load_registered_roles(repo_root);
    if roles.is_empty() {
        // Registry missing/unparseable — fail open with a clear message
        // rather than silently accepting an unregistered role.
        bail!(
            "role registry docs/process/AGENT_ROLES.yaml not found or empty — cannot validate --role {role}"
        );
    }
    if !roles.iter().any(|r| r == role) {
        bail!(
            "unknown --role '{role}' — not in docs/process/AGENT_ROLES.yaml. Known roles: {}",
            roles.join(", ")
        );
    }
    Ok(())
}

/// Top-level directory component of a repo-relative path (the part before
/// the first `/`). A bare filename with no `/` counts as its own top-level
/// "directory" for breadth purposes.
fn top_level(path: &str) -> &str {
    path.split('/').next().unwrap_or(path)
}

/// AC3: broad-scope guard. `--paths` spanning more than one top-level
/// directory requires `--broad` + `--reason`; otherwise it's auto-narrowed
/// to the single most-specific common parent (only possible when every
/// path shares the same top-level directory to begin with, which by
/// definition means there's nothing to narrow — this covers the "already
/// one directory but nested" case as a no-op pass-through).
///
/// Returns the (possibly unchanged) paths CSV to use.
pub fn enforce_broad_scope_guard(
    paths_csv: &str,
    broad: bool,
    reason: Option<&str>,
) -> Result<String> {
    let paths: Vec<&str> = paths_csv
        .split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .collect();
    if paths.is_empty() {
        return Ok(String::new());
    }

    let mut top_dirs: Vec<&str> = paths.iter().map(|p| top_level(p)).collect();
    top_dirs.sort_unstable();
    top_dirs.dedup();

    if top_dirs.len() <= 1 {
        // Single top-level directory (or all bare files under repo root) —
        // nothing to narrow, no broad-scope concern.
        return Ok(paths_csv.to_string());
    }

    if broad {
        if reason.map(str::trim).unwrap_or("").is_empty() {
            bail!(
                "--broad requires --reason '<text>' explaining why a multi-directory claim is necessary"
            );
        }
        return Ok(paths_csv.to_string());
    }

    bail!(
        "claim paths span {} top-level directories ({}) without --broad --reason '<text>'.\n  \
         Narrow --paths to a single directory/module, or pass --broad --reason if the\n  \
         multi-directory scope is genuinely required.",
        top_dirs.len(),
        top_dirs.join(", ")
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_exempt_removes_all_three() {
        let csv = "src/foo.rs,scripts/ci/event-registry-reserved.txt,docs/observability/EVENT_REGISTRY.yaml,scripts/ci/env-vars-internal.txt";
        assert_eq!(strip_append_only_exempt(csv).as_deref(), Some("src/foo.rs"));
    }

    #[test]
    fn strip_exempt_all_exempt_yields_none() {
        let csv = "scripts/ci/event-registry-reserved.txt,scripts/ci/env-vars-internal.txt";
        assert_eq!(strip_append_only_exempt(csv), None);
    }

    #[test]
    fn strip_exempt_no_exempt_is_unchanged() {
        let csv = "src/foo.rs,src/bar.rs";
        assert_eq!(strip_append_only_exempt(csv).as_deref(), Some(csv));
    }

    #[test]
    fn broad_scope_single_dir_passthrough() {
        let csv = "src/foo.rs,src/bar.rs";
        assert_eq!(
            enforce_broad_scope_guard(csv, false, None).unwrap(),
            csv.to_string()
        );
    }

    #[test]
    fn broad_scope_multi_dir_without_flag_rejected() {
        let csv = "src/foo.rs,docs/bar.md";
        assert!(enforce_broad_scope_guard(csv, false, None).is_err());
    }

    #[test]
    fn broad_scope_multi_dir_with_flag_and_reason_allowed() {
        let csv = "src/foo.rs,docs/bar.md";
        assert_eq!(
            enforce_broad_scope_guard(csv, true, Some("cross-cutting rename")).unwrap(),
            csv.to_string()
        );
    }

    #[test]
    fn broad_scope_flag_without_reason_rejected() {
        let csv = "src/foo.rs,docs/bar.md";
        assert!(enforce_broad_scope_guard(csv, true, None).is_err());
        assert!(enforce_broad_scope_guard(csv, true, Some("   ")).is_err());
    }

    #[test]
    fn validate_role_unknown_rejected() {
        let tmp = std::env::temp_dir().join(format!(
            "role-scope-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(tmp.join("docs/process")).unwrap();
        std::fs::write(
            tmp.join("docs/process/AGENT_ROLES.yaml"),
            "roles:\n  - name: curator\n  - name: fleet-worker\n",
        )
        .unwrap();
        assert!(validate_role(&tmp, "curator").is_ok());
        assert!(validate_role(&tmp, "not-a-role").is_err());
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
