//! `memory_graph_viz` tool: expose the memory graph for inspection and demo.
//!
//! Phase 2.3 (Hermes competitive roadmap). Hermes-Agent uses FTS5 only and cannot
//! resolve "Alice" == "my coworker Alice" or traverse multi-hop relations like
//! `Jeff -> uses -> Rust -> in_project -> X`. This tool surfaces the graph that
//! makes those queries possible.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::memory_graph;
use crate::memory_graph_viz;

pub struct MemoryGraphVizTool;

#[async_trait]
impl Tool for MemoryGraphVizTool {
    fn name(&self) -> String {
        "memory_graph_viz".to_string()
    }

    fn description(&self) -> String {
        "Inspect and export Chump's associative memory graph (entity-relation triples). \
         Demonstrates multi-hop recall capability that keyword search (FTS5) cannot do. \
         Actions: stats | export_dot | export_json | demo_queries."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "stats | export_dot | export_json | demo_queries"
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing action"))?
            .trim()
            .to_lowercase();

        match action.as_str() {
            "stats" => Ok(format_stats(memory_graph_viz::graph_stats()?)),
            "export_dot" => {
                let dot = memory_graph_viz::export_graph_dot()?;
                if dot.lines().count() <= 4 {
                    return Ok(
                        "Memory graph is empty. Add memories or episodes first so the graph can extract triples."
                            .to_string(),
                    );
                }
                Ok(dot)
            }
            "export_json" => {
                let s = memory_graph_viz::export_graph_json()?;
                let parsed: Value = serde_json::from_str(&s).unwrap_or(Value::Null);
                let nodes_empty = parsed
                    .get("nodes")
                    .and_then(|n| n.as_array())
                    .map(|a| a.is_empty())
                    .unwrap_or(true);
                if nodes_empty {
                    return Ok(
                        "Memory graph is empty. Add memories or episodes first so the graph can extract triples."
                            .to_string(),
                    );
                }
                Ok(s)
            }
            "demo_queries" => Ok(demo_queries()),
            other => Err(anyhow!("unknown action: {}", other)),
        }
    }
}

fn format_stats(s: memory_graph_viz::GraphStats) -> String {
    if s.node_count == 0 {
        return "Memory graph is empty. No triples have been extracted yet.\n\
                Add memories or episodes; relations will be extracted automatically."
            .to_string();
    }
    let mut out = String::new();
    out.push_str("Chump Memory Graph — Stats\n");
    out.push_str(&format!("  nodes:               {}\n", s.node_count));
    out.push_str(&format!("  edges:               {}\n", s.edge_count));
    out.push_str(&format!(
        "  connected components: {}\n",
        s.connected_components
    ));
    out.push_str(&format!("  avg degree:          {:.2}\n", s.avg_degree));
    if !s.top_entities.is_empty() {
        out.push_str("  top entities by degree:\n");
        for (name, deg) in &s.top_entities {
            out.push_str(&format!("    {:>4}  {}\n", deg, name));
        }
    }
    out
}

/// Curated demo queries that highlight multi-hop associative recall.
/// Each call resolves at runtime against the live graph so output reflects current state.
fn demo_queries() -> String {
    let queries: &[(&str, &str)] = &[
        (
            "what projects does Jeff use Rust for?",
            "Requires traversal: jeff -> uses -> rust -> in_project -> X. FTS5 would only find messages mentioning Jeff and Rust together.",
        ),
        (
            "who works on the same codebase as Alice?",
            "Requires shared-neighbor inference: alice -> contributes_to -> repo <- contributes_from <- people. FTS5 cannot reason about shared neighbors.",
        ),
        (
            "what tools does Chump depend on transitively?",
            "Requires multi-hop traversal of depends_on / requires / uses relations.",
        ),
        (
            "which entities are most central to Jeff's work?",
            "Requires Personalized PageRank seeded from 'jeff'. FTS5 has no notion of importance via graph structure.",
        ),
    ];

    let mut out = String::new();
    out.push_str("Memory Graph Demo Queries (multi-hop recall — FTS5 cannot do these)\n\n");

    let stats = memory_graph_viz::graph_stats().ok();
    let graph_empty = stats.as_ref().map(|s| s.node_count == 0).unwrap_or(true);
    if graph_empty {
        out.push_str("(Note: memory graph is currently empty. Examples below are illustrative.)\n\n");
    }

    for (i, (q, why)) in queries.iter().enumerate() {
        out.push_str(&format!("[{}] Query: {}\n", i + 1, q));
        out.push_str(&format!("    Why graph: {}\n", why));
        let entities = memory_graph::extract_query_entities(q);
        out.push_str(&format!("    Extracted entities: {:?}\n", entities));

        if !graph_empty && !entities.is_empty() {
            // 1-hop
            match memory_graph_viz::export_subgraph_json(&entities, 1) {
                Ok(s) => {
                    let n_edges = count_edges(&s);
                    out.push_str(&format!("    1-hop subgraph edges: {}\n", n_edges));
                }
                Err(e) => out.push_str(&format!("    1-hop error: {}\n", e)),
            }
            // 2-hop (PPR is the actual recall path)
            match memory_graph::associative_recall(&entities, 2, 5) {
                Ok(r) if !r.is_empty() => {
                    out.push_str("    2-hop PPR top results:\n");
                    for (name, score) in r {
                        out.push_str(&format!("      {:.3}  {}\n", score, name));
                    }
                }
                Ok(_) => out.push_str("    2-hop PPR: no associated entities found.\n"),
                Err(e) => out.push_str(&format!("    2-hop error: {}\n", e)),
            }
        } else {
            out.push_str("    (skip live execution — empty graph or no entities)\n");
        }
        out.push('\n');
    }
    out.push_str(
        "Compare to Hermes-Agent (FTS5): would return raw messages containing the query words.\n\
         Chump returns the *answer* (the connected entity) plus an evidence path.\n",
    );
    out
}

fn count_edges(json_str: &str) -> usize {
    serde_json::from_str::<Value>(json_str)
        .ok()
        .as_ref()
        .and_then(|v| v.get("edges"))
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn unknown_action_errors() {
        let t = MemoryGraphVizTool;
        let err = t
            .execute(json!({ "action": "bogus" }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("unknown action"));
    }

    #[tokio::test]
    async fn missing_action_errors() {
        let t = MemoryGraphVizTool;
        let err = t.execute(json!({})).await.unwrap_err();
        assert!(err.to_string().contains("missing action"));
    }

    #[test]
    fn format_stats_empty() {
        let s = memory_graph_viz::GraphStats {
            node_count: 0,
            edge_count: 0,
            connected_components: 0,
            avg_degree: 0.0,
            top_entities: vec![],
        };
        let out = format_stats(s);
        assert!(out.contains("empty"));
    }

    #[test]
    fn format_stats_populated() {
        let s = memory_graph_viz::GraphStats {
            node_count: 5,
            edge_count: 7,
            connected_components: 1,
            avg_degree: 2.8,
            top_entities: vec![("alice".into(), 4), ("rust".into(), 3)],
        };
        let out = format_stats(s);
        assert!(out.contains("nodes"));
        assert!(out.contains("alice"));
    }
}
