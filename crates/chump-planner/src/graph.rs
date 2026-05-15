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

    /// INFRA-1281: topological layer of each open gap.
    ///
    /// Layer 0 = no open prerequisites (foundation). Layer N = `max(layer(prereq)) + 1`
    /// over all open Blocks-prereqs. Closed gaps are skipped — only the open
    /// subgraph matters for the picker's tier ordering.
    ///
    /// Computation: BFS from open roots (no open prereqs) propagating
    /// monotonically-increasing depth. Re-relaxation handles diamonds where
    /// a node has two prereqs on different paths.
    pub fn layers(&self, open_set: &HashSet<GapId>) -> HashMap<GapId, u32> {
        let mut layer: HashMap<GapId, u32> = HashMap::new();
        // Seed: every open gap with zero open prereqs is layer 0.
        for id in open_set {
            if self.open_prerequisites(id, open_set).is_empty() {
                layer.insert(id.clone(), 0);
            }
        }
        // Iterative relaxation: walk every open gap in topological order
        // and set its layer = 1 + max(layer of open prereqs). Bounded by
        // V iterations even with diamonds.
        let Ok(order) = self.topo_order() else {
            return layer;
        };
        for id in &order {
            if !open_set.contains(id) {
                continue;
            }
            let prereqs = self.open_prerequisites(id, open_set);
            if prereqs.is_empty() {
                layer.entry(id.clone()).or_insert(0);
                continue;
            }
            let max_pre = prereqs
                .iter()
                .filter_map(|p| layer.get(p).copied())
                .max()
                .unwrap_or(0);
            layer.insert(id.clone(), max_pre + 1);
        }
        layer
    }

    /// INFRA-1281: critical-path days from each open gap forward through its
    /// dependent chain to a leaf, weighted by `Effort::days()`.
    ///
    /// For a leaf X: `cpd(X) = X.effort.days()`.
    /// For an inner X: `cpd(X) = X.effort.days() + max(cpd(Y) for Y in open dependents)`.
    ///
    /// Picker semantics: a gap with a long CPD gates a long downstream chain
    /// — picking it first compresses fleet wall-clock more than picking a
    /// leaf with the same effort. Combined with `layer`, the picker can
    /// enforce: "no two workers on the same layer until the foundation
    /// layer is drained" while still preferring high-CPD work within a tier.
    pub fn critical_path_days(
        &self,
        gaps: &[Gap],
        open_set: &HashSet<GapId>,
    ) -> HashMap<GapId, f32> {
        let by_id: HashMap<&GapId, &Gap> = gaps.iter().map(|g| (&g.id, g)).collect();
        let mut memo: HashMap<GapId, f32> = HashMap::new();
        // Walk in REVERSE topological order so dependents are computed before
        // their prereqs. petgraph's topo_order returns deps-first; reverse it.
        let Ok(order) = self.topo_order() else {
            return memo;
        };
        for id in order.iter().rev() {
            if !open_set.contains(id) {
                continue;
            }
            let Some(gap) = by_id.get(id) else { continue };
            let self_days = gap.effort.days();
            // dependents = open Blocks-successors of `id`
            let dependents = self.unblocks(id, open_set);
            // unblocks is transitive; we only want DIRECT dependents for the
            // recurrence (otherwise we'd double-count). Recompute as direct:
            let direct: Vec<GapId> = {
                let Some(&idx) = self.index.get(id) else {
                    continue;
                };
                let mut out = Vec::new();
                for edge in self
                    .graph
                    .edges_directed(idx, petgraph::Direction::Outgoing)
                {
                    if *edge.weight() != Relation::Blocks {
                        continue;
                    }
                    let tgt_id = &self.graph[edge.target()];
                    if open_set.contains(tgt_id) {
                        out.push(tgt_id.clone());
                    }
                }
                out
            };
            // Use direct list for the recurrence; `dependents` (transitive) is
            // available if a future caller needs it.
            let _ = dependents; // suppress unused warning when callers don't need it
            let max_child = direct
                .iter()
                .filter_map(|c| memo.get(c).copied())
                .fold(0.0f32, |a, b| a.max(b));
            memo.insert(id.clone(), self_days + max_child);
        }
        memo
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

    // ── INFRA-1281: layer + critical_path_days helpers ──────────────────

    fn mk_e(id: &str, deps: Vec<&str>, effort: Effort) -> Gap {
        let mut g = mk(id, deps);
        g.effort = effort;
        g
    }

    #[test]
    fn layers_match_fixture_dag_from_design() {
        // Fixture from .chump-plans/INFRA-1281/01-design.md:
        //   1 (root, no deps, effort=m)
        //   ├── 2 (deps=[1], effort=s)
        //   ├── 3 (deps=[1], effort=s)
        //   │     └── 4 (deps=[3], effort=xs)
        //   └── 5 (isolated, no deps, effort=m)
        let gaps = vec![
            mk_e("INFRA-1", vec![], Effort::M),
            mk_e("INFRA-2", vec!["INFRA-1"], Effort::S),
            mk_e("INFRA-3", vec!["INFRA-1"], Effort::S),
            mk_e("INFRA-4", vec!["INFRA-3"], Effort::Xs),
            mk_e("INFRA-5", vec![], Effort::M),
        ];
        let g = DependencyGraph::build(&gaps);
        let open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();
        let layers = g.layers(&open);
        let get = |id: &str| *layers.get(&GapId(id.into())).unwrap_or(&u32::MAX);
        assert_eq!(get("INFRA-1"), 0, "INFRA-1: root");
        assert_eq!(get("INFRA-2"), 1, "INFRA-2: child of INFRA-1");
        assert_eq!(get("INFRA-3"), 1, "INFRA-3: child of INFRA-1");
        assert_eq!(get("INFRA-4"), 2, "INFRA-4: child of INFRA-3");
        assert_eq!(get("INFRA-5"), 0, "INFRA-5: isolated root");
    }

    #[test]
    fn critical_path_days_walks_longest_forward_chain() {
        let gaps = vec![
            mk_e("INFRA-1", vec![], Effort::M),           // 3.0d
            mk_e("INFRA-2", vec!["INFRA-1"], Effort::S),  // 1.0d
            mk_e("INFRA-3", vec!["INFRA-1"], Effort::S),  // 1.0d
            mk_e("INFRA-4", vec!["INFRA-3"], Effort::Xs), // 0.5d
            mk_e("INFRA-5", vec![], Effort::M),           // 3.0d
        ];
        let g = DependencyGraph::build(&gaps);
        let open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();
        let cpd = g.critical_path_days(&gaps, &open);
        let get = |id: &str| *cpd.get(&GapId(id.into())).unwrap_or(&-1.0);
        // Leaves (no open dependents): just self
        assert!((get("INFRA-2") - 1.0).abs() < 1e-4, "INFRA-2 leaf: 1.0d");
        assert!((get("INFRA-4") - 0.5).abs() < 1e-4, "INFRA-4 leaf: 0.5d");
        assert!(
            (get("INFRA-5") - 3.0).abs() < 1e-4,
            "INFRA-5 isolated: 3.0d"
        );
        // Inner: 3 = self(1.0) + max(cpd(4)=0.5) = 1.5
        assert!((get("INFRA-3") - 1.5).abs() < 1e-4, "INFRA-3 = 1.0 + 0.5");
        // Root: 1 = self(3.0) + max(cpd(2)=1.0, cpd(3)=1.5) = 4.5
        assert!((get("INFRA-1") - 4.5).abs() < 1e-4, "INFRA-1 = 3.0 + 1.5");
    }

    #[test]
    fn layers_skip_closed_prereqs() {
        // INFRA-3 depends on INFRA-1, but if INFRA-1 is closed it shouldn't
        // count as a prerequisite — INFRA-3 becomes layer 0 effectively.
        let gaps = vec![
            mk_e("INFRA-1", vec![], Effort::S),
            mk_e("INFRA-2", vec!["INFRA-1"], Effort::S),
            mk_e("INFRA-3", vec!["INFRA-1", "INFRA-2"], Effort::S),
        ];
        let g = DependencyGraph::build(&gaps);
        // Close INFRA-1 — leave INFRA-2 and INFRA-3 open.
        let mut open: HashSet<GapId> = gaps.iter().map(|x| x.id.clone()).collect();
        open.remove(&GapId("INFRA-1".into()));
        let layers = g.layers(&open);
        let get = |id: &str| *layers.get(&GapId(id.into())).unwrap_or(&u32::MAX);
        assert_eq!(
            get("INFRA-2"),
            0,
            "INFRA-2 has no OPEN prereqs after INFRA-1 closes"
        );
        assert_eq!(get("INFRA-3"), 1, "INFRA-3 still has open prereq INFRA-2");
        assert_eq!(
            layers.get(&GapId("INFRA-1".into())),
            None,
            "closed gap not in layer map"
        );
    }
}
