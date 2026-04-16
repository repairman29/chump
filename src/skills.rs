//! Skills system — procedural memory for Chump.
//!
//! A skill is a reusable procedure that Chump learns from successful tasks.
//! After completing a complex task (5+ tool calls, error recovery, user correction),
//! Chump can codify the successful workflow as a SKILL.md document for future reuse.
//!
//! Design adopted from NousResearch/hermes-agent for interop with their ecosystem
//! (skills.sh, /.well-known/skills/index.json). Our skills are compatible with theirs
//! but also carry Chump-specific reliability metadata (Beta distribution per skill).
//!
//! Layout on disk:
//!   chump-brain/skills/<skill-name>/SKILL.md
//!   chump-brain/skills/<skill-name>/references/*.md  (optional supporting files)
//!
//! SKILL.md format:
//!   ---
//!   name: fix-clippy-warnings
//!   description: Systematic approach to resolving Rust clippy warnings
//!   version: 1
//!   platforms: [macos, linux]
//!   metadata:
//!     tags: [rust, lint, refactor]
//!     category: code-quality
//!     requires_toolsets: [repo, cli]
//!   ---
//!   ## When to Use
//!   [trigger conditions]
//!
//!   ## Quick Reference
//!   [one-line summary]
//!
//!   ## Procedure
//!   1. step
//!   2. step
//!
//!   ## Pitfalls
//!   [known failure modes]
//!
//!   ## Verification
//!   [how to confirm success]

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Maximum total characters for a SKILL.md file (sanity cap to avoid context bloat).
pub const MAX_SKILL_LEN: usize = 32_000;

/// Maximum metadata characters injected into the system prompt in "Level 0" progressive disclosure.
pub const SKILL_LIST_MAX_CHARS: usize = 3_000;

/// SKILL.md YAML frontmatter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillFrontmatter {
    pub name: String,
    pub description: String,
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub platforms: Vec<String>,
    #[serde(default)]
    pub metadata: SkillMetadata,
}

fn default_version() -> u32 {
    1
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SkillMetadata {
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub requires_toolsets: Vec<String>,
    #[serde(default)]
    pub fallback_for_toolsets: Vec<String>,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub cache_behavior: Option<String>,
    #[serde(default)]
    pub config: serde_yaml::Value,
}

/// A parsed SKILL.md document (frontmatter + body).
#[derive(Debug, Clone)]
pub struct Skill {
    pub frontmatter: SkillFrontmatter,
    pub body: String,
    pub path: PathBuf,
}

impl Skill {
    /// Convenience accessor for the skill name.
    pub fn name(&self) -> &str {
        &self.frontmatter.name
    }

    /// One-line summary for progressive-disclosure level 0.
    pub fn summary_line(&self) -> String {
        let category = self
            .frontmatter
            .metadata
            .category
            .as_deref()
            .unwrap_or("general");
        format!(
            "- {} [{}]: {}",
            self.frontmatter.name, category, self.frontmatter.description
        )
    }
}

/// Root directory for skills under the brain.
pub fn skills_root() -> Result<PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = crate::repo_path::runtime_base();
    let dir = if Path::new(&root).is_absolute() {
        PathBuf::from(root)
    } else {
        base.join(root)
    }
    .join("skills");
    Ok(dir)
}

/// List all installed skills by scanning the skills root directory.
pub fn list_skills() -> Result<Vec<Skill>> {
    let root = skills_root()?;
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let skill_md = entry.path().join("SKILL.md");
        if !skill_md.exists() {
            continue;
        }
        match load_skill_from_path(&skill_md) {
            Ok(skill) => out.push(skill),
            Err(e) => {
                tracing::warn!(path = %skill_md.display(), error = %e, "failed to load SKILL.md");
            }
        }
    }
    out.sort_by(|a, b| a.name().cmp(b.name()));
    Ok(out)
}

/// Load a skill by name.
pub fn load_skill(name: &str) -> Result<Skill> {
    let root = skills_root()?;
    let skill_md = root.join(name).join("SKILL.md");
    if !skill_md.exists() {
        return Err(anyhow!("skill '{}' not found", name));
    }
    load_skill_from_path(&skill_md)
}

