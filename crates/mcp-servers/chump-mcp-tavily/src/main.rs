//! MCP server: Tavily web search via JSON-RPC 2.0 over stdio.
//! Set TAVILY_API_KEY to enable. Supports search_depth, topic, max_results.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    result: Option<Value>,
    error: Option<JsonRpcError>,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
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

fn parse_search_depth(v: Option<&Value>) -> &'static str {
    match v.and_then(Value::as_str) {
        Some("advanced") => "advanced",
        Some("fast") => "fast",
        Some("ultra-fast") => "ultra-fast",
        _ => "basic",
    }
}

fn parse_topic(v: Option<&Value>) -> &'static str {
    match v.and_then(Value::as_str) {
        Some("news") => "news",
        Some("finance") => "finance",
        _ => "general",
    }
}

async fn handle_web_search(params: &Value) -> Result<Value> {
    let query = params["query"]
        .as_str()
        .ok_or_else(|| anyhow!("missing query"))?
        .trim();
    if query.is_empty() {
        return Err(anyhow!("query is empty"));
    }

    let key = std::env::var("TAVILY_API_KEY")
        .map_err(|_| anyhow!("TAVILY_API_KEY is not set"))?
        .trim()
        .to_string();
    if key.is_empty() {
        return Err(anyhow!("TAVILY_API_KEY is empty"));
    }

    let search_depth = parse_search_depth(params.get("search_depth"));
    let topic = parse_topic(params.get("topic"));
    let max_results = params
        .get("max_results")
        .and_then(|v| v.as_u64())
        .map(|n| n.clamp(1, 20) as u32)
        .unwrap_or(5);

    let client = reqwest::Client::new();
    let body = json!({
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
        .await
        .map_err(|e| anyhow!("Tavily request failed: {}", e))?;

    if !res.status().is_success() {
        let status = res.status();
        let text = res.text().await.unwrap_or_default();
        return Ok(json!({ "success": false, "error": format!("Tavily API error {}: {}", status, text) }));
    }

    let data: TavilyResponse = res
        .json()
        .await
        .map_err(|e| anyhow!("parse Tavily response: {}", e))?;

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
                        out.push_str("...");
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

    Ok(json!({ "success": true, "output": out.trim() }))
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "web_search" => handle_web_search(params).await,
        "tools/list" => Ok(json!({
            "tools": [
                {
                    "name": "web_search",
                    "description": "Search the web for current information via Tavily. Params: query (required), search_depth (basic|fast|ultra-fast|advanced), topic (general|news|finance), max_results (1-20).",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "Search query" },
                            "search_depth": { "type": "string", "description": "basic (default), fast, ultra-fast, or advanced" },
                            "topic": { "type": "string", "description": "general (default), news, or finance" },
                            "max_results": { "type": "integer", "description": "Max results 1-20 (default 5)" }
                        },
                        "required": ["query"]
                    }
                }
            ]
        })),
        _ => Err(anyhow!("unknown method: {}", method)),
    }
}

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: JsonRpcRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("Parse error: {}", e),
                    }),
                    id: Value::Null,
                };
                println!("{}", serde_json::to_string(&err_resp).unwrap());
                continue;
            }
        };

        if req.jsonrpc != "2.0" {
            let err_resp = JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be \"2.0\"".to_string(),
                }),
                id: req.id,
            };
            println!("{}", serde_json::to_string(&err_resp).unwrap());
            continue;
        }

        let resp = match handle_method(&req.method, &req.params).await {
            Ok(result) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: Some(result),
                error: None,
                id: req.id,
            },
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32603,
                    message: e.to_string(),
                }),
                id: req.id,
            },
        };
        println!("{}", serde_json::to_string(&resp).unwrap());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_search_depth_defaults() {
        assert_eq!(parse_search_depth(None), "basic");
        assert_eq!(parse_search_depth(Some(&json!("advanced"))), "advanced");
        assert_eq!(parse_search_depth(Some(&json!("bogus"))), "basic");
    }

    #[test]
    fn parse_topic_defaults() {
        assert_eq!(parse_topic(None), "general");
        assert_eq!(parse_topic(Some(&json!("news"))), "news");
    }

    #[tokio::test]
    async fn tools_list_returns_web_search() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], "web_search");
    }
}
