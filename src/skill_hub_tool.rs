//! skill_hub tool — agent/user interface for installing skills from remote registries.
//!
//! Actions:
//!   - `search <query>`     — search available skills across configured registries
//!   - `list_registries`    — show configured registry URLs
//!   - `install <name>`     — install a skill from the first matching registry entry
//!   - `install_url <url>`  — install a skill from a direct SKILL.md URL
//!   - `index_info`         — show what registries are configured and their reachability

use crate::skill_hub::{self, SkillHubEntry, SkillHubIndex};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct SkillHubTool;

impl SkillHubTool {
    pub fn new() -> Self {
        Self
    }
}

impl Default for SkillHubTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Tool for SkillHubTool {
    fn name(&self) -> String {
        "skill_hub".to_string()
    }

    fn description(&self) -> String {
        "Install skills from remote registries (Chump native or Hermes /.well-known/skills/index.json compatible). Actions: search (find skills across registries by query), list_registries (show configured registry URLs), install (install a skill by name from first matching registry), install_url (install from a direct SKILL.md URL), index_info (show registry reachability). Configure registries via the CHUMP_SKILL_REGISTRIES env var (comma-separated URLs). Refuses network calls when CHUMP_AIR_GAP_MODE=1.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["search", "list_registries", "install", "install_url", "index_info"],
                    "description": "Action to perform"
                },
                "query": {
                    "type": "string",
                    "description": "Search query (matches name/description/tags). Required for search."
                },
                "name": {
                    "type": "string",
                    "description": "Skill name to install. Required for install."
                },
                "url": {
                    "type": "string",
                    "description": "Direct URL to a SKILL.md file. Required for install_url."
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
            _ => return Ok("skill_hub needs an object with 'action'.".to_string()),
        };
        let action = obj
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        match action {
            "list_registries" => Ok(handle_list_registries()),
            "index_info" => handle_index_info().await,
            "search" => {
                let query = obj
                    .get("query")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("search requires 'query'"))?;
                handle_search(query).await
            }
            "install" => {
                let name = obj
                    .get("name")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("install requires 'name'"))?;
                handle_install(name).await
            }
            "install_url" => {
                let url = obj
                    .get("url")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("install_url requires 'url'"))?;
                handle_install_url(url).await
            }
            other => Ok(format!(
                "Unknown action '{}'. Valid: search, list_registries, install, install_url, index_info.",
                other
            )),
        }
    }
}

fn handle_list_registries() -> String {
    let regs = skill_hub::default_registries();
    if regs.is_empty() {
        return "No skill registries configured. Set CHUMP_SKILL_REGISTRIES (comma-separated URLs) to enable.".to_string();
    }
    let mut lines = vec![format!("{} registry URL(s) configured:", regs.len())];
    for (i, url) in regs.iter().enumerate() {
        lines.push(format!("  {}. {}", i + 1, url));
    }
    lines.join("\n")
}

async fn handle_index_info() -> Result<String> {
    let regs = skill_hub::default_registries();
    if regs.is_empty() {
        return Ok("No registries configured (set CHUMP_SKILL_REGISTRIES).".to_string());
    }
    if crate::env_flags::chump_air_gap_mode() {
        return Ok(format!(
            "{} registries configured but CHUMP_AIR_GAP_MODE is set; status checks skipped.",
            regs.len()
        ));
    }
    let mut lines = vec!["Registry status:".to_string()];
    for url in &regs {
        match skill_hub::fetch_index(url).await {
            Ok(idx) => lines.push(format!("  OK   {} ({} skills)", url, idx.skills.len())),
            Err(e) => lines.push(format!("  FAIL {} — {}", url, e)),
        }
    }
    Ok(lines.join("\n"))
}

async fn handle_search(query: &str) -> Result<String> {
    let regs = skill_hub::default_registries();
    if regs.is_empty() {
        return Ok("No registries configured (set CHUMP_SKILL_REGISTRIES).".to_string());
    }
    if crate::env_flags::chump_air_gap_mode() {
        return Ok("CHUMP_AIR_GAP_MODE is set; cannot search remote registries.".to_string());
    }
    let q = query.to_ascii_lowercase();
    let mut hits: Vec<(String, SkillHubEntry)> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    for url in &regs {
        match skill_hub::fetch_index(url).await {
            Ok(idx) => {
                for entry in idx.skills {
                    if matches_query(&entry, &q) {
                        hits.push((url.clone(), entry));
                    }
                }
            }
            Err(e) => errors.push(format!("  ! {}: {}", url, e)),
        }
    }
    if hits.is_empty() {
        let mut msg = format!(
            "No skills matching '{}' across {} registry(ies).",
            query,
            regs.len()
        );
        if !errors.is_empty() {
            msg.push_str("\n");
            msg.push_str(&errors.join("\n"));
        }
        return Ok(msg);
    }
    let mut lines = vec![format!("Found {} matching skill(s):", hits.len())];
    for (registry, entry) in &hits {
        lines.push(format!(
            "  - {} (v{}) [{}] — {}\n      from {}",
            entry.name,
            entry.version,
            entry.category.as_deref().unwrap_or("general"),
            entry.description,
            registry
        ));
    }
    if !errors.is_empty() {
        lines.push(String::new());
        lines.push("Registry errors:".to_string());
        lines.extend(errors);
    }
    Ok(lines.join("\n"))
}

