//! INFRA-5773 (INFRA-1863 slice): validate `chump claim --role <role>` against
//! `docs/process/AGENT_ROLES.yaml` rather than accepting any string.
//!
//! Kept permissive on registry-load failure (missing/malformed file) — claim
//! is a hot path and a doc typo shouldn't wedge the fleet. Only an explicit,
//! successfully-loaded registry rejects unregistered roles.

use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct RolesFile {
    #[allow(dead_code)]
    #[serde(default)]
    version: u32,
    roles: Vec<RoleEntry>,
}

#[derive(Debug, Deserialize)]
struct RoleEntry {
    name: String,
}

/// Load the registered role names from `docs/process/AGENT_ROLES.yaml`
/// relative to `repo_root`. Returns `None` when the file is missing or
/// malformed — callers should treat that as "registry unavailable, skip
/// validation" rather than "no roles are valid".
fn load_role_names(repo_root: &Path) -> Option<Vec<String>> {
    let path = repo_root.join("docs/process/AGENT_ROLES.yaml");
    let text = std::fs::read_to_string(&path).ok()?;
    let file: RolesFile = serde_yaml::from_str(&text).ok()?;
    Some(file.roles.into_iter().map(|r| r.name).collect())
}

/// Validate `role` against the registry rooted at `repo_root`. Returns
/// `Ok(())` when the role is registered, or when the registry could not be
/// loaded (fail-open — see module docs). Returns `Err` with a clear message
/// listing valid roles when the registry loaded successfully but `role` is
/// not among them.
pub fn validate_role(repo_root: &Path, role: &str) -> Result<(), String> {
    let Some(known) = load_role_names(repo_root) else {
        return Ok(());
    };
    if known.iter().any(|r| r == role) {
        return Ok(());
    }
    let mut sorted = known;
    sorted.sort();
    Err(format!(
        "unregistered role: {role:?}\n\n\
         Valid roles (docs/process/AGENT_ROLES.yaml): {}\n\n\
         To add a new role, append an entry to docs/process/AGENT_ROLES.yaml \
         in the same PR that introduces its usage.",
        sorted.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_registry(dir: &Path, contents: &str) {
        std::fs::create_dir_all(dir.join("docs/process")).unwrap();
        let mut f = std::fs::File::create(dir.join("docs/process/AGENT_ROLES.yaml")).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
    }

    #[test]
    fn accepts_registered_role() {
        let dir = tempfile::tempdir().unwrap();
        write_registry(
            dir.path(),
            "version: 1\nroles:\n  - name: shepherd\n  - name: target\n",
        );
        assert!(validate_role(dir.path(), "shepherd").is_ok());
    }

    #[test]
    fn rejects_unregistered_role() {
        let dir = tempfile::tempdir().unwrap();
        write_registry(dir.path(), "version: 1\nroles:\n  - name: shepherd\n");
        let err = validate_role(dir.path(), "wizard-supreme").unwrap_err();
        assert!(err.contains("unregistered role"));
        assert!(err.contains("shepherd"));
    }

    #[test]
    fn fails_open_when_registry_missing() {
        let dir = tempfile::tempdir().unwrap();
        assert!(validate_role(dir.path(), "anything").is_ok());
    }

    #[test]
    fn fails_open_when_registry_malformed() {
        let dir = tempfile::tempdir().unwrap();
        write_registry(dir.path(), "not: [valid, yaml, roles");
        assert!(validate_role(dir.path(), "anything").is_ok());
    }
}
