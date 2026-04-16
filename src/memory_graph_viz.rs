//! Memory graph visualization: export the entity-relation knowledge graph
//! as JSON, Graphviz DOT, or a connected subgraph for inspection.
//!
//! Built on top of `memory_graph.rs`. Read-only — no mutations to the graph table.
//! Phase 2.3 of the Hermes competitive roadmap: makes Chump's multi-hop
//! associative recall capability concrete and demoable.

use anyhow::Result;
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};

/// Row from the `chump_memory_graph` table.
#[derive(Debug, Clone)]
pub struct Edge {
    pub subject: String,
    pub relation: String,
    pub object: String,
    pub weight: f64,
}

/// Aggregate stats over the memory graph.
#[derive(Debug, Clone, Serialize)]
pub struct GraphStats {
    pub node_count: usize,
    pub edge_count: usize,
    pub connected_components: usize,
    pub avg_degree: f64,
    /// Top entities by total degree (incoming + outgoing), name + degree, max 10.
    pub top_entities: Vec<(String, usize)>,
}

#[derive(Debug, Clone, Serialize)]
struct JsonNode {
    id: String,
    degree: usize,
}

#[derive(Debug, Clone, Serialize)]
struct JsonEdge {
    source: String,
    target: String,
    relation: String,
    weight: f64,
}

#[derive(Debug, Clone, Serialize)]
struct JsonGraph {
    nodes: Vec<JsonNode>,
    edges: Vec<JsonEdge>,
}

