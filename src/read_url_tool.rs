//! Fetch a URL and return extracted text (strip nav/footer/ads). Optional CSS selector for targeted extraction.
//! Use for docs, GitHub READMEs, blog posts. Caps output to avoid flooding context.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use scraper::{Html, Selector};
use serde_json::{json, Value};

const DEFAULT_MAX_CHARS: usize = 50_000;

pub struct ReadUrlTool;

fn extract_text_from_html(html: &str, selector_opt: Option<&str>) -> Result<String> {
    let fragment = Html::parse_document(html);
    let body_sel = Selector::parse("body").map_err(|e| anyhow!("body selector: {}", e))?;

    let text = if let Some(sel_str) = selector_opt {
        let sel = Selector::parse(sel_str).map_err(|e| anyhow!("selector {:?}: {}", sel_str, e))?;
        fragment
            .select(&sel)
            .flat_map(|el| el.text().collect::<Vec<_>>())
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        // Prefer main content: main, article, [role="main"], .content, then body
        for try_sel in ["main", "article", "[role=\"main\"]", ".content", ".markdown-body", "#content", "body"] {
            if let Ok(s) = Selector::parse(try_sel) {
                let nodes: Vec<_> = fragment.select(&s).collect();
                if !nodes.is_empty() {
                    let out: String = nodes
                        .iter()
                        .flat_map(|el| el.text().collect::<Vec<_>>())
                        .collect::<Vec<_>>()
                        .join(" ");
                    let trimmed = out.trim();
                    if trimmed.len() > 100 {
                        return Ok(trimmed.to_string());
                    }
                }
            }
        }
        fragment
            .select(&body_sel)
            .flat_map(|el| el.text().collect::<Vec<_>>())
            .collect::<Vec<_>>()
            .join(" ")
    };

    let normalized = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    Ok(normalized.trim().to_string())
}

#[async_trait]
impl Tool for ReadUrlTool {
    fn name(&self) -> String {
        "read_url".to_string()
    }

    fn description(&self) -> String {
        "Fetch a URL and return extracted text content (stripped of nav/footer/ads). \
         Use for docs, GitHub READMEs, blog posts, Stack Overflow. \
         Params: url (required). Optional: selector (CSS selector for targeted extraction), max_chars (default 50000).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "url": { "type": "string", "description": "URL to fetch (https or http)" },
                "selector": { "type": "string", "description": "Optional CSS selector to extract only that element (e.g. main, .markdown-body)" },
                "max_chars": { "type": "integer", "description": "Max characters to return (default 50000)" }
            },
            "required": ["url"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let url = input
            .get("url")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("url is required"))?;
        let selector = input.get("selector").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
        let max_chars = input
            .get("max_chars")
            .and_then(|v| v.as_u64())
            .map(|n| n.clamp(1000, 200_000) as usize)
            .unwrap_or(DEFAULT_MAX_CHARS);

        let client = reqwest::Client::builder()
            .user_agent("Chump/1.0 (read_url)")
            .build()?;
        let res = client.get(url).send().await?;
        if !res.status().is_success() {
            return Ok(format!("HTTP {}: {}", res.status(), res.url()));
        }
        let body = res.text().await?;
        let extracted = extract_text_from_html(&body, selector)?;
        let out = if extracted.len() > max_chars {
            format!("{}… [truncated from {} chars]", &extracted[..max_chars], extracted.len())
        } else {
            extracted
        };
        Ok(out)
    }
}
