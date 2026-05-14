//! Dependency graph over gaps.
//!
//! Edge semantics:
//!   - `Relation::Blocks` (hard): target must close before source can ship.
//!     v0.1 source: only the `depends_on` YAML field.
//!   - `Relation::SeeAlso` (soft): advisory cross-reference. NEVER blocks
//!     dispatch. Surfaced for --explain and informational table columns.
//!
//! Cycle policy: detected cycles do not crash the planner. The full topo
//! order is reported as `Err(CycleError { gaps })` so the caller can
//! surface the cycle members; the planner falls back to a stable id-order
//! traversal for ranking purposes (a cycle is a registry bug — the answer
//! is to file META-CYCLE-DETECTED and let a human break it, not to silently
//! reorder the graph).

use crate::gap::{Gap, GapId};
use crate::parse::extract_see_also;
use petgraph::graph::{DiGraph, NodeIndex};
use petgraph::visit::EdgeRef;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Relation {
    Blocks,
    SeeAlso,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReferenceSource {
    /// `depends_on` structured YAML field.
    DependsOn,
    /// Free-text span — only used for SeeAlso.
    Field { name: &'static str, span: String },
}

#[derive(Debug, Clone)]
pub struct Reference {
    pub from: GapId,
    pub to: GapId,
    pub relation: Relation,
    pub source: ReferenceSource,
}

#[derive(Debug, thiserror::Error)]
#[error("dependency cycle detected: {gaps:?}")]
pub struct CycleError {
    pub gaps: Vec<GapId>,
}

impl CycleError {
    /// Stable identity for a cycle: SHA-256 of sorted member-IDs joined by
    /// `,`. The reconciler / META-CYCLE-DETECTED filer uses this so the
    /// same cycle does not refile every run.
    pub fn identity(&self) -> String {
        use sha2::{Digest, Sha256};
        let mut ids: Vec<String> = self.gaps.iter().map(|g| g.0.clone()).collect();
        ids.sort();
        let joined = ids.join(",");
        let digest = Sha256::digest(joined.as_bytes());
        format!("{digest:x}")
    }
}

pub struct DependencyGraph {
    graph: DiGraph<GapId, Relation>,
    index: HashMap<GapId, NodeIndex>,
    refs: Vec<Reference>,
}

impl DependencyGraph {
    pub fn build(gaps: &[Gap]) -> Self {
        let mut graph: DiGraph<GapId, Relation> = DiGraph::new();
        let mut index: HashMap<GapId, NodeIndex> = HashMap::new();

        for g in gaps {
            let idx = graph.add_node(g.id.clone());
            index.insert(g.id.clone(), idx);
        }

        let mut refs: Vec<Reference> = Vec::new();
        let known: HashSet<GapId> = index.keys().cloned().collect();

        for g in gaps {
            let from_idx = index[&g.id];

            // Hard edges from structured `depends_on`. Convention used
            // throughout chump: "A depends_on B" → B blocks A → edge B -> A.
            for dep in &g.depends_on {
                if !known.contains(dep) {
                    // Dangling dep — keep the reference for surfacing but
                    // don't add a graph edge to a phantom node.
                    refs.push(Reference {
                        from: dep.clone(),
                        to: g.id.clone(),
                        relation: Relation::Blocks,
                        source: ReferenceSource::DependsOn,
                    });
                    continue;
                }
                let dep_idx = index[dep];
                graph.add_edge(dep_idx, from_idx, Relation::Blocks);
                refs.push(Reference {
                    from: dep.clone(),
                    to: g.id.clone(),
                    relation: Relation::Blocks,
                    source: ReferenceSource::DependsOn,
                });
            }

            // Soft edges from prose. Source → mentioned-id direction is
            // arbitrary; we keep "from = the gap whose text we read" so the
            // span attribution makes sense in --explain output.
            for m in extract_see_also(g) {
                if !known.contains(&m.target) {
                    continue;
                }
                let target_idx = index[&m.target];
                graph.add_edge(from_idx, target_idx, Relation::SeeAlso);
                refs.push(Reference {
                    from: g.id.clone(),
                    to: m.target,
                    relation: Relation::SeeAlso,
                    source: ReferenceSource::Field {
                        name: m.source_field,
                        span: m.source_span,
                    },
                });
            }
        }

        Self { graph, index, refs }
    }

    pub fn references(&self) -> &[Reference] {
        &self.refs
    }

    pub fn node_count(&self) -> usize {
        self.graph.node_count()
    }

    pub fn edge_count(&self) -> usize {
        self.graph.edge_count()
    }

    pub fn hard_edge_count(&self) -> usize {
        self.graph
            .edge_references()
            .filter(|e| *e.weight() == Relation::Blocks)
            .count()
    }

    /// Topological order over hard edges only. Returns Err with the cycle
    /// members if a cycle exists. The order ranks dependencies before
    /// dependents (i.e. `Blocks` predecessors come first).
    pub fn topo_order(&self) -> Result<Vec<GapId>, CycleError> {
        // Build a hard-only subgraph so SeeAlso edges never trip toposort.
        let hard = self.graph.filter_map(
            |_, n| Some(n.clone()),
            |_, &e| if e == Relation::Blocks { Some(e) } else { None },
        );

        match petgraph::algo::toposort(&hard, None) {
            Ok(order) => Ok(order.into_iter().map(|ix| hard[ix].clone()).collect()),
            Err(cycle) => {
                // toposort gives us one node in the cycle; expand via SCC to
                // recover the full member set.
                let sccs = petgraph::algo::tarjan_scc(&hard);
                let cycle_node = hard[cycle.node_id()].clone();
                let members: Vec<GapId> = sccs
                    .into_iter()
                    .find(|comp| comp.iter().any(|ix| hard[*ix] == cycle_node))
                    .map(|comp| comp.into_iter().map(|ix| hard[ix].clone()).collect())
                    .unwrap_or_else(|| vec![cycle_node]);
                Err(CycleError { gaps: members })
            }
        }
    }

    /// Hard predecessors that are still in `open_set`. A gap whose
    /// prerequisites are all closed is "pickable" from a dependency POV.
    pub fn open_prerequisites(&self, id: &GapId, open_set: &HashSet<GapId>) -> Vec<GapId> {
        let Some(&idx) = self.index.get(id) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for edge in self
            .graph
            .edges_directed(idx, petgraph::Direction::Incoming)
        {
            if *edge.weight() != Relation::Blocks {
                continue;
            }
            let pred = &self.graph[edge.source()];
            if open_set.contains(pred) {
                out.push(pred.clone());
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out.dedup();
        out
    }

    /// Hard successors still in `open_set` — i.e. open gaps that would
    /// become unblocked if `id` closed. Transitive closure: closing one
    /// node may unblock a chain.
    pub fn unblocks(&self, id: &GapId, open_set: &HashSet<GapId>) -> HashSet<GapId> {
        let Some(&start) = self.index.get(id) else {
            return HashSet::new();
        };
        let mut out = HashSet::new();
        let mut stack = vec![start];
        let mut seen: HashSet<NodeIndex> = HashSet::from([start]);
        while let Some(node) = stack.pop() {
            for edge in self
                .graph
                .edges_directed(node, petgraph::Direction::Outgoing)
            {
                if *edge.weight() != Relation::Blocks {
                    continue;
                }
                let tgt = edge.target();
                if !seen.insert(tgt) {
                    continue;
                }
                let tgt_id = &self.graph[tgt];
                if open_set.contains(tgt_id) {
                    out.insert(tgt_id.clone());
                    stack.push(tgt);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gap::{Domain, Effort, Priority, Status};

    fn mk(id: &str, deps: Vec<&str>) -> Gap {
        Gap {
            id: GapId(id.into()),
            domain: Domain::Infra,
            title: id.into(),
            status: Status::Open,
            priority: Priority::P1,
            effort: Effort::S,
            opened_date: None,
            closed_date: None,
            closed_pr: None,
            notes: None,
            description: None,
            acceptance_criteria: None,
            depends_on: deps.into_iter().map(|s| GapId(s.into())).collect(),
        }
    }

    #[test]
    fn topo_sort_orders_deps_before_dependents() {
        let gaps = vec![
            mk("INFRA-3", vec!["INFRA-2"]),
            mk("INFRA-2", vec!["INFRA-1"]),
            mk("INFRA-1", vec![]),
        ];
        let g = DependencyGraph::build(&gaps);
        let order = g.topo_order().unwrap();
        let pos = |id: &str| order.iter().position(|x| x.0 == id).unwrap();
        assert!(pos("INFRA-1") < pos("INFRA-2"));
        assert!(pos("INFRA-2") < pos("INFRA-3"));
    }

    #[test]
    fn cycle_detected_with_full_member_set() {
        let gaps = vec![
            mk("INFRA-A", vec!["INFRA-C"]),
            mk("INFRA-B", vec!["INFRA-A"]),
            mk("INFRA-C", vec!["INFRA-B"]),
        ];
        let g = DependencyGraph::build(&gaps);
        let err = g.topo_order().unwrap_err();
        let mut ids: Vec<String> = err.gaps.iter().map(|x| x.0.clone()).collect();
        ids.sort();
        assert_eq!(ids, vec!["INFRA-A", "INFRA-B", "INFRA-C"]);
        // Identity is stable across runs given the same members.
        let id1 = err.identity();
        assert_eq!(id1.len(), 64);
        let again = g.topo_order().unwrap_err().identity();
        assert_eq!(id1, again);
    }

    #[test]
    fn unblocks_counts_transitive() {
        let gaps = vec![
            mk("INFRA-3", vec!["INFRA-2"]),
            mk("INFRA-2", vec!["INFRA-1"]),
            mk("INFRA-1", vec![]),
            mk("INFRA-9", vec![]),
        ];
        let g = DependencyGraph::build(&gaps);
        let open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();
        let unblocked = g.unblocks(&GapId("INFRA-1".into()), &open);
        // Closing INFRA-1 unblocks INFRA-2 directly and INFRA-3 transitively.
        assert!(unblocked.contains(&GapId("INFRA-2".into())));
        assert!(unblocked.contains(&GapId("INFRA-3".into())));
        assert!(!unblocked.contains(&GapId("INFRA-9".into())));
    }

    #[test]
    fn dangling_depends_on_does_not_crash() {
        let gaps = vec![mk("INFRA-1", vec!["INFRA-DOES-NOT-EXIST"])];
        let g = DependencyGraph::build(&gaps);
        assert!(g.topo_order().is_ok());
    }
}
