//! Web search via Tavily API. Use for research and self-improvement; credits are limited (e.g. 1000/month).
//! Set TAVILY_API_KEY to enable. Supports search_depth (basic|fast|ultra-fast|advanced), topic (general|news|finance), max_results.
//! See https://docs.tavily.com/documentation/api-reference/endpoint/search

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde::Deserialize;
use serde_json::{json, Value};

fn tavily_available() -> bool {
    std::env::var("TAVILY_API_KEY")
        .map(|k| !k.trim().is_empty())
        .unwrap_or(false)
}

#[derive(Debug, Deserialize)]
struct TavilyResponse {
    results: Option<Vec<TavilyResult>>,
    answer: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TavilyResult {
    title: Option<String>,
    url: Option<String>,
    content: Option<String>,
}

/// Allowed search_depth values per Tavily API (basic/fast/ultra-fast = 1 credit, advanced = 2).
fn parse_search_depth(v: Option<&Value>) -> &'static str {
    match v.and_then(Value::as_str) {
        Some("advanced") => "advanced",
        Some("fast") => "fast",
        Some("ultra-fast") => "ultra-fast",
        _ => "basic",
    }
}

/// Allowed topic values: general, news, finance.
fn parse_topic(v: Option<&Value>) -> &'static str {
    match v.and_then(Value::as_str) {
        Some("news") => "news",
        Some("finance") => "finance",
        _ => "general",
    }
}

pub struct TavilyTool;

#[async_trait]
impl Tool for TavilyTool {
    fn name(&self) -> String {
        "web_search".to_string()
    }

    fn description(&self) -> String {
        "Search the web for current information. Use for research, fact-checking, and self-improvement. \
         Params: query (required). Optional: search_depth (basic|fast|ultra-fast|advanced; basic=1 credit, advanced=2), \
         topic (general|news|finance), max_results (1-20). Use sparingly; we have limited monthly credits.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "query": { "type": "string", "description": "Search query" },
                "search_depth": { "type": "string", "description": "basic (default), fast, ultra-fast, or advanced (2 credits)" },
                "topic": { "type": "string", "description": "general (default), news, or finance" },
                "max_results": { "type": "integer", "description": "Max results 1-20 (default 5)" }
            },
            "required": ["query"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let query = input
            .get("query")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        if query.is_empty() {
            return Ok("Error: query is required.".to_string());
        }

        let key = std::env::var("TAVILY_API_KEY")
            .map_err(|_| anyhow!("TAVILY_API_KEY is not set"))?
            .trim()
            .to_string();
        if key.is_empty() {
            return Ok("Error: TAVILY_API_KEY is empty.".to_string());
        }

        let search_depth = parse_search_depth(input.get("search_depth"));
        let topic = parse_topic(input.get("topic"));
        let max_results = input
            .get("max_results")
            .and_then(|v| v.as_u64())
            .map(|n| n.clamp(1, 20) as u32)
            .unwrap_or(5);

        let client = reqwest::Client::new();
        let body = serde_json::json!({
            "query": query,
            "search_depth": search_depth,
            "topic": topic,
            "max_results": max_results
        });
        let res = client
            .post("https://api.tavily.com/search")
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", key))
            .json(&body)
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Ok(format!("Tavily API error {}: {}", status, text));
        }

        let data: TavilyResponse = res.json().await?;
        let mut out = String::new();
        if let Some(answer) = data.answer {
            if !answer.is_empty() {
                out.push_str("Answer: ");
                out.push_str(&answer);
                out.push_str("\n\n");
            }
        }
        if let Some(results) = data.results {
            if !results.is_empty() {
                out.push_str("Sources:\n");
                for (i, r) in results.iter().enumerate() {
                    let title = r.title.as_deref().unwrap_or("(no title)");
                    let url = r.url.as_deref().unwrap_or("");
                    let content = r.content.as_deref().unwrap_or("").trim();
                    if !content.is_empty() {
                        let snippet: String = content.chars().take(300).collect();
                        out.push_str(&format!("{}. {} | {}\n   {}", i + 1, title, url, snippet));
                        if content.len() > 300 {
                            out.push('…');
                        }
                        out.push('\n');
                    } else {
                        out.push_str(&format!("{}. {} | {}\n", i + 1, title, url));
                    }
                }
            }
        }
        if out.is_empty() {
            out = "No results for that query.".to_string();
        }
        Ok(out.trim().to_string())
    }
}

pub fn tavily_enabled() -> bool {
    tavily_available()
}