/// Parse a SKILL.md file from disk.
fn load_skill_from_path(path: &Path) -> Result<Skill> {
    let content = std::fs::read_to_string(path)?;
    parse_skill_md(&content, path)
}

/// Parse SKILL.md content into frontmatter + body.
pub fn parse_skill_md(content: &str, source_path: &Path) -> Result<Skill> {
    let trimmed = content.trim_start();
    if !trimmed.starts_with("---") {
        return Err(anyhow!(
            "SKILL.md missing YAML frontmatter (must start with ---)"
        ));
    }
    // Find the closing ---
    let after_open = &trimmed[3..];
    let end_idx = after_open
        .find("\n---")
        .ok_or_else(|| anyhow!("SKILL.md frontmatter missing closing ---"))?;
    let yaml_part = &after_open[..end_idx];
    let body_part = after_open[end_idx + 4..].trim_start_matches('\n');

    let frontmatter: SkillFrontmatter = serde_yaml::from_str(yaml_part)
        .map_err(|e| anyhow!("invalid SKILL.md frontmatter: {}", e))?;

    if frontmatter.name.trim().is_empty() {
        return Err(anyhow!("SKILL.md frontmatter requires non-empty name"));
    }
    if frontmatter.description.trim().is_empty() {
        return Err(anyhow!(
            "SKILL.md frontmatter requires non-empty description"
        ));
    }

    // Sprint B: SKILL.md strict format standardization
    let required_sections = [
        "## When to Use",
        "## Quick Reference",
        "## Procedure",
        "## Pitfalls",
        "## Verification",
    ];

    for section in required_sections {
        if !body_part.contains(section) {
            return Err(anyhow!("SKILL.md is missing required section: {}", section));
        }
    }

    Ok(Skill {
        frontmatter,
        body: body_part.to_string(),
        path: source_path.to_path_buf(),
    })
}

/// Serialize a skill back to SKILL.md format (for writing).
pub fn serialize_skill(frontmatter: &SkillFrontmatter, body: &str) -> Result<String> {
    let yaml = serde_yaml::to_string(frontmatter)?;
    Ok(format!("---\n{}---\n\n{}", yaml, body.trim_start()))
}

/// Save a new skill to disk. Creates <skills_root>/<name>/SKILL.md.
pub fn save_skill(frontmatter: &SkillFrontmatter, body: &str) -> Result<PathBuf> {
    let root = skills_root()?;
    let name = &frontmatter.name;
    sanitize_skill_name(name)?;
    let skill_dir = root.join(name);
    std::fs::create_dir_all(&skill_dir)?;
    let skill_md = skill_dir.join("SKILL.md");
    let content = serialize_skill(frontmatter, body)?;
    if content.len() > MAX_SKILL_LEN {
        return Err(anyhow!(
            "skill content exceeds max size ({} > {})",
            content.len(),
            MAX_SKILL_LEN
        ));
    }
    std::fs::write(&skill_md, content)?;
    crate::skill_db::upsert_skill_record(
        name,
        &frontmatter.description,
        frontmatter.version,
        frontmatter.metadata.category.as_deref(),
        &frontmatter.metadata.tags,
    )
    .ok();
    Ok(skill_md)
}

/// Delete a skill directory and its metadata row.
pub fn delete_skill(name: &str) -> Result<()> {
    sanitize_skill_name(name)?;
    let root = skills_root()?;
    let dir = root.join(name);
    if dir.exists() {
        std::fs::remove_dir_all(&dir)?;
    }
    crate::skill_db::delete_skill_record(name).ok();
    Ok(())
}

/// Patch a skill in-place: replace old_string with new_string in SKILL.md.
/// Preferred over edit() for small changes — preserves surrounding content.
pub fn patch_skill(name: &str, old_string: &str, new_string: &str) -> Result<()> {
    sanitize_skill_name(name)?;
    let skill = load_skill(name)?;
    let original = std::fs::read_to_string(&skill.path)?;
    if !original.contains(old_string) {
        return Err(anyhow!("old_string not found in {}", name));
    }
    if original.matches(old_string).count() > 1 {
        return Err(anyhow!(
            "old_string appears multiple times in {} — provide more context",
            name
        ));
    }
    let updated = original.replace(old_string, new_string);
    if updated.len() > MAX_SKILL_LEN {
        return Err(anyhow!("skill content would exceed max size"));
    }
    std::fs::write(&skill.path, updated)?;
    Ok(())
}