fn matches_query(entry: &SkillHubEntry, q_lower: &str) -> bool {
    if q_lower.is_empty() {
        return true;
    }
    if entry.name.to_ascii_lowercase().contains(q_lower) {
        return true;
    }
    if entry.description.to_ascii_lowercase().contains(q_lower) {
        return true;
    }
    if entry
        .tags
        .iter()
        .any(|t| t.to_ascii_lowercase().contains(q_lower))
    {
        return true;
    }
    if let Some(cat) = &entry.category {
        if cat.to_ascii_lowercase().contains(q_lower) {
            return true;
        }
    }
    false
}

async fn handle_install(name: &str) -> Result<String> {
    let regs = skill_hub::default_registries();
    if regs.is_empty() {
        return Ok("No registries configured (set CHUMP_SKILL_REGISTRIES).".to_string());
    }
    if crate::env_flags::chump_air_gap_mode() {
        return Err(anyhow!(
            "CHUMP_AIR_GAP_MODE is set; cannot install from registry"
        ));
    }
    let mut last_err: Option<String> = None;
    for url in &regs {
        let idx: SkillHubIndex = match skill_hub::fetch_index(url).await {
            Ok(i) => i,
            Err(e) => {
                last_err = Some(format!("{}: {}", url, e));
                continue;
            }
        };
        if let Some(entry) = idx.skills.into_iter().find(|e| e.name == name) {
            let path = skill_hub::install_skill(&entry).await?;
            let report =
                skill_hub::security_scan(&skill_hub::fetch_skill(&entry).await.unwrap_or_default())
                    .ok();
            let warn_str = match report {
                Some(r) if !r.warnings.is_empty() => format!(
                    "\n\nSecurity warnings ({}):\n  - {}",
                    r.warnings.len(),
                    r.warnings.join("\n  - ")
                ),
                _ => String::new(),
            };
            return Ok(format!(
                "Installed skill '{}' from {} to {}.{}",
                entry.name,
                url,
                path.display(),
                warn_str
            ));
        }
    }
    let mut msg = format!(
        "No skill named '{}' found in any configured registry.",
        name
    );
    if let Some(e) = last_err {
        msg.push_str(&format!(" Last registry error: {}", e));
    }
    Ok(msg)
}

async fn handle_install_url(url: &str) -> Result<String> {
    if crate::env_flags::chump_air_gap_mode() {
        return Err(anyhow!(
            "CHUMP_AIR_GAP_MODE is set; cannot install from URL"
        ));
    }
    let path = skill_hub::install_from_url(url).await?;
    Ok(format!(
        "Installed skill from {} to {}.",
        url,
        path.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_validates() {
        let tool = SkillHubTool::new();
        let schema = tool.input_schema();
        assert!(schema.get("properties").is_some());
        assert!(schema
            .get("required")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().any(|v| v.as_str() == Some("action")))
            .unwrap_or(false));
    }

    #[tokio::test]
    async fn unknown_action_returns_message() {
        let tool = SkillHubTool::new();
        let result = tool.execute(json!({"action": "blarg"})).await.unwrap();
        assert!(result.contains("Unknown action"));
    }

    #[tokio::test]
    async fn list_registries_when_empty() {
        std::env::remove_var("CHUMP_SKILL_REGISTRIES");
        let tool = SkillHubTool::new();
        let result = tool
            .execute(json!({"action": "list_registries"}))
            .await
            .unwrap();
        assert!(result.contains("No skill registries"));
    }

    #[tokio::test]
    async fn search_requires_query() {
        let tool = SkillHubTool::new();
        let err = tool.execute(json!({"action": "search"})).await.unwrap_err();
        assert!(err.to_string().contains("query"));
    }

    #[tokio::test]
    async fn install_requires_name() {
        let tool = SkillHubTool::new();
        let err = tool
            .execute(json!({"action": "install"}))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("name"));
    }

    #[test]
    fn matches_query_basic() {
        let entry = SkillHubEntry {
            name: "fix-clippy".into(),
            description: "Resolve Rust clippy warnings".into(),
            version: "1".into(),
            author: None,
            source_url: String::new(),
            tags: vec!["rust".into(), "lint".into()],
            category: Some("code-quality".into()),
            checksum_sha256: None,
            inline_content: None,
        };
        assert!(matches_query(&entry, "clippy"));
        assert!(matches_query(&entry, "rust"));
        assert!(matches_query(&entry, "code-quality"));
        assert!(matches_query(&entry, "warning"));
        assert!(!matches_query(&entry, "python"));
    }
}
