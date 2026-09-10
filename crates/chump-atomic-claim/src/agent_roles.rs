//! INFRA-5773 (INFRA-1863 slice): `chump claim --role <role>` validation
//! against the `docs/process/AGENT_ROLES.yaml` registry.
//!
//! Deliberately minimal YAML parsing (no serde_yaml dependency added to this
//! crate): the registry format is a fixed two-level shape (`roles:` ->
//! `<role-name>:` -> nested fields), so a line-oriented scan for
//! 2-space-indented keys under `roles:` is sufficient and keeps this crate's
//! build graph small (EFFECTIVE-399 rationale for splitting this crate out
//! in the first place).

use anyhow::{bail, Result};
use std::path::Path;

/// Relative path (from repo root) to the canonical role registry.
pub const REGISTRY_PATH: &str = "docs/process/AGENT_ROLES.yaml";

/// Parse role names out of `docs/process/AGENT_ROLES.yaml`'s `roles:` map.
/// Returns them in file order. Errors if the file is missing/unreadable or
/// has no `roles:` top-level key.
pub fn list_roles(repo_root: &Path) -> Result<Vec<String>> {
    let path = repo_root.join(REGISTRY_PATH);
    let text = std::fs::read_to_string(&path)
        .map_err(|e| anyhow::anyhow!("failed to read {}: {e}", path.display()))?;

    let mut roles = Vec::new();
    let mut in_roles_block = false;
    for line in text.lines() {
        if line.trim_start().starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if line == "roles:" {
            in_roles_block = true;
            continue;
        }
        if !in_roles_block {
            continue;
        }
        // A 2-space-indented `<name>:` line (not deeper-indented) is a role key.
        // Deeper-indented fields (description/skills/list items) are skipped.
        if let Some(rest) = line.strip_prefix("  ") {
            if rest.starts_with(' ') {
                continue; // nested field (4+ space indent) — not a role name
            }
            if let Some(name) = rest.strip_suffix(':') {
                if !name.is_empty() {
                    roles.push(name.to_string());
                }
            }
        } else {
            // Dedented back to column 0 — end of the roles: block.
            break;
        }
    }

    if roles.is_empty() {
        bail!(
            "no roles found under `roles:` in {} — registry malformed or empty",
            path.display()
        );
    }
    Ok(roles)
}

/// Validate `role` against the registry. Returns a clear, actionable error
/// (naming the offending role + listing valid roles) when unregistered.
pub fn validate_role(role: &str, repo_root: &Path) -> Result<()> {
    let roles = list_roles(repo_root)?;
    if roles.iter().any(|r| r == role) {
        Ok(())
    } else {
        bail!(
            "unregistered role '{role}' — not found in {}.\n  Valid roles: {}",
            REGISTRY_PATH,
            roles.join(", ")
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn write_registry(dir: &Path, contents: &str) {
        let proc_dir = dir.join("docs/process");
        fs::create_dir_all(&proc_dir).unwrap();
        fs::write(proc_dir.join("AGENT_ROLES.yaml"), contents).unwrap();
    }

    #[test]
    fn list_roles_parses_registered_roles() {
        let tmp = TempDir::new().unwrap();
        write_registry(
            tmp.path(),
            "roles:\n  curator:\n    description: x\n    skills:\n      - a\n  shepherd:\n    description: y\n",
        );
        let roles = list_roles(tmp.path()).unwrap();
        assert_eq!(roles, vec!["curator".to_string(), "shepherd".to_string()]);
    }

    #[test]
    fn validate_role_accepts_registered() {
        let tmp = TempDir::new().unwrap();
        write_registry(tmp.path(), "roles:\n  curator:\n    description: x\n");
        assert!(validate_role("curator", tmp.path()).is_ok());
    }

    #[test]
    fn validate_role_rejects_unregistered_with_clear_error() {
        let tmp = TempDir::new().unwrap();
        write_registry(tmp.path(), "roles:\n  curator:\n    description: x\n");
        let err = validate_role("wizard-supreme", tmp.path()).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unregistered role 'wizard-supreme'"), "{msg}");
        assert!(msg.contains("curator"), "{msg}");
    }

    #[test]
    fn list_roles_errors_on_missing_file() {
        let tmp = TempDir::new().unwrap();
        assert!(list_roles(tmp.path()).is_err());
    }

    #[test]
    fn real_registry_contains_expected_roles() {
        // Walk up from CARGO_MANIFEST_DIR to the repo root.
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(Path::parent)
            .expect("crates/<name> -> repo root");
        let roles = list_roles(repo_root).expect("real AGENT_ROLES.yaml should parse");
        for expected in [
            "curator",
            "fleet-worker",
            "paramedic",
            "ci-audit",
            "handoff",
            "target",
            "decompose",
            "shepherd",
        ] {
            assert!(
                roles.iter().any(|r| r == expected),
                "expected role '{expected}' in {roles:?}"
            );
        }
    }
}