/// Reject names that would escape the skills directory or break file system conventions.
fn sanitize_skill_name(name: &str) -> Result<()> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("skill name cannot be empty"));
    }
    if trimmed != name {
        return Err(anyhow!(
            "skill name must not have leading/trailing whitespace"
        ));
    }
    if trimmed.contains('/') || trimmed.contains('\\') || trimmed.contains("..") {
        return Err(anyhow!("skill name cannot contain path separators or .."));
    }
    if trimmed.starts_with('.') {
        return Err(anyhow!("skill name cannot start with ."));
    }
    if trimmed.len() > 80 {
        return Err(anyhow!("skill name too long (>80 chars)"));
    }
    for ch in trimmed.chars() {
        if !ch.is_ascii_alphanumeric() && ch != '-' && ch != '_' {
            return Err(anyhow!("skill name must be ASCII alphanumeric, -, or _"));
        }
    }
    Ok(())
}

/// Build the "Level 0" skill summary for system prompt injection.
/// Returns one line per skill, truncated to SKILL_LIST_MAX_CHARS total.
pub fn skills_system_prompt_block() -> String {
    let skills = match list_skills() {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    if skills.is_empty() {
        return String::new();
    }
    // Filter by current platform + available toolsets
    let current_platform = current_platform_name();
    let filtered: Vec<&Skill> = skills
        .iter()
        .filter(|s| {
            let platform_ok = s.frontmatter.platforms.is_empty()
                || s.frontmatter
                    .platforms
                    .iter()
                    .any(|p| p == current_platform);
            platform_ok
        })
        .collect();
    if filtered.is_empty() {
        return String::new();
    }
    let mut lines = vec!["Available skills (use skill_view <name> to see procedure):".to_string()];
    let mut total = lines[0].len();
    for skill in filtered {
        let line = skill.summary_line();
        if total + line.len() + 1 > SKILL_LIST_MAX_CHARS {
            lines.push("... (more skills available; use skill_view to access)".to_string());
            break;
        }
        total += line.len() + 1;
        lines.push(line);
    }
    lines.join("\n")
}

fn current_platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "other"
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

/// Sprint B (B4): Skill caching helper.
/// Checks `chump_skill_cache` for a hit if the skill has `cache_behavior: "deterministic"`.
pub fn check_cache(skill_name: &str, version: u32, args_json: &str) -> Option<String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(args_json.as_bytes());
    let args_hash = hex::encode(hasher.finalize());
    crate::skill_db::check_skill_cache(skill_name, version, &args_hash).unwrap_or(None)
}

/// Sprint B (B4): Record outcome of a deterministic skill into the cache.
pub fn record_cache(skill_name: &str, version: u32, args_json: &str, outcome: &str) -> Result<()> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(args_json.as_bytes());
    let args_hash = hex::encode(hasher.finalize());
    crate::skill_db::write_skill_cache(skill_name, version, &args_hash, outcome)
}

