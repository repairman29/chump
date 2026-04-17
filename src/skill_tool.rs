//! skill_manage tool — agent-facing interface for creating, viewing, updating, and deleting skills.
//!
//! Progressive disclosure:
//!   - Level 0: `list` returns metadata only (name + description + category)
//!   - Level 1: `view <name>` returns full SKILL.md content
//!
//! Actions:
//!   - list: enumerate installed skills
//!   - view <name>: load full SKILL.md content
//!   - create <name> <description> <body>: new skill (body is Markdown with procedure/pitfalls/verification)
//!   - patch <name> <old_string> <new_string>: targeted update
//!   - edit <name> <description> <body>: full replacement
//!   - delete <name>: remove skill
//!   - record_outcome <name> <success>: agent-initiated outcome tracking

use crate::skills::{self, SkillFrontmatter, SkillMetadata};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct SkillManageTool;

impl SkillManageTool {
    pub fn new() -> Self {
        Self
    }
}

impl Default for SkillManageTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Tool for SkillManageTool {
    fn name(&self) -> String {
        "skill_manage".to_string()
    }

    fn description(&self) -> String {
        "Manage Chump's procedural skills (reusable task procedures). Actions: list (show all installed skills as name+description), view (load full SKILL.md with procedure), create (save a new skill from a successful workflow), patch (targeted edit via old_string/new_string), edit (replace content), delete (remove), record_outcome (mark a skill as succeeding or failing after applying it), tap_add (install skills from a public GitHub repo URL). Skills are stored as markdown in chump-brain/skills/<name>/SKILL.md and carry success/failure reliability stats.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list", "view", "create", "patch", "edit", "delete", "record_outcome", "tap_add"],
                    "description": "Action to perform"
                },
                "name": {
                    "type": "string",
                    "description": "Skill name (kebab-case, ASCII alphanumeric + - or _). Required for view/create/patch/edit/delete/record_outcome."
                },
                "description": {
                    "type": "string",
                    "description": "Short description (one sentence). Required for create/edit."
                },
                "body": {
                    "type": "string",
                    "description": "Markdown body with sections: ## When to Use, ## Quick Reference, ## Procedure, ## Pitfalls, ## Verification. Required for create/edit."
                },
                "old_string": {
                    "type": "string",
                    "description": "Existing text to replace (must be unique in SKILL.md). Required for patch."
                },
                "new_string": {
                    "type": "string",
                    "description": "Replacement text. Required for patch."
                },
                "category": {
                    "type": "string",
                    "description": "Optional: category tag (e.g. 'code-quality', 'research', 'ops')."
                },
                "tags": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Optional: list of tags."
                },
                "platforms": {
                    "type": "array",
                    "items": { "type": "string", "enum": ["macos", "linux", "windows"] },
                    "description": "Optional: platforms this skill applies to. Empty = all platforms."
                },
                "requires_toolsets": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Optional: toolsets required for this skill to function."
                },
                "success": {
                    "type": "boolean",
                    "description": "For record_outcome: true if the skill helped, false if it didn't."
                },
                "url": {
                    "type": "string",
                    "description": "GitHub repo URL for tap_add (e.g. https://github.com/owner/repo). The repo must have a skills/ directory with SKILL.md files."
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(msg) = crate::limits::check_tool_input_len(&input) {
            return Ok(msg);
        }
        let obj = match &input {
            Value::Object(m) => m,
            _ => return Ok("skill_manage needs an object with 'action'.".to_string()),
        };
        let action = obj
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        match action {
            "list" => handle_list(),
            "view" => {
                let name = extract_name(obj)?;
                handle_view(&name)
            }
            "create" => {
                let name = extract_name(obj)?;
                let description = obj
                    .get("description")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("create requires 'description'"))?
                    .to_string();
                let body = obj
                    .get("body")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("create requires 'body'"))?
                    .to_string();
                let metadata = extract_metadata(obj);
                let platforms = extract_string_array(obj, "platforms");
                handle_create(&name, &description, &body, metadata, platforms)
            }
            "patch" => {
                let name = extract_name(obj)?;
                let old_string = obj
                    .get("old_string")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("patch requires 'old_string'"))?
                    .to_string();
                let new_string = obj
                    .get("new_string")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("patch requires 'new_string'"))?
                    .to_string();
                handle_patch(&name, &old_string, &new_string)
            }
            "edit" => {
                let name = extract_name(obj)?;
                let description = obj
                    .get("description")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("edit requires 'description'"))?
                    .to_string();
                let body = obj
                    .get("body")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("edit requires 'body'"))?
                    .to_string();
                let metadata = extract_metadata(obj);
                let platforms = extract_string_array(obj, "platforms");
                handle_edit(&name, &description, &body, metadata, platforms)
            }
            "delete" => {
                let name = extract_name(obj)?;
                handle_delete(&name)
            }
            "record_outcome" => {
                let name = extract_name(obj)?;
                let success = obj
                    .get("success")
                    .and_then(|v| v.as_bool())
                    .ok_or_else(|| anyhow!("record_outcome requires 'success' boolean"))?;
                handle_record_outcome(&name, success)
            }
            "tap_add" => {
                let url = obj
                    .get("url")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("tap_add requires 'url'"))?
                    .to_string();
                handle_tap_add(&url).await
            }
            other => Ok(format!(
                "Unknown action '{}'. Valid: list, view, create, patch, edit, delete, record_outcome, tap_add.",
                other
            )),
        }
    }
}