/// Load all edges from the memory graph. Returns empty vec if the table
/// is empty or doesn't exist.
fn load_all_edges() -> Result<Vec<Edge>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = match conn.prepare(
        "SELECT subject, relation, object, weight FROM chump_memory_graph",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(Vec::new()),
    };
    let rows = stmt.query_map([], |r| {
        Ok(Edge {
            subject: r.get::<_, String>(0)?,
            relation: r.get::<_, String>(1)?,
            object: r.get::<_, String>(2)?,
            weight: r.get::<_, f64>(3)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Compute per-node degree (incoming + outgoing).
fn compute_degrees(edges: &[Edge]) -> HashMap<String, usize> {
    let mut deg: HashMap<String, usize> = HashMap::new();
    for e in edges {
        *deg.entry(e.subject.clone()).or_default() += 1;
        *deg.entry(e.object.clone()).or_default() += 1;
    }
    deg
}

/// Count connected components via BFS over the undirected projection.
fn count_components(edges: &[Edge], all_nodes: &HashSet<String>) -> usize {
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    for e in edges {
        adj.entry(e.subject.as_str())
            .or_default()
            .push(e.object.as_str());
        adj.entry(e.object.as_str())
            .or_default()
            .push(e.subject.as_str());
    }
    let mut visited: HashSet<&str> = HashSet::new();
    let mut components = 0usize;
    for n in all_nodes {
        if visited.contains(n.as_str()) {
            continue;
        }
        components += 1;
        let mut q: VecDeque<&str> = VecDeque::new();
        q.push_back(n.as_str());
        visited.insert(n.as_str());
        while let Some(cur) = q.pop_front() {
            if let Some(neighbors) = adj.get(cur) {
                for nb in neighbors {
                    if !visited.contains(nb) {
                        visited.insert(nb);
                        q.push_back(nb);
                    }
                }
            }
        }
    }
    components
}

/// Compute aggregate stats. Empty graph returns zeros and empty top_entities.
pub fn graph_stats() -> Result<GraphStats> {
    let edges = load_all_edges()?;
    if edges.is_empty() {
        return Ok(GraphStats {
            node_count: 0,
            edge_count: 0,
            connected_components: 0,
            avg_degree: 0.0,
            top_entities: Vec::new(),
        });
    }
    let degrees = compute_degrees(&edges);
    let nodes: HashSet<String> = degrees.keys().cloned().collect();
    let node_count = nodes.len();
    let edge_count = edges.len();
    let avg_degree = if node_count == 0 {
        0.0
    } else {
        // Each edge contributes 2 to total degree.
        (2.0 * edge_count as f64) / node_count as f64
    };
    let components = count_components(&edges, &nodes);

    let mut top: Vec<(String, usize)> = degrees.into_iter().collect();
    top.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    top.truncate(10);

    Ok(GraphStats {
        node_count,
        edge_count,
        connected_components: components,
        avg_degree,
        top_entities: top,
    })
}

fn build_json_graph(edges: &[Edge]) -> JsonGraph {
    let degrees = compute_degrees(edges);
    let mut nodes: Vec<JsonNode> = degrees
        .into_iter()
        .map(|(id, degree)| JsonNode { id, degree })
        .collect();
    nodes.sort_by(|a, b| b.degree.cmp(&a.degree).then_with(|| a.id.cmp(&b.id)));

    let json_edges: Vec<JsonEdge> = edges
        .iter()
        .map(|e| JsonEdge {
            source: e.subject.clone(),
            target: e.object.clone(),
            relation: e.relation.clone(),
            weight: e.weight,
        })
        .collect();

    JsonGraph {
        nodes,
        edges: json_edges,
    }
}

/// Export the full graph as JSON: `{"nodes": [{"id", "degree"}], "edges": [...]}`.
pub fn export_graph_json() -> Result<String> {
    let edges = load_all_edges()?;
    let graph = build_json_graph(&edges);
    Ok(serde_json::to_string(&graph)?)
}

/// Escape a string for safe inclusion as a DOT node ID or label.
fn dot_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn build_dot(edges: &[Edge]) -> String {
    let mut out = String::new();
    out.push_str("digraph chump_memory_graph {\n");
    out.push_str("  rankdir=LR;\n");
    out.push_str("  node [shape=box, style=rounded, fontname=\"Helvetica\"];\n");
    out.push_str("  edge [fontname=\"Helvetica\", fontsize=10];\n");

    let mut nodes: HashSet<&str> = HashSet::new();
    for e in edges {
        nodes.insert(e.subject.as_str());
        nodes.insert(e.object.as_str());
    }
    let mut sorted: Vec<&&str> = nodes.iter().collect();
    sorted.sort();
    for n in sorted {
        out.push_str(&format!("  \"{}\";\n", dot_escape(n)));
    }
    for e in edges {
        out.push_str(&format!(
            "  \"{}\" -> \"{}\" [label=\"{}\", weight={:.2}];\n",
            dot_escape(&e.subject),
            dot_escape(&e.object),
            dot_escape(&e.relation),
            e.weight,
        ));
    }
    out.push_str("}\n");
    out
}

/// Export the full graph as Graphviz DOT.
pub fn export_graph_dot() -> Result<String> {
    let edges = load_all_edges()?;
    Ok(build_dot(&edges))
}

/// BFS over the undirected projection from seeds, collecting all nodes within `max_hops`.
fn bfs_subgraph_nodes(edges: &[Edge], seeds: &[String], max_hops: usize) -> HashSet<String> {
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    for e in edges {
        adj.entry(e.subject.as_str())
            .or_default()
            .push(e.object.as_str());
        adj.entry(e.object.as_str())
            .or_default()
            .push(e.subject.as_str());
    }
    let mut visited: HashSet<String> = HashSet::new();
    let mut q: VecDeque<(String, usize)> = VecDeque::new();
    for s in seeds {
        let s_lower = s.to_lowercase();
        if !visited.contains(&s_lower) {
            visited.insert(s_lower.clone());
            q.push_back((s_lower, 0));
        }
    }
    while let Some((cur, hop)) = q.pop_front() {
        if hop >= max_hops {
            continue;
        }
        if let Some(neighbors) = adj.get(cur.as_str()) {
            for nb in neighbors {
                if !visited.contains(*nb) {
                    visited.insert(nb.to_string());
                    q.push_back((nb.to_string(), hop + 1));
                }
            }
        }
    }
    visited
}

/// Export the connected subgraph reachable from `seed_entities` within `max_hops`
/// (undirected projection for reachability) as JSON.
pub fn export_subgraph_json(seed_entities: &[String], max_hops: usize) -> Result<String> {
    let edges = load_all_edges()?;
    if seed_entities.is_empty() || edges.is_empty() {
        let g = JsonGraph {
            nodes: Vec::new(),
            edges: Vec::new(),
        };
        return Ok(serde_json::to_string(&g)?);
    }
    let in_set = bfs_subgraph_nodes(&edges, seed_entities, max_hops);
    let kept: Vec<Edge> = edges
        .into_iter()
        .filter(|e| in_set.contains(&e.subject) && in_set.contains(&e.object))
        .collect();
    let graph = build_json_graph(&kept);
    Ok(serde_json::to_string(&graph)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_graph_stats_are_zero() {
        // Build stats from zero edges directly; doesn't depend on DB state.
        let edges: Vec<Edge> = Vec::new();
        let degrees = compute_degrees(&edges);
        assert!(degrees.is_empty());
        let nodes: HashSet<String> = HashSet::new();
        assert_eq!(count_components(&edges, &nodes), 0);
    }

    #[test]
    fn json_serialization_roundtrip_smoke() {
        let edges = vec![
            Edge {
                subject: "alice".into(),
                relation: "uses".into(),
                object: "rust".into(),
                weight: 1.0,
            },
            Edge {
                subject: "rust".into(),
                relation: "in_project".into(),
                object: "chump".into(),
                weight: 2.5,
            },
        ];
        let g = build_json_graph(&edges);
        let s = serde_json::to_string(&g).unwrap();
        assert!(s.contains("\"alice\""));
        assert!(s.contains("\"chump\""));
        assert!(s.contains("\"uses\""));
        // alice degree 1, rust degree 2, chump degree 1
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        let nodes = v.get("nodes").and_then(|n| n.as_array()).unwrap();
        assert_eq!(nodes.len(), 3);
        let edges = v.get("edges").and_then(|n| n.as_array()).unwrap();
        assert_eq!(edges.len(), 2);
    }

    #[test]
    fn dot_smoke() {
        let edges = vec![Edge {
            subject: "alice".into(),
            relation: "knows".into(),
            object: "bob".into(),
            weight: 1.0,
        }];
        let dot = build_dot(&edges);
        assert!(dot.starts_with("digraph"));
        assert!(dot.contains("\"alice\" -> \"bob\""));
        assert!(dot.contains("label=\"knows\""));
    }

    #[test]
    fn dot_escapes_quotes() {
        let edges = vec![Edge {
            subject: "x\"y".into(),
            relation: "r".into(),
            object: "z".into(),
            weight: 1.0,
        }];
        let dot = build_dot(&edges);
        assert!(dot.contains("x\\\"y"));
    }

    #[test]
    fn bfs_subgraph_respects_hops() {
        let edges = vec![
            Edge {
                subject: "a".into(),
                relation: "r".into(),
                object: "b".into(),
                weight: 1.0,
            },
            Edge {
                subject: "b".into(),
                relation: "r".into(),
                object: "c".into(),
                weight: 1.0,
            },
            Edge {
                subject: "c".into(),
                relation: "r".into(),
                object: "d".into(),
                weight: 1.0,
            },
        ];
        let one = bfs_subgraph_nodes(&edges, &["a".to_string()], 1);
        assert!(one.contains("a") && one.contains("b"));
        assert!(!one.contains("c"));
        let two = bfs_subgraph_nodes(&edges, &["a".to_string()], 2);
        assert!(two.contains("c"));
        assert!(!two.contains("d"));
    }

    #[test]
    fn components_count_disconnected() {
        let edges = vec![
            Edge {
                subject: "a".into(),
                relation: "r".into(),
                object: "b".into(),
                weight: 1.0,
            },
            Edge {
                subject: "x".into(),
                relation: "r".into(),
                object: "y".into(),
                weight: 1.0,
            },
        ];
        let degrees = compute_degrees(&edges);
        let nodes: HashSet<String> = degrees.keys().cloned().collect();
        assert_eq!(count_components(&edges, &nodes), 2);
    }

    #[test]
    fn top_entities_ranks_by_degree() {
        let edges = vec![
            Edge {
                subject: "hub".into(),
                relation: "r".into(),
                object: "a".into(),
                weight: 1.0,
            },
            Edge {
                subject: "hub".into(),
                relation: "r".into(),
                object: "b".into(),
                weight: 1.0,
            },
            Edge {
                subject: "hub".into(),
                relation: "r".into(),
                object: "c".into(),
                weight: 1.0,
            },
        ];
        let degrees = compute_degrees(&edges);
        let mut top: Vec<(String, usize)> = degrees.into_iter().collect();
        top.sort_by(|a, b| b.1.cmp(&a.1));
        assert_eq!(top[0].0, "hub");
        assert_eq!(top[0].1, 3);
    }
}