/// Sprint B (B2): Mutate a skill based on a failure insight.
/// Generates a V2 of the skill with the insight appended to Pitfalls.
pub fn mutate_skill(original_name: &str, insight: &str) -> Result<String> {
    let mut skill = load_skill(original_name)?;

    // Bump version and set parent
    skill.frontmatter.version += 1;
    skill.frontmatter.metadata.parent = Some(format!(
        "{}-v{}",
        original_name,
        skill.frontmatter.version - 1
    ));

    // Naively inject the insight into Pitfalls section if it exists
    let new_body = if skill.body.contains("## Pitfalls") {
        skill.body.replace(
            "## Pitfalls\n",
            &format!("## Pitfalls\n- Evolution Insight: {}\n", insight),
        )
    } else {
        skill.body.push_str(&format!(
            "\n## Pitfalls\n- Evolution Insight: {}\n",
            insight
        ));
        skill.body
    };

    save_skill(&skill.frontmatter, &new_body)?;
    let new_name = format!("{}-v{}", original_name, skill.frontmatter.version);
    Ok(new_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_skill_md() -> String {
        r#"---
name: test-skill
description: A test skill
version: 1
platforms: [macos, linux]
metadata:
  tags: [rust, test]
  category: testing
  requires_toolsets: [repo]
---

## When to Use
When you need to test something.

## Quick Reference
Run `cargo test`.

## Procedure
1. Write a test
2. Run cargo test
3. Verify output

## Pitfalls
- Don't forget to check assertion messages.

## Verification
Test output shows "test result: ok."
"#
        .to_string()
    }

    #[test]
    fn parse_skill_md_ok() {
        let content = sample_skill_md();
        let skill = parse_skill_md(&content, Path::new("/tmp/SKILL.md")).unwrap();
        assert_eq!(skill.name(), "test-skill");
        assert_eq!(skill.frontmatter.description, "A test skill");
        assert_eq!(skill.frontmatter.version, 1);
        assert_eq!(skill.frontmatter.platforms, vec!["macos", "linux"]);
        assert_eq!(skill.frontmatter.metadata.tags, vec!["rust", "test"]);
        assert_eq!(
            skill.frontmatter.metadata.category.as_deref(),
            Some("testing")
        );
        assert!(skill.body.contains("## When to Use"));
    }

    #[test]
    fn parse_missing_frontmatter_errors() {
        let result = parse_skill_md("no frontmatter here\n## Procedure", Path::new("/tmp/x.md"));
        assert!(result.is_err());
    }

    #[test]
    fn parse_unclosed_frontmatter_errors() {
        let result = parse_skill_md("---\nname: x\ndescription: y", Path::new("/tmp/x.md"));
        assert!(result.is_err());
    }

    #[test]
    fn serialize_roundtrip() {
        let content = sample_skill_md();
        let skill = parse_skill_md(&content, Path::new("/tmp/SKILL.md")).unwrap();
        let serialized = serialize_skill(&skill.frontmatter, &skill.body).unwrap();
        let reparsed = parse_skill_md(&serialized, Path::new("/tmp/SKILL.md")).unwrap();
        assert_eq!(reparsed.name(), "test-skill");
        assert_eq!(reparsed.frontmatter.metadata.tags, vec!["rust", "test"]);
    }

    #[test]
    fn sanitize_rejects_traversal() {
        assert!(sanitize_skill_name("../etc/passwd").is_err());
        assert!(sanitize_skill_name("a/b").is_err());
        assert!(sanitize_skill_name("a\\b").is_err());
        assert!(sanitize_skill_name("").is_err());
        assert!(sanitize_skill_name(".hidden").is_err());
        assert!(sanitize_skill_name("with space").is_err());
        assert!(sanitize_skill_name("with.dot").is_err());
    }

    #[test]
    fn sanitize_accepts_valid() {
        assert!(sanitize_skill_name("fix-clippy").is_ok());
        assert!(sanitize_skill_name("my_skill_v2").is_ok());
        assert!(sanitize_skill_name("abc123").is_ok());
    }

    #[test]
    fn summary_line_format() {
        let content = sample_skill_md();
        let skill = parse_skill_md(&content, Path::new("/tmp/SKILL.md")).unwrap();
        let line = skill.summary_line();
        assert!(line.contains("test-skill"));
        assert!(line.contains("testing"));
        assert!(line.contains("A test skill"));
    }

    #[test]
    fn save_and_load_skill_roundtrip() {
        let tmp = std::env::temp_dir().join("chump_skills_roundtrip_test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::env::set_var("CHUMP_BRAIN_PATH", &tmp);
        let fm = SkillFrontmatter {
            name: "roundtrip-test".into(),
            description: "Test skill".into(),
            version: 1,
            platforms: vec![],
            metadata: SkillMetadata {
                tags: vec!["test".into()],
                category: Some("testing".into()),
                requires_toolsets: vec![],
                fallback_for_toolsets: vec![],
                parent: None,
                cache_behavior: None,
                config: serde_yaml::Value::Null,
            },
        };
        let body = "## When to Use\nnow\n## Quick Reference\ndo\n## Procedure\n1. Do a thing\n## Pitfalls\nnone\n## Verification\nnone\n";
        save_skill(&fm, body).unwrap();
        let loaded = load_skill("roundtrip-test").unwrap();
        assert_eq!(loaded.name(), "roundtrip-test");
        assert!(loaded.body.contains("Do a thing"));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
