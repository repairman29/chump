use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardenResult {
    pub repo_path: String,
    pub missing_patterns: Vec<String>,
    pub applied: bool,
    pub hook_installed: bool,
}

pub fn audit_gitignore(repo_path: &Path) -> Result<Vec<String>, String> {
    let gitignore_path = repo_path.join(".gitignore");
    let content = if gitignore_path.exists() {
        fs::read_to_string(&gitignore_path).map_err(|e| e.to_string())?
    } else {
        String::new()
    };

    let patterns: HashSet<&str> = content
        .lines()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();

    let mut missing: Vec<String> = Vec::new();

    if !(patterns.contains(".env*") || patterns.contains(".env") && patterns.contains(".env.*")) {
        missing.push(String::from(".env*"));
    }
    if !patterns.contains("*service*account*.json") {
        missing.push(String::from("*service*account*.json"));
    }
    if !patterns.contains("*.bak") {
        missing.push(String::from("*.bak"));
    }
    if !patterns.contains("*.backup") {
        missing.push(String::from("*.backup"));
    }
    if !patterns.contains("*.pem") {
        missing.push(String::from("*.pem"));
    }

    Ok(missing)
}

pub fn harden_repo(
    repo_path: &Path,
    apply: bool,
    install_hook: bool,
) -> Result<HardenResult, String> {
    let missing_patterns = audit_gitignore(repo_path)?;
    let mut applied = false;
    let mut hook_installed = false;

    if apply && !missing_patterns.is_empty() {
        let gitignore_path = repo_path.join(".gitignore");
        let mut content = if gitignore_path.exists() {
            fs::read_to_string(&gitignore_path).map_err(|e| e.to_string())?
        } else {
            String::new()
        };

        if content.is_empty() {
            content.push_str("# repo-sentinel hardened rules\n");
        } else {
            content.push_str("\n# repo-sentinel hardened rules\n");
        }

        for pattern in &missing_patterns {
            content.push_str(&format!("{}\n", pattern));
        }

        if !content.contains("!.env.example") {
            content.push_str("!.env.example\n");
        }

        fs::write(&gitignore_path, content).map_err(|e| e.to_string())?;
        applied = true;
    }

    if install_hook && apply {
        let hooks_dir = repo_path.join(".git/hooks");
        fs::create_dir_all(&hooks_dir).map_err(|e| e.to_string())?;

        let hook_content = "#!/bin/sh\nset -e\nrepo-sentinel scan --staged --fail-on high\n";
        let hook_path = hooks_dir.join("pre-commit");
        fs::write(&hook_path, hook_content).map_err(|e| e.to_string())?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&hook_path)
                .map_err(|e| e.to_string())?
                .permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&hook_path, perms).map_err(|e| e.to_string())?;
        }

        hook_installed = true;
    }

    Ok(HardenResult {
        repo_path: repo_path.to_string_lossy().into_owned(),
        missing_patterns,
        applied,
        hook_installed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn create_temp_dir() -> PathBuf {
        let mut dir = env::temp_dir();
        dir.push(format!(
            "repo_sentinel_ga_{}_{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_missing() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, "# ignore me").unwrap();
        let missing = audit_gitignore(&dir).unwrap();
        assert_eq!(missing.len(), 5);
    }

    #[test]
    fn test_partial() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, ".env\n.env.*").unwrap();
        let missing = audit_gitignore(&dir).unwrap();
        assert_eq!(missing.len(), 4);
    }

    #[test]
    fn test_dry_run() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, "# ignore me").unwrap();
        let result = harden_repo(&dir, false, false).unwrap();
        assert!(!result.applied);
        assert!(!result.hook_installed);
    }

    #[test]
    fn test_apply() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, "# ignore me").unwrap();
        let result = harden_repo(&dir, true, false).unwrap();
        assert!(result.applied);
        assert!(!result.hook_installed);
    }

    #[test]
    fn test_idempotency() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(
            &gitignore_path,
            "# ignore me\n.env*\n*service*account*.json\n*.bak\n*.backup\n*.pem\n!.env.example",
        )
        .unwrap();
        let result = harden_repo(&dir, true, false).unwrap();
        assert!(!result.applied);
        assert!(!result.hook_installed);
    }

    #[test]
    fn test_install_hook() {
        let dir = create_temp_dir();
        let gitignore_path = dir.join(".gitignore");
        fs::write(&gitignore_path, "# ignore me").unwrap();
        let result = harden_repo(&dir, true, true).unwrap();
        assert!(result.applied);
        assert!(result.hook_installed);
    }
}