fn extract_name(obj: &serde_json::Map<String, Value>) -> Result<String> {
    obj.get("name")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("action requires 'name'"))
}

fn extract_string_array(obj: &serde_json::Map<String, Value>, key: &str) -> Vec<String> {
    obj.get(key)
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn extract_metadata(obj: &serde_json::Map<String, Value>) -> SkillMetadata {
    SkillMetadata {
        tags: extract_string_array(obj, "tags"),
        category: obj
            .get("category")
            .and_then(|v| v.as_str())
            .map(String::from),
        requires_toolsets: extract_string_array(obj, "requires_toolsets"),
        fallback_for_toolsets: extract_string_array(obj, "fallback_for_toolsets"),
        parent: obj.get("parent").and_then(|v| v.as_str()).map(String::from),
        cache_behavior: obj
            .get("cache_behavior")
            .and_then(|v| v.as_str())
            .map(String::from),
        config: serde_yaml::Value::Null,
    }
}

fn handle_list() -> Result<String> {
    let skills = skills::list_skills()?;
    if skills.is_empty() {
        return Ok("No skills installed. Use skill_manage action=create to add one.".to_string());
    }
    let mut lines = vec![format!("Found {} skills:", skills.len())];
    for skill in skills {
        lines.push(skill.summary_line());
    }
    Ok(lines.join("\n"))
}

fn handle_view(name: &str) -> Result<String> {
    let skill = skills::load_skill(name)?;
    let reliability = crate::skill_db::skill_reliability(name).ok();
    let header = match reliability {
        Some((r, n)) if n > 0 => {
            format!(
                "# Skill: {} (v{})\n\n**Description:** {}\n**Reliability:** {:.1}% over {} uses\n\n---\n\n",
                skill.frontmatter.name, skill.frontmatter.version, skill.frontmatter.description, r * 100.0, n
            )
        }
        _ => format!(
            "# Skill: {} (v{})\n\n**Description:** {}\n**Reliability:** no usage data yet\n\n---\n\n",
            skill.frontmatter.name, skill.frontmatter.version, skill.frontmatter.description
        ),
    };
    Ok(format!("{}{}", header, skill.body))
}

fn handle_create(
    name: &str,
    description: &str,
    body: &str,
    metadata: SkillMetadata,
    platforms: Vec<String>,
) -> Result<String> {
    // Ensure skill doesn't already exist
    if skills::load_skill(name).is_ok() {
        return Err(anyhow!(
            "skill '{}' already exists. Use action=patch or action=edit to modify.",
            name
        ));
    }
    let fm = SkillFrontmatter {
        name: name.to_string(),
        description: description.to_string(),
        version: 1,
        platforms,
        metadata,
    };
    let path = skills::save_skill(&fm, body)?;
    Ok(format!(
        "Created skill '{}' at {}. Version 1. Use action=view to inspect.",
        name,
        path.display()
    ))
}

fn handle_patch(name: &str, old_string: &str, new_string: &str) -> Result<String> {
    skills::patch_skill(name, old_string, new_string)?;
    Ok(format!("Patched skill '{}'.", name))
}

fn handle_edit(
    name: &str,
    description: &str,
    body: &str,
    metadata: SkillMetadata,
    platforms: Vec<String>,
) -> Result<String> {
    let existing = skills::load_skill(name)?;
    let fm = SkillFrontmatter {
        name: name.to_string(),
        description: description.to_string(),
        version: existing.frontmatter.version + 1,
        platforms,
        metadata,
    };
    skills::save_skill(&fm, body)?;
    Ok(format!(
        "Edited skill '{}'. Version bumped to {}.",
        name, fm.version
    ))
}

fn handle_delete(name: &str) -> Result<String> {
    skills::delete_skill(name)?;
    Ok(format!("Deleted skill '{}'.", name))
}

fn handle_record_outcome(name: &str, success: bool) -> Result<String> {
    crate::skill_db::record_skill_outcome(name, success)?;
    let (reliability, uses) = crate::skill_db::skill_reliability(name)?;
    Ok(format!(
        "Recorded {} outcome for '{}'. New reliability: {:.1}% over {} uses.",
        if success { "success" } else { "failure" },
        name,
        reliability * 100.0,
        uses
    ))
}

// ── COMP-006: Skills tap (remote install) ────────────────────────────────────

/// Parse a GitHub repo URL into (owner, repo) pair.
/// Accepts: https://github.com/owner/repo, github.com/owner/repo, owner/repo
pub fn parse_github_repo(url: &str) -> Option<(String, String)> {
    let s = url
        .trim()
        .trim_end_matches('/')
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_start_matches("github.com/");
    let parts: Vec<&str> = s.splitn(2, '/').collect();
    if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() {
        let repo = parts[1].trim_end_matches(".git").to_string();
        Some((parts[0].to_string(), repo))
    } else {
        None
    }
}

/// Validate SKILL.md content is safe markdown-only (no script execution).
pub fn validate_skill_markdown_safety(content: &str) -> Result<()> {
    let lower = content.to_lowercase();
    if lower.contains("<script") {
        return Err(anyhow!(
            "SKILL.md contains <script> tag — rejected for security"
        ));
    }
    if lower.contains("<iframe") {
        return Err(anyhow!(
            "SKILL.md contains <iframe> tag — rejected for security"
        ));
    }
    if lower.contains("javascript:") {
        return Err(anyhow!(
            "SKILL.md contains javascript: URI — rejected for security"
        ));
    }
    // Must start with YAML frontmatter (---) to be a valid SKILL.md
    if !content.trim_start().starts_with("---") {
        return Err(anyhow!(
            "SKILL.md missing YAML frontmatter (must start with ---)"
        ));
    }
    Ok(())
}

/// COMP-006: fetch and install skills from a public GitHub repository.
/// The repo must have a `skills/` directory with one or more SKILL.md files.
/// Each skill dir: `skills/<skill-name>/SKILL.md` or `skills/<skill-name>.md`.
async fn handle_tap_add(url: &str) -> Result<String> {
    let (owner, repo) = parse_github_repo(url).ok_or_else(|| {
        anyhow!(
            "Could not parse GitHub URL '{}'. Expected: https://github.com/owner/repo",
            url
        )
    })?;

    let api_url = format!(
        "https://api.github.com/repos/{}/{}/contents/skills",
        owner, repo
    );
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("chump-skills-tap/1.0")
        .build()
        .map_err(|e| anyhow!("http client: {}", e))?;

    let resp = client
        .get(&api_url)
        .send()
        .await
        .map_err(|e| anyhow!("GitHub API request failed: {}", e))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(format!(
            "No skills/ directory found in {}/{}. The repo must have a skills/ directory with SKILL.md files.",
            owner, repo
        ));
    }
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!(
            "GitHub API error {}: {}",
            status,
            &body[..body.len().min(300)]
        ));
    }

    let entries: Vec<serde_json::Value> = resp
        .json()
        .await
        .map_err(|e| anyhow!("GitHub API JSON parse: {}", e))?;

    let mut installed = Vec::new();
    let mut skipped = Vec::new();
    let mut errors = Vec::new();

    for entry in &entries {
        let entry_type = entry["type"].as_str().unwrap_or("");
        let entry_name = entry["name"].as_str().unwrap_or("");

        // Case 1: skills/<name>/SKILL.md (directory)
        // Case 2: skills/<name>.md (file at root of skills/)
        let skill_name: String;
        let raw_url: String;

        if entry_type == "dir" {
            skill_name = entry_name.to_string();
            raw_url = format!(
                "https://raw.githubusercontent.com/{}/{}/main/skills/{}/SKILL.md",
                owner, repo, entry_name
            );
        } else if entry_type == "file" && entry_name.ends_with(".md") {
            skill_name = entry_name.trim_end_matches(".md").to_string();
            raw_url = entry["download_url"].as_str().unwrap_or("").to_string();
            if raw_url.is_empty() {
                skipped.push(format!("{} (no download_url)", entry_name));
                continue;
            }
        } else {
            continue;
        }

        // Fetch the SKILL.md content
        let md_resp = match client.get(&raw_url).send().await {
            Ok(r) => r,
            Err(e) => {
                errors.push(format!("{}: fetch error: {}", skill_name, e));
                continue;
            }
        };
        if !md_resp.status().is_success() {
            if entry_type == "dir" {
                skipped.push(format!("{} (no SKILL.md in directory)", skill_name));
            } else {
                errors.push(format!(
                    "{}: fetch {} returned {}",
                    skill_name,
                    raw_url,
                    md_resp.status()
                ));
            }
            continue;
        }
        let content = match md_resp.text().await {
            Ok(t) => t,
            Err(e) => {
                errors.push(format!("{}: read error: {}", skill_name, e));
                continue;
            }
        };

        // Security validation
        if let Err(e) = validate_skill_markdown_safety(&content) {
            errors.push(format!("{}: security: {}", skill_name, e));
            continue;
        }

        // Parse and install
        let path = std::path::Path::new(&skill_name);
        match crate::skills::parse_skill_md(&content, path) {
            Ok(skill) => match crate::skills::save_skill(&skill.frontmatter, &skill.body) {
                Ok(_) => installed.push(skill_name),
                Err(e) => errors.push(format!("{}: save error: {}", skill_name, e)),
            },
            Err(e) => errors.push(format!("{}: parse error: {}", skill_name, e)),
        }
    }

    if installed.is_empty() && errors.is_empty() && skipped.is_empty() {
        return Ok(format!(
            "No installable skills found in {}/{}.",
            owner, repo
        ));
    }
    let mut lines = Vec::new();
    if !installed.is_empty() {
        lines.push(format!(
            "Installed {} skill(s): {}",
            installed.len(),
            installed.join(", ")
        ));
    }
    if !skipped.is_empty() {
        lines.push(format!("Skipped: {}", skipped.join("; ")));
    }
    if !errors.is_empty() {
        lines.push(format!("Errors: {}", errors.join("; ")));
    }
    Ok(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_validates() {
        let tool = SkillManageTool::new();
        let schema = tool.input_schema();
        assert!(schema.get("properties").is_some());
        assert!(schema
            .get("required")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().any(|v| v.as_str() == Some("action")))
            .unwrap_or(false));
    }

    #[tokio::test]
    async fn unknown_action_returns_error_message() {
        let tool = SkillManageTool::new();
        let input = json!({ "action": "nope" });
        let result = tool.execute(input).await.unwrap();
        assert!(result.contains("Unknown action"));
    }

    #[tokio::test]
    async fn missing_name_errors() {
        let tool = SkillManageTool::new();
        let input = json!({ "action": "view" });
        let err = tool.execute(input).await.unwrap_err();
        assert!(err.to_string().contains("name"));
    }

    #[tokio::test]
    async fn create_requires_description_and_body() {
        let tool = SkillManageTool::new();
        let input = json!({ "action": "create", "name": "test-x" });
        let err = tool.execute(input).await.unwrap_err();
        assert!(err.to_string().contains("description") || err.to_string().contains("body"));
    }

    // ── tap_add unit tests ────────────────────────────────────────────────────

    #[test]
    fn parse_github_repo_handles_full_url() {
        let (owner, repo) = parse_github_repo("https://github.com/acme/my-skills").unwrap();
        assert_eq!(owner, "acme");
        assert_eq!(repo, "my-skills");
    }

    #[test]
    fn parse_github_repo_handles_git_suffix() {
        let (owner, repo) = parse_github_repo("https://github.com/acme/my-skills.git").unwrap();
        assert_eq!(owner, "acme");
        assert_eq!(repo, "my-skills");
    }

    #[test]
    fn parse_github_repo_handles_owner_slash_repo() {
        let (owner, repo) = parse_github_repo("acme/my-skills").unwrap();
        assert_eq!(owner, "acme");
        assert_eq!(repo, "my-skills");
    }

    #[test]
    fn parse_github_repo_rejects_invalid() {
        assert!(parse_github_repo("not-a-url").is_none());
        assert!(parse_github_repo("https://github.com/").is_none());
        assert!(parse_github_repo("").is_none());
    }

    #[test]
    fn validate_skill_markdown_safety_accepts_valid() {
        let md = "---\nname: test\ndescription: A test skill\nversion: 1\n---\n\n## Procedure\n\nDo the thing.\n";
        assert!(validate_skill_markdown_safety(md).is_ok());
    }

    #[test]
    fn validate_skill_markdown_safety_rejects_script_tag() {
        let md = "---\nname: evil\ndescription: bad\nversion: 1\n---\n<script>alert(1)</script>";
        assert!(validate_skill_markdown_safety(md).is_err());
    }

    #[test]
    fn validate_skill_markdown_safety_rejects_iframe() {
        let md = "---\nname: evil\ndescription: bad\nversion: 1\n---\n<iframe src='x'></iframe>";
        assert!(validate_skill_markdown_safety(md).is_err());
    }

    #[test]
    fn validate_skill_markdown_safety_rejects_no_frontmatter() {
        let md = "## No frontmatter\n\nJust some text.";
        assert!(validate_skill_markdown_safety(md).is_err());
    }

    #[tokio::test]
    async fn tap_add_requires_url() {
        let tool = SkillManageTool::new();
        let input = json!({ "action": "tap_add" });
        let err = tool.execute(input).await.unwrap_err();
        assert!(err.to_string().contains("url"));
    }
}
